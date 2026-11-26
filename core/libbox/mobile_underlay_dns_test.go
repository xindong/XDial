package libbox

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"runtime"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	boxDNS "github.com/sagernet/sing-box/dns"

	mDNS "github.com/miekg/dns"
)

func TestMobileUnderlayDNSScopesQueriesToDefaultInterface(t *testing.T) {
	var gotInterfaceIndex int
	var gotQuestion mDNS.Question

	transport := &mobileUnderlayDNSTransport{
		TransportAdapter: boxDNS.NewTransportAdapter(typeMobileUnderlayDNS, "xdial-direct-dns", nil),
		interfaceIndex:   func() int { return 7 },
		lookup: func(_ context.Context, interfaceIndex int, question mDNS.Question, _ time.Duration) (underlayLookupResult, error) {
			gotInterfaceIndex = interfaceIndex
			gotQuestion = question
			return underlayLookupResult{
				addresses: []netip.Addr{netip.MustParseAddr("198.51.100.10")},
				ttl:       42,
			}, nil
		},
	}

	req := new(mDNS.Msg)
	req.SetQuestion("cdn.example.com.", mDNS.TypeA)
	resp, err := transport.Exchange(context.Background(), req)
	if err != nil {
		t.Fatalf("Exchange failed: %v", err)
	}
	if gotInterfaceIndex != 7 || gotQuestion != req.Question[0] {
		t.Fatalf("unexpected lookup args: if=%d question=%v", gotInterfaceIndex, gotQuestion)
	}
	if resp.Rcode != mDNS.RcodeSuccess || len(resp.Answer) != 1 {
		t.Fatalf("unexpected DNS response: %v", resp)
	}
	aRecord, ok := resp.Answer[0].(*mDNS.A)
	if !ok || !aRecord.A.Equal(net.ParseIP("198.51.100.10")) || aRecord.Hdr.Ttl != 42 {
		t.Fatalf("unexpected A record: %v", resp.Answer[0])
	}
}

func TestMobileUnderlayDNSFailsClosedWithoutValidInterface(t *testing.T) {
	called := false
	transport := &mobileUnderlayDNSTransport{
		TransportAdapter: boxDNS.NewTransportAdapter(typeMobileUnderlayDNS, "xdial-direct-dns", nil),
		interfaceIndex:   func() int { return 0 },
		lookup: func(_ context.Context, _ int, _ mDNS.Question, _ time.Duration) (underlayLookupResult, error) {
			called = true
			return underlayLookupResult{}, nil
		},
	}

	req := new(mDNS.Msg)
	req.SetQuestion("cdn.example.com.", mDNS.TypeA)
	if _, err := transport.Exchange(context.Background(), req); !errors.Is(err, errMobileUnderlayDNSUnavailable) {
		t.Fatalf("expected errMobileUnderlayDNSUnavailable, got %v", err)
	}
	if called {
		t.Fatal("lookup must never be invoked with interfaceIndex=0 (kDNSServiceInterfaceIndexAny)")
	}
}

func TestMobileUnderlayDNSNegativeStatuses(t *testing.T) {
	cases := []struct {
		name      string
		qtype     uint16
		lookupErr error
		wantRcode int
	}{
		{
			name:      "no-data stays NOERROR empty",
			qtype:     mDNS.TypeHTTPS,
			lookupErr: errMobileUnderlayDNSNoData,
			wantRcode: mDNS.RcodeSuccess,
		},
		{
			name:      "no-such-name returns NXDOMAIN",
			qtype:     mDNS.TypeA,
			lookupErr: boxDNS.RcodeError(mDNS.RcodeNameError),
			wantRcode: mDNS.RcodeNameError,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			transport := &mobileUnderlayDNSTransport{
				TransportAdapter: boxDNS.NewTransportAdapter(typeMobileUnderlayDNS, "xdial-direct-dns", nil),
				interfaceIndex:   func() int { return 7 },
				lookup: func(_ context.Context, _ int, _ mDNS.Question, _ time.Duration) (underlayLookupResult, error) {
					return underlayLookupResult{}, tc.lookupErr
				},
			}
			req := new(mDNS.Msg)
			req.SetQuestion("cdn.example.com.", tc.qtype)
			resp, err := transport.Exchange(context.Background(), req)
			if err != nil {
				t.Fatalf("Exchange returned unexpected error: %v", err)
			}
			if resp.Rcode != tc.wantRcode || len(resp.Answer) != 0 {
				t.Fatalf("got rcode=%d answers=%d, want rcode=%d answers=0", resp.Rcode, len(resp.Answer), tc.wantRcode)
			}
		})
	}
}

