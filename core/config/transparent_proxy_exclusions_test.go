package config

import (
	"encoding/json"
	"net/netip"
	"reflect"
	"testing"
)

func excludedContainsIP(t *testing.T, networks []TransparentProxyRemoteNetwork, rawIP string) bool {
	t.Helper()
	addr := netip.MustParseAddr(rawIP)
	for _, network := range networks {
		prefix, err := netip.ParsePrefix(network.Address + "/" + itoa(network.PrefixLength))
		if err != nil {
			t.Fatalf("invalid excluded network %+v: %v", network, err)
		}
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits [12]byte
	i := len(digits)
	neg := n < 0
	if neg {
		n = -n
	}
	for n > 0 {
		i--
		digits[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		digits[i] = '-'
	}
	return string(digits[i:])
}

func testOverseasProfile() *Profile {
	return &Profile{
		Lines: []Line{
			{ID: "direct", Name: "直连", Type: LineTypeDirect, Enabled: true},
			{
				ID:          "corp",
				Name:        "公司 VPN",
				Type:        LineTypeVPN,
				Enabled:     true,
				VPNServer:   "vpn.example.com:443",
				VPNUsername: "employee",
				VPNPassword: "secret",
			},
		},
		RuleSets: []RuleSet{
			{
				ID:      "lan",
				Name:    "本地局域网",
				Type:    RuleSetTypeManual,
				Enabled: true,
				CIDRs:   []string{"192.168.0.0/16"},
			},
			{
				ID:      "intranet",
				Name:    "公司内网",
				Type:    RuleSetTypeManual,
				Enabled: true,
				Domains: []string{"corp.example"},
				CIDRs:   []string{"10.0.0.0/8", "172.27.0.0/16"},
			},
			{
				ID:      "corp-cidrs-only",
				Name:    "公司内网网段",
				Type:    RuleSetTypeManual,
				Enabled: true,
				CIDRs:   []string{"10.0.0.0/8", "172.27.0.0/16"},
			},
			{
				ID:               "cn-domains",
				Name:             "国内网站",
				Type:             RuleSetTypeURL,
				Enabled:          true,
				URL:              "https://example.com/cn-domains.srs",
				RuntimeMatchKind: RuleSetMatchDomain,
			},
			{
				ID:               "cn-ip",
				Name:             "国内 IP",
				Type:             RuleSetTypeURL,
				Enabled:          true,
				URL:              "https://example.com/cn-ip.srs",
				RuntimeMatchKind: RuleSetMatchIP,
			},
		},
		Scenarios: []Scenario{
			{
				ID:   "overseas",
				Name: "在国外",
				Bindings: []RuleBinding{
					{RuleSetID: "lan", LineID: "direct"},
					{RuleSetID: "intranet", LineID: "corp"},
					{RuleSetID: "cn-domains", LineID: "corp"},
					{RuleSetID: "cn-ip", LineID: "corp"},
				},
				DefaultLineID: "direct",
			},
			{
				ID:   "domain-before-lan",
				Name: "域名优先于局域网",
				Bindings: []RuleBinding{
					{RuleSetID: "intranet", LineID: "corp"},
					{RuleSetID: "lan", LineID: "direct"},
				},
				DefaultLineID: "corp",
			},
			{
				ID:   "cidr-only-vpn-before-lan",
				Name: "纯网段 VPN 优先于局域网",
				Bindings: []RuleBinding{
					{RuleSetID: "corp-cidrs-only", LineID: "corp"},
					{RuleSetID: "lan", LineID: "direct"},
				},
				DefaultLineID: "corp",
			},
			{
				ID:   "ip-only-vpn-default-direct",
				Name: "纯网段 VPN 默认直连",
				Bindings: []RuleBinding{
					{RuleSetID: "corp-cidrs-only", LineID: "corp"},
				},
				DefaultLineID: "direct",
			},
			{
				ID:            "all-vpn",
				Name:          "全局 VPN",
				DefaultLineID: "corp",
			},
			{
				ID:            "office",
				Name:          "在公司",
				DefaultLineID: "direct",
			},
		},
		ActiveScenarioID: "overseas",
	}
}

func TestComputeDirectExcludedNetworks_OverseasExcludesLANAndProtectsVPNAndDNS(t *testing.T) {
	profile := testOverseasProfile()
	ruleInfo := map[string]TransparentProxyRuleSetIPInfo{
		"cn-domains": {BlocksAll: true},
		"cn-ip":      {}, // Public China IPs have no private overlap
	}

	// Case 1: public system DNS -> whole 192.168.0.0/16 excluded cleanly as 1 CIDR.
	got, err := ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
		ruleInfo,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []TransparentProxyRemoteNetwork{{Address: "192.168.0.0", PrefixLength: 16}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}

	// Case 2: LAN router as system DNS (192.168.68.1) -> LAN peers excluded, router DNS stays captured.
	gotWithRouterDNS, err := ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		[]string{"192.168.68.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
		ruleInfo,
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	for _, lanPeer := range []string{"192.168.68.83", "192.168.68.96", "192.168.1.10"} {
		if !excludedContainsIP(t, gotWithRouterDNS, lanPeer) {
			t.Errorf("expected LAN peer %s to be excluded, got %+v", lanPeer, gotWithRouterDNS)
		}
	}
	for _, mustCapture := range []string{"192.168.68.1", "10.0.0.1", "10.10.20.30", "172.27.0.10", "172.16.5.5", "100.64.0.1", "8.8.8.8"} {
		if excludedContainsIP(t, gotWithRouterDNS, mustCapture) {
			t.Errorf("expected %s to remain captured inside transparent proxy, got %+v", mustCapture, gotWithRouterDNS)
		}
	}
}

func TestComputeDirectExcludedNetworks_PreservesEarlierNonDirectDomainPrecedence(t *testing.T) {
	profile := testOverseasProfile()
	local := []netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")}
	dns := []string{"192.168.68.1"}

	// Case 1: corp.example -> VPN BEFORE 192.168.0.0/16 -> Direct.
	// A corporate hostname resolving to 192.168.1.20 must hit the earlier VPN
	// binding in sing-box, so nothing after the VPN domain rule may be excluded.
	profile.ActiveScenarioID = "domain-before-lan"
	gotDomainBeforeLAN, err := ComputeTransparentProxyDirectExcludedNetworks(profile, dns, local)
	if err != nil {
		t.Fatalf("domain-before-lan error: %v", err)
	}
	if len(gotDomainBeforeLAN) != 0 {
		t.Fatalf("earlier non-Direct domain rule must prevent excluding later LAN CIDRs, got %+v", gotDomainBeforeLAN)
	}

	// Case 2: overseas has intranet/cn-domains -> VPN BEFORE route.final = direct.
	// A local hotspot subnet (172.20.10.0/28) that is NOT covered by an earlier
	// explicit direct binding must NOT bypass the preceding VPN domain rules.
	profile.ActiveScenarioID = "overseas"
	gotOverseasHotspot, err := ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		[]string{"172.20.10.1"},
		[]netip.Prefix{netip.MustParsePrefix("172.20.10.0/28")},
		map[string]TransparentProxyRuleSetIPInfo{
			"cn-domains": {BlocksAll: true},
			"cn-ip":      {},
		},
	)
	if err != nil {
		t.Fatalf("overseas hotspot error: %v", err)
	}
	if excludedContainsIP(t, gotOverseasHotspot, "172.20.10.5") {
		t.Fatalf("fallback local subnet after non-Direct domain rules must stay captured: %+v", gotOverseasHotspot)
	}
	if !excludedContainsIP(t, gotOverseasHotspot, "192.168.68.83") {
		t.Fatalf("explicit LAN binding BEFORE VPN domain rules must still be excluded: %+v", gotOverseasHotspot)
	}

	// Case 3: Pure IP VPN rules (no domain rules) BEFORE default: direct.
	// Non-conflicting LAN / hotspot subnets ARE excluded while VPN CIDRs stay captured.
	profile.ActiveScenarioID = "ip-only-vpn-default-direct"
	gotIPOnlyVPN, err := ComputeTransparentProxyDirectExcludedNetworks(
		profile,
		[]string{"172.20.10.1"},
		[]netip.Prefix{netip.MustParsePrefix("172.20.10.0/28")},
	)
	if err != nil {
		t.Fatalf("ip-only-vpn error: %v", err)
	}
	for _, peer := range []string{"172.20.10.5", "192.168.68.83"} {
		if !excludedContainsIP(t, gotIPOnlyVPN, peer) {
			t.Errorf("expected %s to be excluded when only non-overlapping VPN CIDRs precede final:direct: %+v", peer, gotIPOnlyVPN)
		}
	}
	for _, mustCapture := range []string{"172.20.10.1", "172.27.1.1", "10.1.2.3"} {
		if excludedContainsIP(t, gotIPOnlyVPN, mustCapture) {
			t.Errorf("expected %s to remain captured: %+v", mustCapture, gotIPOnlyVPN)
		}
	}
}

func TestComputeDirectExcludedNetworks_ScenarioSwitchingUpdatesExclusions(t *testing.T) {
	profile := testOverseasProfile()
	local := []netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")}
	dns := []string{"192.168.68.1"}

	// 1. Pure CIDR VPN (10/8, 172.27/16) -> VPN, then LAN (192.168/16) -> Direct, default -> VPN.
	profile.ActiveScenarioID = "cidr-only-vpn-before-lan"
	cidrVPN, err := ComputeTransparentProxyDirectExcludedNetworks(profile, dns, local)
	if err != nil {
		t.Fatalf("cidr-only-vpn-before-lan error: %v", err)
	}
	if !excludedContainsIP(t, cidrVPN, "192.168.68.83") {
		t.Errorf("cidr-only-vpn-before-lan should exclude LAN peer 192.168.68.83: %+v", cidrVPN)
	}
	if excludedContainsIP(t, cidrVPN, "192.168.68.1") || excludedContainsIP(t, cidrVPN, "10.1.1.1") || excludedContainsIP(t, cidrVPN, "172.27.1.1") {
		t.Errorf("cidr-only-vpn-before-lan must keep DNS and VPN ranges captured: %+v", cidrVPN)
	}

	// 2. All-VPN: default -> vpn, no LAN direct rule.
	profile.ActiveScenarioID = "all-vpn"
	allVPN, err := ComputeTransparentProxyDirectExcludedNetworks(profile, dns, local)
	if err != nil {
		t.Fatalf("all-vpn error: %v", err)
	}
	if len(allVPN) != 0 {
		t.Fatalf("all-vpn must not exclude any LAN networks, got %+v", allVPN)
	}

	// 3. Office: default -> direct, no non-direct rules at all -> all RFC1918 + ULA minus DNS.
	profile.ActiveScenarioID = "office"
	office, err := ComputeTransparentProxyDirectExcludedNetworks(profile, dns, local)
	if err != nil {
		t.Fatalf("office error: %v", err)
	}
	for _, ip := range []string{"10.0.0.5", "172.16.1.5", "192.168.68.83", "fd12:3456::1"} {
		if !excludedContainsIP(t, office, ip) {
			t.Errorf("office pure-direct should exclude %s, got %+v", ip, office)
		}
	}
	for _, mustCapture := range []string{"192.168.68.1", "100.64.0.5", "1.1.1.1", "2001:4860:4860::8888"} {
		if excludedContainsIP(t, office, mustCapture) {
			t.Errorf("office must keep %s captured, got %+v", mustCapture, office)
		}
	}
}

func TestComputeDirectExcludedNetworks_VPNSubrangeCarvedOutBeforeDirectLAN(t *testing.T) {
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "corp", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:443", VPNUsername: "u", VPNPassword: "p"},
		},
		RuleSets: []RuleSet{
			{ID: "corp-192", Type: RuleSetTypeManual, Enabled: true, CIDRs: []string{"192.168.100.0/24"}},
			{ID: "lan", Type: RuleSetTypeManual, Enabled: true, CIDRs: []string{"192.168.0.0/16"}},
		},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "corp-192", LineID: "corp"},
				{RuleSetID: "lan", LineID: "direct"},
			},
			DefaultLineID: "corp",
		}},
		ActiveScenarioID: "s",
	}

	got, err := ComputeTransparentProxyDirectExcludedNetworks(profile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if excludedContainsIP(t, got, "192.168.100.10") {
		t.Fatalf("VPN-bound 192.168.100.0/24 must never be excluded: %+v", got)
	}
	if !excludedContainsIP(t, got, "192.168.68.83") {
		t.Fatalf("non-conflicting LAN 192.168.68.83 should be excluded: %+v", got)
	}
}

