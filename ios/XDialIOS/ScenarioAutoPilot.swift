import Foundation
import Network
import NetworkExtension
import Observation
@preconcurrency import Libbox

/// 当前网络的两条线索：连着哪个 Wi-Fi，流量从哪个国家或地区出去。
struct NetworkSurroundings: Equatable, Sendable {
    var ssid: String?
    /// 两位地区代码，例如 JP、US；没查出来为空。
    var countryCode: String?
}

/// 按当前网络挑场景。纯逻辑，方便测试；规则与 VPN 扩展共用 ScenarioAutoDecision。
enum ScenarioAutoPicker {
    typealias Pick = ScenarioAutoPick

    /// 先看 Wi-Fi：连着哪个场景登记过的 Wi-Fi，就用哪个场景。
    /// 否则看网络出口所在的地区：regionScenarios 里列了这个地区就用对应的场景，
    /// 没列就用 "*" 对应的场景。两条线索都没有、或者对应的场景已经被删掉，就不动。
    static func pick(
        for surroundings: NetworkSurroundings,
        scenarios: [Scenario],
        regionScenarios: [String: String] = [:]
    ) -> Pick? {
        struct WirePick: Decodable {
            let scenario_id: String
            let reason: String
        }
        guard let scenariosData = try? JSONEncoder().encode(scenarios),
              let regionsData = try? JSONEncoder().encode(regionScenarios),
              let scenariosJSON = String(data: scenariosData, encoding: .utf8),
              let regionsJSON = String(data: regionsData, encoding: .utf8) else { return nil }
        var error: NSError?
        let raw = LibboxPickScenario(
            scenariosJSON, regionsJSON, surroundings.ssid ?? "", surroundings.countryCode ?? "", &error
        )
        guard error == nil,
              let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(WirePick.self, from: data) else { return nil }
        let reason: Pick.Reason = result.reason == "wifi"
            ? .wifi((surroundings.ssid ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            : .country((surroundings.countryCode ?? "").uppercased())
        return Pick(scenarioID: result.scenario_id, reason: reason)
    }
}

extension ScenarioAutoPolicy {
    /// 各场景在编辑页登记的 Wi-Fi 名称，按场景列表顺序。
    static func wifiRules(for scenarios: [Scenario]) -> [WiFiRule] {
        scenarios.compactMap { scenario in
            let ssids = scenario.matchSSIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return ssids.isEmpty ? nil : WiFiRule(scenarioID: scenario.id, ssids: ssids)
        }
    }

    static func make(profile: Profile, enabled: Bool, regionScenarios: [String: String]) -> ScenarioAutoPolicy {
        ScenarioAutoPolicy(
            enabled: enabled,
            wifiRules: wifiRules(for: profile.scenarios),
            regionScenarios: regionScenarios,
            scenarioIDs: profile.scenarios.map(\.id)
        )
    }
}

/// 观察当前网络并给出该用哪个场景。只在 App 开着的时候工作。
@Observable
@MainActor
final class ScenarioAutoPilot {
    /// 最近一次判断的结果；还没判断过、或者没判断出来时为空。
    private(set) var pick: ScenarioAutoPicker.Pick?
    private(set) var isSurveying = false
    /// 判断过至少一次（用来区分「还在判断」和「没判断出来」）。
    private(set) var hasSurveyed = false
    /// 最近一次判断的经过。设置页的诊断和主屏不在同一个视图里，所以放在共享位置。
    static private(set) var lastRecord: ScenarioSurveyRecord?
    /// 网络变了（换了 Wi-Fi、Wi-Fi 换成蜂窝）时调用，由主屏决定要不要重新判断。
    @ObservationIgnored var onNetworkChange: (() -> Void)?

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var lastPathSignature: String?
    @ObservationIgnored private var changeDebounce: Task<Void, Never>?
    @ObservationIgnored private var switchGuard = ScenarioAutoSwitchGuard()

    /// 「自动」开关（主屏的 @AppStorage 存在同一个键里）。
    static let autoEnabledKey = "xdial.auto-scenario"
    static var isAutoEnabled: Bool {
        UserDefaults.standard.object(forKey: autoEnabledKey) as? Bool ?? true
    }

    /// 已连接时要不要自动换到 target。刚刚才从 target 自动换走的话就不再换回去——
    /// 两次判断结果打架时（比如查出口的请求没能绕开隧道），宁可停下来提示，也不能反复断线重连。
    /// 只用于扩展不支持隧道内切换（旧版本）时由 App 断开重连的情况。
    func mayAutoSwitch(to target: String, now: Date = Date()) -> Bool {
        switchGuard.mayAutoSwitch(to: target, now: now)
    }

    func noteAutoSwitch(from: String, to: String, now: Date = Date()) {
        switchGuard.note(from: from, to: to, now: now)
    }
    @ObservationIgnored private var running: Task<ScenarioAutoPicker.Pick?, Never>?
    /// Bumped whenever the physical network changes. A survey started on an
    /// older network is neither reused nor allowed to overwrite the result.
    @ObservationIgnored private(set) var networkGeneration = 0
    @ObservationIgnored private var runningGeneration = -1
    @ObservationIgnored private var lastSurveyAt: Date?

    /// Marks a physical network change; tests use it to stand in for the path monitor.
    func noteNetworkChanged() {
        networkGeneration += 1
        lastSurveyAt = nil
        pick = nil
        hasSurveyed = false
        Self.lastRecord = nil
    }

    /// 最近一次判断是不是还新鲜（点连接时用，避免每次都等）。
    var isFresh: Bool {
        guard let lastSurveyAt else { return false }
        return Date().timeIntervalSince(lastSurveyAt) < 20
    }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // 只关心物理网络换没换；VPN 自己的虚拟网卡上上下下不算。
            let physical = path.availableInterfaces
                .filter { $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet }
                .map { "\($0.type):\($0.name)" }
                .sorted().joined(separator: ",")
            // 换一个 Wi-Fi 时网卡不变、网关会变，所以把网关也算进去。
            let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
            let signature = "\(path.status):\(physical):\(gateways)"
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard signature != self.lastPathSignature else { return }
                let isFirst = self.lastPathSignature == nil
                self.lastPathSignature = signature
                guard !isFirst else { return }
                self.noteNetworkChanged()
                // 换网络时系统会连着报好几次，等它稳定下来再判断一次。
                self.changeDebounce?.cancel()
                self.changeDebounce = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled else { return }
                    self?.onNetworkChange?()
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "xdial.scenario-autopilot.path"))
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        lastPathSignature = nil
        changeDebounce?.cancel()
        changeDebounce = nil
    }

    /// 看一眼当前网络，返回该用的场景。同时来的多次调用合并成一次。
    /// regionScenarios 为空时只看 Wi-Fi，不去查网络出口。
    /// 已连接时传入 exitCountryViaTunnel：这时 App 自己的请求按场景分流、域名解析也归隧道，
    /// 只有 VPN 扩展经 Direct 线路才查得到本地网络的出口。
    @discardableResult
    func survey(
        scenarios: [Scenario],
        regionScenarios: [String: String] = [:],
        exitCountryViaTunnel: (@MainActor () async -> ExitCountryProbeResult)? = nil
    ) async -> ScenarioAutoPicker.Pick? {
        // Merge concurrent calls only within one network; a survey from before a
        // network change must not answer for the new network.
        if let running, runningGeneration == networkGeneration {
            let generation = networkGeneration
            let result = await running.value
            return networkGeneration == generation ? result : nil
        }
        isSurveying = true
        let generation = networkGeneration
        let pathSignature = lastPathSignature
        let task = Task { () -> ScenarioAutoPicker.Pick? in
            let ssid = await NetworkProbe.currentSSID()
            guard generation == networkGeneration else { return nil }
            let ssidRead = !(ssid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            // 已经靠 Wi-Fi 认出来了，或者没有按地区选场景的配置，就不用去查出口。
            if let pick = ScenarioAutoPicker.pick(
                for: NetworkSurroundings(ssid: ssid, countryCode: nil),
                scenarios: scenarios
            ) {
                Self.lastRecord = ScenarioSurveyRecord(
                    at: Date(), ssidRead: ssidRead, ssidMatched: true, exit: .notNeeded, picked: true
                )
                return pick
            }
            guard !regionScenarios.isEmpty else {
                Self.lastRecord = ScenarioSurveyRecord(
                    at: Date(), ssidRead: ssidRead, ssidMatched: false, exit: .notNeeded, picked: false
                )
                return nil
            }
            let viaTunnel = exitCountryViaTunnel != nil
            let lookup: ExitCountryProbeResult
            if let exitCountryViaTunnel {
                lookup = await exitCountryViaTunnel()
            } else {
                lookup = await NetworkProbe.exitCountryCode()
            }
            guard generation == networkGeneration else { return nil }
            let pick = ScenarioAutoPicker.pick(
                for: NetworkSurroundings(ssid: ssid, countryCode: lookup.code),
                scenarios: scenarios,
                regionScenarios: regionScenarios
            )
            var record = ScenarioSurveyRecord(
                at: Date(),
                ssidRead: ssidRead,
                ssidMatched: false,
                exit: lookup.code.map { .found(code: $0, viaTunnel: viaTunnel) }
                    ?? .failed(viaTunnel: viaTunnel, reason: lookup.failure),
                picked: pick != nil
            )
            record.exitEndpoint = lookup.endpoint
            record.exitAttempts = lookup.attempts
            record.exitMS = lookup.ms
            record.networkToken = ScenarioNetworkIdentity.diagnosticToken(path: pathSignature, ssid: ssid)
            Self.lastRecord = record
            return pick
        }
        running = task
        runningGeneration = generation
        let result = await task.value
        if running == task {
            running = nil
            runningGeneration = -1
        }
        if networkGeneration != generation {
            isSurveying = running != nil
            return nil
        }
        pick = result
        isSurveying = false
        hasSurveyed = true
        lastSurveyAt = Date()
        return result
    }
}

