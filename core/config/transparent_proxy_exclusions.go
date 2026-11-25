package config

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/netip"
	"sort"
	"strings"

	C "github.com/sagernet/sing-box/constant"
	"github.com/sagernet/sing-box/option"
)

// MaxTransparentProxyDirectExcludedNetworks caps the number of Scenario-derived
// direct-bypass CIDRs sent to macOS NETransparentProxyNetworkSettings so system
// network rule evaluation remains bounded even for complex configs.
const MaxTransparentProxyDirectExcludedNetworks = 128

// TransparentProxyRemoteNetwork is one canonical CIDR network entry consumed by
// macOS NETransparentProxyNetworkSettings.excludedNetworkRules.
type TransparentProxyRemoteNetwork struct {
	Address      string `json:"address"`
	PrefixLength int    `json:"prefix_length"`
}

// TransparentProxyRuleSetIPInfo carries pre-parsed destination matching facts
// for a materialized URL or subscription GEOIP rule set. Leaving ExactIPs false
// (or Opaque true) makes the exclusion planner treat the rule set conservatively.
type TransparentProxyRuleSetIPInfo struct {
	HasDomain bool
	ExactIPs  bool
	CIDRs     []netip.Prefix
	Opaque    bool
}

var privateLANUniverse = []netip.Prefix{
	netip.MustParsePrefix("10.0.0.0/8"),
	netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"),
	netip.MustParsePrefix("fc00::/7"),
}

// IsPrivateLANPrefix reports whether prefix is valid and completely contained
// within RFC1918 IPv4 private space or IPv6 ULA space. Link-local, multicast,
// loopback, CGNAT/Tailnet (100.64.0.0/10), and public ranges return false.
func IsPrivateLANPrefix(prefix netip.Prefix) bool {
	normalized, ok := normalizePrefix(prefix)
	if !ok {
		return false
	}
	for _, universe := range privateLANUniverse {
		if prefixContains(universe, normalized) {
			return true
		}
	}
	return false
}

// ComputeTransparentProxyDirectExcludedNetworks computes the canonical, bounded
// set of private/LAN prefixes that the active Scenario routes strictly to Direct
// and that can therefore bypass macOS NETransparentProxyProvider without altering
// routing, application attribution, Tailscale MagicDNS, or system DNS capture.
func ComputeTransparentProxyDirectExcludedNetworks(
	profile *Profile,
	systemDNS []string,
	underlayLocalSubnets []netip.Prefix,
) ([]TransparentProxyRemoteNetwork, error) {
	return ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
		profile,
		systemDNS,
		underlayLocalSubnets,
		nil,
	)
}

// ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo is identical to
// ComputeTransparentProxyDirectExcludedNetworks, but also accepts pre-parsed IP
// metadata for materialized URL rule sets (keyed by RuleSet.ID) and generated
// subscription GEOIP rule sets (keyed by their sing-box rule_set tag).
func ComputeTransparentProxyDirectExcludedNetworksWithRuleSetInfo(
	profile *Profile,
	systemDNS []string,
	underlayLocalSubnets []netip.Prefix,
	ruleSetInfo map[string]TransparentProxyRuleSetIPInfo,
) ([]TransparentProxyRemoteNetwork, error) {
	var groupErr error
	profile, groupErr = ExpandRuleSetGroups(profile)
	if groupErr != nil {
		return nil, groupErr
	}
	if profile == nil {
		return nil, fmt.Errorf("profile is nil")
	}
	scenario := profile.ActiveScenario()
	if scenario == nil {
		return nil, fmt.Errorf("no active scenario")
	}
	if _, err := inspectScenarioReferences(profile, scenario); err != nil {
		return nil, err
	}

	activeLineIDs, activeSubscriptionIDs := effectiveActiveTargetIDs(profile, scenario)
	expandGroupLineIDs(profile, activeLineIDs)

	validTags := map[string]bool{"direct": true}
	for _, line := range profile.Lines {
		if !activeLineIDs[line.ID] || !line.Enabled {
			continue
		}
		if line.Type == LineTypeDirect || line.Type == LineTypeVPN || line.Type == LineTypeTailscale {
			validTags[resolveOutboundTag(&line)] = true
			continue
		}
		if ob := buildProxyOutbound(&line); ob != nil {
			if tag, _ := ob["tag"].(string); tag != "" {
				validTags[tag] = true
			}
		}
	}

	subTagMap := make(map[string]string)
	subGroupTagMap := make(map[string]map[string]string)
	for _, sub := range profile.Subscriptions {
		if !activeSubscriptionIDs[sub.ID] || !sub.Enabled || len(sub.Lines) == 0 {
			continue
		}
		obs, mainTag, groupTags := buildSubscriptionOutbounds(&sub, PlatformTransparentProxy)
		if mainTag != "" {
			subTagMap[sub.ID] = mainTag
			subGroupTagMap[sub.ID] = groupTags
			for _, ob := range obs {
				if tag, _ := ob["tag"].(string); tag != "" {
					validTags[tag] = true
				}
			}
		}
	}

	undecided := append([]netip.Prefix(nil), privateLANUniverse...)
	var excluded []netip.Prefix
	seenNonDirectDomain := false

	promoteDirect := func(cidrs []netip.Prefix) {
		if len(undecided) == 0 || len(cidrs) == 0 {
			return
		}
		matched := intersectPrefixSets(undecided, cidrs)
		if len(matched) == 0 {
			return
		}
		excluded = coalescePrefixes(append(excluded, matched...))
		undecided = subtractPrefixSets(undecided, matched)
	}
	blockCIDRs := func(cidrs []netip.Prefix) {
		if len(undecided) == 0 || len(cidrs) == 0 {
			return
		}
		undecided = subtractPrefixSets(undecided, cidrs)
	}
	blockAllRemaining := func() {
		undecided = nil
	}

	isDirectOutbound := func(outTag string) bool {
		return outTag == "direct" || selectedGroupUsesDirect(profile, outTag)
	}

	// 1. Evaluate Scenario bindings in exact sing-box route order.
	for index := range scenario.Bindings {
		if len(undecided) == 0 {
			break
		}
		binding := &scenario.Bindings[index]
		ruleSet := profile.FindRuleSet(binding.RuleSetID)
		if ruleSet == nil || !ruleSet.Enabled {
			continue
		}
		outTag := bindingOutboundTag(profile, binding, subTagMap, validTags)
		if outTag == "" {
			continue
		}
		isDirect := isDirectOutbound(outTag)

		switch ruleSet.Type {
		case RuleSetTypeApplication:
			if len(applicationRuleSetSelectors(ruleSet)) == 0 {
				continue
			}
			// A non-Direct application rule can route any destination IP (including
			// LAN) to a non-Direct Line for matching processes (or non-matching
			// processes when inverted). A Direct application rule only covers
			// selected processes, so it cannot mark any IP universally Direct.
			if !isDirect {
				blockAllRemaining()
			}

		case RuleSetTypeManual:
			hasDomains := len(ruleSet.Domains) > 0
			hasCIDRs := len(ruleSet.CIDRs) > 0
			if !hasDomains && !hasCIDRs {
				continue
			}
			parsedCIDRs, cidrsValid := parseRuleCIDRs(ruleSet.CIDRs)
			if ruleSet.Invert {
				if !isDirect {
					if hasDomains {
						seenNonDirectDomain = true
					}
					if !cidrsValid || !hasCIDRs {
						blockAllRemaining()
					} else {
						// Inverted CIDR matches everything outside parsedCIDRs.
						outside := subtractPrefixSets(privateLANUniverse, parsedCIDRs)
						blockCIDRs(outside)
					}
				} else if !hasDomains && hasCIDRs && cidrsValid {
					// Pure inverted CIDR → direct matches everything outside parsedCIDRs.
					outside := subtractPrefixSets(privateLANUniverse, parsedCIDRs)
					promoteDirect(outside)
				}
				continue
			}
			if hasDomains && !isDirect {
				seenNonDirectDomain = true
			}
			if hasCIDRs {
				if !cidrsValid {
					if !isDirect {
						blockAllRemaining()
					}
					continue
				}
				if isDirect {
					promoteDirect(parsedCIDRs)
				} else {
					blockCIDRs(parsedCIDRs)
				}
			}

		case RuleSetTypeNative:
			classified := classifyNativeRuleForExclusions(ruleSet.NativeRule, ruleSet.Invert)
			if classified.opaque {
				if !isDirect {
					blockAllRemaining()
				}
				continue
			}
			if classified.hasDomain && !isDirect {
				seenNonDirectDomain = true
			}
			if isDirect {
				if len(classified.directCIDRs) > 0 {
					promoteDirect(classified.directCIDRs)
				}
			} else {
				if classified.blocksAll {
					blockAllRemaining()
				} else if len(classified.blockCIDRs) > 0 {
					blockCIDRs(classified.blockCIDRs)
				}
			}

		case RuleSetTypeURL:
			if ruleSet.URL == "" {
				continue
			}
			if ruleSet.Invert {
				if !isDirect {
					blockAllRemaining()
				}
				continue
			}
			info, hasInfo := ruleSetInfo[ruleSet.ID]
			if !hasInfo {
				if ruleSet.RuntimeMatchKind == RuleSetMatchDomain {
					info = TransparentProxyRuleSetIPInfo{
						HasDomain: true,
						ExactIPs:  true,
					}
				} else {
					info = TransparentProxyRuleSetIPInfo{Opaque: true}
				}
			}
			if info.Opaque || !info.ExactIPs {
				if !isDirect {
					blockAllRemaining()
				}
				continue
			}
			if info.HasDomain && !isDirect {
				seenNonDirectDomain = true
			}
			if isDirect {
				if !info.HasDomain && len(info.CIDRs) > 0 {
					promoteDirect(info.CIDRs)
				}
			} else if len(info.CIDRs) > 0 {
				blockCIDRs(info.CIDRs)
			}
		}
	}

	// 2. Tailscale MagicDNS dynamic peer / subnet routes execute after Scenario
	// bindings and before subscription rules / final. They may claim dynamic
	// RFC1918 subnet-router routes, so stop promoting any still-undecided prefix.
	if len(effectiveActiveMagicDNSEndpointTags(profile, scenario)) > 0 {
		blockAllRemaining()
	}

	// 3. Active Subscription rules execute after Scenario bindings and MagicDNS.
	for _, sub := range profile.Subscriptions {
		if len(undecided) == 0 {
			break
		}
		if !activeSubscriptionIDs[sub.ID] || !sub.Enabled {
			continue
		}
		groupTags := subGroupTagMap[sub.ID]
		if groupTags == nil {
			continue
		}
		compiled, _, err := collectSubscriptionRules(&sub, groupTags)
		if err != nil {
			return nil, fmt.Errorf("compile subscription %q exclusion rules: %w", sub.ID, err)
		}
		for _, rule := range compiled {
			if len(undecided) == 0 {
				break
			}
			isDirect := rule.outTag == "direct"
			switch rule.matchKey {
			case "domain", "domain_suffix", "domain_keyword":
				if !isDirect {
					seenNonDirectDomain = true
				}
			case "ip_cidr":
				rawValues, _ := rule.values.([]string)
				parsed, ok := parseRuleCIDRs(rawValues)
				if !ok {
					if !isDirect {
						blockAllRemaining()
					}
					continue
				}
				if isDirect {
					promoteDirect(parsed)
				} else {
					blockCIDRs(parsed)
				}
			case "ip_is_private":
				if isDirect {
					promoteDirect(privateLANUniverse)
				} else {
					blockAllRemaining()
				}
			case "rule_set":
				tag, _ := rule.values.(string)
				info, hasInfo := ruleSetInfo[tag]
				if !hasInfo || info.Opaque || !info.ExactIPs {
					if !isDirect {
						blockAllRemaining()
					}
					continue
				}
				if info.HasDomain && !isDirect {
					seenNonDirectDomain = true
				}
				if isDirect {
					if !info.HasDomain && len(info.CIDRs) > 0 {
						promoteDirect(info.CIDRs)
					}
				} else if len(info.CIDRs) > 0 {
					blockCIDRs(info.CIDRs)
				}
			default:
				if !isDirect {
					blockAllRemaining()
				}
			}
		}
	}

	// 4. Default outbound (route.final).
	defaultTag := "direct"
	if scenario.DefaultSubscriptionID != "" {
		if tag, ok := subTagMap[scenario.DefaultSubscriptionID]; ok && validTags[tag] {
			defaultTag = tag
		}
	} else if scenario.DefaultLineID != "" {
		if l := profile.FindLine(scenario.DefaultLineID); l != nil && l.Enabled {
			candidate := resolveOutboundTag(l)
			if validTags[candidate] {
				defaultTag = candidate
			}
		}
	}

	normalizedLocalSubnets := normalizePrivateLANSubnets(underlayLocalSubnets)
	if len(undecided) > 0 && isDirectOutbound(defaultTag) {
		if !seenNonDirectDomain {
			// No non-Direct domain rule precedes final: direct, so every remaining
			// undecided private/LAN range is unconditionally Direct.
			promoteDirect(undecided)
		} else if len(normalizedLocalSubnets) > 0 {
			// A non-Direct domain rule (e.g. corporate intranet domains via VPN)
			// precedes final: direct. Keep unmentioned RFC1918 ranges captured so
			// domain-routed corporate IPs stay inside XDial, while still allowing
			// the current Underlay physical interface's on-link LAN subnet (when
			// not claimed by any non-Direct IP / App / MagicDNS rule) to bypass.
			promoteDirect(normalizedLocalSubnets)
		}
	}

	// 5. Preserve DNS sealing (INV3): never exclude any system DNS server host
	// address (e.g. a LAN router at 192.168.68.1), so mDNSResponder queries on
	// port 53 continue entering NETransparentProxyProvider -> hijack-dns.
	dnsHostPrefixes := parseSystemDNSHostPrefixes(systemDNS)
	if len(dnsHostPrefixes) > 0 && len(excluded) > 0 {
		excluded = subtractPrefixSets(excluded, dnsHostPrefixes)
	}

	excluded = coalescePrefixes(excluded)
	if len(excluded) > MaxTransparentProxyDirectExcludedNetworks {
		// Fall back safely to the local Underlay subnet portion if complex hole
		// punching exceeded the NE rule budget.
		if len(normalizedLocalSubnets) > 0 {
			excluded = coalescePrefixes(intersectPrefixSets(excluded, normalizedLocalSubnets))
		}
		if len(excluded) > MaxTransparentProxyDirectExcludedNetworks {
			excluded = excluded[:MaxTransparentProxyDirectExcludedNetworks]
		}
	}

	if len(excluded) == 0 {
		return nil, nil
	}
	result := make([]TransparentProxyRemoteNetwork, 0, len(excluded))
	for _, prefix := range excluded {
		result = append(result, TransparentProxyRemoteNetwork{
			Address:      prefix.Addr().String(),
			PrefixLength: prefix.Bits(),
		})
	}
	return result, nil
}

