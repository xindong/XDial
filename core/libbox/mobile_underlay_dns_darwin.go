//go:build darwin && cgo

package libbox

/*
#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {
	char *output;
	size_t output_size;
	size_t output_length;
	uint32_t ttl;
	int32_t error_code;
	int answer_count;
	int done;
} xdial_underlay_dns_result;

static int64_t xdial_underlay_dns_now_millis(void) {
	struct timespec now;
	clock_gettime(CLOCK_MONOTONIC, &now);
	return ((int64_t)now.tv_sec * 1000) + (now.tv_nsec / 1000000);
}

static void xdial_underlay_dns_reply(
	DNSServiceRef sd_ref,
	DNSServiceFlags flags,
	uint32_t interface_index,
	DNSServiceErrorType error_code,
	const char *hostname,
	const struct sockaddr *address,
	uint32_t ttl,
	void *context
) {
	(void)sd_ref;
	(void)interface_index;
	(void)hostname;
	xdial_underlay_dns_result *result = (xdial_underlay_dns_result *)context;
	if (error_code != kDNSServiceErr_NoError) {
		if (error_code != kDNSServiceErr_NoSuchRecord || result->answer_count == 0) {
			result->error_code = error_code;
		}
		result->done = 1;
		return;
	}
	if ((flags & kDNSServiceFlagsAdd) != 0 && address != NULL) {
		char text[INET6_ADDRSTRLEN];
		const void *source = NULL;
		if (address->sa_family == AF_INET) {
			source = &((const struct sockaddr_in *)address)->sin_addr;
		} else if (address->sa_family == AF_INET6) {
			source = &((const struct sockaddr_in6 *)address)->sin6_addr;
		}
		if (source != NULL && inet_ntop(address->sa_family, source, text, sizeof(text)) != NULL) {
			size_t text_length = strlen(text);
			size_t separator = result->answer_count > 0 ? 1 : 0;
			if (result->output_length + separator + text_length + 1 <= result->output_size) {
				if (separator != 0) {
					result->output[result->output_length++] = '\n';
				}
				memcpy(result->output + result->output_length, text, text_length);
				result->output_length += text_length;
				result->output[result->output_length] = '\0';
				result->answer_count++;
				if (result->ttl == 0 || (ttl > 0 && ttl < result->ttl)) {
					result->ttl = ttl;
				}
			}
		}
	}
	if ((flags & kDNSServiceFlagsMoreComing) == 0) {
		result->done = 1;
	}
}

static int32_t xdial_underlay_dns_lookup(
	uint32_t interface_index,
	const char *hostname,
	uint32_t protocol,
	int timeout_millis,
	char *output,
	size_t output_size,
	uint32_t *ttl
) {
	if (interface_index == 0) {
		return kDNSServiceErr_BadParam;
	}
	xdial_underlay_dns_result result;
	memset(&result, 0, sizeof(result));
	result.output = output;
	result.output_size = output_size;
	if (output_size > 0) {
		output[0] = '\0';
	}

	DNSServiceRef service = NULL;
	DNSServiceErrorType start_error = DNSServiceGetAddrInfo(
		&service,
		kDNSServiceFlagsTimeout,
		interface_index,
		protocol,
		hostname,
		xdial_underlay_dns_reply,
		&result
	);
	if (start_error != kDNSServiceErr_NoError) {
		return start_error;
	}
	int socket_fd = DNSServiceRefSockFD(service);
	if (socket_fd < 0) {
		DNSServiceRefDeallocate(service);
		return kDNSServiceErr_BadReference;
	}

	int64_t deadline = xdial_underlay_dns_now_millis() + timeout_millis;
	while (!result.done) {
		int64_t remaining = deadline - xdial_underlay_dns_now_millis();
		if (remaining <= 0) {
			result.error_code = kDNSServiceErr_Timeout;
			break;
		}
		struct pollfd descriptor = {
			.fd = socket_fd,
			.events = POLLIN,
		};
		int poll_result = poll(&descriptor, 1, (int)remaining);
		if (poll_result == 0) {
			result.error_code = kDNSServiceErr_Timeout;
			break;
		}
		if (poll_result < 0) {
			if (errno == EINTR) {
				continue;
			}
			result.error_code = kDNSServiceErr_Unknown;
			break;
		}
		if ((descriptor.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0 && (descriptor.revents & POLLIN) == 0) {
			result.error_code = kDNSServiceErr_Unknown;
			break;
		}
		DNSServiceErrorType process_error = DNSServiceProcessResult(service);
		if (process_error != kDNSServiceErr_NoError) {
			result.error_code = process_error;
			break;
		}
	}
	DNSServiceRefDeallocate(service);
	if (ttl != NULL) {
		*ttl = result.ttl;
	}
	return result.error_code;
}
*/
import "C"

import (
	"context"
	"net/netip"
	"strings"
	"time"
	"unsafe"

	"github.com/sagernet/sing-box/dns"
	E "github.com/sagernet/sing/common/exceptions"

	mDNS "github.com/miekg/dns"
)

func mobileUnderlayUsesNativeScopedResolver() bool {
	return true
}

func darwinScopedDNSServiceLookup(
	ctx context.Context,
	interfaceIndex int,
	name string,
	qtype uint16,
	timeout time.Duration,
) (underlayLookupResult, error) {
	if err := ctx.Err(); err != nil {
		return underlayLookupResult{}, err
	}
	if interfaceIndex <= 0 {
		return underlayLookupResult{}, errMobileUnderlayDNSUnavailable
	}
	protocol := C.uint32_t(C.kDNSServiceProtocol_IPv4)
	if qtype == mDNS.TypeAAAA {
		protocol = C.uint32_t(C.kDNSServiceProtocol_IPv6)
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	buffer := make([]byte, mobileUnderlayDNSBufBytes)
	var ttl C.uint32_t
	code := int32(C.xdial_underlay_dns_lookup(
		C.uint32_t(interfaceIndex),
		cName,
		protocol,
		C.int(timeout.Milliseconds()),
		(*C.char)(unsafe.Pointer(&buffer[0])),
		C.size_t(len(buffer)),
		&ttl,
	))
	if err := ctx.Err(); err != nil {
		return underlayLookupResult{}, err
	}
	switch code {
	case int32(C.kDNSServiceErr_NoError):
	case int32(C.kDNSServiceErr_NoSuchName):
		return underlayLookupResult{}, dns.RcodeError(mDNS.RcodeNameError)
	case int32(C.kDNSServiceErr_NoSuchRecord):
		return underlayLookupResult{}, errMobileUnderlayDNSNoData
	case int32(C.kDNSServiceErr_Timeout):
		return underlayLookupResult{}, context.DeadlineExceeded
	default:
		return underlayLookupResult{}, E.New("underlay scoped DNS lookup failed: code ", code)
	}
	addresses := make([]netip.Addr, 0, 4)
	for _, value := range strings.Fields(C.GoString((*C.char)(unsafe.Pointer(&buffer[0])))) {
		address, err := netip.ParseAddr(value)
		if err != nil {
			return underlayLookupResult{}, E.Cause(err, "parse underlay DNS answer")
		}
		addresses = append(addresses, address.Unmap())
	}
	if len(addresses) == 0 {
		return underlayLookupResult{}, errMobileUnderlayDNSNoData
	}
	return underlayLookupResult{addresses: addresses, ttl: uint32(ttl)}, nil
}
