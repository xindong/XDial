package libbox

import (
	"context"
	"fmt"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/sing/service"
)

// All cold AnyConnect rule fetches in the Apple host share sslcon's process
// session. The traffic runtime lives in the separate packet tunnel provider.
var appleColdVPNLease = make(chan struct{}, 1)

func fetchAppleColdRule(profile *config.Profile, lineID, basePath, url string, limit int64) ([]byte, error) {
	data, err := config.GenerateAppleColdRuleAcquisition(profile, lineID, basePath, appleResourceDNS())
	if err != nil {
		return nil, err
	}
	outbound, resolver, err := resourceAcquisitionTags(data)
	if err != nil {
		return nil, err
	}
	line := profile.FindLine(lineID)
	if line == nil {
		return nil, fmt.Errorf("rule-set download Line is unavailable")
	}
	parent, cancel := context.WithTimeout(context.Background(), lineProfileSourceTimeout)
	defer cancel()
	ctx := boxContext(parent)
	switch line.Type {
	case config.LineTypeVPN:
		if line.VPNUsername == "" || line.VPNPassword == "" {
			return nil, fmt.Errorf("rule-set download AnyConnect credentials are missing")
		}
		select {
		case appleColdVPNLease <- struct{}{}:
			defer func() { <-appleColdVPNLease }()
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		ip, err := ResolveServerIPv4(line.VPNServer)
		if err != nil {
			return nil, err
		}
		vpn, err := New(nil).createAnyConnectRuntimeCapability(startVPNConfig(
			line.VPNServer, ip, line.VPNUsername, line.VPNPassword, line.AllowInsecure,
		))
		if err != nil {
			return nil, redactedFailure{"rule-set download AnyConnect connection failed", err}
		}
		defer vpn.stop()
		ctx = service.ContextWith[*anyConnectLineRuntime](ctx, vpn.line)
	case config.LineTypeTailscale:
		locks, err := acquireTailscaleStateLocks(string(data))
		if err != nil {
			return nil, err
		}
		defer releaseTailscaleStateLocks(locks)
	}

	resource, err := newResourceBox(ctx, data, outbound, resolver)
	if err != nil {
		return nil, err
	}
	defer resource.instance.Close()
	if line.Type == config.LineTypeTailscale {
		if err := resource.waitForRuleExitNode(outbound, line.TailscaleExitNode, line.TailscaleMagicDNS); err != nil {
			return nil, err
		}
	}
	return resource.fetch(url, limit)
}
