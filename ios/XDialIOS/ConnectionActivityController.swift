import ActivityKit
import Combine
import Foundation
import UIKit

/// 把连接状态同步到锁屏和灵动岛的实时活动。
///
/// 系统只允许 App 在前台时新建实时活动；后台触发的连接（控制中心、快捷指令）会在
/// 下次回到前台时补上。更新和结束不受这个限制。
@MainActor
final class ConnectionActivityController {
    static let preferenceKey = "xdial.live-activity.enabled"
    static let backgroundSpeedKey = "xdial.live-activity.background-speed"

    private let app: AppState
    private var subscriptions: Set<AnyCancellable> = []
    private var queue: Task<Void, Never>?
    private var lastState: XDialConnectionAttributes.ContentState?
    private var sampler: Task<Void, Never>?

    /// 用户可以在设置里关掉；默认打开。
    static var isEnabledByUser: Bool {
        get { UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    init(app: AppState) {
        self.app = app
        app.objectWillChange
            .merge(with: app.engine.objectWillChange)
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.sync() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification))
            .sink { [weak self] _ in self?.sync() }
            .store(in: &subscriptions)
        sync(force: !Self.isEnabledByUser)
    }

    private var shouldSample: Bool {
        app.isConnected && Self.isEnabledByUser
            && (UIApplication.shared.applicationState != .background
                || UserDefaults.standard.bool(forKey: Self.backgroundSpeedKey))
    }

    /// 退出允许采样的状态时取消整个任务，恢复后用两个新样本计算速率。
    func refreshSampling() {
        guard shouldSample else {
            guard let stopped = sampler else { return }
            stopped.cancel()
            sampler = nil
            let previous = queue
            queue = Task { [weak self] in
                await previous?.value
                await stopped.value
                // A stale date alone may leave the compact island showing its last number.
                for activity in Activity<XDialConnectionAttributes>.activities {
                    guard let self, !self.shouldSample else { return }
                    let state = activity.content.state
                    guard state.speedSampledAt != nil else { continue }
                    await activity.update(ActivityContent(state: state.clearingSpeed(), staleDate: nil))
                }
            }
            return
        }
        guard sampler == nil else { return }
        sampler = Task { [weak self] in
            var estimator = TrafficRateEstimator()
            var lastSample: Date?
            var connectionStart: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                guard self.shouldSample else {
                    self.refreshSampling()
                    return
                }
                let start = self.app.engine.connectedAt
                let totals = await self.app.trafficTotals()
                guard !Task.isCancelled else { return }
                guard self.shouldSample else {
                    self.refreshSampling()
                    return
                }
                let now = Date()
                let interval = lastSample.map { now.timeIntervalSince($0) }
                let continuous = connectionStart == start && interval.map {
                    $0 > 0 && $0 < XDialConnectionAttributes.ContentState.speedLifetime
                } == true
                connectionStart = start
                lastSample = totals == nil ? nil : now
                guard let rate = estimator.update(totals, sampledAt: now), continuous,
                      self.app.engine.connectedAt == start,
                      rate.downloadBytesPerSecond != nil else { continue }
                for activity in Activity<XDialConnectionAttributes>.activities {
                    guard !Task.isCancelled else { return }
                    var state = activity.content.state
                    guard state.connectedAt != nil else { continue }
                    state.downloadBytesPerSecond = rate.downloadBytesPerSecond
                    state.uploadBytesPerSecond = rate.uploadBytesPerSecond
                    state.speedSampledAt = now
                    await activity.update(ActivityContent(state: state, staleDate: state.speedExpiresAt))
                }
            }
        }
    }

    /// 设置里的开关变化后调用。
    func preferenceChanged() {
        sync(force: true)
    }

    private var desiredState: XDialConnectionAttributes.ContentState? {
        guard Self.isEnabledByUser else { return nil }
        let scenario = app.activeScenario?.name ?? ""
        switch app.engine.status {
        case "connecting":
            return .init(phase: .working, title: app.tr("正在连接…", "Connecting…"),
                         scenarioName: scenario, connectedAt: nil)
        case "reconnecting":
            return .init(phase: .working, title: app.tr("正在重连…", "Reconnecting…"),
                         scenarioName: scenario, connectedAt: nil)
        case "action-required":
            return .init(phase: .attention, title: app.tr("需要登录 Tailscale", "Sign-in Required"),
                         scenarioName: scenario, connectedAt: app.engine.connectedAt)
        case "connected":
            let degraded = app.engine.dataPathSummary?.hasPrefix(dataPathDegradedPrefix) ?? false
            // Connection and self-check are separate facts: the title stays the
            // connection state and the check gets its own line.
            let detail: String? = degraded
                ? (app.engine.dataPathRechecking
                    ? app.tr("自检未通过，正在重新检测", "Route check failed · rechecking")
                    : app.tr("线路自检未通过", "Route check didn't pass"))
                : nil
            return .init(
                phase: .connected,
                title: app.tr("已连接", "Connected"),
                scenarioName: scenario,
                connectedAt: app.engine.connectedAt ?? Date(),
                detail: detail
            )
        default:
            return nil
        }
    }

    private func sync(force: Bool = false) {
        refreshSampling()
        let desired = desiredState
        guard force || desired != lastState else { return }
        lastState = desired
        let disconnectTitle = app.tr("断开", "Disconnect")
        let previous = queue
        queue = Task { [weak self] in
            await previous?.value
            await Self.apply(desired, disconnectTitle: disconnectTitle)
            // 新建失败（多半是 App 不在前台）时清掉记录，回到前台后会再试一次。
            if desired != nil, Activity<XDialConnectionAttributes>.activities.isEmpty {
                self?.lastState = nil
            }
        }
    }

    private static func apply(
        _ desired: XDialConnectionAttributes.ContentState?,
        disconnectTitle: String
    ) async {
        let activities = Activity<XDialConnectionAttributes>.activities
        guard let desired else {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }
        var state = desired
        if let current = activities.first, state.connectedAt != nil, state.connectedAt == current.content.state.connectedAt {
            // 网速由采样单独刷新，这里更新状态时保留上一次的读数。
            state.speedSampledAt = current.content.state.speedSampledAt
            state.downloadBytesPerSecond = current.content.state.downloadBytesPerSecond
            state.uploadBytesPerSecond = current.content.state.uploadBytesPerSecond
        }
        let content = ActivityContent(state: state, staleDate: state.speedExpiresAt)
        if let current = activities.first {
            // 只保留一个，多出来的（比如上次没来得及结束的）收掉。
            for extra in activities.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
            await current.update(content)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try Activity.request(
                attributes: XDialConnectionAttributes(disconnectTitle: disconnectTitle),
                content: content,
                pushType: nil
            )
        } catch {
            appLog("LiveActivity: request failed: \(error.localizedDescription)")
        }
    }
}
