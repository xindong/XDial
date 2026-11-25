package libbox

import (
	"bytes"
	"encoding/json"
	"net"
	"net/netip"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/sing-box/common/srs"
	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

// underlayLocalSubnetsResolver is replaceable in unit tests so tests can supply
// deterministic Underlay interface subnets without depending on host NIC state.
var underlayLocalSubnetsResolver = defaultUnderlayLocalSubnets

// defaultUnderlayLocalSubnets reads the private/ULA on-link subnets configured
// on the Underlay default interface. It filters purely by POSIX interface flags
// and RFC1918/ULA address containment, never by interface name or product.
func defaultUnderlayLocalSubnets(interfaceName string) []netip.Prefix {
	interfaceName = strings.TrimSpace(interfaceName)
	if interfaceName == "" {
		return nil
	}
	iface, err := net.InterfaceByName(interfaceName)
	if err != nil || iface == nil {
		return nil
	}
	if iface.Flags&net.FlagUp == 0 ||
		iface.Flags&net.FlagLoopback != 0 ||
		iface.Flags&net.FlagPointToPoint != 0 {
		return nil
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return nil
	}
	var subnets []netip.Prefix
	for _, raw := range addrs {
		ipNet, ok := raw.(*net.IPNet)
		if !ok || ipNet == nil {
			continue
		}
		addr, ok := netip.AddrFromSlice(ipNet.IP)
		if !ok {
			continue
		}
		addr = addr.Unmap()
		ones, bits := ipNet.Mask.Size()
		if ones <= 0 || ones >= bits || bits != addr.BitLen() {
			continue
		}
		prefix := netip.PrefixFrom(addr, ones).Masked()
		if config.IsPrivateLANPrefix(prefix) {
			subnets = append(subnets, prefix)
		}
	}
	return subnets
}

func collectTransparentProxyRuleSetIPInfo(
	profile *config.Profile,
	configJSON []byte,
) map[string]config.TransparentProxyRuleSetIPInfo {
	if profile == nil {
		return nil
	}
	scenario := profile.ActiveScenario()
	if scenario == nil {
		return nil
	}

	info := make(map[string]config.TransparentProxyRuleSetIPInfo)
	for _, binding := range scenario.Bindings {
		rule := profile.FindRuleSet(binding.RuleSetID)
		if rule == nil || !rule.Enabled || rule.Type != config.RuleSetTypeURL {
			continue
		}
		if _, exists := info[rule.ID]; exists {
			continue
		}
		if rule.RuntimeMatchKind == config.RuleSetMatchDomain {
			info[rule.ID] = config.TransparentProxyRuleSetIPInfo{
				HasDomain: true,
				ExactIPs:  true,
			}
			continue
		}
		if !strings.HasPrefix(rule.URL, "file://") {
			info[rule.ID] = config.TransparentProxyRuleSetIPInfo{Opaque: true}
			continue
		}
		localPath := strings.TrimPrefix(rule.URL, "file://")
		format := rule.Format
		if format != "binary" && format != "source" {
			format = neRuleSetFormat(rule)
			if format == "text" {
				format = "source"
			}
		}
		content, _, _, err := readValidatedNERuleSet(localPath, format, maxNERuleSetBytes)
		if err != nil {
			info[rule.ID] = config.TransparentProxyRuleSetIPInfo{Opaque: true}
			continue
		}
		info[rule.ID] = extractRuleSetIPInfo(content, format)
	}

	var document struct {
		Route struct {
			RuleSets []struct {
				Tag    string `json:"tag"`
				Type   string `json:"type"`
				Format string `json:"format"`
				Path   string `json:"path"`
			} `json:"rule_set"`
		} `json:"route"`
	}
	if json.Unmarshal(configJSON, &document) == nil {
		for _, set := range document.Route.RuleSets {
			if !strings.HasPrefix(set.Tag, "sub-geoip-") {
				continue
			}
			if _, exists := info[set.Tag]; exists {
				continue
			}
			if set.Type != "local" || set.Path == "" {
				info[set.Tag] = config.TransparentProxyRuleSetIPInfo{Opaque: true}
				continue
			}
			content, _, _, err := readValidatedNERuleSet(set.Path, set.Format, maxNERuleSetBytes)
			if err != nil {
				info[set.Tag] = config.TransparentProxyRuleSetIPInfo{Opaque: true}
				continue
			}
			info[set.Tag] = extractRuleSetIPInfo(content, set.Format)
		}
	}

	return info
}

func extractRuleSetIPInfo(content []byte, format string) config.TransparentProxyRuleSetIPInfo {
	var compat option.PlainRuleSetCompat
	var err error
	switch format {
	case "binary":
		compat, err = srs.Read(bytes.NewReader(content), true)
	case "source":
		err = json.Unmarshal(content, &compat)
	default:
		return config.TransparentProxyRuleSetIPInfo{Opaque: true}
	}
	if err != nil {
		return config.TransparentProxyRuleSetIPInfo{Opaque: true}
	}
	plain, err := compat.Upgrade()
	if err != nil {
		return config.TransparentProxyRuleSetIPInfo{Opaque: true}
	}
	if len(plain.Rules) == 0 {
		return config.TransparentProxyRuleSetIPInfo{Opaque: true}
	}
	result := config.TransparentProxyRuleSetIPInfo{ExactIPs: true}
	if !collectHeadlessRuleIPInfo(plain.Rules, &result) {
		return config.TransparentProxyRuleSetIPInfo{Opaque: true}
	}
	return result
}

func collectHeadlessRuleIPInfo(
	rules []option.HeadlessRule,
	out *config.TransparentProxyRuleSetIPInfo,
) bool {
	for _, rule := range rules {
		switch rule.Type {
		case "", C.RuleTypeDefault:
			opts := rule.DefaultOptions
			if opts.Invert || hasNonDestinationRuleConditions(opts) {
				return false
			}
			hasDomain := len(opts.Domain) > 0 ||
				len(opts.DomainSuffix) > 0 ||
				len(opts.DomainKeyword) > 0 ||
				len(opts.DomainRegex) > 0 ||
				len(opts.AdGuardDomain) > 0 ||
				opts.DomainMatcher != nil ||
				opts.AdGuardDomainMatcher != nil
			hasIP := len(opts.IPCIDR) > 0 || opts.IPSet != nil
			if !hasDomain && !hasIP {
				return false
			}
			out.HasDomain = out.HasDomain || hasDomain
			for _, raw := range opts.IPCIDR {
				prefix, ok := parseRuleSetPrefix(raw)
				if !ok {
					return false
				}
				if overlapsPrivateLAN(prefix) {
					out.CIDRs = append(out.CIDRs, prefix)
				}
			}
			if opts.IPSet != nil {
				for _, prefix := range opts.IPSet.Prefixes() {
					if overlapsPrivateLAN(prefix) {
						out.CIDRs = append(out.CIDRs, prefix)
					}
				}
			}
		case C.RuleTypeLogical:
			if rule.LogicalOptions.Invert || len(rule.LogicalOptions.Rules) == 0 {
				return false
			}
			if !collectHeadlessRuleIPInfo(rule.LogicalOptions.Rules, out) {
				return false
			}
		default:
			return false
		}
	}
	return true
}

func parseRuleSetPrefix(raw string) (netip.Prefix, bool) {
	raw = strings.TrimSpace(raw)
	if prefix, err := netip.ParsePrefix(raw); err == nil {
		addr := prefix.Addr()
		bits := prefix.Bits()
		if addr.Is4In6() {
			addr = addr.Unmap()
			bits -= 96
			if bits < 0 || bits > 32 {
				return netip.Prefix{}, false
			}
		}
		return netip.PrefixFrom(addr, bits).Masked(), true
	}
	if addr, err := netip.ParseAddr(raw); err == nil {
		addr = addr.Unmap()
		return netip.PrefixFrom(addr, addr.BitLen()), true
	}
	return netip.Prefix{}, false
}

var libboxPrivateLANPrefixes = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("fc00::/7"),
}

func overlapsPrivateLAN(prefix netip.Prefix) bool {
	if !prefix.IsValid() {
		return false
	}
	for _, candidate := range libboxPrivateLANPrefixes {
		if candidate.Overlaps(prefix) {
			return true
		}
	}
	return false
}
