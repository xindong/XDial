import AppIntents
import Foundation

/// Debug shows as "XDial Debug"; runtime copy names the app the way the system does.
private var appName: String { XDialBuildIdentity.applicationDisplayName }

// Shortcuts on the Mac run in the app process, so they reuse the same AppState
// entry points as the menu: connect, disconnect and the Home Scenario picker.
// They never open windows: anything that needs the user (the data use notice,
// installation, missing credentials) is reported back as the reason instead.

@MainActor
enum MacIntentHost {
    private(set) static weak var state: AppState?

    static func register(_ state: AppState) {
        self.state = state
    }

    /// Shortcuts may launch XDial; wait briefly for the library to load.
    static func require() async throws -> AppState {
        for _ in 0..<50 {
            if let state, state.profileLibraryLoaded { return state }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw MacIntentError.message(state?.tr("\(appName) 还没准备好，请打开 \(appName) 后重试。",
                                               "\(appName) is not ready. Open \(appName) and try again.")
            ?? "\(appName) is not ready. Open \(appName) and try again.")
    }

    /// Polls until `done` holds; false on timeout.
    static func wait(seconds: Double, until done: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while ContinuousClock.now < deadline {
            if done() { return true }
            try await Task.sleep(for: .milliseconds(200))
        }
        return done()
    }
}

enum MacIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): return "\(text)"
        }
    }
}

// MARK: - Scenario entity

struct MacScenarioEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "intent.scenario.type")
    static let defaultQuery = MacScenarioEntityQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct MacScenarioEntityQuery: EntityQuery {
    func entities(for identifiers: [MacScenarioEntity.ID]) async throws -> [MacScenarioEntity] {
        let wanted = Set(identifiers)
        return try await Self.all().filter { wanted.contains($0.id) }
    }

    func suggestedEntities() async throws -> [MacScenarioEntity] {
        try await Self.all()
    }

    @MainActor
    private static func all() async throws -> [MacScenarioEntity] {
        try await MacIntentHost.require().profile.scenarios.map {
            MacScenarioEntity(id: $0.id, name: $0.name)
        }
    }
}

// MARK: - Intents

struct MacConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.connect.title"
    static let description = IntentDescription("intent.connect.description")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await MacIntentHost.require()
        let tr = state.tr
        guard let scenario = state.activeScenario else {
            throw MacIntentError.message(tr("还没有可用的场景，请打开 \(appName) 添加场景。",
                                            "There is no Scenario yet. Open \(appName) to add one."))
        }
        if state.isConnected, !state.isBusy {
            return .result(dialog: "\(tr("\(appName) 已连接：", "\(appName) is connected: "))\(scenario.name)")
        }
        guard state.dataUseNoticeAccepted else {
            throw MacIntentError.message(tr("请先打开 \(appName)，确认数据使用说明后再连接。",
                                            "Open \(appName) and confirm the data use notice before connecting."))
        }
        guard state.installation.isReady else {
            throw MacIntentError.message(tr("\(appName) 还没完成安装，请打开 \(appName) 完成安装。",
                                            "\(appName) is not fully installed. Open \(appName) to finish installing."))
        }
        if let blocker = ConnectionConfigurationBlocker.evaluate(scenario, in: state.profile) {
            throw MacIntentError.message(blocker.title(tr) + " " + blocker.detail(tr))
        }
        var engineStarted: Bool?
        state.connect { engineStarted = $0 }
        let finished = try await MacIntentHost.wait(seconds: 120) {
            engineStarted != nil && !state.engine.isBusy
        }
        if finished, engineStarted == true, state.isConnected {
            return .result(dialog: "\(tr("\(appName) 已连接：", "\(appName) is connected: "))\(scenario.name)")
        }
        guard finished else {
            throw MacIntentError.message(tr("\(appName) 仍在连接，请稍后在菜单栏查看结果。",
                                            "\(appName) is still connecting. Check the menu bar for the result."))
        }
        let reason = engineStarted == true
            ? state.presentedConnectionReport?.error?.message ?? state.engine.lastError
            : nil
        throw MacIntentError.message(reason.map { tr("连接没有成功：", "The connection failed: ") + $0 }
            ?? tr("连接没有成功，请打开 \(appName) 查看原因。", "The connection failed. Open \(appName) to see why."))
    }
}

