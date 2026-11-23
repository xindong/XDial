import Combine
import XCTest
@testable import XDial

// MARK: - 共用规则

final class ScenarioAutoSwitchRuleTests: XCTestCase {
    func testSwitchNetworkSettingsSettleEveryTerminalPath() throws {
        enum Failure: Error { case prepare, expired, invalidated, engine, commit }
        for failure in [Failure.prepare, .expired, .invalidated, .engine, .commit] {
            var routes = ["source"]
            var settlements = 0
            var operationRan = false
            let result: Result<String, Error> = ScenarioSwitchNetworkTransaction.run {
                routes = ["source", "candidate"]
                // A system settings callback can fail after making partial changes.
                if case .prepare = failure { throw failure }
            } operation: {
                operationRan = true
                if case .expired = failure {
                    _ = try ScenarioSwitchDeadline(requested: 1, now: 2).probeTimeoutMS(now: 2)
                }
                throw failure
            } settle: { committed in
                settlements += 1
                routes = committed ? ["candidate"] : ["source"]
            }
            guard case .failure = result else { return XCTFail("failure committed") }
            XCTAssertEqual(routes, ["source"])
            XCTAssertEqual(settlements, 1)
            if case .prepare = failure { XCTAssertFalse(operationRan) }
        }
        var routes = ["source"]
        var settlements = 0
        let result = ScenarioSwitchNetworkTransaction.run {
            routes = ["source", "candidate"]
        } operation: { "committed" } settle: { committed in
            settlements += 1
            routes = committed ? ["candidate"] : ["source"]
        }
        XCTAssertEqual(try result.get(), "committed")
        XCTAssertEqual(routes, ["candidate"])
        XCTAssertEqual(settlements, 1)
    }

    func testSwitchDeadlineIncludesQueueAndPreparationTime() throws {
        let request = ScenarioSwitchDeadline(now: 100)
        let provider = ScenarioSwitchDeadline(requested: request.uptime, now: 125)
        XCTAssertEqual(provider.uptime, 160)
        // Slow successful probes cannot extend the transaction indefinitely.
        for index in 0..<6 {
            XCTAssertEqual(try provider.probeTimeoutMS(now: 100 + Double(index) * 9), 10_000)
        }
        XCTAssertEqual(try provider.probeTimeoutMS(now: 158), 2_000)
        XCTAssertThrowsError(try provider.probeTimeoutMS(now: 160))
        XCTAssertThrowsError(try provider.probeTimeoutMS(now: 190))
        XCTAssertLessThan(request.uptime - 100, ScenarioSwitchDeadline.replySeconds)
    }

    func testSwitchDeadlineCannotBeExtendedByPeer() {
        XCTAssertEqual(ScenarioSwitchDeadline(requested: 500, now: 100).uptime, 160)
        XCTAssertEqual(ScenarioSwitchDeadline(requested: 90, now: 100).uptime, 90)
        XCTAssertEqual(ScenarioSwitchDeadline(requested: .nan, now: 100).uptime, 100)
    }

    func testCatalogCompletionPreservesPolicyChangesAndCannotReviveClearedBuilds() {
        let enabled = ScenarioAutoPolicy(enabled: true, wifiRules: [], regionScenarios: [:], scenarioIDs: ["a"])
        var disabled = enabled
        disabled.enabled = false
        var state = ScenarioCatalogBuildState()
        let first = state.begin(policy: enabled)
        // No catalog exists yet, but turning off Auto must still affect the first save.
        state.update(policy: disabled)
        XCTAssertEqual(state.policyForCompletion(first, cancelled: false), disabled)
        XCTAssertNil(state.policyForCompletion(first, cancelled: true))
        let second = state.begin(policy: enabled)
        XCTAssertNil(state.policyForCompletion(first, cancelled: false))
        state.clear()
        XCTAssertNil(state.policyForCompletion(second, cancelled: false))
    }

