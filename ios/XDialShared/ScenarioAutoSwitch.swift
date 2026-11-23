import Foundation
import Security
import CryptoKit

// App 与 VPN 扩展共用的自动选场景规则、扩展上报的场景状态，以及共享 Keychain 里的场景目录。
// 只依赖 Foundation / Security：小组件也编译这个目录。

/// One monotonic deadline travels from the App through queueing, preparation and probes.
/// Leave 30 seconds before the App watchdog for abort/restore and the reply.
struct ScenarioSwitchDeadline: Sendable {
    static let requestKey = "scenario_deadline_uptime"
    static let operationSeconds: TimeInterval = 60
    static let replySeconds: TimeInterval = 90
    let uptime: TimeInterval

    init(requested: TimeInterval? = nil, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let local = now + Self.operationSeconds
        uptime = requested.map { $0.isFinite ? min($0, local) : now } ?? local
    }

    func probeTimeoutMS(now: TimeInterval = ProcessInfo.processInfo.systemUptime) throws -> Int {
        let remaining = min(10, uptime - now)
        guard remaining >= 0.001 else {
            throw NSError(domain: "XDial.ScenarioSwitch", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "场景切换超时，未提交新场景"])
        }
        return Int(remaining * 1_000)
    }
}

/// The caller owns network settings for the whole switch, including preparation errors.
/// Every exit settles once; only a committed operation may retain candidate settings.
enum ScenarioSwitchNetworkTransaction {
    static func run<Value>(
        prepare: () throws -> Void,
        operation: () throws -> Value,
        settle: (Bool) -> Void
    ) -> Result<Value, Error> {
        var committed = false
        defer { settle(committed) }
        do {
            try prepare()
            let value = try operation()
            committed = true
            return .success(value)
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - 判断规则

/// Main actor owned catalog build state. Policy changes survive the first build;
/// cancellation, disconnect and a newer build invalidate an older completion.
struct ScenarioCatalogBuildState {
    private var buildID = UUID()
    private var policy: ScenarioAutoPolicy?

    mutating func begin(policy: ScenarioAutoPolicy) -> UUID {
        buildID = UUID()
        self.policy = policy
        return buildID
    }

    mutating func update(policy: ScenarioAutoPolicy) { self.policy = policy }

    mutating func clear() {
        buildID = UUID()
        policy = nil
    }

    func policyForCompletion(_ id: UUID, cancelled: Bool) -> ScenarioAutoPolicy? {
        !cancelled && id == buildID ? policy : nil
    }
}

/// 最近一次自动判断的经过，写进「XDial 诊断」。不记录 Wi-Fi 名称。
struct ScenarioSurveyRecord: Codable, Equatable, Sendable {
    enum ExitLookup: Equatable, Sendable {
        /// 已经靠 Wi-Fi 认出来，或者没有按地区选场景的配置。
        case notNeeded
        /// viaTunnel：已连接时由 VPN 扩展经 Direct 线路查；否则由 App 直接查。
        case found(code: String, viaTunnel: Bool)
        case failed(viaTunnel: Bool, reason: String?)
    }

    let at: Date
    let ssidRead: Bool
    let ssidMatched: Bool
    let exit: ExitLookup
    let picked: Bool
    /// 由 VPN 扩展在后台完成的判断。
    var byTunnel: Bool = false
    /// Which service answered the region lookup (`apple-gcc`, `cloudflare-trace`)
    /// and failed attempts before it; nil for records from older versions.
    var exitEndpoint: String?
    var exitAttempts: String?
    var exitMS: Int?
    /// `ScenarioNetworkIdentity.diagnosticToken` of the network the lookup ran on.
    var networkToken: String?

    init(at: Date, ssidRead: Bool, ssidMatched: Bool, exit: ExitLookup, picked: Bool, byTunnel: Bool = false) {
        self.at = at
        self.ssidRead = ssidRead
        self.ssidMatched = ssidMatched
        self.exit = exit
        self.picked = picked
        self.byTunnel = byTunnel
    }

    /// 「XDial 诊断」里的一行。
    func summary(isChinese: Bool) -> String {
        let time = Self.timeFormatter.string(from: at)
        let wifi = ssidRead
            ? (ssidMatched ? (isChinese ? "已读到并匹配" : "read, matched") : (isChinese ? "已读到，未匹配" : "read, no match"))
            : (isChinese ? "未读到" : "not read")
        let (open, close, colon) = isChinese ? ("（", "）", "：") : (" (", ")", ": ")
        let exitText: String
        switch exit {
        case .notNeeded:
            exitText = isChinese ? "未查询" : "not queried"
        case .found(let code, let viaTunnel):
            let source = viaTunnel ? (isChinese ? "经直连线路" : "via Direct line") : (isChinese ? "本机直接查询" : "queried locally")
            exitText = "\(code)\(open)\(source)\(close)"
        case .failed(let viaTunnel, let reason):
            let source = viaTunnel ? (isChinese ? "经直连线路" : "via Direct line") : (isChinese ? "本机直接查询" : "queried locally")
            let failed = isChinese ? "查询失败" : "failed"
            exitText = "\(failed)\(open)\(source)\(reason.map { "\(colon)\($0)" } ?? "")\(close)"
        }
        let outcome = picked ? (isChinese ? "已判断" : "decided") : (isChinese ? "没判断出来" : "undecided")
        let by = byTunnel ? (isChinese ? "（VPN 扩展）" : " (VPN extension)") : ""
        var evidence: [String] = []
        if let exitEndpoint { evidence.append((isChinese ? "来源 " : "service ") + exitEndpoint) }
        if let exitAttempts, !exitAttempts.isEmpty { evidence.append((isChinese ? "先前失败 " : "failed first ") + exitAttempts) }
        if let exitMS { evidence.append(String(format: "%.1fs", Double(exitMS) / 1000)) }
        if let networkToken { evidence.append((isChinese ? "网络 " : "network ") + networkToken) }
        let age = Int(max(0, Date().timeIntervalSince(at)))
        evidence.append(isChinese ? "\(age) 秒前" : "\(age)s ago")
        let evidenceText = evidence.joined(separator: isChinese ? "，" : ", ")
        return isChinese
            ? "\(time) \(outcome)\(by)；Wi-Fi \(wifi)；出口 \(exitText)；依据：\(evidenceText)"
            : "\(time) \(outcome)\(by); Wi-Fi \(wifi); exit \(exitText); evidence: \(evidenceText)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    enum CodingKeys: String, CodingKey {
        case at
        case ssidRead = "ssid_read"
        case ssidMatched = "ssid_matched"
        case exitKind = "exit"
        case exitCode = "exit_code"
        case exitViaTunnel = "exit_via_tunnel"
        case exitReason = "exit_reason"
        case picked
        case byTunnel = "by_tunnel"
        case exitEndpoint = "exit_endpoint"
        case exitAttempts = "exit_attempts"
        case exitMS = "exit_ms"
        case networkToken = "network_token"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        at = try container.decode(Date.self, forKey: .at)
        ssidRead = try container.decode(Bool.self, forKey: .ssidRead)
        ssidMatched = try container.decode(Bool.self, forKey: .ssidMatched)
        picked = try container.decode(Bool.self, forKey: .picked)
        byTunnel = try container.decodeIfPresent(Bool.self, forKey: .byTunnel) ?? false
        exitEndpoint = try container.decodeIfPresent(String.self, forKey: .exitEndpoint)
        exitAttempts = try container.decodeIfPresent(String.self, forKey: .exitAttempts)
        exitMS = try container.decodeIfPresent(Int.self, forKey: .exitMS)
        networkToken = try container.decodeIfPresent(String.self, forKey: .networkToken)
        let viaTunnel = try container.decodeIfPresent(Bool.self, forKey: .exitViaTunnel) ?? false
        switch try container.decode(String.self, forKey: .exitKind) {
        case "found":
            exit = .found(code: try container.decode(String.self, forKey: .exitCode), viaTunnel: viaTunnel)
        case "failed":
            exit = .failed(viaTunnel: viaTunnel, reason: try container.decodeIfPresent(String.self, forKey: .exitReason))
        default:
            exit = .notNeeded
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(at, forKey: .at)
        try container.encode(ssidRead, forKey: .ssidRead)
        try container.encode(ssidMatched, forKey: .ssidMatched)
        try container.encode(picked, forKey: .picked)
        try container.encode(byTunnel, forKey: .byTunnel)
        try container.encodeIfPresent(exitEndpoint, forKey: .exitEndpoint)
        try container.encodeIfPresent(exitAttempts, forKey: .exitAttempts)
        try container.encodeIfPresent(exitMS, forKey: .exitMS)
        try container.encodeIfPresent(networkToken, forKey: .networkToken)
        switch exit {
        case .notNeeded:
            try container.encode("not_needed", forKey: .exitKind)
        case .found(let code, let viaTunnel):
            try container.encode("found", forKey: .exitKind)
            try container.encode(code, forKey: .exitCode)
            try container.encode(viaTunnel, forKey: .exitViaTunnel)
        case .failed(let viaTunnel, let reason):
            try container.encode("failed", forKey: .exitKind)
            try container.encode(viaTunnel, forKey: .exitViaTunnel)
            try container.encodeIfPresent(reason, forKey: .exitReason)
        }
    }
}

// MARK: - 扩展上报的场景状态

/// A path callback can reuse a settled decision only while all its inputs still match.
struct ScenarioSurveyContext: Equatable {
    let network: String
    let revision: String
    let policy: ScenarioAutoPolicy
    let runningID: String

    struct Settled {
        let context: ScenarioSurveyContext
        let at: TimeInterval

        func covers(_ candidate: ScenarioSurveyContext, now: TimeInterval) -> Bool {
            context == candidate && now - at < 300
        }
    }
}

/// VPN 扩展当前运行的场景、最近一次判断与切换。扩展写进 App Group，并发 Darwin 通知；
/// App 回到前台或收到通知时读取。
struct TunnelScenarioState: Codable, Equatable, Sendable {
    struct SwitchRecord: Codable, Equatable, Sendable {
        enum Origin: String, Codable, Sendable {
            /// 扩展按网络变化自动切换。
            case automatic
            /// App 请求（用户选择或 App 前台的判断）。
            case app
        }

        enum Mode: String, Codable, Sendable {
            /// 新场景在旁边准备好后接管隧道。
            case staged
            /// 系统 VPN 不停，换一个引擎。
            case restart
        }

        let from: String
        let to: String
        let origin: Origin
        let mode: Mode?
        let at: Date
        let succeeded: Bool
        /// 失败原因，展示给用户；不含凭据。
        let failure: String?
    }

    /// 当前承载流量的场景；扩展没有在运行或不知道时为空。
    var runningScenarioID: String?
    /// 最近一次判断的结论。没判断出来时保留上一次。
    var lastPick: ScenarioAutoPick?
    var currentPick: ScenarioAutoPick? {
        lastSurvey?.picked == false ? nil : lastPick
    }
    var lastSurvey: ScenarioSurveyRecord?
    /// 判断出该换、却因为十分钟内刚换过而没有自动换的场景。App 显示为建议。
    var suggestedScenarioID: String?
    var lastSwitch: SwitchRecord?
    /// 正在切换时的目标场景。
    var switchingTo: String?
    var guardState = ScenarioAutoSwitchGuard()
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case runningScenarioID = "running_scenario_id"
        case lastPick = "last_pick"
        case lastSurvey = "last_survey"
        case suggestedScenarioID = "suggested_scenario_id"
        case lastSwitch = "last_switch"
        case switchingTo = "switching_to"
        case guardState = "guard"
        case updatedAt = "updated_at"
    }

    init(
        runningScenarioID: String? = nil,
        lastPick: ScenarioAutoPick? = nil,
        lastSurvey: ScenarioSurveyRecord? = nil,
        suggestedScenarioID: String? = nil,
        lastSwitch: SwitchRecord? = nil,
        switchingTo: String? = nil,
        guardState: ScenarioAutoSwitchGuard = ScenarioAutoSwitchGuard(),
        updatedAt: Date = Date()
    ) {
        self.runningScenarioID = runningScenarioID
        self.lastPick = lastPick
        self.lastSurvey = lastSurvey
        self.suggestedScenarioID = suggestedScenarioID
        self.lastSwitch = lastSwitch
        self.switchingTo = switchingTo
        self.guardState = guardState
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runningScenarioID = try container.decodeIfPresent(String.self, forKey: .runningScenarioID)
        lastPick = try container.decodeIfPresent(ScenarioAutoPick.self, forKey: .lastPick)
        lastSurvey = try container.decodeIfPresent(ScenarioSurveyRecord.self, forKey: .lastSurvey)
        suggestedScenarioID = try container.decodeIfPresent(String.self, forKey: .suggestedScenarioID)
        lastSwitch = try container.decodeIfPresent(SwitchRecord.self, forKey: .lastSwitch)
        switchingTo = try container.decodeIfPresent(String.self, forKey: .switchingTo)
        guardState = try container.decodeIfPresent(ScenarioAutoSwitchGuard.self, forKey: .guardState)
            ?? ScenarioAutoSwitchGuard()
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    static func decode(_ data: Data) -> TunnelScenarioState? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TunnelScenarioState.self, from: data)
    }

    func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }
}

enum TunnelScenarioStateStore {
    static let defaultsKey = "xdial.tunnel.scenario-state"
    /// 扩展更新状态后发出的 Darwin 通知。
    static let changedNotification = "com.xd.xdial.tunnel.scenario-state-changed"