type nativeRuleExclusionClass struct {
	hasDomain   bool
	directCIDRs []netip.Prefix
	blockCIDRs  []netip.Prefix
	blocksAll   bool
	opaque      bool
}

func classifyNativeRuleForExclusions(raw json.RawMessage, outerInvert bool) nativeRuleExclusionClass {
	var rule option.HeadlessRule
	if err := json.Unmarshal(raw, &rule); err != nil || !rule.IsValid() {
		return nativeRuleExclusionClass{opaque: true}
	}
	return classifyHeadlessRuleForExclusions(rule, outerInvert)
}

func classifyHeadlessRuleForExclusions(rule option.HeadlessRule, outerInvert bool) nativeRuleExclusionClass {
	switch rule.Type {
	case "", C.RuleTypeDefault:
		opts := rule.DefaultOptions
		inverted := outerInvert != opts.Invert
		hasDomain := len(opts.Domain) > 0 ||
			len(opts.DomainSuffix) > 0 ||
			len(opts.DomainKeyword) > 0 ||
			len(opts.DomainRegex) > 0 ||
			len(opts.AdGuardDomain) > 0 ||
			opts.DomainMatcher != nil ||
			opts.AdGuardDomainMatcher != nil
		hasIP := len(opts.IPCIDR) > 0 || opts.IPSet != nil
		if !hasDomain && !hasIP {
			return nativeRuleExclusionClass{opaque: true}
		}
		var cidrs []netip.Prefix
		if len(opts.IPCIDR) > 0 {
			parsed, ok := parseRuleCIDRs(opts.IPCIDR)
			if !ok {
				return nativeRuleExclusionClass{opaque: true}
			}
			cidrs = append(cidrs, parsed...)
		}
		if opts.IPSet != nil {
			cidrs = append(cidrs, opts.IPSet.Prefixes()...)
		}
		cidrs = intersectPrefixSets(coalescePrefixes(cidrs), privateLANUniverse)

		if inverted {
			if hasDomain {
				return nativeRuleExclusionClass{hasDomain: true, blocksAll: true}
			}
			outside := subtractPrefixSets(privateLANUniverse, cidrs)
			return nativeRuleExclusionClass{
				directCIDRs: outside,
				blockCIDRs:  outside,
			}
		}
		if hasDomain && !hasIP {
			return nativeRuleExclusionClass{hasDomain: true}
		}
		if hasDomain && hasIP {
			// Default rule ANDs domain and IP: can only match within cidrs when
			// blocking, and cannot guarantee unconditional direct for literal IPs.
			return nativeRuleExclusionClass{
				hasDomain:  true,
				blockCIDRs: cidrs,
			}
		}
		return nativeRuleExclusionClass{
			directCIDRs: cidrs,
			blockCIDRs:  cidrs,
		}

	case C.RuleTypeLogical:
		inverted := outerInvert != rule.LogicalOptions.Invert
		if inverted || len(rule.LogicalOptions.Rules) == 0 {
			return nativeRuleExclusionClass{opaque: true}
		}
		switch rule.LogicalOptions.Mode {
		case C.LogicalTypeOr:
			var combined nativeRuleExclusionClass
			for _, child := range rule.LogicalOptions.Rules {
				c := classifyHeadlessRuleForExclusions(child, false)
				if c.opaque {
					return nativeRuleExclusionClass{opaque: true}
				}
				combined.hasDomain = combined.hasDomain || c.hasDomain
				combined.blocksAll = combined.blocksAll || c.blocksAll
				combined.directCIDRs = append(combined.directCIDRs, c.directCIDRs...)
				combined.blockCIDRs = append(combined.blockCIDRs, c.blockCIDRs...)
			}
			combined.directCIDRs = coalescePrefixes(combined.directCIDRs)
			combined.blockCIDRs = coalescePrefixes(combined.blockCIDRs)
			return combined
		case C.LogicalTypeAnd:
			var combined nativeRuleExclusionClass
			hasDirectBound := false
			hasBlockBound := false
			for _, child := range rule.LogicalOptions.Rules {
				c := classifyHeadlessRuleForExclusions(child, false)
				if c.opaque {
					return nativeRuleExclusionClass{opaque: true}
				}
				combined.hasDomain = combined.hasDomain || c.hasDomain
				if !c.blocksAll && (len(c.blockCIDRs) > 0 || !c.hasDomain) {
					if !hasBlockBound {
						combined.blockCIDRs = append([]netip.Prefix(nil), c.blockCIDRs...)
						hasBlockBound = true
					} else {
						combined.blockCIDRs = intersectPrefixSets(combined.blockCIDRs, c.blockCIDRs)
					}
				}
				if !c.hasDomain && len(c.directCIDRs) > 0 {
					if !hasDirectBound {
						combined.directCIDRs = append([]netip.Prefix(nil), c.directCIDRs...)
						hasDirectBound = true
					} else {
						combined.directCIDRs = intersectPrefixSets(combined.directCIDRs, c.directCIDRs)
					}
				} else {
					// If any AND branch depends on domain, it cannot guarantee direct.
					combined.directCIDRs = nil
					hasDirectBound = true
				}
			}
			if !hasBlockBound && !combined.hasDomain {
				combined.blocksAll = true
			}
			return combined
		default:
			return nativeRuleExclusionClass{opaque: true}
		}
	default:
		return nativeRuleExclusionClass{opaque: true}
	}
}