    func testSettledPathNotificationsRespectSSIDPolicyRevisionAndExpiry() {
        let policy = ScenarioAutoPolicy(enabled: true, wifiRules: [], regionScenarios: ["CN": "a"], scenarioIDs: ["a"])
        func context(_ ssid: String = "Home", revision: String = "1", runningID: String = "a",
                     rules: ScenarioAutoPolicy = policy) -> ScenarioSurveyContext {
            .init(network: ScenarioNetworkIdentity.key(path: "wifi", ssid: ssid),
                  revision: revision, policy: rules, runningID: runningID)
        }
        let settled = ScenarioSurveyContext.Settled(context: context(), at: 10)
        XCTAssertTrue(settled.covers(context(), now: 230))
        XCTAssertFalse(settled.covers(context(), now: 310))
        var changed = policy
        changed.regionScenarios = [:]
        for next in [context("Office"), context(revision: "2"), context(runningID: "b"), context(rules: changed)] {
            XCTAssertFalse(settled.covers(next, now: 11))
        }
    }

    func testWiFiIdentityDistinguishesNetworksWithIdenticalInterfaceAndGateway() {
        let path = "satisfied:wifi:en0:192.168.1.1"
        let office = ScenarioNetworkIdentity.key(path: path, ssid: "Office")
        let home = ScenarioNetworkIdentity.key(path: path, ssid: "Home")
        XCTAssertNotEqual(office, home)
        XCTAssertFalse(office.contains("Office"))
        var guardState = ScenarioAutoSwitchGuard()
        guardState.note(from: "a", to: "b", network: office)
        XCTAssertFalse(guardState.mayAutoSwitch(to: "a", network: office))
        XCTAssertTrue(guardState.mayAutoSwitch(to: "a", network: home))
    }

    func testGuardBlocksBouncingBackOnTheSameNetworkOnly() {
        var guardState = ScenarioAutoSwitchGuard()
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(guardState.mayAutoSwitch(to: "outside", network: "wifi:en0:gw-a", now: start))
        guardState.note(from: "office", to: "outside", network: "wifi:en0:gw-a", now: start)

        // 同一个网络里又判断回办公室：两次判断打架，不再切回。
        XCTAssertFalse(guardState.mayAutoSwitch(
            to: "office", network: "wifi:en0:gw-a", now: start.addingTimeInterval(60)
        ))
        // 真的回到了另一个网络（换了网关）：照常切换。
        XCTAssertTrue(guardState.mayAutoSwitch(
            to: "office", network: "wifi:en0:gw-b", now: start.addingTimeInterval(60)
        ))
        // 不带网络特征（App 自己断开重连的旧路径）时维持原来的十分钟规则。
        XCTAssertFalse(guardState.mayAutoSwitch(to: "office", now: start.addingTimeInterval(60)))
        XCTAssertTrue(guardState.mayAutoSwitch(
            to: "office", network: "wifi:en0:gw-a", now: start.addingTimeInterval(601)
        ))
    }

    func testPolicyListsRegisteredWiFiInScenarioOrder() {
        var profile = Profile.bootstrap()
        profile.scenarios = [
            Scenario(id: "office", name: "办公室", matchSSIDs: [" Office ", ""], defaultLineID: "vpn"),
            Scenario(id: "home", name: "家", defaultLineID: "direct"),
            Scenario(id: "cafe", name: "咖啡馆", matchSSIDs: ["Office", "Cafe"], defaultLineID: "direct"),
        ]
        let policy = ScenarioAutoPolicy.make(profile: profile, enabled: true, regionScenarios: ["JP": "home", "*": "gone"])
        XCTAssertEqual(policy.wifiRules, [
            .init(scenarioID: "office", ssids: ["Office"]),
            .init(scenarioID: "cafe", ssids: ["Office", "Cafe"]),
        ])
        XCTAssertEqual(policy.scenarioIDs, ["office", "home", "cafe"])
        XCTAssertEqual(policy.regionScenarioIDs, ["home"])
        XCTAssertEqual(ScenarioAutoDecision.wifiPick(ssid: "Office", rules: policy.wifiRules)?.scenarioID, "office")
        // 对应表指向已删除的场景时不选。
        XCTAssertNil(ScenarioAutoDecision.regionPick(
            countryCode: "NZ", regionScenarios: policy.regionScenarios, scenarioIDs: policy.scenarioIDs
        ))
    }

