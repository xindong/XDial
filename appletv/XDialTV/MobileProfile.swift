import Foundation

extension RuleSet {
    static let connectivityDirectID = "xdial-connectivity-direct"
    static let connectivityAnyConnectID = "xdial-connectivity-anyconnect"
    /// 保留旧持久化 ID，避免升级时短暂出现第三条规则；语义已经从
    /// “AnyConnect”迁移为当前场景中确定选出的非 Direct 验收出口。
    static let connectivityOutboundID = connectivityAnyConnectID

    static func isConnectivityTestRuleID(_ id: String) -> Bool {
        id == connectivityDirectID || id == connectivityOutboundID
    }

    var isConnectivityTestRule: Bool {
        Self.isConnectivityTestRuleID(id)
    }
}

/// 打包时带进 App 的预置配置。首次安装时直接用它；已有配置时把它加进去，每个 revision 只加一次。
struct ProfileSeed: Equatable, Sendable {
    var profile: Profile
    /// 预置内容有增删时加一；老用户升级后据此补上新内容。
    var revision: Int
    /// 预置改过内容的手动规则：规则 ID → 之前各版发过的匹配内容。
    var ruleSetHistory: [String: [ShippedRuleContent]] = [:]
    /// 预置改过路由的场景：场景 ID → 之前各版发过的默认出口和规则绑定。
    var scenarioHistory: [String: [ShippedScenarioRouting]] = [:]
}

/// 预置某一版发出的手动规则匹配内容。比较时不计顺序和大小写。
struct ShippedRuleContent: Hashable, Sendable {
    var domains: Set<String>
    var cidrs: Set<String>

