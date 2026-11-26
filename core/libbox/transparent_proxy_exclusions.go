package libbox

import (
	"bytes"
	"encoding/json"
	"net"
	"net/netip"
	"strings"

	"github.com/kafeifei/xdial/core/config"
	"github.com/sagernet/sing-box/common/srs"
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
				BlocksAll: true,
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
	return config.SummarizeHeadlessRulesForExclusions(plain.Rules)
}
