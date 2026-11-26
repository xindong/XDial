//go:build !windows

package libbox

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing/common/buf"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

type udpRouteObservation struct {
	ctx      context.Context
	metadata adapter.InboundContext
	outbound string
}

type udpRouteObserver struct {
	routingProbeTracker
	routes   chan udpRouteObservation
	holdPort uint16
	release  <-chan struct{}
}

func (o *udpRouteObserver) RoutedPacketConnection(ctx context.Context, conn N.PacketConn, metadata adapter.InboundContext, _ adapter.Rule, outbound adapter.Outbound) N.PacketConn {
	o.routes <- udpRouteObservation{ctx: ctx, metadata: metadata, outbound: outbound.Tag()}
	if o.release != nil && metadata.Destination.Port == o.holdPort {
		select {
		case <-ctx.Done():
		case <-o.release:
		}
	}
	return conn
}

// Each real server signs the reply with its own label. Verify who received the
// request as well as who the SOCKS header says sent the response.
func TestTransparentSOCKSUDPMultipleDestinations(t *testing.T) {
	servers := make([]M.Socksaddr, 2)
	for index := range servers {
		server, err := net.ListenPacket("udp4", "127.0.0.1:0")
		if err != nil {
			t.Fatal(err)
		}
		defer server.Close()
		servers[index] = M.SocksaddrFromNet(server.LocalAddr())
		go func(label byte) {
			var data [65535]byte
			data[0] = label
			for {
				n, from, err := server.ReadFrom(data[1:])
				if err != nil {
					return
				}
				// Echo the sequence and received length, including for an empty
				// or large datagram, without requiring a fragmented reply.
				_, _ = server.WriteTo([]byte{data[0], data[1], byte(n >> 8), byte(n)}, from)
			}
		}(byte('A' + index))
	}

	for _, connected := range []bool{false, true} {
		t.Run(fmt.Sprintf("connected-outbound=%t", connected), func(t *testing.T) {
			port := freeFlowCorrectionPort(t)
			rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
				"log":{"disabled":true},
				"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,
					"xdial_flow_metadata":true,"users":[{"username":"test-app","password":"fixture"}]}],
				"outbounds":[{"type":"direct","tag":"line-A"},{"type":"direct","tag":"line-B"}],
				"route":{"rules":[
					{"port":%d,"action":"route","outbound":"line-A","udp_connect":%t},
					{"port":%d,"action":"route","outbound":"line-B","udp_connect":%t}]}
			}`, port, servers[0].Port, connected, servers[1].Port, connected))
			defer rt.Stop()
			observer := &udpRouteObserver{routes: make(chan udpRouteObservation, 16)}
			rt.box.Router().AppendTracker(observer)
			client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "test-app", "fixture")
			for first := range servers {
				t.Run(fmt.Sprintf("first-%c", 'A'+first), func(t *testing.T) {
					ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
					defer cancel()
					conn, err := client.ListenPacket(ctx, servers[first])
					if err != nil {
						t.Fatal(err)
					}
					defer conn.Close()
					deadline, _ := ctx.Deadline()
					if err := conn.SetDeadline(deadline); err != nil {
						t.Fatal(err)
					}
					var bound string
					if first == 1 {
						bound = rt.platform.diagnostics().DefaultInterfaceName
						marker := append([]byte{0, 'X', 'D', 2, 4, byte(len(bound))}, bound...)
						if _, err := conn.WriteTo([]byte{0}, M.Socksaddr{Fqdn: string(marker)}); err != nil {
							t.Fatal(err)
						}
					}

					for seq, size := range []int{8192, 1, 0, 4096} {
						target := (first + seq) % len(servers)
						want := servers[target]
						data := bytes.Repeat([]byte{byte(seq)}, size)
						if _, err := conn.WriteTo(data, want); err != nil {
							t.Fatal(err)
						}
						var reply [128]byte
						n, from, err := conn.ReadFrom(reply[:])
						if err != nil {
							t.Fatalf("packet %d to %s: %v", seq, want, err)
						}
						if n != 4 || from.String() != want.String() || reply[0] != byte('A'+target) ||
							(size > 0 && reply[1] != byte(seq)) || int(reply[2])<<8|int(reply[3]) != size {
							t.Errorf("packet %d (%d bytes) to %s: got %v from %s", seq, size, want, reply[:n], from)
						}
					}

					for _, target := range []int{first, 1 - first} {
						select {
						case route := <-observer.routes:
							if route.metadata.Destination != servers[target] || route.outbound != fmt.Sprintf("line-%c", 'A'+target) ||
								route.metadata.Inbound != "flow" || route.metadata.User != "test-app" || route.metadata.XDialBoundInterface != bound {
								t.Fatalf("route to %s: outbound %s, inbound %s, user %q, bound interface %q",
									route.metadata.Destination, route.outbound, route.metadata.Inbound, route.metadata.User, route.metadata.XDialBoundInterface)
							}
							t.Cleanup(func() {
								select {
								case <-route.ctx.Done():
								case <-time.After(3 * time.Second):
									t.Errorf("route to %s outlived the closed SOCKS association", route.metadata.Destination)
								}
							})
						case <-ctx.Done():
							t.Fatal("missing per-destination route")
						}
					}
				})
			}
		})
	}
}

// Hold one route before its outbound starts reading. Fill its queue, keep
// another peer responsive, then evict and reopen the held destination.
func TestTransparentSOCKSUDPTargetLimits(t *testing.T) {
	const targetLimit = 64
	peers := make([]*net.UDPConn, targetLimit+1)
	for i := range peers {
		peer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		defer peer.Close()
		peers[i] = peer
	}

	port := freeFlowCorrectionPort(t)
	rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
		"log":{"disabled":true},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,"xdial_flow_metadata":true}],
		"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}
	}`, port))
	defer rt.Stop()
	release := make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	defer resume()
	observer := &udpRouteObserver{
		routes:   make(chan udpRouteObservation, len(peers)+1),
		holdPort: M.SocksaddrFromNet(peers[0].LocalAddr()).Port, release: release,
	}
	rt.box.Router().AppendTracker(observer)
	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "", "")
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	conn, err := client.ListenPacket(ctx, M.SocksaddrFromNet(peers[0].LocalAddr()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}

	send := func(index int, value byte) {
		t.Helper()
		if _, err := conn.WriteTo([]byte{value}, peers[index].LocalAddr()); err != nil {
			t.Fatal(err)
		}
	}
	nextRoute := func(index int) context.Context {
		t.Helper()
		select {
		case route := <-observer.routes:
			if route.metadata.Destination != M.SocksaddrFromNet(peers[index].LocalAddr()) {
				t.Fatalf("route for %s, want peer %d", route.metadata.Destination, index)
			}
			return route.ctx
		case <-ctx.Done():
			t.Fatalf("peer %d did not get its own route", index)
			return nil
		}
	}
	roundTrip := func(index int, value byte) {
		t.Helper()
		server := peers[index]
		if err := server.SetDeadline(deadline); err != nil {
			t.Fatal(err)
		}
		var data [64]byte
		n, remote, err := server.ReadFrom(data[:])
		if err != nil || n != 1 || data[0] != value {
			t.Fatalf("peer %d received %v, want [%d]: %v", index, data[:n], value, err)
		}
		if _, err := server.WriteTo(data[:n], remote); err != nil {
			t.Fatal(err)
		}
		n, responder, err := conn.ReadFrom(data[:])
		if err != nil || n != 1 || data[0] != value || responder.String() != server.LocalAddr().String() {
			t.Fatalf("reply for peer %d: %v from %v: %v", index, data[:n], responder, err)
		}
	}

	send(0, 0)
	held := nextRoute(0)
	for i := 0; i < 32; i++ {
		send(0, 0)
	}
	send(1, 1)
	nextRoute(1)
	roundTrip(1, 1)
	for i := 2; i < len(peers); i++ {
		send(i, byte(i))
		nextRoute(i)
	}
	select {
	case <-held.Done():
	case <-ctx.Done():
		t.Fatal("the least recently used route survived the 65th target")
	}
	resume()
	send(0, 42)
	nextRoute(0)
	roundTrip(0, 42)
}