    init(domains: [String], cidrs: [String]) {
        self.domains = Set(domains.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        self.cidrs = Set(cidrs.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    init(_ rule: RuleSet) { self.init(domains: rule.domains, cidrs: rule.cidrs) }
}

struct ActiveRouteTargetSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let type: String
    let isSubscription: Bool
}

extension Profile {
    private static var connectivityRuleSets: [RuleSet] {
        [
            RuleSet(
                id: RuleSet.connectivityDirectID,
                name: "连接验收 · Direct",
                type: "manual",
                cidrs: ["1.0.0.1/32"]
            ),
            RuleSet(
                id: RuleSet.connectivityOutboundID,
                name: "连接验收 · 非 Direct 出口",
                type: "manual",
                cidrs: ["1.1.1.1/32"]
            ),
        ]
    }

    static func connectivityBindings(outboundLineID: String, directLineID: String) -> [RuleBinding] {
        var bindings: [RuleBinding] = []
        if !directLineID.isEmpty {
            bindings.append(RuleBinding(
                ruleSetID: RuleSet.connectivityDirectID,
                lineID: directLineID
            ))
        }
        if !outboundLineID.isEmpty && outboundLineID != directLineID {
            bindings.append(RuleBinding(
                ruleSetID: RuleSet.connectivityOutboundID,
                lineID: outboundLineID
            ))
        }
        return bindings
    }

    func referencedLineIDs(in scenario: Scenario) -> Set<String> {
        let activeRules = Set(ruleSets.filter(\.enabled).map(\.id))
        let targets = Set(scenario.bindings.filter { activeRules.contains($0.ruleSetID) }.map(\.lineID) + [scenario.defaultLineID])
        let roots = lines.filter { targets.contains($0.id) }
        return targets.union(leafLines(for: roots).map(\.id))
    }

    /// 返回场景中用于双出口路由验收的非 Direct 目标。选择顺序是协议的一部分：
    /// 非 Direct 默认出口优先；否则按普通、已启用规则绑定的原始顺序取首个。
    /// 锁定验收规则自身不会参与选择，避免旧错误绑定把迁移继续带错。
    func connectivityOutboundBinding(for scenario: Scenario) -> RuleBinding? {
        func isAvailableNonDirect(_ binding: RuleBinding) -> Bool {
            if !binding.subscriptionID.isEmpty {
                return subscriptions.contains {
                    $0.id == binding.subscriptionID && $0.enabled
                        && $0.lines.contains(where: { $0.enabled })
                }
            }
            guard !binding.lineID.isEmpty,
                  let line = lines.first(where: {
                      $0.id == binding.lineID && $0.enabled
                  }) else { return false }
            if line.type == "tailscale" {
                // An overlay-only endpoint is globally generated for subnet
                // routes, but it is not a public egress for the 1.1.1.1 probe.
                return !line.tailscaleExitNode
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            }
            return line.type != "direct"
        }

        let defaultBinding = RuleBinding(
            ruleSetID: RuleSet.connectivityOutboundID,
            lineID: scenario.defaultLineID,
            subscriptionID: scenario.defaultSubscriptionID
        )
        if isAvailableNonDirect(defaultBinding) {
            return defaultBinding
        }

        for binding in scenario.bindings where !binding.ruleSetID.isEmpty {
            guard !RuleSet.isConnectivityTestRuleID(binding.ruleSetID),
            ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true,
            isAvailableNonDirect(binding) else {
                continue
            }
            return RuleBinding(
                ruleSetID: RuleSet.connectivityOutboundID,
                lineID: binding.lineID,
                subscriptionID: binding.subscriptionID
            )
        }
        return nil
    }

    /// 与生成器的活动目标语义一致：默认出口始终计入；只有 enabled 规则的绑定
    /// 计入；线路和订阅统一去重。主页使用这一份摘要，避免订阅场景被误显示成
    /// “没有线路”，也避免 disabled 规则把未运行目标带进来。
    func activeRouteTargetSummaries(for scenario: Scenario) -> [ActiveRouteTargetSummary] {
        var result: [ActiveRouteTargetSummary] = []
        var seen = Set<String>()

        func append(lineID: String, subscriptionID: String) {
            if !subscriptionID.isEmpty {
                let key = "sub:\(subscriptionID)"
                guard seen.insert(key).inserted,
                      let subscription = subscriptions.first(where: {
                          $0.id == subscriptionID && $0.enabled
                              && $0.lines.contains(where: { $0.enabled })
                      }) else { return }
                result.append(ActiveRouteTargetSummary(
                    id: key,
                    name: subscription.name,
                    type: "subscription",
                    isSubscription: true
                ))
                return
            }
            let key = "port:\(lineID)"
            guard !lineID.isEmpty, seen.insert(key).inserted,
                  let line = lines.first(where: {
                      $0.id == lineID && $0.enabled
                  }) else { return }
            result.append(ActiveRouteTargetSummary(
                id: key,
                name: line.name,
                type: line.type,
                isSubscription: false
            ))
        }

        append(
            lineID: scenario.defaultLineID,
            subscriptionID: scenario.defaultSubscriptionID
        )
        for binding in scenario.bindings {
            guard ruleSets.first(where: { $0.id == binding.ruleSetID })?.enabled == true else {
                continue
            }
            append(lineID: binding.lineID, subscriptionID: binding.subscriptionID)
        }
        return result
    }

    /// 连接验收规则是真实 profile 的一部分，会在配置页展示，而不是生成器
    /// 暗中注入的路由。旧 profile 升级时会恢复两条精确 CIDR；第二条只绑定
    /// 确定选出的非 Direct 活动目标。纯 Direct 场景不伪造第二个出口。
    @discardableResult
    mutating func ensureConnectivityTestConfiguration() -> Bool {
        let before = self

        for expected in Self.connectivityRuleSets {
            if let index = ruleSets.firstIndex(where: { $0.id == expected.id }) {
                ruleSets[index] = expected
            } else {
                ruleSets.append(expected)
            }
        }

        let directLineID = lines.first(where: { $0.type == "direct" && $0.enabled })?.id ?? ""
        for index in scenarios.indices {
            let ordinaryBindings = scenarios[index].bindings.filter {
                $0.ruleSetID != RuleSet.connectivityDirectID
                    && $0.ruleSetID != RuleSet.connectivityOutboundID
            }
            var selectionScenario = scenarios[index]
            selectionScenario.bindings = ordinaryBindings
            let outboundBinding = connectivityOutboundBinding(for: selectionScenario)
            var acceptanceBindings: [RuleBinding] = []
            if !directLineID.isEmpty {
                acceptanceBindings.append(RuleBinding(
                    ruleSetID: RuleSet.connectivityDirectID,
                    lineID: directLineID
                ))
            }
            if let outboundBinding {
                acceptanceBindings.append(outboundBinding)
            }
            scenarios[index].bindings = acceptanceBindings + ordinaryBindings
            if !scenarios[index].matchOrder.isEmpty {
                let order = scenarios[index].matchOrder.filter { !RuleSet.isConnectivityTestRuleID($0) }
                scenarios[index].matchOrder = acceptanceBindings.map(\.ruleSetID) + order
            }
        }

        return self != before
    }

    /// 把一份预置配置加进已经在用的配置里。只添加缺的线路、规则和场景；用户自己建的、改过的
    /// 和当前选中的场景都不动。预置里的线路如果和已有线路是同一类型、同一个服务器，就沿用已有的
    /// 那条（账号密码还在上面），预置场景改绑到它。`scenarioHistory` 里列出的场景，路由仍等于
    /// 之前某一版发的（用户没改过）时换成预置的新路由，名称、图标和 Wi-Fi 触发不动。返回是否有改动。
    @discardableResult
    mutating func adding(seed: Profile, ruleSetHistory: [String: [ShippedRuleContent]] = [:],
                         scenarioHistory: [String: [ShippedScenarioRouting]] = [:]) -> Bool {
        let before = self

        // 预置线路 ID → 实际使用的线路 ID。
        var lineIDs: [String: String] = [:]
        for seedLine in seed.lines {
            if lines.contains(where: { $0.id == seedLine.id }) {
                lineIDs[seedLine.id] = seedLine.id
            } else if seedLine.type == "direct",
                      let direct = lines.first(where: { $0.type == "direct" && $0.enabled }) {
                lineIDs[seedLine.id] = direct.id
            } else if seedLine.type == "vpn",
                      !seedLine.vpnServer.isEmpty,
                      let same = lines.first(where: {
                          $0.type == "vpn" && $0.vpnServer.caseInsensitiveCompare(seedLine.vpnServer) == .orderedSame
                      }) {
                lineIDs[seedLine.id] = same.id
            } else {
                lines.append(seedLine)
                lineIDs[seedLine.id] = seedLine.id
            }
        }

        for ruleSet in seed.ruleSets
        where !ruleSet.isConnectivityTestRule && !ruleSets.contains(where: { $0.id == ruleSet.id }) {
            ruleSets.append(ruleSet)
        }
        // 预置改过内容的规则：用户没动过（仍是之前某一版发的内容）才换成新内容，改过的保留。
        for ruleSet in seed.ruleSets {
            guard let shipped = ruleSetHistory[ruleSet.id],
                  let index = ruleSets.firstIndex(where: { $0.id == ruleSet.id }) else { continue }
            let current = ShippedRuleContent(ruleSets[index])
            guard current != ShippedRuleContent(ruleSet) else { continue }
            if shipped.contains(current) {
                ruleSets[index].domains = ruleSet.domains
                ruleSets[index].cidrs = ruleSet.cidrs
            } else {
                appLog("seed: kept the user's edits to rule \(ruleSet.id)")
            }
        }

        // 预置改过路由的场景：用户没动过（仍是之前某一版发的路由）才换成新路由，改过的保留。
        // 比较时去掉 App 自己维护的连接验收绑定，最后由 ensureConnectivityTestConfiguration 补回。
        for source in seed.scenarios {
            guard let shipped = scenarioHistory[source.id],
                  let index = scenarios.firstIndex(where: { $0.id == source.id }),
                  let target = ShippedScenarioRouting(source, ignoring: RuleSet.isConnectivityTestRuleID)?
                      .mapped(lines: lineIDs) else { continue }
            let current = ShippedScenarioRouting(scenarios[index], ignoring: RuleSet.isConnectivityTestRuleID)
            guard current != target else { continue }
            if let current, shipped.map({ $0.mapped(lines: lineIDs) }).contains(current) {
                scenarios[index].defaultLineID = target.defaultLineID
                scenarios[index].bindings = target.bindings.map {
                    RuleBinding(ruleSetID: $0.ruleSetID, lineID: $0.lineID)
                }
                scenarios[index].matchOrder = []
            } else {
                appLog("seed: kept the user's edits to scenario \(source.id)")
            }
        }

        let seedScenarioIDs = seed.scenarios.map(\.id)
        for var scenario in seed.scenarios where !scenarios.contains(where: { $0.id == scenario.id }) {
            scenario.defaultLineID = lineIDs[scenario.defaultLineID] ?? scenario.defaultLineID
            scenario.bindings = scenario.bindings
                .filter { !RuleSet.isConnectivityTestRuleID($0.ruleSetID) }
                .map { binding in
                    var bound = binding
                    bound.lineID = lineIDs[binding.lineID] ?? binding.lineID
                    return bound
                }
            scenarios.append(scenario)
        }
        // 预置场景按预置里的顺序排在前面，其余的保持原来的先后。
        let leading = seedScenarioIDs.compactMap { id in scenarios.first(where: { $0.id == id }) }
        scenarios = leading + scenarios.filter { !seedScenarioIDs.contains($0.id) }
        if activeScenarioID.isEmpty { activeScenarioID = seed.activeScenarioID }

        ensureConnectivityTestConfiguration()
        return self != before
    }

    static func bootstrap() -> Profile {
        var p = Profile()
        p.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "vpn", name: "AnyConnect", type: "vpn"),
            Line(id: "ss", name: "SS 节点", type: "trojan", enabled: false),
        ]
        p.ruleSets = [
            RuleSet(id: "internal", name: "内部域名", type: "manual"),
        ] + connectivityRuleSets
        return p
    }

