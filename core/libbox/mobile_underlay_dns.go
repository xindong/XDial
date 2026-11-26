package libbox

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strings"
	"time"

	"github.com/sagernet/sing-box/adapter"
	boxC "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/dns"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing/service"

	mDNS "github.com/miekg/dns"
)

const (
	typeMobileUnderlayDNS     = "xdial-underlay"
	mobileUnderlayDNSTimeout  = 5 * time.Second
	mobileUnderlayDNSSlots    = 32
	mobileUnderlayDNSBufBytes = 4096
)

var (
	errMobileUnderlayDNSNoData      = errors.New("mobile underlay DNS returned no data")
	errMobileUnderlayDNSUnavailable = errors.New("mobile underlay DNS interface is unavailable")
	mobileUnderlayDNSSemaphore      = make(chan struct{}, mobileUnderlayDNSSlots)
)

type mobileUnderlayDNSServerOptions struct {
	Fallback string `json:"fallback,omitempty"`
}

type underlayLookupResult struct {
	addresses []netip.Addr
	ttl       uint32
}

// mobileUnderlayDNSTransport resolves Direct-bound names through the live
// physical Underlay interface on Apple Network Extensions using interface-scoped
// DNSServiceGetAddrInfo, avoiding loops back into the tunnel's 198.18.0.2 DNS
// and following Wi-Fi / cellular changes published by NWPathMonitor.
//
// On non-Darwin platforms (e.g. Linux tests), it delegates to the configured
// fallback transport.
type mobileUnderlayDNSTransport struct {
	dns.TransportAdapter

	networkManager   adapter.NetworkManager
	transportManager adapter.DNSTransportManager
	fallbackTag      string
	fallback         adapter.DNSTransport
	lookup           func(ctx context.Context, interfaceIndex int, name string, qtype uint16, timeout time.Duration) (underlayLookupResult, error)
	interfaceIndex   func() int
}

func registerMobileUnderlayDNSTransport(registry *dns.TransportRegistry) {
	dns.RegisterTransport[mobileUnderlayDNSServerOptions](
		registry,
		typeMobileUnderlayDNS,
		newMobileUnderlayDNSTransport,
	)
}

func newMobileUnderlayDNSTransport(
	ctx context.Context,
	_ log.ContextLogger,
	tag string,
	options mobileUnderlayDNSServerOptions,
) (adapter.DNSTransport, error) {
	fallbackTag := strings.TrimSpace(options.Fallback)
	var dependencies []string
	if fallbackTag != "" {
		dependencies = []string{fallbackTag}
	}
	return &mobileUnderlayDNSTransport{
		TransportAdapter: dns.NewTransportAdapter(typeMobileUnderlayDNS, tag, dependencies),
		networkManager:   service.FromContext[adapter.NetworkManager](ctx),
		transportManager: service.FromContext[adapter.DNSTransportManager](ctx),
		fallbackTag:      fallbackTag,
	}, nil
}

func (t *mobileUnderlayDNSTransport) Start(stage adapter.StartStage) error {
	if stage != adapter.StartStateInitialize {
		return nil
	}
	if t.fallbackTag == "" {
		return nil
	}
	if t.transportManager == nil {
		return fmt.Errorf("mobile underlay DNS transport manager is unavailable")
	}
	fallback, loaded := t.transportManager.Transport(t.fallbackTag)
	if !loaded {
		return fmt.Errorf("mobile underlay DNS fallback %q is unavailable", t.fallbackTag)
	}
	t.fallback = fallback
	return nil
}

func (t *mobileUnderlayDNSTransport) Close() error {
	t.fallback = nil
	return nil
}

func (t *mobileUnderlayDNSTransport) Reset() {}

func (t *mobileUnderlayDNSTransport) currentInterfaceIndex() int {
	if t.interfaceIndex != nil {
		return t.interfaceIndex()
	}
	if t.networkManager == nil {
		return 0
	}
	iface := t.networkManager.DefaultNetworkInterface()
	if iface == nil || iface.Index <= 0 {
		return 0
	}
	return iface.Index
}

func (t *mobileUnderlayDNSTransport) Exchange(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	if message == nil || len(message.Question) != 1 {
		return nil, os.ErrInvalid
	}
	if !mobileUnderlayUsesNativeScopedResolver() && t.lookup == nil {
		if t.fallback == nil {
			return nil, errMobileUnderlayDNSUnavailable
		}
		return t.fallback.Exchange(ctx, message)
	}
	return t.exchangeScoped(ctx, message)
}

func (t *mobileUnderlayDNSTransport) ExchangeAsync(
	ctx context.Context,
	message *mDNS.Msg,
	callback func(response *mDNS.Msg, err error),
) {
	go func() {
		response, err := t.Exchange(ctx, message)
		callback(response, err)
	}()
}

func (t *mobileUnderlayDNSTransport) exchangeScoped(ctx context.Context, message *mDNS.Msg) (*mDNS.Msg, error) {
	question := message.Question[0]
	if question.Qtype != mDNS.TypeA && question.Qtype != mDNS.TypeAAAA {
		return dns.FixedResponseStatus(message, mDNS.RcodeSuccess), nil
	}
	ifaceIndex := t.currentInterfaceIndex()
	if ifaceIndex <= 0 {
		// Never fall back to kDNSServiceInterfaceIndexAny (0), which would route
		// back into the Network Extension's 198.18.0.2 DNS and loop.
		return nil, errMobileUnderlayDNSUnavailable
	}
	select {
	case mobileUnderlayDNSSemaphore <- struct{}{}:
		defer func() { <-mobileUnderlayDNSSemaphore }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	timeout := mobileUnderlayDNSTimeout
	if deadline, hasDeadline := ctx.Deadline(); hasDeadline {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return nil, ctx.Err()
		}
		if remaining < timeout {
			timeout = remaining
		}
	}
	lookup := t.lookup
	if lookup == nil {
		lookup = darwinScopedDNSServiceLookup
	}
	result, err := lookup(ctx, ifaceIndex, question.Name, question.Qtype, timeout)
	if err != nil {
		var rcodeErr dns.RcodeError
		if errors.As(err, &rcodeErr) {
			return dns.FixedResponseStatus(message, int(rcodeErr)), nil
		}
		if errors.Is(err, errMobileUnderlayDNSNoData) {
			return dns.FixedResponseStatus(message, mDNS.RcodeSuccess), nil
		}
		return nil, err
	}
	ttl := result.ttl
	if ttl == 0 {
		ttl = boxC.DefaultDNSTTL
	}
	return dns.FixedResponse(message.Id, question, result.addresses, ttl), nil
}

var _ adapter.DNSTransport = (*mobileUnderlayDNSTransport)(nil)