func normalizePrivateLANSubnets(subnets []netip.Prefix) []netip.Prefix {
	var out []netip.Prefix
	for _, raw := range subnets {
		prefix, ok := normalizePrefix(raw)
		if !ok || !IsPrivateLANPrefix(prefix) {
			continue
		}
		if prefix.Bits() >= prefix.Addr().BitLen() {
			continue
		}
		out = append(out, prefix)
	}
	return coalescePrefixes(out)
}

func parseSystemDNSHostPrefixes(systemDNS []string) []netip.Prefix {
	var out []netip.Prefix
	for _, raw := range systemDNS {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		addr, err := netip.ParseAddr(raw)
		if err != nil {
			continue
		}
		addr = addr.Unmap()
		out = append(out, netip.PrefixFrom(addr, addr.BitLen()))
	}
	return coalescePrefixes(out)
}

func parseRuleCIDRs(raw []string) ([]netip.Prefix, bool) {
	var out []netip.Prefix
	for _, entry := range raw {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		if prefix, err := netip.ParsePrefix(entry); err == nil {
			normalized, ok := normalizePrefix(prefix)
			if !ok {
				return nil, false
			}
			out = append(out, normalized)
			continue
		}
		if addr, err := netip.ParseAddr(entry); err == nil {
			addr = addr.Unmap()
			out = append(out, netip.PrefixFrom(addr, addr.BitLen()))
			continue
		}
		return nil, false
	}
	return coalescePrefixes(out), true
}

