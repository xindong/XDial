import Foundation

/// 打包时带进 App 的预置配置（App 包里的 PrivateConfig/Seed.json）。企业包用它给员工预先
/// 配好线路、规则和场景；公开仓库里没有这份文件，App 就用空白起步配置。
///
/// 文件格式：
/// ```
/// {
///   "format": "xdial-mobile-seed",
///   "schema_version": 1,
///   "revision": 1,
///   "region_scenarios": { "US": "场景 ID", "*": "其它地区用的场景 ID" },
///   "rule_set_history": { "手动规则 ID": [{ "domains": […], "cidrs": […] }] },
///   "scenario_history": { "场景 ID": [{ "default_line_id": "…", "bindings": [{ "rule_set_id": "…", "line_id": "…" }] }] },
///   "profile": { …与「导出配置」里的 profile 相同，不得包含账号密码… }
/// }
/// ```
struct MobileSeed: Equatable, Sendable {
    static let format = "xdial-mobile-seed"
    static let schemaVersion = 1

    let profileSeed: ProfileSeed
    /// 网络出口所在的地区（两位代码）→ 该用的场景 ID；"*" 是没列出的地区。
    /// 留空表示不按出口选场景，App 也不会去查出口。
    let regionScenarios: [String: String]

    /// 这次构建带的预置。跑单元测试时一律当作没有，测试结果不随本机有没有私有配置而变。
    static let bundled: MobileSeed? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return nil }
        return load(bundle: .main)
    }()

    static func load(bundle: Bundle) -> MobileSeed? {
        guard let url = bundle.url(forResource: "Seed", withExtension: "json", subdirectory: "PrivateConfig"),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try decode(data)
        } catch {
            appLog("MobileSeed: embedded seed is invalid and was ignored: \(error.localizedDescription)")
            return nil
        }
    }

    static func decode(_ data: Data) throws -> MobileSeed {
        guard data.count <= MobileConfigurationService.maxImportBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileConfigurationError.invalidJSON
        }
        guard root["format"] as? String == format,
              let schema = root["schema_version"] as? NSNumber, schema.intValue == schemaVersion,
              let revision = root["revision"] as? NSNumber, revision.intValue >= 1,
              let profileObject = root["profile"] as? [String: Any] else {
            throw MobileConfigurationError.unsupportedFormat
        }
        // profile 部分和「从文件导入」走同一套校验。
        let profileData = try JSONSerialization.data(withJSONObject: profileObject)
        var profile = try MobileConfigurationService.importProfile(from: profileData)
        profile.ensureConnectivityTestConfiguration()

        var regions: [String: String] = [:]
        for (region, scenarioID) in (root["region_scenarios"] as? [String: String]) ?? [:] {
            let key = region.trimmingCharacters(in: .whitespaces).uppercased()
            guard key == "*" || (key.count == 2 && key.allSatisfy { $0.isASCII && $0.isLetter }),
                  profile.scenarios.contains(where: { $0.id == scenarioID }) else {
                throw MobileConfigurationError.unsupportedFormat
            }
            regions[key] = scenarioID
        }
        // 预置改过内容的手动规则，记着之前各版发过的内容，只用来判断用户有没有改过。
        var history: [String: [ShippedRuleContent]] = [:]
        if let raw = root["rule_set_history"] {
            guard let entries = raw as? [String: [[String: Any]]] else { throw MobileConfigurationError.unsupportedFormat }
            for (ruleID, versions) in entries {
                guard profile.ruleSets.contains(where: { $0.id == ruleID && $0.type == "manual" }) else {
                    throw MobileConfigurationError.unsupportedFormat
                }
                history[ruleID] = try versions.map { version in
                    guard Set(version.keys).isSubset(of: ["domains", "cidrs"]),
                          let domains = (version["domains"] ?? [String]()) as? [String],
                          let cidrs = (version["cidrs"] ?? [String]()) as? [String] else {
                        throw MobileConfigurationError.unsupportedFormat
                    }
                    return ShippedRuleContent(domains: domains, cidrs: cidrs)
                }
            }
        }
        // 预置改过路由的场景，记着之前各版发过的默认出口和规则绑定，同样只用来判断用户有没有改过。
        var scenarioHistory: [String: [ShippedScenarioRouting]] = [:]
        if let raw = root["scenario_history"] {
            guard let entries = raw as? [String: [Any]] else { throw MobileConfigurationError.unsupportedFormat }
            let lineIDs = Set(profile.lines.map(\.id))
            let ruleIDs = Set(profile.ruleSets.map(\.id))
            for (scenarioID, versions) in entries {
                guard profile.scenarios.contains(where: { $0.id == scenarioID }) else {
                    throw MobileConfigurationError.unsupportedFormat
                }
                scenarioHistory[scenarioID] = try versions.map { version in
                    guard let routing = ShippedScenarioRouting.decode(version),
                          lineIDs.contains(routing.defaultLineID),
                          routing.bindings.allSatisfy({ ruleIDs.contains($0.ruleSetID) && lineIDs.contains($0.lineID) }) else {
                        throw MobileConfigurationError.unsupportedFormat
                    }
                    return routing
                }
            }
        }
        return MobileSeed(
            profileSeed: ProfileSeed(profile: profile, revision: revision.intValue, ruleSetHistory: history,
                                     scenarioHistory: scenarioHistory),
            regionScenarios: regions
        )
    }
}