// Verify that one transparent-proxy SOCKS5 UDP association keeps
// Endpoint-Independent Mapping (Full-Cone semantics) across multiple direct
// destinations, accepts unsolicited packets on the shared socket, isolates
// other outbounds on the same association, and isolates separate associations.
func TestTransparentSOCKSUDPDirectEndpointIndependentMapping(t *testing.T) {
	newObservedServer := func(label byte) (*net.UDPConn, M.Socksaddr, chan net.Addr) {
		t.Helper()
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = conn.Close() })
		seen := make(chan net.Addr, 8)
		go func() {
			var buf [2048]byte
			for {
				n, from, err := conn.ReadFromUDP(buf[:])
				if err != nil {
					return
				}
				seen <- from
				reply := append([]byte{label, ':'}, buf[:n]...)
				_, _ = conn.WriteToUDP(reply, from)
			}
		}()
		return conn, M.SocksaddrFromNet(conn.LocalAddr()), seen
	}

	_, stunA, seenA := newObservedServer('A')
	_, stunB, seenB := newObservedServer('B')
	_, otherLine, seenOther := newObservedServer('X')

	unsolicitedPeer, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer unsolicitedPeer.Close()
	unsolicitedAddr := M.SocksaddrFromNet(unsolicitedPeer.LocalAddr())

	port := freeFlowCorrectionPort(t)
	rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
		"log":{"disabled":true},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,
			"xdial_flow_metadata":true,"users":[{"username":"test-app","password":"fixture"}]}],
		"outbounds":[
			{"type":"direct","tag":"direct"},
			{"type":"direct","tag":"other-line"}
		],
		"route":{
			"rules":[{"port":%d,"action":"route","outbound":"other-line"}],
			"final":"direct"
		}
	}`, port, otherLine.Port))
	defer rt.Stop()

	observer := &udpRouteObserver{routes: make(chan udpRouteObservation, 16)}
	rt.box.Router().AppendTracker(observer)

	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "test-app", "fixture")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	deadline, _ := ctx.Deadline()

	assoc1, err := client.ListenPacket(ctx, stunA)
	if err != nil {
		t.Fatal(err)
	}
	defer assoc1.Close()
	if err := assoc1.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}

	roundTrip := func(conn net.PacketConn, target M.Socksaddr, payload string, wantReply string) {
		t.Helper()
		if _, err := conn.WriteTo([]byte(payload), target); err != nil {
			t.Fatalf("send %q to %s: %v", payload, target, err)
		}
		var reply [256]byte
		n, from, err := conn.ReadFrom(reply[:])
		if err != nil {
			t.Fatalf("read reply from %s: %v", target, err)
		}
		if from.String() != target.String() || string(reply[:n]) != wantReply {
			t.Fatalf("reply from %s: got %q from %s, want %q", target, string(reply[:n]), from, wantReply)
		}
	}

	// Two different direct targets on the same association must observe the exact same source port.
	roundTrip(assoc1, stunA, "probe-a", "A:probe-a")
	fromA := <-seenA
	roundTrip(assoc1, stunB, "probe-b", "B:probe-b")
	fromB := <-seenB
	if fromA.String() != fromB.String() {
		t.Fatalf("direct UDP source mapping varied by destination: stunA saw %s, stunB saw %s", fromA, fromB)
	}

	// Unsolicited Full-Cone packet from a third peer to that mapped port must arrive with exact source.
	if _, err := unsolicitedPeer.WriteToUDP([]byte("peer-punch"), fromA.(*net.UDPAddr)); err != nil {
		t.Fatalf("send unsolicited packet: %v", err)
	}
	var punchBuf [256]byte
	n, punchFrom, err := assoc1.ReadFrom(punchBuf[:])
	if err != nil {
		t.Fatalf("read unsolicited Full-Cone packet: %v", err)
	}
	if punchFrom.String() != unsolicitedAddr.String() || string(punchBuf[:n]) != "peer-punch" {
		t.Fatalf("unsolicited packet: got %q from %s, want %q from %s", string(punchBuf[:n]), punchFrom, "peer-punch", unsolicitedAddr)
	}

	// A target routed to another outbound on the same association routes independently without breaking direct EIM.
	roundTrip(assoc1, otherLine, "probe-other", "X:probe-other")
	fromOther := <-seenOther
	if fromOther.String() == fromA.String() {
		t.Fatalf("other-line outbound unexpectedly reused direct socket %s", fromA)
	}
	roundTrip(assoc1, stunA, "probe-a-2", "A:probe-a-2")
	fromA2 := <-seenA
	if fromA2.String() != fromA.String() {
		t.Fatalf("direct source port changed after other-line traffic: got %s, want %s", fromA2, fromA)
	}

	// Verify per-destination routing decisions were preserved.
	gotOutbounds := map[M.Socksaddr]string{}
	for range 3 {
		select {
		case route := <-observer.routes:
			gotOutbounds[route.metadata.Destination] = route.outbound
		case <-ctx.Done():
			t.Fatal("missing route observation")
		}
	}
	if gotOutbounds[stunA] != "direct" || gotOutbounds[stunB] != "direct" || gotOutbounds[otherLine] != "other-line" {
		t.Fatalf("unexpected per-destination outbounds: %+v", gotOutbounds)
	}

	// A separate SOCKS5 UDP association (another app socket) must get its own direct source port.
	assoc2, err := client.ListenPacket(ctx, stunA)
	if err != nil {
		t.Fatal(err)
	}
	defer assoc2.Close()
	if err := assoc2.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	roundTrip(assoc2, stunA, "assoc2", "A:assoc2")
	fromAssoc2 := <-seenA
	if fromAssoc2.String() == fromA.String() {
		t.Fatalf("separate associations unexpectedly shared direct port %s", fromA)
	}
}

// Verify that a domain-resolved direct destination (ListenSerialNetworkPacket)
// and a literal-IP direct destination (ListenPacket) on the same association
// share the same outbound UDP port while preserving domain reply unmapping.
func TestTransparentSOCKSUDPDirectSharedPortAcrossDomainAndLiteral(t *testing.T) {
	newEcho := func() (*net.UDPConn, M.Socksaddr, chan net.Addr) {
		t.Helper()
		conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = conn.Close() })
		seen := make(chan net.Addr, 4)
		go func() {
			var buf [2048]byte
			for {
				n, from, err := conn.ReadFromUDP(buf[:])
				if err != nil {
					return
				}
				seen <- from
				_, _ = conn.WriteToUDP(buf[:n], from)
			}
		}()
		return conn, M.SocksaddrFromNet(conn.LocalAddr()), seen
	}

	_, serverA, seenA := newEcho()
	_, serverB, seenB := newEcho()

	port := freeFlowCorrectionPort(t)
	rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
		"log":{"disabled":true},
		"dns":{
			"servers":[{"type":"hosts","tag":"local-hosts","predefined":{"stun-a.example":["127.0.0.1"]}}],
			"final":"local-hosts"
		},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,"xdial_flow_metadata":true}],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{
			"rules":[{"action":"resolve","server":"local-hosts"}],
			"final":"direct"
		}
	}`, port))
	defer rt.Stop()

	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "", "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	deadline, _ := ctx.Deadline()

	domainDest := M.ParseSocksaddrHostPort("stun-a.example", serverA.Port)
	conn, err := client.ListenPacket(ctx, domainDest)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}

	packetConn, ok := conn.(N.PacketConn)
	if !ok {
		t.Fatalf("socks ListenPacket returned %T, want N.PacketConn", conn)
	}

	if _, err := conn.WriteTo([]byte("by-name"), domainDest); err != nil {
		t.Fatal(err)
	}
	replyBuf := buf.NewPacket()
	defer replyBuf.Release()
	from, err := packetConn.ReadPacket(replyBuf)
	if err != nil {
		t.Fatal(err)
	}
	if from != domainDest || string(replyBuf.Bytes()) != "by-name" {
		t.Fatalf("domain reply: got %q from %s, want %q from %s", string(replyBuf.Bytes()), from, "by-name", domainDest)
	}
	observedDomain := <-seenA

	if _, err := conn.WriteTo([]byte("by-ip"), serverB); err != nil {
		t.Fatal(err)
	}
	replyBuf.Reset()
	from, err = packetConn.ReadPacket(replyBuf)
	if err != nil {
		t.Fatal(err)
	}
	if from != serverB || string(replyBuf.Bytes()) != "by-ip" {
		t.Fatalf("literal reply: got %q from %s, want %q from %s", string(replyBuf.Bytes()), from, "by-ip", serverB)
	}
	observedLiteral := <-seenB

	if observedDomain.String() != observedLiteral.String() {
		t.Fatalf("domain and literal direct targets used different source ports: %s vs %s", observedDomain, observedLiteral)
	}
}

