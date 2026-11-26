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
	uint16_t query_type;
	int has_terminal_record;
	int done;
} xdial_underlay_dns_result;

static int xdial_underlay_dns_accept_callback(xdial_underlay_dns_result *result, DNSServiceErrorType error_code) {
	if (result->done) {
		return 0;
	}
	if (error_code != kDNSServiceErr_NoError) {
		if (error_code != kDNSServiceErr_NoSuchRecord || result->answer_count == 0) {
			result->error_code = error_code;
		}
		result->done = 1;
		return 0;
	}
	return 1;
}

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
	if (!xdial_underlay_dns_accept_callback(result, error_code)) {
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

static void xdial_underlay_dns_record_reply(
	DNSServiceRef sd_ref,
	DNSServiceFlags flags,
	uint32_t interface_index,
	DNSServiceErrorType error_code,
	const char *name,
	uint16_t rr_type,
	uint16_t rr_class,
	uint16_t data_length,
	const void *data,
	uint32_t ttl,
	void *context
) {
	(void)sd_ref;
	(void)interface_index;
	xdial_underlay_dns_result *result = context;
	if (!xdial_underlay_dns_accept_callback(result, error_code)) {
		return;
	}
	if ((flags & kDNSServiceFlagsAdd) != 0) {
		size_t name_length = strlen(name);
		// Frame each result with network-order lengths and RR metadata.
		uint16_t fields[] = {htons((uint16_t)name_length), htons(rr_type), htons(rr_class), htons(data_length)};
		uint32_t wire_ttl = htonl(ttl);
		size_t frame_length = sizeof(fields) + sizeof(wire_ttl) + name_length + data_length;
		if (frame_length > result->output_size - result->output_length) {
			result->error_code = kDNSServiceErr_NoMemory;
			result->done = 1;
			return;
		}
		char *frame = result->output + result->output_length;
		memcpy(frame, fields, sizeof(fields));
		memcpy(frame + sizeof(fields), &wire_ttl, sizeof(wire_ttl));
		frame += sizeof(fields) + sizeof(wire_ttl);
		memcpy(frame, name, name_length);
		if (data_length != 0) {
			memcpy(frame + name_length, data, data_length);
		}
		result->output_length += frame_length;
		result->answer_count++;
		if (rr_type != kDNSServiceType_CNAME || result->query_type == kDNSServiceType_CNAME ||
			result->query_type == kDNSServiceType_ANY) {
			result->has_terminal_record = 1;
		}
	}
	// A CNAME can arrive in a separate batch before the requested record.
	if (result->has_terminal_record && (flags & kDNSServiceFlagsMoreComing) == 0) {
		result->done = 1;
	}
}

static int32_t xdial_underlay_dns_lookup(
	uint32_t interface_index,
	const char *hostname,
	uint32_t protocol,
	uint16_t rr_type,
	uint16_t rr_class,
	int timeout_millis,
	char *output,
	size_t output_size,
	size_t *output_length,
	uint32_t *ttl
) {
	if (interface_index == 0) {
		return kDNSServiceErr_BadParam;
	}
	xdial_underlay_dns_result result;
	memset(&result, 0, sizeof(result));
	result.output = output;
	result.output_size = output_size;
	result.query_type = rr_type;
	if (output_size > 0) {
		output[0] = '\0';
	}

	DNSServiceRef service = NULL;
	DNSServiceErrorType start_error;
	if (protocol != 0) {
		start_error = DNSServiceGetAddrInfo(&service, kDNSServiceFlagsTimeout, interface_index,
			protocol, hostname, xdial_underlay_dns_reply, &result);
	} else {
		start_error = DNSServiceQueryRecord(&service, kDNSServiceFlagsTimeout | kDNSServiceFlagsReturnIntermediates, interface_index,
			hostname, rr_type, rr_class, xdial_underlay_dns_record_reply, &result);
	}
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
	*output_length = result.output_length;
	if (ttl != NULL) {
		*ttl = result.ttl;
	}
	return result.error_code;
}
*/
import "C"

import (
	"context"
	"encoding/binary"
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
	question mDNS.Question,
	timeout time.Duration,
) (underlayLookupResult, error) {
	if err := ctx.Err(); err != nil {
		return underlayLookupResult{}, err
	}
	if interfaceIndex <= 0 {
		return underlayLookupResult{}, errMobileUnderlayDNSUnavailable
	}
	var protocol C.uint32_t
	if question.Qclass == mDNS.ClassINET {
		switch question.Qtype {
		case mDNS.TypeA:
			protocol = C.kDNSServiceProtocol_IPv4
		case mDNS.TypeAAAA:
			protocol = C.kDNSServiceProtocol_IPv6
		}
	}
	cName := C.CString(question.Name)
	defer C.free(unsafe.Pointer(cName))
	buffer := make([]byte, mobileUnderlayDNSBufBytes)
	var ttl C.uint32_t
	var outputLength C.size_t
	code := int32(C.xdial_underlay_dns_lookup(
		C.uint32_t(interfaceIndex),
		cName,
		protocol,
		C.uint16_t(question.Qtype),
		C.uint16_t(question.Qclass),
		C.int(timeout.Milliseconds()),
		(*C.char)(unsafe.Pointer(&buffer[0])),
		C.size_t(len(buffer)),
		&outputLength,
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
	if outputLength == 0 {
		return underlayLookupResult{}, errMobileUnderlayDNSNoData
	}
	buffer = buffer[:int(outputLength)]
	if protocol == 0 {
		records, err := unpackUnderlayDNSRecords(buffer)
		return underlayLookupResult{records: records}, err
	}
	addresses := make([]netip.Addr, 0, 4)
	for _, value := range strings.Fields(string(buffer)) {
		address, err := netip.ParseAddr(value)
		if err != nil {
			return underlayLookupResult{}, E.Cause(err, "parse underlay DNS answer")
		}
		addresses = append(addresses, address.Unmap())
	}
	return underlayLookupResult{addresses: addresses, ttl: uint32(ttl)}, nil
}

func unpackUnderlayDNSRecords(buffer []byte) ([]mDNS.RR, error) {
	const headerSize = 12
	var records []mDNS.RR
	for len(buffer) != 0 {
		if len(buffer) < headerSize {
			return nil, E.New("truncated underlay DNS record header")
		}
		nameLength := int(binary.BigEndian.Uint16(buffer[:2]))
		header := mDNS.RR_Header{
			Rrtype:   binary.BigEndian.Uint16(buffer[2:4]),
			Class:    binary.BigEndian.Uint16(buffer[4:6]),
			Rdlength: binary.BigEndian.Uint16(buffer[6:8]),
			Ttl:      binary.BigEndian.Uint32(buffer[8:12]),
		}
		buffer = buffer[headerSize:]
		recordLength := nameLength + int(header.Rdlength)
		if nameLength == 0 || len(buffer) < recordLength {
			return nil, E.New("invalid underlay DNS record length")
		}
		header.Name = string(buffer[:nameLength])
		record, _, err := mDNS.UnpackRRWithHeader(header, buffer[nameLength:recordLength], 0)
		if err != nil {
			return nil, E.Cause(err, "decode underlay DNS record")
		}
		records = append(records, record)
		buffer = buffer[recordLength:]
	}
	return records, nil
}
