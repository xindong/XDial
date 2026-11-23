package libbox

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"time"

	"github.com/kafeifei/xdial/core/config"
	"github.com/kafeifei/xdial/core/subscription"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/option"
	jsonext "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
	"github.com/sagernet/sing/service"
)

type androidBootstrap struct {
	instance  *box.Box
	ctx       context.Context
	router    adapter.DNSRouter
	transport adapter.DNSTransport
	outbound  adapter.Outbound
}

// This capability has no ingress, cache or user Scenario. Both DNS and numeric
// dialing belong to one protected sing-box Direct transport on the captured OS
// network. It is safe while an old OS TUN remains installed with no reader.
func (l *Libbox) newAndroidBootstrap(parent context.Context, systemDNSJSON string) (*androidBootstrap, error) {
	var servers []string
	if json.Unmarshal([]byte(systemDNSJSON), &servers) != nil {
		return nil, fmt.Errorf("invalid system DNS snapshot")
	}
	profile := &config.Profile{Lines: []config.Line{{ID: "direct", Type: config.LineTypeDirect, Enabled: true}}, Scenarios: []config.Scenario{{ID: "bootstrap", DefaultLineID: "direct"}}, ActiveScenarioID: "bootstrap"}
	data, err := config.GenerateSingBoxAndroid(profile, "", servers)
	if err != nil {
		return nil, err
	}
	return l.newAndroidResourceTransport(parent, data, "direct", "")
}

func (l *Libbox) newAndroidAcquisition(parent context.Context, profile *config.Profile, lineID, systemDNSJSON, basePath string) (*androidBootstrap, error) {
	var servers []string
	if json.Unmarshal([]byte(systemDNSJSON), &servers) != nil {
		return nil, fmt.Errorf("invalid system DNS snapshot")
	}
	data, err := config.GenerateAndroidAcquisition(profile, lineID, basePath, servers)
	if err != nil {
		return nil, err
	}
	outboundTag, resolverTag, err := resourceAcquisitionTags(data)
	if err != nil {
		return nil, err
	}
	return l.newAndroidResourceTransport(parent, data, outboundTag, resolverTag)
}

func (l *Libbox) newAndroidResourceTransport(parent context.Context, data []byte, outboundTag, resolverTag string) (*androidBootstrap, error) {
	if parent.Err() != nil {
		return nil, parent.Err()
	}
	l.mu.Lock()
	platform := l.platform.lineRuntimeCapability()
	l.mu.Unlock()
	if platform.socketProtector == nil {
		return nil, fmt.Errorf("protected network unavailable")
	}
	ctx := service.ContextWith[adapter.PlatformInterface](boxContext(parent), platform)
	return newResourceBox(ctx, data, outboundTag, resolverTag)
}

// newResourceBox starts one isolated resource capability: no ingress, cache or
// user Scenario. DNS and numeric dialing both belong to outboundTag's exact Line.
// ctx decides socket ownership: Android supplies its protecting platform; Apple
// callers run where XDial capture cannot see these sockets.
func newResourceBox(ctx context.Context, data []byte, outboundTag, resolverTag string) (*androidBootstrap, error) {
	options, err := jsonext.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		return nil, err
	}
	options.Inbounds = nil
	options.Experimental = nil
	options.Log = &option.LogOptions{Disabled: true}
	instance, err := box.New(box.Options{Options: options, Context: ctx})
	if err != nil {
		return nil, err
	}
	fail := func() (*androidBootstrap, error) {
		instance.Close()
		return nil, fmt.Errorf("protected network unavailable")
	}
	if err = instance.Start(); err != nil {
		instance.Close()
		return nil, redactedFailure{"protected network unavailable", err}
	}
	router := service.FromContext[adapter.DNSRouter](ctx)
	transports := service.FromContext[adapter.DNSTransportManager](ctx)
	if router == nil || transports == nil {
		return fail()
	}
	var transport adapter.DNSTransport
	var found bool
	if resolverTag == "" {
		transport, found = directLineResolver(transports)
	} else {
		transport, found = transports.Transport(resolverTag)
	}
	if !found {
		return fail()
	}
	outbound, found := instance.Outbound().Outbound(outboundTag)
	if !found {
		return fail()
	}
	return &androidBootstrap{instance, ctx, router, transport, outbound}, nil
}