func TestComputeDirectExcludedNetworks_ApplicationAttributionSafety(t *testing.T) {
	baseLines := []Line{
		{ID: "direct", Type: LineTypeDirect, Enabled: true},
		{
			ID:             "px",
			Type:           LineTypeTrojan,
			Enabled:        true,
			TrojanServer:   "px.example.com",
			TrojanPort:     443,
			TrojanPassword: "secret",
			TrojanSNI:      "px.example.com",
		},
	}
	appRule := RuleSet{
		ID:           "app-rule",
		Type:         RuleSetTypeApplication,
		Enabled:      true,
		Applications: []ApplicationMatch{{Path: "/Applications/TestApp.app", BundleIdentifier: "com.example.test"}},
	}
	lanRule := RuleSet{
		ID:      "lan",
		Type:    RuleSetTypeManual,
		Enabled: true,
		CIDRs:   []string{"192.168.0.0/16"},
	}

	// Non-direct app rule BEFORE lan -> direct: must NOT exclude anything.
	appFirst := &Profile{
		Lines:    baseLines,
		RuleSets: []RuleSet{appRule, lanRule},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "app-rule", LineID: "px"},
				{RuleSetID: "lan", LineID: "direct"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "s",
	}
	gotAppFirst, err := ComputeTransparentProxyDirectExcludedNetworks(
		appFirst,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(gotAppFirst) != 0 {
		t.Fatalf("non-direct application rule before LAN must prevent exclusions, got %+v", gotAppFirst)
	}

	// Explicit lan -> direct BEFORE non-direct app rule: 192.168.0.0/16 IS excluded,
	// while other RFC1918 ranges stay captured for the app rule.
	lanFirst := &Profile{
		Lines:    baseLines,
		RuleSets: []RuleSet{appRule, lanRule},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "lan", LineID: "direct"},
				{RuleSetID: "app-rule", LineID: "px"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "s",
	}
	gotLanFirst, err := ComputeTransparentProxyDirectExcludedNetworks(
		lanFirst,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("10.0.1.0/24")},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !excludedContainsIP(t, gotLanFirst, "192.168.68.83") {
		t.Fatalf("LAN rule preceding app rule should be excluded: %+v", gotLanFirst)
	}
	if excludedContainsIP(t, gotLanFirst, "10.0.1.5") || excludedContainsIP(t, gotLanFirst, "172.16.0.5") {
		t.Fatalf("ranges falling after non-direct app rule must remain captured: %+v", gotLanFirst)
	}

	// Direct app rule alone with default proxy must NOT exclude LAN for other apps.
	directAppOnly := &Profile{
		Lines:    baseLines,
		RuleSets: []RuleSet{appRule},
		Scenarios: []Scenario{{
			ID:            "s",
			Bindings:      []RuleBinding{{RuleSetID: "app-rule", LineID: "direct"}},
			DefaultLineID: "px",
		}},
		ActiveScenarioID: "s",
	}
	gotDirectApp, err := ComputeTransparentProxyDirectExcludedNetworks(
		directAppOnly,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(gotDirectApp) != 0 {
		t.Fatalf("direct application rule must not globally exclude LAN: %+v", gotDirectApp)
	}
}

func TestComputeDirectExcludedNetworks_TailscaleMagicDNSSafety(t *testing.T) {
	tsLine := Line{
		ID:                "ts",
		Type:              LineTypeTailscale,
		Enabled:           true,
		TailscaleExitNode: "exit-node",
		TailscaleMagicDNS: true,
	}
	// Active MagicDNS with default direct and no explicit LAN rule: dynamic subnet
	// router routes could match RFC1918 before final: direct, so exclude nothing.
	noExplicitLAN := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			tsLine,
		},
		RuleSets: []RuleSet{{
			ID:      "only-cidr",
			Type:    RuleSetTypeManual,
			Enabled: true,
			CIDRs:   []string{"10.99.0.0/16"},
		}},
		Scenarios: []Scenario{{
			ID:            "s",
			Bindings:      []RuleBinding{{RuleSetID: "only-cidr", LineID: "ts"}},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "s",
	}
	gotNoLAN, err := ComputeTransparentProxyDirectExcludedNetworks(
		noExplicitLAN,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(gotNoLAN) != 0 {
		t.Fatalf("active Tailscale MagicDNS without explicit LAN direct rule must not exclude fallback ranges: %+v", gotNoLAN)
	}

	// Explicit LAN -> direct precedes MagicDNS peer/subnet routes in route.rules.
	withExplicitLAN := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			tsLine,
		},
		RuleSets: []RuleSet{
			{ID: "lan", Type: RuleSetTypeManual, Enabled: true, CIDRs: []string{"192.168.0.0/16"}},
			{ID: "only-domain", Type: RuleSetTypeManual, Enabled: true, Domains: []string{"ts-bound.example"}},
		},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "lan", LineID: "direct"},
				{RuleSetID: "only-domain", LineID: "ts"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "s",
	}
	gotWithLAN, err := ComputeTransparentProxyDirectExcludedNetworks(
		withExplicitLAN,
		[]string{"1.1.1.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !excludedContainsIP(t, gotWithLAN, "192.168.68.83") {
		t.Fatalf("explicit LAN rule preceding MagicDNS should be excluded: %+v", gotWithLAN)
	}
	if excludedContainsIP(t, gotWithLAN, "10.0.0.1") || excludedContainsIP(t, gotWithLAN, "100.64.0.1") {
		t.Fatalf("non-LAN / Tailnet ranges must stay captured with MagicDNS: %+v", gotWithLAN)
	}
}

func TestComputeDirectExcludedNetworks_URLAndNativeAndSubscriptionRules(t *testing.T) {
	// URL rule set containing corporate private CIDR 172.27.0.0/16 -> vpn blocks that CIDR.
	profile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "corp", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:443", VPNUsername: "u", VPNPassword: "p"},
		},
		RuleSets: []RuleSet{
			{ID: "corp-url", Type: RuleSetTypeURL, Enabled: true, URL: "https://example.com/corp.srs", RuntimeMatchKind: RuleSetMatchIP},
			{ID: "native-lan", Type: RuleSetTypeNative, Enabled: true, NativeRule: json.RawMessage(`{"ip_cidr":["192.168.0.0/16","172.27.0.0/16"]}`)},
		},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "corp-url", LineID: "corp"},
				{RuleSetID: "native-lan", LineID: "direct"},
			},
			DefaultLineID: "corp",
		}},
		ActiveScenarioID: "s",
	}
	got, err := ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		[]string{"1.1.1.1"},
		nil,
		map[string]TransparentProxyRuleSetIPInfo{
			"corp-url": {
				BlockCIDRs: []netip.Prefix{netip.MustParsePrefix("172.27.0.0/16")},
			},
		},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if excludedContainsIP(t, got, "172.27.1.5") {
		t.Fatalf("URL rule set VPN CIDR 172.27.0.0/16 must not be excluded: %+v", got)
	}
	if !excludedContainsIP(t, got, "192.168.68.83") {
		t.Fatalf("native LAN rule 192.168.0.0/16 should be excluded: %+v", got)
	}

	// Native logical AND rule bound to direct intersects CIDRs instead of unioning.
	logicalAndProfile := &Profile{
		Lines: profile.Lines,
		RuleSets: []RuleSet{{
			ID:      "native-and",
			Type:    RuleSetTypeNative,
			Enabled: true,
			NativeRule: json.RawMessage(
				`{"type":"logical","mode":"and","rules":[{"ip_cidr":["192.168.0.0/16"]},{"ip_cidr":["192.168.1.0/24"]}]}`,
			),
		}},
		Scenarios: []Scenario{{
			ID:            "s",
			Bindings:      []RuleBinding{{RuleSetID: "native-and", LineID: "direct"}},
			DefaultLineID: "corp",
		}},
		ActiveScenarioID: "s",
	}
	gotAnd, err := ComputeTransparentProxyDirectExcludedNetworks(logicalAndProfile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("native logical AND error: %v", err)
	}
	if !excludedContainsIP(t, gotAnd, "192.168.1.10") {
		t.Fatalf("native logical AND intersection 192.168.1.0/24 should be excluded: %+v", gotAnd)
	}
	if excludedContainsIP(t, gotAnd, "192.168.2.1") {
		t.Fatalf("native logical AND must not exclude addresses outside /24 intersection: %+v", gotAnd)
	}

	// Native default rule with BOTH domain_suffix and ip_cidr evaluates them with
	// OR in sing-box: when bound to VPN, the domain alternative can match a
	// corporate hostname resolving to 192.168.1.10, so later direct exclusions
	// must be blocked completely.
	mixedNativeVPNProfile := &Profile{
		Lines: profile.Lines,
		RuleSets: []RuleSet{
			{
				ID:         "mixed-corp",
				Type:       RuleSetTypeNative,
				Enabled:    true,
				NativeRule: json.RawMessage(`{"domain_suffix":["corp.example"],"ip_cidr":["10.0.0.0/8"]}`),
			},
			{
				ID:      "lan",
				Type:    RuleSetTypeManual,
				Enabled: true,
				CIDRs:   []string{"192.168.0.0/16"},
			},
		},
		Scenarios: []Scenario{{
			ID: "s",
			Bindings: []RuleBinding{
				{RuleSetID: "mixed-corp", LineID: "corp"},
				{RuleSetID: "lan", LineID: "direct"},
			},
			DefaultLineID: "direct",
		}},
		ActiveScenarioID: "s",
	}
	gotMixedNativeVPN, err := ComputeTransparentProxyDirectExcludedNetworks(mixedNativeVPNProfile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("mixed native VPN error: %v", err)
	}
	if len(gotMixedNativeVPN) != 0 {
		t.Fatalf("mixed domain+ip_cidr native VPN rule must block later LAN exclusions, got %+v", gotMixedNativeVPN)
	}

	// Same OR semantics when bound to Direct: ip_cidr branch unconditionally
	// matches 192.168.0.0/16 even when domain_suffix is also present.
	mixedNativeDirectProfile := &Profile{
		Lines: profile.Lines,
		RuleSets: []RuleSet{{
			ID:         "mixed-lan",
			Type:       RuleSetTypeNative,
			Enabled:    true,
			NativeRule: json.RawMessage(`{"domain_suffix":["lan.example"],"ip_cidr":["192.168.0.0/16"]}`),
		}},
		Scenarios: []Scenario{{
			ID:            "s",
			Bindings:      []RuleBinding{{RuleSetID: "mixed-lan", LineID: "direct"}},
			DefaultLineID: "corp",
		}},
		ActiveScenarioID: "s",
	}
	gotMixedNativeDirect, err := ComputeTransparentProxyDirectExcludedNetworks(mixedNativeDirectProfile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("mixed native Direct error: %v", err)
	}
	if !excludedContainsIP(t, gotMixedNativeDirect, "192.168.68.83") {
		t.Fatalf("mixed domain+ip_cidr native Direct rule should exclude ip_cidr branch: %+v", gotMixedNativeDirect)
	}
	if excludedContainsIP(t, gotMixedNativeDirect, "10.0.0.5") {
		t.Fatalf("mixed domain+ip_cidr native Direct rule must not exclude other ranges: %+v", gotMixedNativeDirect)
	}

	// Opaque URL rule set before direct rule fails closed.
	gotOpaque, err := ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		[]string{"1.1.1.1"},
		nil,
		map[string]TransparentProxyRuleSetIPInfo{
			"corp-url": {Opaque: true},
		},
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(gotOpaque) != 0 {
		t.Fatalf("opaque non-direct URL rule set must fail closed, got %+v", gotOpaque)
	}

	// Subscription GEOIP,LAN -> DIRECT excludes private LAN after carving out earlier VPN CIDRs.
	subProfile := &Profile{
		Lines: []Line{
			{ID: "direct", Type: LineTypeDirect, Enabled: true},
			{ID: "corp", Type: LineTypeVPN, Enabled: true, VPNServer: "vpn.example.com:443", VPNUsername: "u", VPNPassword: "p"},
		},
		RuleSets: []RuleSet{
			{ID: "corp-cidr", Type: RuleSetTypeManual, Enabled: true, CIDRs: []string{"10.0.0.0/8"}},
		},
		Subscriptions: []Subscription{{
			ID:      "sub1",
			Name:    "Sub",
			URL:     "https://example.com/sub",
			Enabled: true,
			Lines: []Line{{
				ID:             "n1",
				Name:           "HK",
				Type:           LineTypeTrojan,
				Enabled:        true,
				TrojanServer:   "hk.example.com",
				TrojanPort:     443,
				TrojanPassword: "secret",
				TrojanSNI:      "hk.example.com",
			}},
			Rules: []SubscriptionRule{
				{Type: "IP-CIDR", Value: "192.168.200.0/24", Group: "__default__"},
				{Type: "GEOIP", Value: "LAN", Group: "DIRECT"},
			},
		}},
		Scenarios: []Scenario{{
			ID:                    "s",
			Bindings:              []RuleBinding{{RuleSetID: "corp-cidr", LineID: "corp"}},
			DefaultSubscriptionID: "sub1",
		}},
		ActiveScenarioID: "s",
	}
	gotSub, err := ComputeTransparentProxyDirectExcludedNetworks(subProfile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("subscription error: %v", err)
	}
	if excludedContainsIP(t, gotSub, "10.1.2.3") || excludedContainsIP(t, gotSub, "192.168.200.5") {
		t.Fatalf("VPN/Proxy CIDRs must stay captured before subscription GEOIP,LAN: %+v", gotSub)
	}
	if !excludedContainsIP(t, gotSub, "192.168.68.83") || !excludedContainsIP(t, gotSub, "172.16.5.5") {
		t.Fatalf("subscription GEOIP,LAN -> DIRECT should exclude remaining LAN ranges: %+v", gotSub)
	}

	// Subscription non-Direct domain rule BEFORE GEOIP,LAN -> DIRECT blocks LAN exclusion.
	subProfile.Subscriptions[0].Rules = []SubscriptionRule{
		{Type: "DOMAIN-SUFFIX", Value: "corp.example", Group: "__default__"},
		{Type: "GEOIP", Value: "LAN", Group: "DIRECT"},
	}
	gotSubDomainFirst, err := ComputeTransparentProxyDirectExcludedNetworks(subProfile, []string{"1.1.1.1"}, nil)
	if err != nil {
		t.Fatalf("subscription domain-first error: %v", err)
	}
	if len(gotSubDomainFirst) != 0 {
		t.Fatalf("subscription non-Direct domain rule before GEOIP,LAN must block exclusion, got %+v", gotSubDomainFirst)
	}
}