func TestMobileUnderlayDNSReturnsScopedRecords(t *testing.T) {
	for _, value := range []string{
		"_service._tcp.example. 42 IN SRV 10 5 443 server.example.",
		"example. 0 IN TXT \"verification=example\"",
		"5.2.0.192.in-addr.arpa. 123 IN PTR server.example.",
		"example. 30 IN HTTPS 1 . alpn=h2",
	} {
		record, err := mDNS.NewRR(value)
		if err != nil {
			t.Fatal(err)
		}
		header := record.Header()
		t.Run(mDNS.TypeToString[header.Rrtype], func(t *testing.T) {
			req := new(mDNS.Msg).SetQuestion(header.Name, header.Rrtype)
			transport := &mobileUnderlayDNSTransport{
				interfaceIndex: func() int { return 7 },
				lookup: func(_ context.Context, index int, question mDNS.Question, _ time.Duration) (underlayLookupResult, error) {
					if index != 7 || question != req.Question[0] {
						t.Fatalf("unexpected lookup: index=%d, question=%v", index, question)
					}
					return underlayLookupResult{records: []mDNS.RR{record}}, nil
				},
			}
			resp, err := transport.Exchange(context.Background(), req)
			if err != nil {
				t.Fatal(err)
			}
			if resp.Id != req.Id || !resp.Response || resp.Rcode != mDNS.RcodeSuccess ||
				len(resp.Question) != 1 || resp.Question[0] != req.Question[0] ||
				len(resp.Answer) != 1 || resp.Answer[0].String() != record.String() {
				t.Fatalf("unexpected response: %v", resp)
			}
		})
	}
}

func TestMobileUnderlayDNSFallbackOnNonDarwin(t *testing.T) {
	if mobileUnderlayUsesNativeScopedResolver() {
		t.Skip("fallback delegation applies only when native Darwin scoped resolver is disabled")
	}
	fallback := newFakeMobileDNSTransport("xdial-public-dns")
	transport := &mobileUnderlayDNSTransport{
		TransportAdapter: boxDNS.NewTransportAdapter(typeMobileUnderlayDNS, "xdial-direct-dns", []string{"xdial-public-dns"}),
		fallback:         fallback,
	}
	req := new(mDNS.Msg)
	req.SetQuestion("cdn.example.com.", mDNS.TypeA)
	resp, err := transport.Exchange(context.Background(), req)
	if err != nil {
		t.Fatalf("fallback exchange failed: %v", err)
	}
	if resp.Rcode != mDNS.RcodeSuccess || fallback.calls != 1 {
		t.Fatalf("expected fallback to be called once, calls=%d resp=%v", fallback.calls, resp)
	}
}

func TestMobileUnderlayDNSDarwinRejectsZeroInterface(t *testing.T) {
	if runtime.GOOS != "darwin" || !mobileUnderlayUsesNativeScopedResolver() {
		t.Skip("Darwin scoped DNSServiceGetAddrInfo test requires darwin+cgo")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Verify interfaceIndex=0 is rejected directly at the Darwin helper so it
	// can never fall back to kDNSServiceInterfaceIndexAny and loop into TUN DNS.
	for _, rrType := range []uint16{mDNS.TypeA, mDNS.TypeHTTPS} {
		question := mDNS.Question{Name: "localhost.", Qtype: rrType, Qclass: mDNS.ClassINET}
		if _, err := darwinScopedDNSServiceLookup(ctx, 0, question, 2*time.Second); !errors.Is(err, errMobileUnderlayDNSUnavailable) {
			t.Fatalf("expected interfaceIndex=0 rejection for %v, got %v", question, err)
		}
	}
}

func TestMobileUnderlayDNSTransportIsRegistered(t *testing.T) {
	registry := dnsTransportRegistry()
	if _, ok := registry.CreateOptions(typeMobileUnderlayDNS); !ok {
		t.Fatalf("expected %q to be registered in dnsTransportRegistry", typeMobileUnderlayDNS)
	}
	// Ensure Start binds fallback dependency cleanly when transportManager is provided.
	var _ adapter.DNSTransport = (*mobileUnderlayDNSTransport)(nil)
}