/// 读 Wi-Fi 名称、查网络出口所在地。
enum NetworkProbe {
    static func currentSSID() async -> String? {
        #if targetEnvironment(simulator)
        // 模拟器读不到 Wi-Fi：-XDialFakeSSID <名称> 用来演示。
        return launchArgument("-XDialFakeSSID")
        #else
        // 需要「访问 Wi-Fi 信息」权限；App 装了 VPN 配置，所以不用再要定位授权。
        return await withCheckedContinuation { continuation in
            NEHotspotNetwork.fetchCurrent { network in
                continuation.resume(returning: network?.ssid)
            }
        }
        #endif
    }

    /// 没连接时网络出口所在的国家或地区。先问苹果，问不到再问 Cloudflare。
    /// 请求绑在物理网卡上。已连接时不用它：系统把域名解析交给隧道，禁止走隧道的请求解析不了，
    /// 改由 VPN 扩展经 Direct 线路查（见 ScenarioAutoPilot.survey）。
    /// 两处都没查到时，failure 写明各自是没有回应还是回复无效，供诊断使用。
    static func exitCountryCode() async -> ExitCountryProbeResult {
        #if targetEnvironment(simulator)
        if let fake = launchArgument("-XDialFakeCountry") {
            return ExitCountryProbeResult(code: fake.uppercased(), failure: nil)
        }
        #endif
        let result = await UnderlayCountryLookup.lookupWithEvidence()
        return ExitCountryProbeResult(
            code: result.code, failure: result.failure, endpoint: result.endpoint,
            attempts: result.attempts.isEmpty ? nil : result.attempts.joined(separator: ","), ms: result.ms)
    }

    static func countryCode(inAppleReply text: String) -> String? { UnderlayCountryLookup.countryCode(inAppleReply: text) }
    static func countryCode(inCloudflareTrace text: String) -> String? { UnderlayCountryLookup.countryCode(inCloudflareTrace: text) }
    static func localFailure(apple: String?, cloudflare: String?) -> String { UnderlayCountryLookup.localFailure(apple: apple, cloudflare: cloudflare) }
    #if targetEnvironment(simulator)
    private static func launchArgument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
        let value = arguments[index + 1]
        return value.isEmpty ? nil : value
    }
    #endif
}

/// 订阅一个 Darwin 通知（VPN 扩展更新场景状态后发出），在主线程回调。
final class DarwinNotificationObserver: @unchecked Sendable {
    private let name: String
    private let handler: @MainActor () -> Void

    init(name: String, handler: @escaping @MainActor () -> Void) {
        self.name = name
        self.handler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let me = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in me.handler() }
            },
            name as CFString,
            nil,
            .deliverImmediately
        )
    }

    deinit {
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            CFNotificationName(name as CFString),
            nil
        )
    }
}
