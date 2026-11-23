//go:build with_gvisor && !windows

package libbox

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/kafeifei/xdial/core/engine"
	M "github.com/sagernet/sing/common/metadata"
	N "github.com/sagernet/sing/common/network"
	"github.com/sagernet/sing/protocol/socks"
)

// Observe each destination on the actual VPNBridge tunnel output.
func TestTransparentSOCKSUDPMultipleDestinationsOnVPNBridge(t *testing.T) {
	bridge, err := engine.NewVPNBridge("10.0.0.2", 1400)
	if err != nil {
		t.Fatal(err)
	}
	session := newFakeConnSession()
	bridge.Start(session)
	defer func() {
		close(session.CloseChan)
		bridge.Close()
	}()
	port := freeFlowCorrectionPort(t)
	config := fmt.Sprintf(`{
		"log":{"disabled":true},
		"inbounds":[{"type":"socks","tag":"flow","listen":"127.0.0.1","listen_port":%d,"xdial_flow_metadata":true}],
		"outbounds":[{"type":"vpn","tag":"vpn"}],"route":{"final":"vpn"}
	}`, port)
	_, _, stop := startBoxOffline(t, []byte(config), bridge)
	defer stop()
	client := socks.NewClient(N.SystemDialer, M.ParseSocksaddrHostPort("127.0.0.1", uint16(port)), socks.Version5, "", "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, err := client.ListenPacket(ctx, M.ParseSocksaddr("192.0.2.10:3479"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	deadline, _ := ctx.Deadline()
	if err := conn.SetDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	for i, ip := range []string{"192.0.2.10", "192.0.2.20", "192.0.2.10", "192.0.2.20"} {
		if _, err := conn.WriteTo([]byte{byte(i)}, M.ParseSocksaddrHostPort(ip, 3479)); err != nil {
			t.Fatal(err)
		}
		waitForTunnelUDP(t, session, ip, 3479, 3*time.Second)
	}
}