func TestComputeDirectExcludedNetworks_UnreferencedObjectsHaveNoEffect(t *testing.T) {
	baseline := testOverseasProfile()
	baselineGot, err := ComputeTransparentProxyDirectExcludedNetworks(
		baseline,
		[]string{"192.168.68.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("baseline error: %v", err)
	}

	mutated := testOverseasProfile()
	mutated.Lines = append(mutated.Lines, Line{
		ID:                "unused-ts",
		Type:              LineTypeTailscale,
		Enabled:           true,
		TailscaleExitNode: "exit",
		TailscaleMagicDNS: true,
	})
	mutated.RuleSets = append(mutated.RuleSets, RuleSet{
		ID:           "unused-app",
		Type:         RuleSetTypeApplication,
		Enabled:      true,
		Applications: []ApplicationMatch{{Path: "/Applications/Unused.app"}},
	})
	mutatedGot, err := ComputeTransparentProxyDirectExcludedNetworks(
		mutated,
		[]string{"192.168.68.1"},
		[]netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")},
	)
	if err != nil {
		t.Fatalf("mutated error: %v", err)
	}
	if !reflect.DeepEqual(baselineGot, mutatedGot) {
		t.Fatalf("unreferenced objects changed exclusions:\nbaseline=%+v\nmutated=%+v", baselineGot, mutatedGot)
	}
}