    func testTunnelStateRoundTripsEveryRecordedFact() throws {
        var guardState = ScenarioAutoSwitchGuard()
        guardState.note(from: "a", to: "b", network: "n", now: Date(timeIntervalSince1970: 10))
        let records: [ScenarioSurveyRecord.ExitLookup] = [
            .notNeeded,
            .found(code: "JP", viaTunnel: true),
            .failed(viaTunnel: true, reason: "timeout"),
            .failed(viaTunnel: false, reason: nil),
        ]
        for exit in records {
            let state = TunnelScenarioState(
                runningScenarioID: "b",
                lastPick: ScenarioAutoPick(scenarioID: "b", reason: .country("JP")),
                lastSurvey: ScenarioSurveyRecord(
                    at: Date(timeIntervalSince1970: 20), ssidRead: true, ssidMatched: false,
                    exit: exit, picked: true, byTunnel: true
                ),
                suggestedScenarioID: "c",
                lastSwitch: .init(
                    from: "a", to: "b", origin: .automatic, mode: .staged,
                    at: Date(timeIntervalSince1970: 30), succeeded: true, failure: nil
                ),
                switchingTo: nil,
                guardState: guardState,
                updatedAt: Date(timeIntervalSince1970: 40)
            )
            let data = try XCTUnwrap(state.encoded())
            XCTAssertEqual(TunnelScenarioState.decode(data), state)
        }
        let wifi = ScenarioAutoPick(scenarioID: "office", reason: .wifi("Office"))
        let decoded = try JSONDecoder().decode(ScenarioAutoPick.self, from: JSONEncoder().encode(wifi))
        XCTAssertEqual(decoded, wifi)
    }

    func testSurveySummaryNamesTheTunnelWithoutTheWiFiName() {
        let record = ScenarioSurveyRecord(
            at: Date(), ssidRead: true, ssidMatched: true, exit: .notNeeded, picked: true, byTunnel: true
        )
        XCTAssertTrue(record.summary(isChinese: true).contains("VPN 扩展"))
        XCTAssertTrue(record.summary(isChinese: false).contains("VPN extension"))
    }

    func testCatalogRejectsTooManyOrTooLargeEntries() {
        let policy = ScenarioAutoPolicy(enabled: true, wifiRules: [], regionScenarios: [:], scenarioIDs: [])
        XCTAssertTrue(ScenarioSwitchCatalog(policy: policy, entries: ["a": Data("{}".utf8)]).isValid)
        let many = Dictionary(uniqueKeysWithValues: (0...ScenarioSwitchCatalog.maxEntries).map { ("s\($0)", Data()) })
        XCTAssertFalse(ScenarioSwitchCatalog(policy: policy, entries: many).isValid)
        let huge = Data(count: ScenarioSwitchCatalog.maxTotalBytes + 1)
        XCTAssertFalse(ScenarioSwitchCatalog(policy: policy, entries: ["a": huge]).isValid)
    }
}

// MARK: - App 侧的隧道内切换

@MainActor
private final class SwitchSpyEngine: TunnelEngine, ObservableObject {
    @Published private(set) var status = "disconnected"
    var lastError: String?
    var dataPathSummary: String?
    var statusPublisher: AnyPublisher<String, Never> { $status.eraseToAnyPublisher() }
    var isConnected: Bool { status == "connected" }
    var isBusy: Bool { status == "connecting" || status == "disconnecting" }

    func start(profileJSON: String) { status = "connected" }
    func stop() { status = "disconnected" }
    func syncStatus() {}
    func setStatus(_ value: String) { status = value }
}