    static func load(appGroup: String) -> TunnelScenarioState? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: defaultsKey) else { return nil }
        return TunnelScenarioState.decode(data)
    }

    /// Wi-Fi 名称只随实时消息交给 App 显示，不写进共享存储。
    static func save(_ state: TunnelScenarioState, appGroup: String) {
        var stored = state
        if case .wifi? = stored.lastPick?.reason, let pick = stored.lastPick {
            stored.lastPick = ScenarioAutoPick(scenarioID: pick.scenarioID, reason: .wifi(""))
        }
        guard let data = stored.encoded() else { return }
        UserDefaults(suiteName: appGroup)?.set(data, forKey: defaultsKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(changedNotification as CFString),
            nil, nil, true
        )
    }
}

// MARK: - 场景目录

/// App 为"可能被选中的场景"提前生成的启动包与判断规则。存在 App 与扩展共用的 Keychain 里：
/// 启动包含 AnyConnect 凭据与线路运行身份，不能写进 App Group 文件或诊断。
///
/// 每个启动包就是按需启动信封的 JSON（format / schema_version / transport / parameters /
/// config_json），参数里另带 `scenario_id` 与线路运行身份。
struct ScenarioSwitchCatalog: Codable, Equatable, Sendable {
    static let currentFormat = "xdial-scenario-catalog"
    static let currentSchemaVersion = 1
    static let maxEntries = 8
    static let maxTotalBytes = 12 * 1024 * 1024