    static func templateOverseas(ruleSetIDs: [String], vpnLineID: String, directLineID: String) -> Scenario {
        Scenario(
            id: UUID().uuidString,
            name: "海外",
            bindings: connectivityBindings(outboundLineID: vpnLineID, directLineID: directLineID)
                + ruleSetIDs.filter { id in
                    id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
                }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) },
            defaultLineID: directLineID
        )
    }

    static func templateDomestic(ruleSetIDs: [String], remoteRuleSetID: String, vpnLineID: String, directLineID: String) -> Scenario {
        var bindings = connectivityBindings(outboundLineID: vpnLineID, directLineID: directLineID)
            + ruleSetIDs.filter { id in
                id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
            }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !remoteRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: remoteRuleSetID, lineID: vpnLineID))
        }
        return Scenario(
            id: UUID().uuidString,
            name: "国内",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }

    static func templateDomesticSS(ruleSetIDs: [String], remoteRuleSetID: String, vpnLineID: String, ssLineID: String, directLineID: String) -> Scenario {
        var bindings = connectivityBindings(outboundLineID: ssLineID, directLineID: directLineID)
            + ruleSetIDs.filter { id in
                id != RuleSet.connectivityDirectID && id != RuleSet.connectivityAnyConnectID
            }.map { RuleBinding(ruleSetID: $0, lineID: vpnLineID) }
        if !remoteRuleSetID.isEmpty {
            bindings.append(RuleBinding(ruleSetID: remoteRuleSetID, lineID: ssLineID))
        }
        return Scenario(
            id: UUID().uuidString,
            name: "国内+SS",
            bindings: bindings,
            defaultLineID: directLineID
        )
    }
}