@MainActor
private final class SwitchSpyManager: TunnelManaging {
    let isProfileInstalled = true
    private weak var engine: SwitchSpyEngine?
    private(set) var catalogBuilds: [(ids: [String], policy: ScenarioAutoPolicy, keepingOthers: Bool)] = []
    private(set) var policyUpdates: [ScenarioAutoPolicy] = []
    private(set) var switchRequests: [(scenarioID: String, revision: String)] = []
    private(set) var adoptedScenarios: [String] = []
    private(set) var stopCallCount = 0
    private(set) var reapplied = false
    var switchReply: ScenarioSwitchReply = .unsupported
    var evaluationState: TunnelScenarioState?
    var evaluationUnsupported = false

    init(engine: SwitchSpyEngine) {
        self.engine = engine
    }

    func refreshProfileStatus(completion: @escaping @Sendable (Bool) -> Void) { completion(true) }

    func startTunnel(
        profile: Profile,
        anyConnect: AnyConnectCredentials?,
        allowSystemOnDemand: Bool,
        origin: ConnectionTimeline.StartOrigin,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        engine?.setStatus("connected")
        completion(.success(()))
    }

    func stopTunnel() {
        stopCallCount += 1
        engine?.setStatus("disconnected")
    }

    func rebuildScenarioCatalog(
        inputs: [ScenarioCatalogInput],
        policy: ScenarioAutoPolicy,
        keepingOthers: Bool
    ) async -> String? {
        catalogBuilds.append((inputs.map(\.scenarioID), policy, keepingOthers))
        return "revision-\(catalogBuilds.count)"
    }

    func updateScenarioCatalogPolicy(_ policy: ScenarioAutoPolicy) -> Bool {
        policyUpdates.append(policy)
        return true
    }

    func requestScenarioSwitch(to scenarioID: String, revision: String, reapply: Bool) async -> ScenarioSwitchReply {
        reapplied = reapply
        switchRequests.append((scenarioID, revision))
        return switchReply
    }

    private(set) var evaluationRequestCount = 0
    private(set) var stateRequestCount = 0

    func requestScenarioEvaluation() async -> ScenarioEvaluationReply {
        evaluationRequestCount += 1
        if evaluationUnsupported { return .unsupported }
        return evaluationState.map(ScenarioEvaluationReply.evaluated) ?? .unavailable
    }
    func requestScenarioState() async -> TunnelScenarioState? {
        stateRequestCount += 1
        return evaluationState
    }
    func adoptSwitchedScenario(_ scenarioID: String) { adoptedScenarios.append(scenarioID) }
}

@MainActor
final class ScenarioInTunnelSwitchTests: XCTestCase {
    private var autoEnabled = true

    private func makeApp(noticeAccepted: Bool = true) -> (AppState, SwitchSpyEngine, SwitchSpyManager) {
        let persistence = AppPersistenceContext.testing(identifier: "switch-" + UUID().uuidString)
        XCTAssertTrue(persistence.clearForTesting())
        addTeardownBlock { _ = persistence.clearForTesting() }
        if noticeAccepted {
            persistence.defaults.set(AppState.dataUseNoticeVersion, forKey: persistence.dataUseNoticeKey)
        }
        let engine = SwitchSpyEngine()
        let manager = SwitchSpyManager(engine: engine)
        let app = AppState(engine: engine, tunnelManager: manager, persistence: persistence)
        var profile = Profile.bootstrap()
        profile.lines[1].vpnServer = "gateway.example.com"
        profile.lines[1].vpnUsername = "tester"
        profile.lines[1].vpnPassword = "secret"
        profile.scenarios = [
            Scenario(id: "office", name: "办公室", matchSSIDs: ["Office"], defaultLineID: "direct"),
            Scenario(id: "outside", name: "外面", defaultLineID: "vpn"),
            Scenario(id: "manual", name: "手动", defaultLineID: "direct"),
        ]
        profile.activeScenarioID = "office"
        profile.ensureConnectivityTestConfiguration()
        app.profile = profile
        XCTAssertTrue(app.save())
        app.scenarioAutoPolicyProvider = { [unowned self] profile in
            ScenarioAutoPolicy.make(profile: profile, enabled: self.autoEnabled, regionScenarios: ["*": "outside"])
        }
        return (app, engine, manager)
    }

    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    private func state(running: String, suggested: String? = nil) -> TunnelScenarioState {
        TunnelScenarioState(
            runningScenarioID: running,
            lastPick: ScenarioAutoPick(scenarioID: running, reason: .country("NZ")),
            suggestedScenarioID: suggested
        )
    }