// Verify IPv6 multi-destination shared-port mapping, cross-family isolation
// between IPv4 and IPv6 sockets on the same association, and IPv4-mapped IPv6
// normalization onto the IPv4 shared socket.
func TestTransparentSOCKSUDPDirectDualStackAndIPv6Mapping(t *testing.T) {
	newEcho := func(network string, ip net.IP, label byte) (M.Socksaddr, chan net.Addr, error) {
		conn, err := net.ListenUDP(network, &net.UDPAddr{IP: ip})
		if err != nil {
			return M.Socksaddr{}, nil, err
		}
		t.Cleanup(func() { _ = conn.Close() })
		seen := make(chan net.Addr, 8)
		go func() {
			var data [2048]byte
			for {
				n, from, readErr := conn.ReadFromUDP(data[:])
				if readErr != nil {
					return
				}
				seen <- from
				reply := append([]byte{label, ':'}, data[:n]...)
				_, _ = conn.WriteToUDP(reply, from)
			}
		}()
		return M.SocksaddrFromNet(conn.LocalAddr()), seen, nil
	}

	v6A, seenV6A, err := newEcho("udp6", net.IPv6loopback, '1')
	if err != nil {
		t.Skipf("IPv6 loopback UDP unavailable: %v", err)
	}
	v6B, seenV6B, err := newEcho("udp6", net.IPv6loopback, '2')
	if err != nil {
		t.Fatal(err)
	}
	v4A, seenV4A, err := newEcho("udp4", net.IPv4(127, 0, 0, 1), '4')
	if err != nil {
		t.Fatal(err)
	}

	port := freeFlowCorrectionPort(t)
	rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
		"log":{"disabled":true},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,"xdial_flow_metadata":true}],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{"final":"direct"}
	}`, port))
	defer rt.Stop()

	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "", "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	deadline, _ := ctx.Deadline()

	conn, err := client.ListenPacket(ctx, v6A)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	if err := conn.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	packetConn, ok := conn.(N.PacketConn)
	if !ok {
		t.Fatalf("socks ListenPacket returned %T, want N.PacketConn", conn)
	}

	roundTrip := func(target M.Socksaddr, wantSource M.Socksaddr, payload, wantReply string) {
		t.Helper()
		pkt := buf.NewPacket()
		pkt.Resize(N.CalculateFrontHeadroom(packetConn), 0)
		_, _ = pkt.WriteString(payload)
		if err := packetConn.WritePacket(pkt, target); err != nil {
			t.Fatalf("send %q to %s: %v", payload, target, err)
		}
		reply := buf.NewPacket()
		defer reply.Release()
		from, err := packetConn.ReadPacket(reply)
		if err != nil {
			t.Fatalf("read reply from %s: %v", target, err)
		}
		if from.Unwrap() != wantSource.Unwrap() || string(reply.Bytes()) != wantReply {
			t.Fatalf("reply for %s: got %q from %s, want %q from %s", target, string(reply.Bytes()), from, wantReply, wantSource)
		}
	}

	// Two IPv6 direct destinations share one IPv6 outbound UDP port.
	roundTrip(v6A, v6A, "v6-a", "1:v6-a")
	fromV6A := <-seenV6A
	roundTrip(v6B, v6B, "v6-b", "2:v6-b")
	fromV6B := <-seenV6B
	if fromV6A.String() != fromV6B.String() {
		t.Fatalf("IPv6 direct targets used different source ports: %s vs %s", fromV6A, fromV6B)
	}

	// IPv4 and IPv4-mapped IPv6 destinations on the same association share one
	// IPv4 socket, isolated from the IPv6 socket.
	roundTrip(v4A, v4A, "v4-plain", "4:v4-plain")
	fromV4Plain := <-seenV4A
	if fromV4Plain.String() == fromV6A.String() {
		t.Fatalf("IPv4 target unexpectedly shared IPv6 socket %s", fromV6A)
	}

	mappedV4 := M.SocksaddrFrom(netip.MustParseAddr("::ffff:127.0.0.1"), v4A.Port)
	roundTrip(mappedV4, v4A, "v4-mapped", "4:v4-mapped")
	fromV4Mapped := <-seenV4A
	if fromV4Mapped.String() != fromV4Plain.String() {
		t.Fatalf("IPv4-mapped target used different source port than plain IPv4: %s vs %s", fromV4Mapped, fromV4Plain)
	}

	// Alternated IPv6 traffic still reuses the original IPv6 source port.
	roundTrip(v6A, v6A, "v6-a-2", "1:v6-a-2")
	fromV6A2 := <-seenV6A
	if fromV6A2.String() != fromV6A.String() {
		t.Fatalf("IPv6 source port changed after IPv4 traffic: got %s, want %s", fromV6A2, fromV6A)
	}
}

// Verify that when a domain target and a literal-IP target on the same
// association resolve to the exact same IP:port, each logical target preserves
// its own reply source mapping without stealing the other's replies.
func TestTransparentSOCKSUDPDirectDomainAndLiteralSameResolvedPeer(t *testing.T) {
	server, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()
	serverAddr := M.SocksaddrFromNet(server.LocalAddr())
	go func() {
		var data [2048]byte
		for {
			n, from, readErr := server.ReadFromUDP(data[:])
			if readErr != nil {
				return
			}
			_, _ = server.WriteToUDP(data[:n], from)
		}
	}()

	port := freeFlowCorrectionPort(t)
	rt := newLoopbackFlowRuntimeWithConfig(t, fmt.Sprintf(`{
		"log":{"disabled":true},
		"dns":{
			"servers":[{"type":"hosts","tag":"local-hosts","predefined":{"alias.example":["127.0.0.1"]}}],
			"final":"local-hosts"
		},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,"xdial_flow_metadata":true}],
		"outbounds":[{"type":"direct","tag":"direct"}],
		"route":{
			"rules":[{"action":"resolve","server":"local-hosts"}],
			"final":"direct"
		}
	}`, port))
	defer rt.Stop()

	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "", "")
	domainDest := M.ParseSocksaddrHostPort("alias.example", serverAddr.Port)

	for _, domainFirst := range []bool{true, false} {
		t.Run(fmt.Sprintf("domain-first=%t", domainFirst), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			deadline, _ := ctx.Deadline()

			firstDest := serverAddr
			secondDest := domainDest
			if domainFirst {
				firstDest = domainDest
				secondDest = serverAddr
			}

			conn, err := client.ListenPacket(ctx, firstDest)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := conn.SetDeadline(deadline); err != nil {
				t.Fatal(err)
			}
			packetConn, ok := conn.(N.PacketConn)
			if !ok {
				t.Fatalf("socks ListenPacket returned %T, want N.PacketConn", conn)
			}

			sendAndVerify := func(dest M.Socksaddr, payload string) {
				t.Helper()
				pkt := buf.NewPacket()
				pkt.Resize(N.CalculateFrontHeadroom(packetConn), 0)
				_, _ = pkt.WriteString(payload)
				if err := packetConn.WritePacket(pkt, dest); err != nil {
					t.Fatalf("send %q to %s: %v", payload, dest, err)
				}
				reply := buf.NewPacket()
				defer reply.Release()
				from, err := packetConn.ReadPacket(reply)
				if err != nil {
					t.Fatalf("read reply for %s: %v", dest, err)
				}
				if from != dest || string(reply.Bytes()) != payload {
					t.Fatalf("reply for %s: got %q from %s, want %q from %s", dest, string(reply.Bytes()), from, payload, dest)
				}
			}

			// Interleave writes to both logical targets sharing the same resolved IP:port.
			sendAndVerify(firstDest, "first-1")
			sendAndVerify(secondDest, "second-1")
			sendAndVerify(firstDest, "first-2")
			sendAndVerify(secondDest, "second-2")
		})
	}
}