    let format: String
    let schemaVersion: Int
    /// 每次重建目录都换新值。App 请求切换时带上，扩展据此确认读到的是同一份目录。
    let revision: String
    var policy: ScenarioAutoPolicy
    /// 场景 ID → 启动包（信封 JSON 原文）。
    var entries: [String: Data]

    enum CodingKeys: String, CodingKey {
        case format
        case schemaVersion = "schema_version"
        case revision
        case policy
        case entries
    }

    init(revision: String = UUID().uuidString, policy: ScenarioAutoPolicy, entries: [String: Data]) {
        format = Self.currentFormat
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.policy = policy
        self.entries = entries
    }

    var isValid: Bool {
        format == Self.currentFormat
            && schemaVersion == Self.currentSchemaVersion
            && !revision.isEmpty
            && entries.count <= Self.maxEntries
            && entries.values.reduce(0) { $0 + $1.count } <= Self.maxTotalBytes
    }
}

enum ScenarioSwitchCatalogStore {
    enum LoadResult: Equatable {
        case missing
        case available(ScenarioSwitchCatalog)
        case unavailable(OSStatus)
        case corrupt
    }

    private static let infoKey = "XDialSharedKeychainAccessGroup"
    private static let service = "com.kafeifei.xdial.on-demand"
    private static let account = "scenario-catalog-v1"