struct MacDisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.disconnect.title"
    static let description = IntentDescription("intent.disconnect.description")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await MacIntentHost.require()
        let tr = state.tr
        state.disconnect()
        guard try await MacIntentHost.wait(seconds: 60, until: { state.engine.status == "disconnected" }) else {
            throw MacIntentError.message(tr("\(appName) 仍在断开，请稍后在菜单栏查看结果。",
                                            "\(appName) is still disconnecting. Check the menu bar for the result."))
        }
        return .result(dialog: "\(tr("\(appName) 已断开", "\(appName) is disconnected"))")
    }
}

struct MacSwitchScenarioIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.switch.title"
    static let description = IntentDescription("intent.switch.description")

    @Parameter(title: "intent.scenario.type")
    var scenario: MacScenarioEntity

    static var parameterSummary: some ParameterSummary {
        Summary("intent.switch.summary \(\.$scenario)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = try await MacIntentHost.require()
        let tr = state.tr
        guard let target = state.profile.scenarios.first(where: { $0.id == scenario.id }) else {
            throw MacIntentError.message(tr("这个场景已不存在。", "This Scenario no longer exists."))
        }
        guard state.engine.status != "disconnecting" else {
            throw MacIntentError.message(tr("\(appName) 正在断开，请稍后再试。", "\(appName) is disconnecting. Try again shortly."))
        }
        let wasConnected = state.isConnected || state.isBusy
        // The same entry point as the Scenario list in the menu bar popover.
        state.selectHomeScenario(target.id)
        guard wasConnected else {
            guard state.profile.activeScenarioID == target.id else {
                throw MacIntentError.message(tr("没能切换场景，请打开 \(appName) 查看原因。",
                                                "The Scenario did not change. Open \(appName) to see why."))
            }
            return .result(dialog: "\(tr("已选择", "Selected")) \(target.name)\(tr("，下次连接时生效", "; it applies on the next connection"))")
        }
        let finished = try await MacIntentHost.wait(seconds: 120) { !state.isBusy }
        guard finished else {
            throw MacIntentError.message(tr("\(appName) 仍在切换场景，请稍后在菜单栏查看结果。",
                                            "\(appName) is still switching. Check the menu bar for the result."))
        }
        guard state.isConnected, state.profile.activeScenarioID == target.id else {
            throw MacIntentError.message(tr("没能切换到", "Could not switch to ") + target.name
                + tr("，请打开 \(appName) 查看原因。", ". Open \(appName) to see why."))
        }
        return .result(dialog: "\(tr("已切换到", "Switched to")) \(target.name)")
    }
}

/// Read-only: what XDial is doing now, for automations and support checks.
struct MacConnectionStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.status.title"
    static let description = IntentDescription("intent.status.description")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let state = try await MacIntentHost.require()
        let tr = state.tr
        let scenario = state.activeScenario?.name ?? tr("无场景", "no Scenario")
        let status: String
        switch state.engine.status {
        case "connected": status = tr("已连接", "Connected")
        case "connecting", "reconnecting": status = tr("正在连接", "Connecting")
        case "disconnecting": status = tr("正在断开", "Disconnecting")
        default: status = tr("未连接", "Not connected")
        }
        let summary = "\(status) · \(scenario)"
        return .result(value: summary, dialog: "\(summary)")
    }
}

struct XDialMacShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MacConnectIntent(), phrases: ["Connect \(.applicationName)", "连接 \(.applicationName)"],
                    shortTitle: "intent.connect.short", systemImageName: "power")
        AppShortcut(intent: MacDisconnectIntent(), phrases: ["Disconnect \(.applicationName)", "断开 \(.applicationName)"],
                    shortTitle: "intent.disconnect.short", systemImageName: "poweroff")
        AppShortcut(intent: MacSwitchScenarioIntent(),
                    phrases: ["Switch \(.applicationName) Scenario", "切换 \(.applicationName) 场景"],
                    shortTitle: "intent.switch.short", systemImageName: "arrow.triangle.branch")
        AppShortcut(intent: MacConnectionStatusIntent(),
                    phrases: ["\(.applicationName) status", "\(.applicationName) 状态"],
                    shortTitle: "intent.status.short", systemImageName: "info.circle")
    }
}
