package libbox

import (
	"context"
	"fmt"
	"net/netip"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/sing-box/adapter"
	C "github.com/sagernet/sing-box/constant"
)

// StartAndroidSession selects the effective protocol from the shared Profile.
// The host supplies TUN/protection/interface facts before calling it. Credentials
// remain in memory; no platform UI duplicates active-Line selection rules.
func (l *Libbox) StartAndroidSession(profileJSON, configJSON, systemDNSJSON string) error {
	profile, err := config.ParseRuntimeProfile([]byte(profileJSON))
	if err != nil {
		return err
	}
	if _, err = config.BuildConnectionPlan(profile); err != nil {
		return err
	}
	line := profile.ActiveVPNLine()
	tail, err := config.ActiveTailscaleLine(profile)
	if err != nil {
		return err
	}
	tailID, tailIdentity := "", ""
	if tail != nil {
		tailID = tail.ID
		tailIdentity, err = lineRuntimeIdentity(profile, tail)
		if err != nil {
			return err
		}
	}
	if tail != nil {
		if err = validateAndroidTailscaleTransport(configJSON, tailID, tailIdentity); err != nil {
			return err
		}
	}
	if line == nil {
		if tail != nil {
			return l.StartStandaloneWithTailscaleLineID(tailID, tailIdentity, configJSON)
		}
		return l.StartStandalone(configJSON)
	}
	if strings.TrimSpace(line.VPNServer) == "" || strings.TrimSpace(line.VPNUsername) == "" || line.VPNPassword == "" {
		return fmt.Errorf("AnyConnect credentials are missing")
	}
	address, err := l.resolveAndroidServer(line.VPNServer, systemDNSJSON)
	if err != nil {
		return err
	}
	identity, err := lineRuntimeIdentity(profile, line)
	if err != nil {
		return err
	}
	return l.StartResolvedWithLineRuntimes(line.VPNServer, address, line.VPNUsername, line.VPNPassword, line.AllowInsecure, identity, tailID, tailIdentity, configJSON)
}

// The VPN server is a transport endpoint on the captured Underlay, not user
// traffic. Its bootstrap lookup uses a separate sing-box Direct DNS transport,
// with the same protected socket contract and OS DNS snapshot. No TUN or user
// route is installed by this temporary Box; the sole traffic reader is untouched.
func (l *Libbox) resolveAndroidServer(server, systemDNSJSON string) (string, error) {
	return l.resolveAndroidServerContext(context.Background(), server, systemDNSJSON)
}
func (l *Libbox) resolveAndroidServerContext(ctx context.Context, server, systemDNSJSON string) (string, error) {
	host, err := serverHostname(server)
	if err != nil {
		return "", err
	}
	if address, err := netip.ParseAddr(host); err == nil {
		if address.Is4() {
			return address.String(), nil
		}
		return "", fmt.Errorf("server endpoint is not IPv4")
	}
	parent, cancel := context.WithTimeout(ctx, serverAddressResolutionTimeout)
	defer cancel()
	bootstrap, err := l.newAndroidBootstrap(parent, systemDNSJSON)
	if err != nil {
		return "", err
	}
	defer bootstrap.instance.Close()
	addresses, err := bootstrap.router.Lookup(bootstrap.ctx, host, adapter.DNSQueryOptions{Transport: bootstrap.transport, Strategy: C.DomainStrategyIPv4Only})
	if err != nil {
		return "", redactedFailure{"server IPv4 lookup failed", err}
	}
	for _, address := range addresses {
		if address.Is4() {
			return address.String(), nil
		}
	}
	return "", fmt.Errorf("server endpoint has no IPv4 address")
}

func (l *Libbox) StartAndroidSessionResult(profileJSON, configJSON, systemDNSJSON string) *StartupResult {
	return startupResult("", l.StartAndroidSession(profileJSON, configJSON, systemDNSJSON))
}