    func testConnectingPreparesEveryScenarioTheExtensionMayPick() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()

        XCTAssertTrue(app.isConnected)
        let build = try? XCTUnwrap(manager.catalogBuilds.first)
        // 当前场景、登记了 Wi-Fi 的场景、地区表里的场景；只能手动选的场景不需要。
        XCTAssertEqual(build?.ids, ["office", "outside"])
        XCTAssertEqual(build?.keepingOthers, false)
        XCTAssertEqual(build?.policy.enabled, true)
    }

    func testPlaceCanActivateAnOtherwiseManualScenarioWithoutDisconnecting() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        let initial = app.scenarioAutoPolicyProvider!
        app.scenarioAutoPolicyProvider = { profile in
            var policy = initial(profile)
            policy.placeMatch = .init(scenarioID: "manual", expires: Date().addingTimeInterval(600))
            return policy
        }
        manager.evaluationState = state(running: "manual")
        app.updateScenarioAutoPolicy()
        app.refreshScenarioCatalog()
        await settle()
        XCTAssertEqual(manager.policyUpdates.last?.placePick()?.scenarioID, "manual")
        XCTAssertTrue(manager.catalogBuilds.last?.ids.contains("manual") == true)
        XCTAssertEqual(app.profile.activeScenarioID, "manual")
        XCTAssertEqual(manager.stopCallCount, 0)
    }

    func testConnectingAsksTheExtensionOnceTheCatalogIsReady() async {
        let (app, _, manager) = makeApp()
        // 连接前 App 自己没查到出口；连上后由扩展经 Direct 线路重新判断。
        manager.evaluationState = state(running: "outside")
        app.connect()
        await settle()

        XCTAssertEqual(manager.catalogBuilds.count, 1)
        XCTAssertEqual(manager.evaluationRequestCount, 1)
        XCTAssertEqual(app.profile.activeScenarioID, "outside")
        XCTAssertEqual(manager.adoptedScenarios, ["outside"])
    }

    func testConnectingWithAutoOffOnlyReadsTheExtensionState() async {
        let (app, _, manager) = makeApp()
        autoEnabled = false
        manager.evaluationState = state(running: "office")
        app.connect()
        await settle()

        XCTAssertEqual(manager.evaluationRequestCount, 0)
        XCTAssertEqual(manager.stateRequestCount, 1)
        XCTAssertEqual(app.profile.activeScenarioID, "office")
    }

    func testApplyingEditedCurrentScenarioDoesNotStopTheTunnel() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        app.profile.scenarios[0].defaultLineID = "vpn"
        XCTAssertTrue(app.save())
        manager.switchReply = .switched(state(running: "office"))
        app.reconnectToApplyChanges()
        await settle()
        XCTAssertTrue(manager.reapplied)
        XCTAssertEqual(manager.stopCallCount, 0)
        XCTAssertFalse(app.hasPendingRuntimeChanges)
    }

    func testManualSwitchKeepsTheVPNUpAndAdoptsTheNewScenario() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        manager.switchReply = .switched(state(running: "manual"))

        let result = await app.switchScenarioInTunnel(to: "manual")
        await settle()

        XCTAssertEqual(result, .switched)
        XCTAssertEqual(manager.stopCallCount, 0, "switching must not stop the system tunnel")
        XCTAssertEqual(manager.switchRequests.map(\.scenarioID), ["manual"])
        // 切换前只生成目标场景，保留目录里其他场景。
        XCTAssertEqual(manager.catalogBuilds[1].ids, ["manual"])
        XCTAssertEqual(manager.catalogBuilds[1].keepingOthers, true)
        XCTAssertEqual(manager.switchRequests.first?.revision, "revision-2")
        XCTAssertEqual(app.profile.activeScenarioID, "manual")
        XCTAssertFalse(app.hasPendingRuntimeChanges)
        XCTAssertEqual(manager.adoptedScenarios, ["manual"])
        // 切完按新配置补齐整个目录。
        XCTAssertEqual(manager.catalogBuilds.last?.ids.first, "manual")
        XCTAssertEqual(manager.catalogBuilds.last?.keepingOthers, false)
    }

    func testFailedSwitchKeepsTheRunningScenarioAndExplainsWhy() async {
        let (app, engine, manager) = makeApp()
        app.connect()
        await settle()
        manager.switchReply = .failed("新场景的线路暂时不可用：timeout", state(running: "office"))

        let result = await app.switchScenarioInTunnel(to: "outside")

        XCTAssertEqual(result, .failed)
        XCTAssertEqual(app.profile.activeScenarioID, "office")
        XCTAssertTrue(app.isConnected)
        XCTAssertEqual(engine.lastError, "新场景的线路暂时不可用：timeout")
        XCTAssertTrue(manager.adoptedScenarios.isEmpty)
    }

    func testOldExtensionFallsBackToTheCaller() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        manager.switchReply = .unsupported

        let result = await app.switchScenarioInTunnel(to: "manual")

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(app.profile.activeScenarioID, "office")
    }

    func testBackgroundSwitchIsAdoptedWhenTheAppAsks() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        manager.evaluationState = state(running: "outside")

        let handled = await app.requestTunnelScenarioEvaluation()

        XCTAssertEqual(handled, .handled)
        XCTAssertEqual(app.profile.activeScenarioID, "outside")
        XCTAssertEqual(app.tunnelScenarioState?.runningScenarioID, "outside")
        XCTAssertFalse(app.hasPendingRuntimeChanges)
        XCTAssertEqual(manager.adoptedScenarios, ["outside"])
    }

    func testEvaluationIsNotHandledWhileDisconnected() async {
        let (app, _, manager) = makeApp()
        manager.evaluationState = state(running: "outside")
        let handled = await app.requestTunnelScenarioEvaluation()
        XCTAssertEqual(handled, .unavailable)
        XCTAssertEqual(app.profile.activeScenarioID, "office")
    }

    func testRunningTunnelIsNotAskedToJudgeBeforeTheNoticeIsConfirmed() async {
        // 升级后打开 App 时隧道可能已经在运行：确认说明之前，不请扩展判断（可能查询出口地区）。
        let (app, engine, manager) = makeApp(noticeAccepted: false)
        manager.evaluationState = state(running: "outside")
        engine.setStatus("connected")
        await settle()

        XCTAssertTrue(app.isConnected)
        let handled = await app.requestTunnelScenarioEvaluation()
        XCTAssertEqual(handled, .unavailable)
        let probe = await app.directExitCountry()
        XCTAssertNil(probe.code)
        XCTAssertEqual(manager.evaluationRequestCount, 0)
        XCTAssertEqual(app.profile.activeScenarioID, "office")

        app.acceptDataUseNotice()
        let afterAccept = await app.requestTunnelScenarioEvaluation()
        XCTAssertEqual(afterAccept, .handled)
        XCTAssertEqual(manager.evaluationRequestCount, 1)
    }

    func testSlowExtensionIsNotMistakenForAnOldOne() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        // 扩展没回应：不能退回断开重连。
        manager.evaluationState = nil
        let slow = await app.requestTunnelScenarioEvaluation()
        XCTAssertEqual(slow, .unavailable)
        manager.evaluationUnsupported = true
        let old = await app.requestTunnelScenarioEvaluation()
        XCTAssertEqual(old, .unsupported)
        XCTAssertEqual(manager.stopCallCount, 0)
    }

    func testTurningAutoOffReachesTheExtension() async {
        let (app, _, manager) = makeApp()
        app.connect()
        await settle()
        autoEnabled = false

        app.updateScenarioAutoPolicy()

        XCTAssertEqual(manager.policyUpdates.last?.enabled, false)
    }
}
