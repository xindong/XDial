import XCTest
@testable import XDial

final class HomeSupportTests: XCTestCase {
    func testSeedScenariosReadAsPlainSentences() {
        let profile = SeedFixture.profile()
        XCTAssertEqual(profile.scenarios.map(\.name), ["在公司", "在本地区", "在外地", "在港口"])
        func summary(_ id: String, chinese: Bool = true) -> String {
            let scenario = profile.scenarios.first { $0.id == id }!
            return ScenarioDescriber.summary(for: scenario, in: profile, isChinese: chinese)
        }

        XCTAssertEqual(summary("office"), "全部直连，不经过 VPN")
        XCTAssertEqual(summary("home-region"), "本地局域网、本地区网站、本地区 IP 直连，其余走公司 VPN")
        XCTAssertEqual(summary("abroad"), "公司内网、本地区网站、本地区 IP 走公司 VPN，其余直连")
        XCTAssertEqual(summary("harbor"), "公司内网、受限服务、本地区网站等 4 项走公司 VPN，其余直连")
        XCTAssertEqual(
            summary("abroad", chinese: false),
            "公司内网, 本地区网站, 本地区 IP via 公司 VPN, everything else direct"
        )

        func symbol(_ id: String) -> String {
            ScenarioDescriber.symbol(for: profile.scenarios.first { $0.id == id }!, in: profile)
        }
        XCTAssertEqual(symbol("office"), "building.2.fill")
        XCTAssertEqual(symbol("home-region"), "globe.asia.australia.fill")
        XCTAssertEqual(symbol("abroad"), "airplane")
        XCTAssertEqual(symbol("harbor"), "ferry.fill")
    }

    func testSeedIsValidatedLikeAnImportedFile() throws {
        let seed = try SeedFixture.seed()
        XCTAssertEqual(seed.profileSeed.revision, 3)
        XCTAssertEqual(seed.regionScenarios, ["JP": "home-region", "SG": "harbor", "*": "abroad"])
        XCTAssertEqual(seed.profileSeed.profile.activeScenarioID, "home-region")
        // 预置里不带账号密码，员工自己填。
        XCTAssertTrue(seed.profileSeed.profile.lines.allSatisfy { $0.vpnUsername.isEmpty && $0.vpnPassword.isEmpty })

        func broken(_ change: (inout [String: Any]) -> Void) -> Data {
            var root = try! JSONSerialization.jsonObject(with: Data(SeedFixture.json.utf8)) as! [String: Any]
            change(&root)
            return try! JSONSerialization.data(withJSONObject: root)
        }
        XCTAssertThrowsError(try MobileSeed.decode(broken { $0["format"] = "something-else" }))
        XCTAssertThrowsError(try MobileSeed.decode(broken { $0["revision"] = 0 }))
        // 地区指向一个不存在的场景：整份预置都不收，免得带着半截配置上线。
        XCTAssertThrowsError(try MobileSeed.decode(broken { $0["region_scenarios"] = ["JP": "missing"] }))
        XCTAssertThrowsError(try MobileSeed.decode(broken { $0["region_scenarios"] = ["Japan": "office"] }))
        XCTAssertThrowsError(try MobileSeed.decode(Data("not json".utf8)))
    }

    func testSeedUpdatesAReworkedRuleOnlyWhileTheUserLeftItAsShipped() throws {
        var root = try JSONSerialization.jsonObject(with: Data(SeedFixture.json.utf8)) as! [String: Any]
        // 新一版把一个公共站点从公司内网拿掉，并记下上一版发的内容。
        root["rule_set_history"] = ["intranet": [["domains": ["corp.example.com", "Shop.Example.com"], "cidrs": ["10.0.0.0/8"]]]]
        let seed = try MobileSeed.decode(JSONSerialization.data(withJSONObject: root)).profileSeed
        XCTAssertEqual(seed.ruleSetHistory["intranet"],
                       [ShippedRuleContent(domains: ["shop.example.com", "corp.example.com"], cidrs: ["10.0.0.0/8"])])

        var untouched = Profile()
        untouched.ruleSets = [RuleSet(id: "intranet", name: "公司内网", type: "manual",
                                      domains: ["shop.example.com", "corp.example.com"], cidrs: ["10.0.0.0/8"])]
        XCTAssertTrue(untouched.adding(seed: seed.profile, ruleSetHistory: seed.ruleSetHistory))
        XCTAssertEqual(untouched.ruleSets.first { $0.id == "intranet" }?.domains, ["corp.example.com"])
        XCTAssertEqual(untouched.ruleSets.first { $0.id == "intranet" }?.cidrs, ["10.0.0.0/8"])
        // 再启动一次不再变化。
        XCTAssertFalse(untouched.adding(seed: seed.profile, ruleSetHistory: seed.ruleSetHistory))

        var edited = Profile()
        edited.ruleSets = [RuleSet(id: "intranet", name: "公司内网", type: "manual",
                                   domains: ["shop.example.com", "corp.example.com", "mine.example"], cidrs: ["10.0.0.0/8"])]
        _ = edited.adding(seed: seed.profile, ruleSetHistory: seed.ruleSetHistory)
        XCTAssertEqual(edited.ruleSets.first { $0.id == "intranet" }?.domains,
                       ["shop.example.com", "corp.example.com", "mine.example"])
    }

