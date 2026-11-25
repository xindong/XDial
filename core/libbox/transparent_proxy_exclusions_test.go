package libbox

import (
	"encoding/json"
	"net/netip"
	"os"
	"path/filepath"
	"testing"

	"github.com/kafeifei/xdial/core/config"
)

func sessionExcludedContainsIP(t *testing.T, networks []config.TransparentProxyRemoteNetwork, ip string) bool {
	t.Helper()
	addr := netip.MustParseAddr(ip)
	for _, network := range networks {
		prefix := netip.PrefixFrom(netip.MustParseAddr(network.Address), network.PrefixLength)
		if prefix.Contains(addr) {
			return true
		}
	}
	return false
}

func TestGenerateTransparentProxySessionDirectExcludedNetworks(t *testing.T) {
	originalResolver := underlayLocalSubnetsResolver
	defer func() { underlayLocalSubnetsResolver = originalResolver }()
	underlayLocalSubnetsResolver = func(interfaceName string) []netip.Prefix {
		if interfaceName == "en0" {
			return []netip.Prefix{netip.MustParsePrefix("192.168.68.0/22")}
		}
		if interfaceName == "en7" {
			return []netip.Prefix{netip.MustParsePrefix("172.20.10.0/28")}
		}
		return nil
	}

	basePath := t.TempDir()
	ruleDir, err := prepareNERuleSetDirectory(basePath)
	if err != nil {
		t.Fatal(err)
	}

	cnDomainURL := "https://rules.example/cn-domains.json"
	cnIPURL := "https://rules.example/cn-ip.json"
	corpURL := "https://rules.example/corp-ip.json"

	writeRuleCache := func(ruleID, rawURL, body string) {
		t.Helper()
		cachePath := neRuleSetCachePath(ruleDir, "profile", ruleID, rawURL, "source", "source")
		if err := os.WriteFile(cachePath, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	writeRuleCache("cn-domains", cnDomainURL, `{"version":2,"rules":[{"domain_suffix":["cn.example"]}]}`)
	writeRuleCache("cn-ip", cnIPURL, `{"version":2,"rules":[{"ip_cidr":["114.114.114.0/24","223.5.5.0/24"]}]}`)
	writeRuleCache("corp-ip", corpURL, `{"version":2,"rules":[{"ip_cidr":["172.27.0.0/16","192.168.99.0/24"]}]}`)

	makeProfile := func(activeScenarioID string) string {
		profile := config.Profile{
			Lines: []config.Line{
				{ID: "direct", Name: "直连", Type: config.LineTypeDirect, Enabled: true},
				{
					ID:          "company",
					Name:        "公司 VPN",
					Type:        config.LineTypeVPN,
					Enabled:     true,
					VPNServer:   "vpn.example.com:8443",
					VPNUsername: "employee",
					VPNPassword: "secret-password",
				},
			},
			RuleSets: []config.RuleSet{
				{ID: "lan", Name: "本地局域网", Type: config.RuleSetTypeManual, Enabled: true, CIDRs: []string{"192.168.0.0/16"}},
				{ID: "intranet", Name: "公司内网", Type: config.RuleSetTypeManual, Enabled: true, Domains: []string{"corp.example"}, CIDRs: []string{"10.0.0.0/8"}},
				{ID: "cn-domains", Name: "国内网站", Type: config.RuleSetTypeURL, Enabled: true, URL: cnDomainURL, Format: "json"},
				{ID: "cn-ip", Name: "国内 IP", Type: config.RuleSetTypeURL, Enabled: true, URL: cnIPURL, Format: "json"},
				{ID: "corp-ip", Name: "企业 URL IP", Type: config.RuleSetTypeURL, Enabled: true, URL: corpURL, Format: "json"},
			},
			Scenarios: []config.Scenario{
				{
					ID:   "overseas",
					Name: "在国外",
					Bindings: []config.RuleBinding{
						{RuleSetID: "lan", LineID: "direct"},
						{RuleSetID: "intranet", LineID: "company"},
						{RuleSetID: "cn-domains", LineID: "company"},
						{RuleSetID: "cn-ip", LineID: "company"},
					},
					DefaultLineID: "direct",
				},
				{
					ID:   "corp-url-first",
					Name: "企业优先",
					Bindings: []config.RuleBinding{
						{RuleSetID: "corp-ip", LineID: "company"},
						{RuleSetID: "lan", LineID: "direct"},
					},
					DefaultLineID: "company",
				},
				{
					ID:            "all-vpn",
					Name:          "全局 VPN",
					DefaultLineID: "company",
				},
			},
			ActiveScenarioID: activeScenarioID,
		}
		data, err := json.Marshal(profile)
		if err != nil {
			t.Fatal(err)
		}
		return string(data)
	}

	// 1. Overseas scenario on en0 (192.168.68.0/22, DNS 192.168.68.1):
	// LAN peers excluded, router DNS and VPN CIDRs stay captured.
	rawOverseas, err := GenerateTransparentProxySession(
		makeProfile("overseas"),
		basePath,
		29876,
		"session-user",
		"session-password",
		"en0",
		`["192.168.68.1"]`,
	)
	if err != nil {
		t.Fatalf("overseas GenerateTransparentProxySession: %v", err)
	}
	var overseasSession transparentProxySession
	if err := json.Unmarshal([]byte(rawOverseas), &overseasSession); err != nil {
		t.Fatal(err)
	}
	if !sessionExcludedContainsIP(t, overseasSession.DirectExcludedNetworks, "192.168.68.83") ||
		!sessionExcludedContainsIP(t, overseasSession.DirectExcludedNetworks, "192.168.68.96") {
		t.Fatalf("expected LAN peers to be excluded in overseas session: %+v", overseasSession.DirectExcludedNetworks)
	}
	if sessionExcludedContainsIP(t, overseasSession.DirectExcludedNetworks, "192.168.68.1") {
		t.Fatalf("system DNS router must stay captured for hijack-dns: %+v", overseasSession.DirectExcludedNetworks)
	}
	if sessionExcludedContainsIP(t, overseasSession.DirectExcludedNetworks, "10.1.2.3") {
		t.Fatalf("company VPN 10.0.0.0/8 must stay captured: %+v", overseasSession.DirectExcludedNetworks)
	}

	// 2. Network change to en7 (172.20.10.0/28, DNS 172.20.10.1) in overseas scenario:
	// New Underlay local subnet is excluded (minus its router DNS).
	rawEn7, err := GenerateTransparentProxySession(
		makeProfile("overseas"),
		basePath,
		29877,
		"session-user",
		"session-password",
		"en7",
		`["172.20.10.1"]`,
	)
	if err != nil {
		t.Fatalf("en7 GenerateTransparentProxySession: %v", err)
	}
	var en7Session transparentProxySession
	if err := json.Unmarshal([]byte(rawEn7), &en7Session); err != nil {
		t.Fatal(err)
	}
	if !sessionExcludedContainsIP(t, en7Session.DirectExcludedNetworks, "172.20.10.5") {
		t.Fatalf("expected en7 local subnet peer 172.20.10.5 to be excluded: %+v", en7Session.DirectExcludedNetworks)
	}
	if sessionExcludedContainsIP(t, en7Session.DirectExcludedNetworks, "172.20.10.1") {
		t.Fatalf("en7 system DNS 172.20.10.1 must stay captured: %+v", en7Session.DirectExcludedNetworks)
	}

	// 3. URL rule set with private VPN CIDR (192.168.99.0/24) before LAN -> direct:
	// 192.168.99.0/24 is carved out and stays in VPN; 192.168.68.83 is excluded.
	rawCorpURL, err := GenerateTransparentProxySession(
		makeProfile("corp-url-first"),
		basePath,
		29878,
		"session-user",
		"session-password",
		"en0",
		`["1.1.1.1"]`,
	)
	if err != nil {
		t.Fatalf("corp-url-first GenerateTransparentProxySession: %v", err)
	}
	var corpURLSession transparentProxySession
	if err := json.Unmarshal([]byte(rawCorpURL), &corpURLSession); err != nil {
		t.Fatal(err)
	}
	if sessionExcludedContainsIP(t, corpURLSession.DirectExcludedNetworks, "192.168.99.5") ||
		sessionExcludedContainsIP(t, corpURLSession.DirectExcludedNetworks, "172.27.5.5") {
		t.Fatalf("URL rule set VPN CIDRs must never be excluded: %+v", corpURLSession.DirectExcludedNetworks)
	}
	if !sessionExcludedContainsIP(t, corpURLSession.DirectExcludedNetworks, "192.168.68.83") {
		t.Fatalf("non-conflicting LAN peer should be excluded: %+v", corpURLSession.DirectExcludedNetworks)
	}

	// 4. Scenario switch to all-vpn clears direct_excluded_networks completely.
	rawAllVPN, err := GenerateTransparentProxySession(
		makeProfile("all-vpn"),
		basePath,
		29879,
		"session-user",
		"session-password",
		"en0",
		`["192.168.68.1"]`,
	)
	if err != nil {
		t.Fatalf("all-vpn GenerateTransparentProxySession: %v", err)
	}
	var allVPNSession transparentProxySession
	if err := json.Unmarshal([]byte(rawAllVPN), &allVPNSession); err != nil {
		t.Fatal(err)
	}
	if len(allVPNSession.DirectExcludedNetworks) != 0 {
		t.Fatalf("all-vpn scenario must clear direct_excluded_networks, got %+v", allVPNSession.DirectExcludedNetworks)
	}
	_ = filepath.Clean(ruleDir)
}