func normalizePrefix(prefix netip.Prefix) (netip.Prefix, bool) {
	if !prefix.IsValid() {
		return netip.Prefix{}, false
	}
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

func prefixContains(outer, inner netip.Prefix) bool {
	return outer.Addr().Is4() == inner.Addr().Is4() &&
		outer.Bits() <= inner.Bits() &&
		outer.Contains(inner.Addr())
}

func splitPrefix(prefix netip.Prefix) (netip.Prefix, netip.Prefix) {
	nextBits := prefix.Bits() + 1
	left := netip.PrefixFrom(prefix.Addr(), nextBits)
	raw := append([]byte(nil), prefix.Addr().AsSlice()...)
	raw[prefix.Bits()/8] |= byte(1 << (7 - (prefix.Bits() % 8)))
	rightAddr, _ := netip.AddrFromSlice(raw)
	right := netip.PrefixFrom(rightAddr, nextBits)
	return left, right
}

func subtractOnePrefix(base, sub netip.Prefix) []netip.Prefix {
	if !base.Overlaps(sub) {
		return []netip.Prefix{base}
	}
	if prefixContains(sub, base) {
		return nil
	}
	left, right := splitPrefix(base)
	out := subtractOnePrefix(left, sub)
	out = append(out, subtractOnePrefix(right, sub)...)
	return out
}

func subtractPrefixSets(base, removals []netip.Prefix) []netip.Prefix {
	current := append([]netip.Prefix(nil), base...)
	for _, removal := range removals {
		if len(current) == 0 {
			return nil
		}
		next := make([]netip.Prefix, 0, len(current))
		for _, item := range current {
			next = append(next, subtractOnePrefix(item, removal)...)
		}
		current = next
	}
	return coalescePrefixes(current)
}

func intersectPrefixSets(left, right []netip.Prefix) []netip.Prefix {
	var out []netip.Prefix
	for _, a := range left {
		for _, b := range right {
			if !a.Overlaps(b) {
				continue
			}
			if prefixContains(a, b) {
				out = append(out, b)
			} else {
				out = append(out, a)
			}
		}
	}
	return coalescePrefixes(out)
}

func coalescePrefixes(prefixes []netip.Prefix) []netip.Prefix {
	if len(prefixes) == 0 {
		return nil
	}
	normalized := make([]netip.Prefix, 0, len(prefixes))
	for _, p := range prefixes {
		if clean, ok := normalizePrefix(p); ok {
			normalized = append(normalized, clean)
		}
	}
	if len(normalized) == 0 {
		return nil
	}
	sort.Slice(normalized, func(i, j int) bool {
		a, b := normalized[i], normalized[j]
		if a.Addr().Is4() != b.Addr().Is4() {
			return a.Addr().Is4()
		}
		if cmp := bytes.Compare(a.Addr().AsSlice(), b.Addr().AsSlice()); cmp != 0 {
			return cmp < 0
		}
		return a.Bits() < b.Bits()
	})

	dedup := make([]netip.Prefix, 0, len(normalized))
	for _, p := range normalized {
		if len(dedup) > 0 && prefixContains(dedup[len(dedup)-1], p) {
			continue
		}
		dedup = append(dedup, p)
	}

	stack := make([]netip.Prefix, 0, len(dedup))
	for _, curr := range dedup {
		for len(stack) > 0 {
			prev := stack[len(stack)-1]
			if prev.Addr().Is4() != curr.Addr().Is4() || prev.Bits() != curr.Bits() || prev.Bits() == 0 {
				break
			}
			parent := netip.PrefixFrom(prev.Addr(), prev.Bits()-1).Masked()
			left, right := splitPrefix(parent)
			if left != prev || right != curr {
				break
			}
			stack = stack[:len(stack)-1]
			curr = parent
		}
		stack = append(stack, curr)
	}
	return stack
}