    func testSeedRejectsRuleHistoryThatDoesNotDescribeAManualRule() throws {
        func decode(_ history: Any) throws -> MobileSeed {
            var root = try JSONSerialization.jsonObject(with: Data(SeedFixture.json.utf8)) as! [String: Any]
            root["rule_set_history"] = history
            return try MobileSeed.decode(JSONSerialization.data(withJSONObject: root))
        }
        XCTAssertThrowsError(try decode(["region-domains": [["domains": ["a.example"]]]]))
        XCTAssertThrowsError(try decode(["missing": [["domains": ["a.example"]]]]))
        XCTAssertThrowsError(try decode(["intranet": [["domains": ["a.example"], "invert": true]]]))
        XCTAssertThrowsError(try decode(["intranet": "not a list"]))
    }

    /// 新一版给「在外地」加了一条排在最前的直连规则，并记下上一版发的路由。
    private func reroutedSeed(history: Any? = nil) throws -> ProfileSeed {
        var root = try JSONSerialization.jsonObject(with: Data(SeedFixture.json.utf8)) as! [String: Any]
        root["revision"] = 4
        var profile = root["profile"] as! [String: Any]
        var rules = profile["rule_sets"] as! [[String: Any]]
        rules.append(["id": "product", "name": "产品", "type": "manual", "enabled": true, "url": "", "format": "auto",
                      "domains": ["product.example"], "cidrs": []])
        profile["rule_sets"] = rules
        var scenarios = profile["scenarios"] as! [[String: Any]]
        let abroad = scenarios.firstIndex { $0["id"] as? String == "abroad" }!
        let shipped = scenarios[abroad]["bindings"] as! [[String: Any]]
        scenarios[abroad]["bindings"] = [["rule_set_id": "product", "line_id": "direct"]] + shipped
        profile["scenarios"] = scenarios
        root["profile"] = profile
        root["scenario_history"] = history ?? ["abroad": [["default_line_id": "direct", "bindings": shipped]]]
        return try MobileSeed.decode(JSONSerialization.data(withJSONObject: root)).profileSeed
    }

