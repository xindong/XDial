//go:build !windows

package libbox

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
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