    static func load(bundle: Bundle = .main) -> LoadResult {
        guard let accessGroup = accessGroup(bundle: bundle) else {
            return .unavailable(errSecMissingEntitlement)
        }
        var query = baseQuery(accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var output: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &output)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data = output as? Data,
              let catalog = try? JSONDecoder().decode(ScenarioSwitchCatalog.self, from: data),
              catalog.isValid else {
            return .corrupt
        }
        return .available(catalog)
    }

    @discardableResult
    static func save(_ catalog: ScenarioSwitchCatalog, bundle: Bundle = .main) -> OSStatus {
        guard catalog.isValid, let data = try? JSONEncoder().encode(catalog) else { return errSecParam }
        guard let accessGroup = accessGroup(bundle: bundle) else { return errSecMissingEntitlement }
        let query = baseQuery(accessGroup: accessGroup)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        guard updateStatus == errSecItemNotFound else { return updateStatus }
        var item = query
        item.merge(values) { _, newValue in newValue }
        return SecItemAdd(item as CFDictionary, nil)
    }

    @discardableResult
    static func clear(bundle: Bundle = .main) -> OSStatus {
        guard let accessGroup = accessGroup(bundle: bundle) else { return errSecMissingEntitlement }
        let status = SecItemDelete(baseQuery(accessGroup: accessGroup) as CFDictionary)
        return status == errSecItemNotFound ? errSecSuccess : status
    }

    private static func accessGroup(bundle: Bundle) -> String? {
        let configured = bundle.object(forInfoDictionaryKey: infoKey) as? String
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty && !trimmed.contains("$(") ? trimmed : nil
    }

    private static func baseQuery(accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }
}

// MARK: - 启动包参数

/// 场景启动包（按需启动信封）里与切换有关的参数名。旧扩展忽略这些参数。
enum ScenarioStartParameter {
    static let scenarioID = "scenario_id"
    /// 实时活动上显示的场景名。
    static let scenarioName = "scenario_name"
    static let anyConnectLineID = "anyconnect_line_id"
    static let anyConnectRuntimeIdentity = "anyconnect_runtime_identity"
    static let tailscaleLineID = "tailscale_line_id"
    static let tailscaleRuntimeIdentity = "tailscale_runtime_identity"
}