    func testSeedUpdatesAReroutedScenarioOnlyWhileTheUserLeftItAsShipped() throws {
        let seed = try reroutedSeed()
        XCTAssertEqual(seed.scenarioHistory["abroad"]?.first?.bindings.first,
                       ShippedScenarioRouting.Binding(ruleSetID: "local-network", lineID: "direct"))

        // 已装上一版的员工：VPN 线路是自己早先建的那条（预置沿用了它），场景改过名和图标。
        var untouched = Profile()
        untouched.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "my-vpn", name: "我的 VPN", type: "vpn", vpnServer: "vpn.example.com:8443"),
        ]
        untouched.adding(seed: SeedFixture.profile())
        let abroad = untouched.scenarios.firstIndex { $0.id == "abroad" }!
        untouched.scenarios[abroad].name = "出差"
        untouched.scenarios[abroad].iconOverride = "office"
        XCTAssertTrue(untouched.adding(seed: seed.profile, scenarioHistory: seed.scenarioHistory))
        let updated = untouched.scenarios[abroad]
        XCTAssertEqual(updated.name, "出差")
        XCTAssertEqual(updated.iconOverride, "office")
        XCTAssertEqual(updated.bindings.filter { !RuleSet.isConnectivityTestRuleID($0.ruleSetID) }.map(\.ruleSetID),
                       ["product", "local-network", "intranet", "region-domains", "region-ips"])
        XCTAssertEqual(updated.bindings.first { $0.ruleSetID == "intranet" }?.lineID, "my-vpn")
        // 连接验收绑定仍由 App 维护，排在最前。
        XCTAssertEqual(updated.bindings.prefix(2).map(\.ruleSetID),
                       [RuleSet.connectivityDirectID, RuleSet.connectivityOutboundID])
        // 没列进历史的场景不动；再启动一次不再变化。
        XCTAssertFalse(untouched.adding(seed: seed.profile, scenarioHistory: seed.scenarioHistory))

        // 员工自己调过这个场景的规则：保留。
        var edited = Profile()
        edited.adding(seed: SeedFixture.profile())
        let index = edited.scenarios.firstIndex { $0.id == "abroad" }!
        edited.scenarios[index].bindings.removeAll { $0.ruleSetID == "region-ips" }
        let before = edited.scenarios[index]
        edited.adding(seed: seed.profile, scenarioHistory: seed.scenarioHistory)
        XCTAssertEqual(edited.scenarios[index].bindings, before.bindings)

        // 没有场景历史的旧预置格式：已有场景照旧只补不改。
        var legacy = Profile()
        legacy.adding(seed: SeedFixture.profile())
        let shipped = legacy.scenarios[index]
        legacy.adding(seed: seed.profile)
        XCTAssertEqual(legacy.scenarios[index].bindings, shipped.bindings)
    }

    func testSeedRejectsScenarioHistoryThatDoesNotDescribeThePreset() throws {
        let valid: [String: Any] = ["default_line_id": "direct", "bindings": [["rule_set_id": "intranet", "line_id": "office-vpn"]]]
        XCTAssertNoThrow(try reroutedSeed(history: ["abroad": [valid]]))
        XCTAssertNoThrow(try reroutedSeed(history: ["abroad": [["default_line_id": "direct"]]]))
        for bad: Any in [
            ["missing": [valid]],
            ["abroad": "not a list"],
            ["abroad": [["bindings": []]]],
            ["abroad": [["default_line_id": "missing-line"]]],
            ["abroad": [["default_line_id": "direct", "name": "在外地"]]],
            ["abroad": [["default_line_id": "direct", "bindings": [["rule_set_id": "missing", "line_id": "direct"]]]]],
            ["abroad": [["default_line_id": "direct", "bindings": [["rule_set_id": "intranet", "line_id": "missing"]]]]],
            ["abroad": [["default_line_id": "direct", "bindings": [["rule_set_id": "intranet"]]]]],
            ["abroad": [["default_line_id": "direct",
                         "bindings": [["rule_set_id": "intranet", "line_id": "office-vpn", "condition_ids": []]]]]],
        ] {
            XCTAssertThrowsError(try reroutedSeed(history: bad), "\(bad)")
        }
    }

    func testAddingSeedKeepsUserDataAndIsIdempotent() {
        let seed = SeedFixture.profile()
        // 用户已经在用的配置：自己改过预置里的同名规则，另外建了一个场景。
        var profile = Profile()
        profile.lines = [
            Line(id: "direct", name: "直连", type: "direct", verified: true),
            Line(id: "office-vpn", name: "公司 VPN", type: "vpn", vpnServer: "vpn.example.com:8443"),
        ]
        profile.ruleSets = [RuleSet(id: "intranet", name: "公司内网", type: "manual", domains: ["my-own-edit.example"])]
        profile.scenarios = [
            Scenario(id: "mine", name: "我的场景", defaultLineID: "direct"),
            Scenario(id: "office", name: "我改过名的公司", defaultLineID: "direct"),
        ]
        profile.activeScenarioID = "mine"

        XCTAssertTrue(profile.adding(seed: seed))
        XCTAssertEqual(
            profile.scenarios.map(\.name),
            ["我改过名的公司", "在本地区", "在外地", "在港口", "我的场景"]
        )
        XCTAssertEqual(profile.activeScenarioID, "mine")
        XCTAssertEqual(profile.ruleSets.first { $0.id == "intranet" }?.domains, ["my-own-edit.example"])
        XCTAssertNotNil(profile.ruleSets.first { $0.id == "restricted-services" })
        XCTAssertEqual(profile.lines.count, 2)
        // 再加一次不应该有任何变化。
        XCTAssertFalse(profile.adding(seed: seed))
    }

    func testAddingSeedReusesAnExistingLineToTheSameServer() {
        let seed = SeedFixture.profile()
        // 老用户的线路 ID 和预置不一样，但连的是同一个服务器：沿用它（账号密码在上面）。
        var legacy = Profile()
        legacy.lines = [
            Line(id: "d", name: "直连", type: "direct", verified: true),
            Line(
                id: "my-anyconnect", name: "AnyConnect", type: "vpn",
                vpnServer: "VPN.example.com:8443", vpnUsername: "someone", vpnPassword: "secret"
            ),
        ]
        XCTAssertTrue(legacy.adding(seed: seed))
        XCTAssertEqual(legacy.lines.map(\.id), ["d", "my-anyconnect"])
        let abroad = legacy.scenarios.first { $0.id == "abroad" }!
        XCTAssertEqual(abroad.defaultLineID, "d")
        XCTAssertTrue(abroad.bindings.contains(RuleBinding(ruleSetID: "region-domains", lineID: "my-anyconnect")))
        XCTAssertEqual(legacy.scenarios.first { $0.id == "home-region" }?.defaultLineID, "my-anyconnect")

        // 连的是别的服务器：预置线路作为新线路加进来，原来的不动。
        var other = Profile()
        other.lines = [
            Line(id: "d", name: "直连", type: "direct", verified: true),
            Line(id: "other", name: "别的 VPN", type: "vpn", vpnServer: "vpn.example.net"),
        ]
        XCTAssertTrue(other.adding(seed: seed))
        XCTAssertEqual(other.lines.map(\.id), ["d", "other", "office-vpn"])
        XCTAssertEqual(other.scenarios.first { $0.id == "home-region" }?.defaultLineID, "office-vpn")
    }

    func testScenarioWithoutSplitRulesDescribesTheDefaultRoute() {
        var profile = SeedFixture.profile()
        let allDirect = Scenario(id: "office", name: "公司", defaultLineID: "direct")
        let allVPN = Scenario(id: "all", name: "全局", defaultLineID: "office-vpn")
        profile.scenarios = [allDirect, allVPN]

        XCTAssertEqual(
            ScenarioDescriber.summary(for: allDirect, in: profile, isChinese: true),
            "全部直连，不经过 VPN"
        )
        XCTAssertEqual(
            ScenarioDescriber.summary(for: allVPN, in: profile, isChinese: true),
            "全部流量走公司 VPN"
        )
        XCTAssertEqual(ScenarioDescriber.symbol(for: allDirect, in: profile), "wifi")
        XCTAssertEqual(ScenarioDescriber.symbol(for: allVPN, in: profile), "globe.asia.australia.fill")
    }

    func testSummarySkipsDisabledRulesAndConnectivityChecks() {
        var profile = SeedFixture.profile()
        let index = profile.ruleSets.firstIndex { $0.id == "intranet" }!
        profile.ruleSets[index].enabled = false
        let intranet = Scenario(
            id: "intranet", name: "仅公司内网",
            bindings: Profile.connectivityBindings(outboundLineID: "office-vpn", directLineID: "direct")
                + [RuleBinding(ruleSetID: "intranet", lineID: "office-vpn")],
            defaultLineID: "direct"
        )

        // 唯一的分流规则停用后，只剩连接自检规则，不应出现在描述里。
        XCTAssertEqual(
            ScenarioDescriber.summary(for: intranet, in: profile, isChinese: true),
            "全部直连，不经过 VPN"
        )
    }

    func testLongRuleListsAreShortened() {
        var profile = SeedFixture.profile()
        var scenario = Scenario(id: "many", name: "多规则", defaultLineID: "direct")
        for number in 1...5 {
            profile.ruleSets.append(RuleSet(id: "r\(number)", name: "规则\(number)", type: "manual"))
            scenario.bindings.append(RuleBinding(ruleSetID: "r\(number)", lineID: "office-vpn"))
        }
        XCTAssertEqual(
            ScenarioDescriber.summary(for: scenario, in: profile, isChinese: true),
            "规则1、规则2、规则3等 5 项走公司 VPN，其余直连"
        )
    }

    func testConnectionProblemsAreClassifiedByWhatTheUserShouldDo() {
        XCTAssertNil(ConnectionProblem.classify(nil, isChinese: true))
        XCTAssertNil(ConnectionProblem.classify("  ", isChinese: true))

        XCTAssertEqual(
            ConnectionProblem.classify("Login failed.\nPlease enter your password.", isChinese: true)?.kind,
            .credentials
        )
        XCTAssertEqual(
            ConnectionProblem.classify(
                "线路“AnyConnect、直连”不通，已自动断开\n诊断：stage=engine_started",
                isChinese: true
            )?.kind,
            .network
        )
        XCTAssertEqual(
            ConnectionProblem.classify("tls: failed to verify certificate: x509: certificate has expired", isChinese: true)?.kind,
            .server
        )
        XCTAssertEqual(
            ConnectionProblem.classify(
                "连接启动失败\n诊断：error=anyconnect dial: AnyConnect connect: dial tcp4 203.0.113.9:8443: connect: connection refused",
                isChinese: true
            )?.kind,
            .server
        )
        XCTAssertEqual(
            ConnectionProblem.classify(
                "安全配置版本不一致，已停止使用凭据。请在设置中重新导入或重置配置。",
                isChinese: true
            )?.kind,
            .needsReset
        )
        XCTAssertEqual(
            ConnectionProblem.classify("shared rule-set directory is unavailable", isChinese: true)?.kind,
            .other
        )
    }

    func testProblemKeepsTheRawErrorForDetails() {
        let problem = ConnectionProblem.classify("Login failed.", isChinese: false)
        XCTAssertEqual(problem?.detail, "Login failed.")
        XCTAssertEqual(problem?.title, "Wrong username or password")
    }
}