func (b *androidBootstrap) fetch(rawURL string, limit int64) ([]byte, error) {
	return b.fetchResource(rawURL, limit, false)
}
func (b *androidBootstrap) fetchResource(rawURL string, limit int64, source bool) ([]byte, error) {
	lookup := func(ctx context.Context, _, host string) ([]netip.Addr, error) {
		return b.router.Lookup(ctx, host, adapter.DNSQueryOptions{Transport: b.transport, DisableCache: true})
	}
	dial := func(ctx context.Context, network, address string) (net.Conn, error) {
		target, err := netip.ParseAddrPort(address)
		if err != nil {
			return nil, fmt.Errorf("numeric resource destination required")
		}
		return b.outbound.DialContext(ctx, network, M.SocksaddrFrom(target.Addr(), target.Port()))
	}
	fetch := subscription.FetchStrictBytesWithNetworkContext
	if source {
		fetch = subscription.FetchProfileSourceBytesWithNetworkContext
	}
	content, err := fetch(b.ctx, rawURL, limit, lookup, dial)
	if err != nil {
		return nil, redactedFailure{"protected resource fetch failed", err}
	}
	return content, nil
}

// CancelPreparation is nonblocking, so an Android user stop can interrupt DNS or
// HTTP while its serial service worker is still preparing. Stop performs cleanup.
func (l *Libbox) CancelPreparation() {
	l.mu.Lock()
	if l.androidRefreshCancel != nil {
		l.androidRefreshCancel()
	}
	cancel := l.startPreparationCancel
	androidSwitchCancel := l.androidSwitchCancel
	switchCancel := l.switchPreparationCancel
	if l.preparedSwitch != nil {
		switchCancel = l.preparedSwitch.runtimeCancel
	}
	l.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if androidSwitchCancel != nil {
		androidSwitchCancel()
	}
	if switchCancel != nil {
		switchCancel()
	}
}

// PrepareAndroidConfig materializes validated offline caches before starting the
// sole data-plane reader. Unbound GenerateAndroidConfig is deliberately cache-only.
// Explicit acquisition never silently falls back to Direct. Protocol-owned
// sessions still require a separate identity lease; native proxies are isolated.
func (l *Libbox) PrepareAndroidConfig(profileJSON, systemDNSJSON, basePath string) (string, error) {
	return l.prepareAndroidConfigContext(context.Background(), profileJSON, systemDNSJSON, basePath)
}

func (l *Libbox) prepareAndroidConfigContext(parentContext context.Context, profileJSON, systemDNSJSON, basePath string) (string, error) {
	l.mu.Lock()
	if l.running || l.startPreparing || l.cleaning {
		l.mu.Unlock()
		return "", fmt.Errorf("configuration preparation requires an idle runtime")
	}
	parent, cancel := context.WithTimeout(parentContext, 60*time.Second)
	l.startPreparing = true
	l.startPreparationCancel = cancel
	l.startPreparationUsers.Add(1)
	l.mu.Unlock()
	var bootstrap *androidBootstrap
	defer func() {
		cancel()
		if bootstrap != nil {
			bootstrap.instance.Close()
		}
		l.mu.Lock()
		l.startPreparing = false
		l.startPreparationCancel = nil
		l.mu.Unlock()
		l.startPreparationUsers.Done()
	}()
	fetch := func(rawURL string, limit int64) ([]byte, error) {
		if err := parent.Err(); err != nil {
			return nil, redactedFailure{"configuration preparation cancelled", err}
		}
		if bootstrap == nil {
			var err error
			bootstrap, err = l.newAndroidBootstrap(parent, systemDNSJSON)
			if err != nil {
				return nil, err
			}
		}
		return bootstrap.fetch(rawURL, limit)
	}
	profile, err := config.ParseRuntimeProfile([]byte(profileJSON))
	if err != nil {
		return "", err
	}
	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		return "", err
	}
	_, err = materializeNERuleSetsWithFetchForRule(profile, basePath, func(rule *config.RuleSet) neRuleSetFetcher {
		if rule.EffectiveFetchLineID() != "direct" {
			return func(rawURL string, limit int64) ([]byte, error) {
				resource, err := l.newAndroidAcquisition(parent, profile, rule.EffectiveFetchLineID(), systemDNSJSON, basePath)
				if err != nil {
					return nil, err
				}
				defer resource.instance.Close()
				return resource.fetch(rawURL, limit)
			}
		}
		return fetch
	}, nil)
	if err != nil {
		return "", err
	}
	var servers []string
	if json.Unmarshal([]byte(systemDNSJSON), &servers) != nil {
		return "", fmt.Errorf("invalid system DNS snapshot")
	}
	data, err := config.GenerateSingBoxAndroid(profile, basePath, servers)
	if err != nil {
		return "", err
	}
	data, err = materializeGeneratedNERuleSets(data, ruleDir, fetch)
	if err != nil {
		return "", err
	}
	if parent.Err() != nil {
		return "", redactedFailure{"configuration preparation cancelled", parent.Err()}
	}
	if len(data) > maxNEConfigBytes {
		return "", fmt.Errorf("generated configuration exceeds limit")
	}
	return string(data), nil
}

func (l *Libbox) PrepareAndroidConfigResult(profileJSON, systemDNSJSON, basePath string) *StartupResult {
	return startupResult(l.PrepareAndroidConfig(profileJSON, systemDNSJSON, basePath))
}
