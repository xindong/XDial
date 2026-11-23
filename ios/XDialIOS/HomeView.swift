import SwiftUI

/// 主屏以拨盘和连接状态为主；自动模式收起场景，手动模式直接选择。
struct HomeView: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var signInLineID: SignInTarget?
    @State private var connectAfterSignIn = false
    @State private var showingSettings = false
    /// 打开设置时直接弹出「导入配置」（公开版首页空状态的入口）。
    @State private var settingsStartsImport = false
    @State private var showingAdvanced = false
    @State private var showingProblemDetail = false
    @State private var isConfirmingReset = false
    @State private var tailscaleLoginLineID: String?
    @State private var tailscaleLoginError: String?
    @State private var trafficRate = TrafficRate.unavailable
    /// 按当前网络自动选场景；手动点了别的场景就关掉。
    @AppStorage("xdial.auto-scenario") private var autoScenario = true
    @State private var autoPilot = ScenarioAutoPilot()
    @State private var showingAutoScenarios = false
    @State private var dismissedSuggestionID: String?
    /// 点了连接、正在先看一眼当前网络的那一两秒。
    @State private var isPreparingConnection = false
    /// 正在自动断开、换场景、重连。
    @State private var isAutoSwitching = false

    private struct SignInTarget: Identifiable {
        let id: String
    }

    var body: some View {
        GeometryReader { proxy in
            // 横屏和 iPhone Duo 展开后足够宽：左边拨盘，右边场景和账号。
            let isWide = proxy.size.width >= 700
            let columns = isWide
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 32))
                : AnyLayout(VStackLayout(spacing: 22))
            // 拨盘跟着屏幕高度走：矮屏（Duo 折叠、横屏）缩小，展开的大屏放大一点。
            let dialDiameter = isWide
                ? min(240, max(170, proxy.size.height * 0.36))
                : min(216, max(160, proxy.size.height * 0.26))
            ScrollView {
                VStack(spacing: 12) {
                    header
                    columns {
                        VStack(spacing: 22) {
                            hero(dialDiameter: dialDiameter)

                            if app.requiresUserAction {
                                tailscaleSignInCard
                            }
                            if isDegraded {
                                routeCheckNote
                            }
                            if let suggested = suggestedScenario {
                                suggestionCard(suggested)
                            }
                            if app.hasPendingRuntimeChanges {
                                PendingRuntimeChangesBanner()
                            }
                            if let problem, isIdle {
                                problemCard(problem)
                            } else if isIdle, !app.activeScenarioNeedsSignIn, !setupIssues.isEmpty {
                                setupCard
                            }
                        }
                        .frame(maxWidth: .infinity)

                        VStack(spacing: 22) {
                            scenarioSection
                            accountSection
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, isWide ? 26 : 0)
                    }
                }
                .padding(.horizontal, isWide ? 32 : 20)
                .padding(.bottom, 28)
                .frame(maxWidth: isWide ? 1080 : 560)
                .frame(maxWidth: .infinity)
                .animation(.smooth(duration: 0.4), value: isWide)
            }
        }
        .background(background)
        .sheet(item: $signInLineID, onDismiss: connectIfRequested) { target in
            SignInSheet(lineID: target.id) {
                connectAfterSignIn = true
            }
            .environmentObject(app)
        }
        .sheet(isPresented: $showingSettings, onDismiss: { settingsStartsImport = false }) {
            MobileSettingsView(startsImport: $settingsStartsImport)
                .environmentObject(app)
        }
        .sheet(isPresented: $showingAdvanced) {
            AdvancedConfigurationSheet()
                .environmentObject(app)
        }
        .sheet(isPresented: $showingProblemDetail) {
            ProblemDetailSheet(detail: problemDetailText)
                .environmentObject(app)
        }
        .alert(
            app.tr("恢复默认配置？", "Restore the default configuration?"),
            isPresented: $isConfirmingReset
        ) {
            Button(app.tr("恢复默认", "Restore Defaults"), role: .destructive) {
                restoreDefaults()
            }
            Button(app.tr("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(app.hasCompanyPreset ? app.tr(
                "线路、规则和场景会回到公司默认配置，账号需要重新登录。",
                "Lines, rules and scenarios return to the company defaults. You will need to sign in again."
            ) : app.tr(
                "线路、规则和场景会被清空，回到初始状态。",
                "Lines, rules and scenarios are cleared back to the initial state."
            ))
        }
        .sensoryFeedback(.error, trigger: problem?.detail) { _, new in new != nil }
        .tint(XDialTheme.accent)
        .task {
            autoPilot.onNetworkChange = { Task { await refreshScenarioAndConnectAfterOpening(afterNetworkChange: true) } }
            autoPilot.start()
            await refreshScenarioAndConnectAfterOpening()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshScenarioAndConnectAfterOpening()
            }
        }
        .onChange(of: app.dataUseNoticeAccepted) { _, accepted in
            // 确认说明后接着做刚才没做的判断，以及本次启动的自动连接。
            if accepted { Task { await refreshScenarioAndConnectAfterOpening() } }
        }
        .onChange(of: autoScenario) { _, isOn in
            showingAutoScenarios = false
            LocationScenarios.shared.reconcile()
            app.updateScenarioAutoPolicy()
            if isOn { Task { await refreshAutoScenario() } }
        }
        .onChange(of: isIdle) { _, idle in
            // 断开以后重新看一眼，接着按当前网络选场景。
            if idle { Task { await refreshScenarioAndConnectAfterOpening() } }
        }
    }

    // MARK: - 自动选场景

    /// 首次显示、回前台和换网络共用入口。作废的查询不能消费本次启动的连接机会；
    /// 换网络后的回调会在新场景判断完成后接住它，后台启动则等回到前台。
    private func refreshScenarioAndConnectAfterOpening(afterNetworkChange: Bool = false) async {
        let generation = autoPilot.networkGeneration
        await refreshAutoScenario(afterNetworkChange: afterNetworkChange)
        await app.connectAfterOpeningIfWanted {
            scenePhase == .active && generation == autoPilot.networkGeneration
        }
    }

    /// 看一眼当前网络，换到对应的场景。没连着就直接换；已经连着就交给 VPN 扩展判断，
    /// 由它在不断开 VPN 的情况下切换（App 被挂起时它也照样判断）。
    private func refreshAutoScenario(afterNetworkChange: Bool = false) async {
        // 所有入口（首次显示、回到前台、换网络、开关、断开与点连接）都先读系统状态。
        // 冷启动时扩展可能已经在跑，不能把 App 的初始 disconnected 当成真实状态。
        await app.refreshTunnelProfileStatusAndWait()
        // 用户确认数据使用说明之前，不做需要联网的自动判断（出口地区查询）。
        guard !Task.isCancelled, app.dataUseNoticeAccepted, autoScenario, !app.profile.scenarios.isEmpty else { return }
        if app.isConnected {
            // 网络变化时扩展自己已经在判断，这里只同步它的结论。
            if afterNetworkChange, app.tunnelScenarioState != nil {
                await app.refreshTunnelScenarioState()
                return
            }
            switch await app.requestTunnelScenarioEvaluation() {
            case .handled, .unavailable:
                return
            case .unsupported:
                // 扩展是旧版本：沿用 App 判断、断开重连。
                break
            }
        } else if isWorking || app.hasActiveTunnel {
            // 隧道正在连接或自检：本机直接查出口会被隧道挡住，这时也不能改选场景。
            // 连上以后由 VPN 扩展判断（见 AppState.refreshScenarioCatalog）。
            return
        }
        // 已连接时只有 VPN 扩展查得到本地网络的出口，见 ScenarioAutoPilot.survey。
        var exitCountryViaTunnel: (@MainActor () async -> ExitCountryProbeResult)?
        if app.isConnected {
            let app = app
            exitCountryViaTunnel = { await app.directExitCountry() }
        }
        let generation = autoPilot.networkGeneration
        let pick = await autoPilot.survey(
            scenarios: app.profile.scenarios,
            regionScenarios: MobileSeed.bundled?.regionScenarios ?? [:],
            exitCountryViaTunnel: exitCountryViaTunnel
        )
        guard !Task.isCancelled, generation == autoPilot.networkGeneration,
              let pick, autoScenario else { return }
        let current = app.profile.activeScenarioID
        guard pick.scenarioID != current else {
            dismissedSuggestionID = nil
            return
        }
        if isIdle {
            app.selectScenario(pick.scenarioID)
        } else if app.isConnected, !isAutoSwitching, autoPilot.mayAutoSwitch(to: pick.scenarioID) {
            // 刚从这个场景自动换走又要换回来的话不再自动换，改成在主屏上提示，免得反复断线。
            autoPilot.noteAutoSwitch(from: current, to: pick.scenarioID)
            isAutoSwitching = true
            await app.switchScenarioAndReconnect(to: pick.scenarioID)
            isAutoSwitching = false
        }
    }

    /// 已连接、当前网络该用另一个场景、但又不适合自动换（刚刚才换过）时，给出的建议。
    private var suggestedScenario: Scenario? {
        guard autoScenario, app.isConnected, !isAutoSwitching, !app.isSwitchingScenarioInTunnel else { return nil }
        let suggestedID: String?
        if let tunnelState = app.tunnelScenarioState {
            suggestedID = tunnelState.currentPick == nil ? nil : tunnelState.suggestedScenarioID
        } else {
            suggestedID = autoPilot.pick?.scenarioID
        }
        guard let suggestedID, suggestedID != app.profile.activeScenarioID,
              suggestedID != dismissedSuggestionID else { return nil }
        return app.profile.scenarios.first { $0.id == suggestedID }
    }

    /// 已连接时以 VPN 扩展的判断为准；没连接时是 App 自己的判断。
    private var currentPick: ScenarioAutoPicker.Pick? {
        if app.isConnected, let state = app.tunnelScenarioState {
            return state.currentPick
        }
        return autoPilot.pick
    }

    /// 「已连上 Wi-Fi「Office」」「网络出口在日本」这样的一句话。
    private var autoScenarioNote: String {
        if app.isSwitchingScenarioInTunnel || (app.isConnected && app.tunnelScenarioState?.switchingTo != nil) {
            return app.tr("正在切换上网方式…", "Switching routing…")
        }
        guard let pick = currentPick else {
            if !(app.isConnected && app.tunnelScenarioState?.lastSurvey != nil),
               autoPilot.isSurveying || !autoPilot.hasSurveyed {
                return app.tr("正在判断所在网络…", "Checking the current network…")
            }
            return app.tr("未能识别当前网络，沿用所选场景", "Network unidentified. Keeping the selected scenario.")
        }
        switch pick.reason {
        case .place:
            return app.tr("位于场景登记的地点", "At the saved place for this scenario")
        case .wifi(let ssid) where ssid.isEmpty:
            return app.tr("已连上场景登记的 Wi-Fi", "On a Wi-Fi registered for this scenario")
        case .wifi(let ssid):
            return app.tr("已连上 Wi-Fi「\(ssid)」", "On Wi-Fi “\(ssid)”")
        case .country(let code):
            let locale = Locale(identifier: app.language == .zh ? "zh-Hans" : "en")
            let name = locale.localizedString(forRegionCode: code) ?? code
            return app.tr("网络出口在\(name)", "Network exits in \(name)")
        }
    }

    private func suggestionCard(_ scenario: Scenario) -> some View {
        noticeCard(
            symbol: "arrow.triangle.branch",
            tint: XDialTheme.accent,
            title: app.tr("建议切到「\(scenario.name)」", "Switch to “\(scenario.name)”?"),
            message: app.tr(
                "\(autoScenarioNote)，和现在用的上网方式不一样。",
                "\(autoScenarioNote), which doesn't match the current routing."
            ),
            identifier: "home-auto-suggestion"
        ) {
            Button(app.tr("切换", "Switch")) {
                Task { await switchWhileConnected(to: scenario.id) }
            }
            .buttonStyle(XDialPillButtonStyle())
            Button(app.tr("暂不", "Not Now")) { dismissedSuggestionID = scenario.id }
                .buttonStyle(XDialPillButtonStyle(tint: XDialTheme.inkSecondary))
        }
    }

    /// 已连接时切换场景：优先在隧道内切换，VPN 不断开；扩展是旧版本时才断开重连。
    private func switchWhileConnected(to id: String) async {
        switch await app.switchScenarioInTunnel(to: id) {
        case .switched, .failed:
            return
        case .unavailable:
            await app.switchScenarioAndReconnect(to: id)
        }
    }

    /// 点连接时，如果刚换过网络还没来得及判断，先等这一下，免得用错场景。
    private func connectAfterCheckingNetwork() {
        app.cancelPendingLaunchConnection()
        guard autoScenario, !autoPilot.isFresh else {
            app.connect()
            return
        }
        isPreparingConnection = true
        Task {
            await refreshAutoScenario()
            isPreparingConnection = false
            if app.canConnect {
                app.connect()
            } else if app.activeScenarioNeedsSignIn, let line = app.accountLine {
                presentSignIn(line.id)
            }
        }
    }

    // MARK: - 状态

    private var status: String { app.engine.status }
    private var isWorking: Bool {
        app.waitingForNetwork || ["connecting", "disconnecting", "reconnecting"].contains(status)
    }
    private var isIdle: Bool { !isWorking && !app.hasActiveTunnel }
    private var isDegraded: Bool {
        app.isConnected && (app.engine.dataPathSummary?.hasPrefix(dataPathDegradedPrefix) ?? false)
    }
    private var problem: ConnectionProblem? {
        ConnectionProblem.classify(
            app.engine.lastError.map(userFacingConnectionText),
            isChinese: app.language == .zh,
            companyPreset: app.hasCompanyPreset
        )
    }
    private var setupIssues: [String] {
        let lines = app.incompleteActiveLineSummaries
        return lines.isEmpty ? Array(app.activeConfigurationIssues.prefix(3)) : lines
    }

    private var phase: DialPhase {
        if isWorking || isPreparingConnection { return .working }
        if app.requiresUserAction || app.tailscaleSetupLineID != nil { return .attention }
        if app.isConnected { return .connected }
        return .idle
    }

    private var statusTitle: String {
        if app.tailscaleSetupLineID != nil, !app.hasFormalTunnel {
            return app.tr("正在设置 Tailscale", "Setting Up Tailscale")
        }
        switch status {
        case "connecting": return app.tr("正在连接…", "Connecting…")
        case "disconnecting": return app.tr("正在断开…", "Disconnecting…")
        case "reconnecting": return app.tr("正在重连…", "Reconnecting…")
        case "action-required": return app.tr("需要登录 Tailscale", "Tailscale Sign-in Required")
        case "connected": return app.tr("已连接", "Connected")
        default:
            if app.waitingForNetwork { return app.tr("等待网络恢复…", "Waiting for Network…") }
            if isPreparingConnection { return app.tr("正在判断网络…", "Checking the Network…") }
            if app.activeScenarioNeedsSignIn { return app.tr("还没登录", "Not Signed In") }
            return app.tr("未连接", "Not Connected")
        }
    }

    private var statusHint: String {
        if app.tailscaleSetupLineID != nil, !app.hasFormalTunnel {
            return app.tr("轻点拨盘取消", "Tap the dial to cancel")
        }
        if isWorking {
            return status == "disconnecting"
                ? ""
                : app.tr("轻点拨盘取消", "Tap the dial to cancel")
        }
        if app.hasFormalTunnel {
            return app.tr("轻点拨盘断开", "Tap the dial to disconnect")
        }
        if app.activeScenarioNeedsSignIn {
            return app.hasCompanyPreset
                ? app.tr("登录公司账号后就能连接", "Sign in with your company account to connect")
                : app.tr("登录账号后就能连接", "Sign in to connect")
        }
        if !app.isConnectionConfigured {
            return app.tr("当前场景还没设置好", "This scenario isn't ready yet")
        }
        return app.tr("轻点拨盘连接", "Tap the dial to connect")
    }

    // MARK: - 顶部与拨盘

    private var header: some View {
        HStack {
            Text("XDial")
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(XDialTheme.ink)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(XDialTheme.accent)
                    .frame(width: 36, height: 36)
                    .xdialGlass(interactive: true, in: Circle(), fallback: XDialTheme.surface)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(app.tr("设置", "Settings"))
            .accessibilityIdentifier("home-settings")
        }
        .padding(.top, 24)
    }

    private func hero(dialDiameter: CGFloat) -> some View {
        VStack(spacing: 18) {
            DialControl(
                phase: phase,
                isDimmed: isIdle && !app.canConnect && !app.activeScenarioNeedsSignIn,
                diameter: dialDiameter,
                action: dialTapped
            )
            .disabled(status == "disconnecting")
            .accessibilityLabel(dialAccessibilityLabel)
            .accessibilityIdentifier("connection-toggle")
            .padding(.top, dialDiameter < 200 ? 10 : 26)
            .padding(.bottom, dialDiameter < 200 ? 4 : 14)

            VStack(spacing: 6) {
                Text(statusTitle)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(XDialTheme.ink)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("home-status")

                if app.isConnected, let warning = LineProbeReading.warning(
                    app.engine.lineProbeReadings, isChinese: app.language == .zh
                ) {
                    Text(warning)
                        .font(.footnote)
                        .foregroundStyle(XDialTheme.warning)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("home-line-probe-warning")
                }

                // 第二行固定一行高：已连接时是计时，其它时候是一句提示。
                Group {
                    if app.hasFormalTunnel, let connectedAt = app.engine.connectedAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(formatDuration(context.date.timeIntervalSince(connectedAt)))
                                .font(.system(.body, design: .rounded).monospacedDigit())
                                .foregroundStyle(XDialTheme.inkSecondary)
                        }
                    } else {
                        Text(statusHint.isEmpty ? " " : statusHint)
                            .font(.subheadline)
                            .foregroundStyle(XDialTheme.inkTertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(minHeight: 22)
            }
            .animation(.smooth(duration: 0.3), value: statusTitle)

            // 这一格高度固定，连接前后下面的卡片不会跳。
            ZStack {
                if app.isConnected {
                    trafficRow
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else if isIdle, app.activeScenarioNeedsSignIn, let line = app.accountLine {
                    Button {
                        presentSignIn(line.id)
                    } label: {
                        Text(app.tr("登录\(displayName(line))", "Sign in to \(displayName(line))"))
                    }
                    .buttonStyle(XDialPrimaryButtonStyle())
                    .transition(.opacity)
                    .accessibilityIdentifier("home-sign-in")
                }
            }
            .frame(height: 54)
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: app.isConnected)
        .task(id: samplesTraffic) {
            await sampleTraffic()
        }
    }

    private var dialAccessibilityLabel: String {
        if app.tailscaleSetupLineID != nil, !app.hasFormalTunnel {
            return app.tr("取消 Tailscale 设置", "Cancel Tailscale Setup")
        }
        if app.hasFormalTunnel { return app.tr("断开", "Disconnect") }
        if isWorking { return app.tr("取消连接", "Cancel Connecting") }
        return app.tr("连接", "Connect")
    }

    private func dialTapped() {
        guard !isPreparingConnection else { return }
        if app.waitingForNetwork || app.hasFormalTunnel || status == "connecting" || status == "reconnecting" {
            app.disconnect()
        } else if app.tailscaleSetupLineID != nil {
            app.finishTailscaleSetup()
        } else if app.canConnect {
            connectAfterCheckingNetwork()
        } else if app.activeScenarioNeedsSignIn, let line = app.accountLine {
            presentSignIn(line.id)
        } else if problem?.kind == .needsReset {
            isConfirmingReset = true
        } else {
            showingAdvanced = true
        }
    }

    private var background: some View {
        ZStack(alignment: .top) {
            XDialTheme.canvas
            LinearGradient(
                colors: [phaseTint.opacity(0.16), phaseTint.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 460)
            .animation(.smooth(duration: 0.6), value: phase)
        }
        .ignoresSafeArea()
    }

    private var phaseTint: Color {
        switch phase {
        case .idle, .working: return XDialTheme.accent
        case .connected: return XDialTheme.success
        case .attention: return XDialTheme.warning
        }
    }

    // MARK: - 流量

    /// 只在主屏可见、App 在前台且已连接时每秒采样；退后台或断开即停。
    private var samplesTraffic: Bool {
        app.isConnected && scenePhase == .active
    }

    private func sampleTraffic() async {
        guard samplesTraffic else {
            trafficRate = .unavailable
            return
        }
        var estimator = TrafficRateEstimator()
        while !Task.isCancelled {
            let totals = await app.trafficTotals()
            guard !Task.isCancelled else { return }
            if let rate = estimator.update(totals, sampledAt: Date()) {
                trafficRate = rate
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private var trafficRow: some View {
        let download = TrafficRate.format(trafficRate.downloadBytesPerSecond)
        let upload = TrafficRate.format(trafficRate.uploadBytesPerSecond)
        return HStack(spacing: 18) {
            trafficMetric(symbol: "arrow.down", value: download)
            trafficMetric(symbol: "arrow.up", value: upload)
        }
        .padding(.horizontal, 18)
        .frame(height: 38)
        .xdialGlass(in: Capsule(), fallback: XDialTheme.surface.opacity(0.7))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(app.tr(
            "下载 \(download)，上传 \(upload)",
            "Download \(download), upload \(upload)"
        ))
        .accessibilityIdentifier("traffic-rate")
    }

    private func trafficMetric(symbol: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(XDialTheme.success)
            Text(value)
                .font(.system(.footnote, design: .rounded).monospacedDigit())
                .foregroundStyle(XDialTheme.inkSecondary)
        }
    }

    // MARK: - 提示卡

    private func noticeCard<Actions: View>(
        symbol: String,
        tint: Color,
        title: String,
        message: String,
        identifier: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(XDialTheme.ink)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(XDialTheme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 10) {
                actions()
            }
            .padding(.leading, 40)
        }
        .xdialCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func problemCard(_ problem: ConnectionProblem) -> some View {
        noticeCard(
            symbol: problem.kind == .credentials ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle.fill",
            tint: XDialTheme.danger,
            title: problem.title,
            message: problem.advice,
            identifier: "home-problem"
        ) {
            switch problem.kind {
            case .credentials:
                if let line = app.accountLine {
                    Button(app.tr("重新登录", "Sign In Again")) { presentSignIn(line.id) }
                        .buttonStyle(XDialPillButtonStyle())
                        .accessibilityIdentifier("home-problem-action")
                }
            case .server:
                if app.canConnect {
                    Button(app.tr("再试一次", "Try Again")) { app.connect() }
                        .buttonStyle(XDialPillButtonStyle())
                        .accessibilityIdentifier("home-problem-action")
                }
            case .needsReset:
                Button(app.tr("恢复默认配置", "Restore Defaults")) { isConfirmingReset = true }
                    .buttonStyle(XDialPillButtonStyle(tint: XDialTheme.danger))
                    .accessibilityIdentifier("home-problem-action")
            case .network, .other:
                if app.canConnect {
                    Button(app.tr("再试一次", "Try Again")) { app.connect() }
                        .buttonStyle(XDialPillButtonStyle())
                        .accessibilityIdentifier("home-problem-action")
                }
            }
            Button(app.tr("详情", "Details")) { showingProblemDetail = true }
                .buttonStyle(XDialPillButtonStyle(tint: XDialTheme.inkSecondary))
            if problem.kind != .needsReset {
                Button(app.tr("知道了", "Dismiss")) { app.engine.lastError = nil }
                    .buttonStyle(XDialPillButtonStyle(tint: XDialTheme.inkSecondary))
            }
        }
    }

    private var setupCard: some View {
        noticeCard(
            symbol: "wrench.and.screwdriver.fill",
            tint: XDialTheme.warning,
            title: app.tr("当前场景还差一步", "This scenario needs one more step"),
            message: setupIssues.joined(separator: app.tr("；", "; ")),
            identifier: "home-setup"
        ) {
            Button(app.tr("去设置", "Open Setup")) { showingAdvanced = true }
                .buttonStyle(XDialPillButtonStyle())
                .accessibilityIdentifier("home-setup-action")
        }
    }

    private var routeCheckNote: some View {
        let rechecking = app.engine.dataPathRechecking
        return HStack(spacing: 12) {
            Text(rechecking
                ? app.tr("正在复查线路", "Rechecking route")
                : app.tr("线路自检未通过", "Route check failed"))
            if !rechecking {
                Button(app.tr("重试", "Retry")) { app.recheckConnection() }
                    .accessibilityIdentifier("home-degraded-recheck")
            }
            Button(app.tr("详情", "Details")) { showingProblemDetail = true }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("home-degraded-note")
    }

    private var problemDetailText: String {
        if let detail = problem?.detail { return detail }
        return app.engine.dataPathSummary ?? ""
    }

    // MARK: - 场景

    private var scenarioSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                XDialSectionLabel(text: app.tr("上网方式", "Routing"))
                Spacer()
                if !app.profile.scenarios.isEmpty {
                    Toggle(isOn: $autoScenario) {
                        Text(app.tr("自动", "Auto"))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(XDialTheme.inkSecondary)
                    }
                    .toggleStyle(.switch)
                    .fixedSize()
                    .scaleEffect(0.82, anchor: .trailing)
                    .accessibilityIdentifier("home-auto-scenario")
                }
            }
            if autoScenario, !app.profile.scenarios.isEmpty {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        showingAutoScenarios.toggle()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(app.tr("当前选择", "Current selection"))
                            .font(.caption)
                            .foregroundStyle(XDialTheme.inkSecondary)
                        Text(app.activeScenario?.name ?? app.tr("未选择场景", "No scenario selected"))
                            .font(.headline)
                            .foregroundStyle(XDialTheme.ink)
                        Label(autoScenarioNote, systemImage: "location.fill")
                            .font(.footnote)
                            .foregroundStyle(XDialTheme.inkSecondary)
                            .contentTransition(.opacity)
                            .accessibilityIdentifier("home-auto-note")
                        HStack {
                            Text(showingAutoScenarios
                                 ? app.tr("收起场景", "Hide scenarios")
                                 : app.tr("展开场景 · 手动调整", "Show scenarios · Adjust manually"))
                            Spacer()
                            Image(systemName: showingAutoScenarios ? "chevron.up" : "chevron.down")
                        }
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(XDialTheme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(XDialTheme.surface, in: RoundedRectangle(cornerRadius: XDialTheme.cardRadius))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("home-scenario-disclosure")
                .accessibilityValue(showingAutoScenarios
                                    ? app.tr("已展开", "Expanded")
                                    : app.tr("已收起", "Collapsed"))
            }

            if app.profile.scenarios.isEmpty {
                noticeCard(
                    symbol: "square.stack.3d.up.slash",
                    tint: XDialTheme.inkSecondary,
                    title: app.tr("还没有场景", "No scenarios yet"),
                    message: app.hasCompanyPreset ? app.tr(
                        "场景决定哪些网站走公司 VPN。恢复默认配置就能直接用。",
                        "A scenario decides which sites use the company VPN. Restore the defaults to get started."
                    ) : app.tr(
                        "场景决定哪些网站走哪条线路。导入你的配置文件，或者在「线路与规则」里添加服务器和场景。",
                        "A scenario decides which line each site uses. Import your configuration file, or add your servers and scenarios in Lines & Rules."
                    ),
                    identifier: "home-no-scenarios"
                ) {
                    if app.hasCompanyPreset {
                        Button(app.tr("恢复默认配置", "Restore Defaults")) { isConfirmingReset = true }
                            .buttonStyle(XDialPillButtonStyle())
                    } else {
                        HStack(spacing: 10) {
                            Button(app.tr("导入配置", "Import")) {
                                settingsStartsImport = true
                                showingSettings = true
                            }
                            .buttonStyle(XDialPillButtonStyle())
                            .accessibilityIdentifier("home-import-configuration")
                            Button(app.tr("添加线路", "Add a Line")) { showingAdvanced = true }
                                .buttonStyle(XDialPillButtonStyle())
                                .accessibilityIdentifier("home-add-line")
                        }
                    }
                }
            } else if !autoScenario || showingAutoScenarios {
                VStack(spacing: 10) {
                    ForEach(app.profile.scenarios) { scenario in
                        scenarioCard(scenario)
                    }
                }
            }
        }
    }

    private func scenarioCard(_ scenario: Scenario) -> some View {
        HomeScenarioCard(
            id: scenario.id, name: scenario.name,
            summary: ScenarioDescriber.summary(for: scenario, in: app.profile, isChinese: app.language == .zh),
            symbol: ScenarioDescriber.symbol(for: scenario, in: app.profile),
            isActive: scenario.id == app.profile.activeScenarioID,
            requiresConfirmation: !isIdle, tr: app.tr,
            onManualSelection: {
                autoScenario = false
                app.updateScenarioAutoPolicy()
            }
        ) {
            if isIdle { app.selectScenario(scenario.id) }
            else { Task { await switchWhileConnected(to: scenario.id) } }
        }
        .disabled(status == "disconnecting")
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        if let line = app.accountLine {
            let username = line.vpnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            VStack(alignment: .leading, spacing: 10) {
                XDialSectionLabel(text: app.tr("账号", "Account"))
                Button {
                    presentSignIn(line.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: app.accountIsIncomplete ? "person.crop.circle.badge.plus" : "person.crop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(XDialTheme.accent)
                            .frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName(line))
                                .font(.headline)
                                .foregroundStyle(XDialTheme.ink)
                            Text(app.accountIsIncomplete
                                 ? app.tr("未登录", "Not signed in")
                                 : username)
                                .font(.subheadline)
                                .foregroundStyle(XDialTheme.inkSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(XDialTheme.inkTertiary)
                    }
                    .xdialCard(padding: 16)
                    .contentShape(RoundedRectangle(cornerRadius: XDialTheme.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("home-account")
            }
        }
    }

    private func displayName(_ line: Line) -> String {
        let name = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty
            ? (app.hasCompanyPreset ? app.tr("公司 VPN", "Company VPN") : app.tr("VPN 账号", "VPN Account"))
            : name
    }

    private func presentSignIn(_ lineID: String) {
        connectAfterSignIn = false
        signInLineID = SignInTarget(id: lineID)
    }

    /// 登录弹层收起后再发起连接，让拨盘的转动动画完整可见。
    private func connectIfRequested() {
        guard connectAfterSignIn else { return }
        connectAfterSignIn = false
        if app.canConnect { app.connect() }
    }

    private func restoreDefaults() {
        guard !app.hasActiveTunnel, !app.isBusy else { return }
        let previous = app.profile
        app.engine.lastError = nil
        if !app.replaceProfileAndSave(app.defaultProfile) {
            app.profile = previous
        }
    }

    // MARK: - Tailscale 授权

    private var tailscaleSignInCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(
                app.tr("需要登录 Tailscale", "Tailscale Sign-in Required"),
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            .font(.headline)
            .foregroundStyle(XDialTheme.warning)

            Text(app.tr(
                "这是 XDial 内置线路的独立授权，和手机上的 Tailscale App 不共用。授权一次后会自动继续连接。",
                "This authorizes XDial's built-in route separately from the Tailscale app. After a one-time sign-in, XDial continues connecting."
            ))
            .font(.subheadline)
            .foregroundStyle(XDialTheme.inkSecondary)

            ForEach(app.tailscaleAuthRequests) { request in
                Button {
                    startTailscaleLogin(request)
                } label: {
                    if tailscaleLoginLineID == request.lineID {
                        HStack {
                            ProgressView()
                            Text(app.tr("正在准备登录…", "Preparing sign-in…"))
                        }
                    } else {
                        Label(
                            app.tailscaleAuthRequests.count == 1
                                ? app.tr("登录 Tailscale", "Sign In to Tailscale")
                                : app.tr("登录 \(request.lineName)", "Sign In to \(request.lineName)"),
                            systemImage: "safari"
                        )
                    }
                }
                .buttonStyle(XDialPrimaryButtonStyle(tint: XDialTheme.warning))
                .disabled(tailscaleLoginLineID != nil)
            }

            if let tailscaleLoginError {
                Label(tailscaleLoginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(XDialTheme.danger)
            }
        }
        .xdialCard()
    }

    private func startTailscaleLogin(_ request: TailscaleAuthRequest) {
        guard tailscaleLoginLineID == nil else { return }
        tailscaleLoginLineID = request.lineID
        tailscaleLoginError = nil
        app.beginTailscaleLogin(lineID: request.lineID) { result in
            Task { @MainActor in
                tailscaleLoginLineID = nil
                switch result {
                case .success(let status):
                    let backendState = status.backendState.lowercased()
                    guard app.applyTailscaleRuntimeStatus(
                        lineID: request.lineID,
                        status: status
                    ) else {
                        tailscaleLoginError = app.tr(
                            "Tailscale 登录状态无法保存。",
                            "The Tailscale sign-in state could not be saved."
                        )
                        return
                    }
                    if backendState == "running" {
                        return
                    }
                    guard let url = AppState.validTailscaleAuthURL(status.authURL) else {
                        tailscaleLoginError = app.tr(
                            "没有取得有效的登录入口，请重试。",
                            "No valid sign-in link was returned. Please retry."
                        )
                        return
                    }
                    openURL(url)
                case .failure(let error):
                    tailscaleLoginError = userFacingConnectionText(error.localizedDescription)
                }
            }
        }
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// 报错或自检结果的原文，可复制、可分享给管理员。
private struct ProblemDetailSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    let detail: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(XDialTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(XDialTheme.canvas.ignoresSafeArea())
            .navigationTitle(app.tr("详情", "Details"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: detail) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(app.tr("完成", "Done")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(XDialTheme.accent)
    }
}

/// 从主屏直接打开的高级配置。
struct AdvancedConfigurationSheet: View {
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ConfigurationView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(app.tr("完成", "Done")) { dismiss() }
                    }
                }
        }
        .tint(XDialTheme.accent)
    }
}

struct PendingRuntimeChangesBanner: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title3)
                    .foregroundStyle(XDialTheme.warning)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.tr("改动要重新连接后才生效", "Reconnect to apply your changes"))
                        .font(.headline)
                        .foregroundStyle(XDialTheme.ink)
                    Text(app.tr(
                        "当前连接还在用改动前的配置。",
                        "The current connection still uses the previous configuration."
                    ))
                    .font(.subheadline)
                    .foregroundStyle(XDialTheme.inkSecondary)
                }
            }
            Button(app.tr("重新连接", "Reconnect")) {
                app.reconnectToApplyChanges()
            }
            .buttonStyle(XDialPillButtonStyle())
            .disabled(!app.isConnected || app.isBusy)
            .padding(.leading, 40)
        }
        .xdialCard()
    }
}

func lineSymbol(_ type: String) -> String {
    switch type {
    case "direct": return "arrow.right"
    case "vpn": return "building.2"
    case "tailscale": return "point.3.connected.trianglepath.dotted"
    default: return "network"
    }
}
