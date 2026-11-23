import AppKit
import SwiftUI

private struct PolicyMapping: Identifiable {
    let id: String
    let ruleName: String
    let lineName: String
    let lineID: String
    let error: ConnectionReportError?
}

private struct FailurePresentation {
    let title: String
    let detail: String?
    var collapsesDetail = false
}

struct MainPopover: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var updater: AppUpdateChecker
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var networkInfo = NetworkInfo.shared
    @ObservedObject var trafficInfo: TrafficInfo
    @State private var showsScenarios = false
    @State private var contentHeight: CGFloat = 260
    @State private var showsConnectionDetails = false
    @State private var showsPolicyMappings = false

    private let actionColor = XDialPalette.primaryAction
    private let progressColor = XDialPalette.progress
    private let successColor = XDialPalette.success
    private let dangerColor = XDialPalette.danger
    private let warningColor = XDialPalette.warning
    private let proxyOnlyColor = XDialPalette.proxyOnly

    private var content: some View {
        VStack(spacing: 0) {
            header
            homeControls
            if let port = proxyOnlyPort {
                Divider()
                proxyOnlyBand(port: port)
            }
            if needsSSIDAccess {
                Divider()
                ssidAccessWarningBand
            }
            if let blocker = state.connectionConfigurationBlocker {
                Divider()
                connectionBlockerBand(blocker)
            }
            if state.showsParkedRecoveryNotice {
                Divider()
                parkedRecoveryBand
            }
            if let failure = scenarioSwitchFailureProjection {
                Divider()
                scenarioSwitchFailureBand(failure)
            } else if showsStatusBand {
                Divider()
                statusBand
                if showsConnectionDetails,
                   let report = connectionProgressReport,
                   !report.tasks.isEmpty {
                    Divider()
                        .padding(.horizontal, 20)
                    connectionProgressDetails(report)
                }
            }
            if let report = expandableReport {
                Divider()
                details(report)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var scrollLimit: CGFloat {
        (NSScreen.main?.visibleFrame.height ?? 800) - 48
    }

    var body: some View {
        ScrollView {
            content
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 360, height: min(contentHeight, scrollLimit))
        .animation(
            .easeInOut(duration: 0.2),
            value: state.browsingRecord.profile.scenarios.count
        )
        .background(XDialPalette.canvas)
        .contextMenu { applicationMenuItems }
    }

    @ViewBuilder
    private var applicationMenuItems: some View {
        Section {
            if let candidate = updater.releaseCandidate {
                Button(
                    candidate.channel == .beta
                        ? state.tr(
                            "beta 版本 \(candidate.tag)…",
                            "Beta Version \(candidate.tag)…"
                        )
                        : state.tr(
                            "新版本 \(candidate.tag)…",
                            "New Version \(candidate.tag)…"
                        )
                ) {
                    presentUpdateWindow()
                }
            } else if XDialBuildIdentity.allowsAutomaticUpdates {
                Button(state.tr("检查更新…", "Check for Updates…")) {
                    presentUpdateWindow()
                    Task { await updater.checkNow() }
                }
            }
            #if !XDIAL_STORE
            Button(state.tr("安装状态…", "Installation Status…")) {
                state.installation.present()
            }
            #endif
        }
        Button(state.tr("退出 \(XDialBuildIdentity.productTitle)", "Quit \(XDialBuildIdentity.productTitle)")) {
            MenuBarRecoveryController.shared.requestQuit()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(XDialBuildIdentity.productTitle)
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                if state.isConnected,
                   let connectedAt = state.engine.connectedAt {
                    Circle()
                        .fill(headerAccent.opacity(0.72))
                        .frame(width: 3.5, height: 3.5)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(
                            formatDuration(
                                Int(
                                    context.date.timeIntervalSince(
                                        connectedAt
                                    )
                                )
                            )
                        )
                        .font(
                            .system(
                                size: 12,
                                weight: .medium,
                                design: .rounded
                            )
                        )
                        .monospacedDigit()
                        .foregroundStyle(headerAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            headerAccent.opacity(0.12),
                            in: Capsule()
                        )
                    }
                    if isProxyOnly {
                        Button {
                            state.editorPosition.showGeneral(.startup)
                            openSettingsWindow()
                        } label: {
                            Text(state.tr("仅 SOCKS5", "SOCKS5 only"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(proxyOnlyColor)
                                .padding(.horizontal, 7)
                                .frame(height: 20)
                                .background(proxyOnlyColor.opacity(0.12), in: Capsule())
                                .overlay {
                                    Capsule().stroke(proxyOnlyColor.opacity(0.32), lineWidth: 0.75)
                                }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help(state.tr("打开连接方式设置", "Open connection mode settings"))
                        .accessibilityLabel(state.tr(
                            "仅 SOCKS5，系统流量未经过 XDial",
                            "SOCKS5 only; system traffic does not pass through XDial"
                        ))
                        .accessibilityHint(state.tr(
                            "打开通用设置中的连接方式",
                            "Opens the connection mode in General settings"
                        ))
                    }
                }
            }
            if let candidate = updater.releaseCandidate {
                Button {
                    presentUpdateWindow()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(XDialPalette.danger)
                            .frame(width: 5, height: 5)
                        // A beta shows its X.Y.Z with the window's Beta mark
                        // carrying beta.N, about as wide as the bare tag.
                        if candidate.channel == .beta,
                           let tag = candidate.releaseTag,
                           let beta = tag.beta {
                            Text(verbatim: "v\(tag.version)")
                                .font(.system(size: 10.5, weight: .semibold))
                            AppUpdateBetaBadge(text: "beta.\(beta)")
                        } else {
                            Text(candidate.tag)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                    }
                    .foregroundStyle(XDialPalette.warning)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        XDialPalette.warning.opacity(0.09),
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().stroke(
                            XDialPalette.warning.opacity(0.28),
                            lineWidth: 0.75
                        )
                    }
                }
                .buttonStyle(.plain)
                .help(state.tr("打开 XDial 更新", "Open XDial Update"))
                .accessibilityLabel(
                    candidate.channel == .beta
                        ? state.tr(
                            "beta 版本 \(candidate.tag) 可用",
                            "Beta version \(candidate.tag) available"
                        )
                        : state.tr(
                            "新版本 \(candidate.tag) 可用",
                            "New version \(candidate.tag) available"
                        )
                )
            }
            Spacer()
            Button(action: openSettingsWindow) {
                headerIcon("gearshape.fill", tint: XDialPalette.accent)
            }
            .buttonStyle(.plain)
            .help(state.tr("设置", "Settings"))
            .accessibilityLabel(state.tr("设置", "Settings"))

            Menu {
                applicationMenuItems
            } label: {
                headerIcon("ellipsis", tint: .secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(state.tr("更多操作", "More Actions"))
            .accessibilityLabel(state.tr("更多操作", "More Actions"))
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 54)
    }

    private func headerIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13.5, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .frame(width: 30, height: 30)
            .xdialGlass(interactive: true, in: Circle(), fallback: XDialPalette.surface)
            .contentShape(Circle())
    }

    /// 仅 SOCKS5 的连接不接管系统：所有“已连接”的颜色改用暮紫，并常驻提示。
    private var isProxyOnly: Bool {
        proxyOnlyPort != nil
    }

    private var proxyOnlyPort: UInt16? {
        guard state.isConnected,
              let ingress = state.committedIngress,
              ingress.mode == .localSOCKS else { return nil }
        return ingress.localSOCKSPort
    }

    private var connectedColor: Color {
        isProxyOnly ? proxyOnlyColor : successColor
    }

    private func proxyOnlyBand(port: UInt16) -> some View {
        let address = "127.0.0.1:\(port)"
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "powerplug.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(proxyOnlyColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.tr(
                    "系统流量没有经过 XDial",
                    "System traffic is not going through XDial"
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                Text(state.tr(
                    "只有把 SOCKS5 代理设为 \(address) 的程序按场景分流。",
                    "Only apps using the SOCKS5 proxy \(address) follow the Scenario."
                ))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(proxyOnlyColor)
                    .frame(width: 26, height: 26)
                    .background(proxyOnlyColor.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help(state.tr("复制 \(address)", "Copy \(address)"))
            .accessibilityLabel(state.tr("复制代理地址", "Copy proxy address"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    proxyOnlyColor.opacity(0.11),
                    proxyOnlyColor.opacity(0.035),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private var headerAccent: Color {
        if state.isConnected {
            return connectedColor
        }
        if state.isBusy {
            return progressColor
        }
        if let report = state.presentedConnectionReport,
           report.error != nil || report.state == .failed {
            return dangerColor
        }
        return Color.secondary.opacity(0.82)
    }

    private func openSettingsWindow() {
        ApplicationWindowLifecycleController.shared
            .prepareToPresentSettingsWindow()
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentUpdateWindow() {
        ApplicationWindowLifecycleController.shared
            .prepareToPresentUpdateWindow()
        openWindow(id: "update")
        NSApp.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var homeControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(dialTitle)
                        .font(.system(.title, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(dialHint)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                DialControl(phase: dialPhase, attentionTint: dangerColor, connectedTint: connectedColor, diameter: 112) {
                    if state.scenarioSwitchTargetID != nil && state.isConnected {
                        state.cancelPendingScenarioSwitch()
                    } else if state.isConnected || state.isBusy {
                        state.disconnect()
                    } else if let selected = state.activeScenario {
                        if let lineID = ConnectionConfigurationBlocker.evaluate(selected, in: state.profile)?.lineID {
                            openAccount(lineID, connect: selected.id)
                        } else {
                            state.connectScenario(selected.id)
                        }
                    }
                }
                .disabled(state.engine.status == "disconnecting" || (state.surveyingRegion && !state.isConnected && !state.isBusy) ||
                          (state.activeScenario == nil && !state.isBusy && !state.isConnected))
                .accessibilityLabel(dialActionTitle)
                .accessibilityValue(dialTitle)
                .help(dialActionTitle)
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 16)
            .environment(\.colorScheme, .dark)
            .background { DialInstrumentSurface() }
            .clipShape(RoundedRectangle(cornerRadius: 22))

            if !state.dataUseNoticeAccepted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    Text(state.tr("连接前请阅读并确认数据使用说明。", "Review and confirm the data use notice before connecting."))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                Button(state.tr("阅读数据使用说明…", "Read the Data Use Notice…")) { state.presentDataUseNotice() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("home-data-use-notice")
            }
            if state.profile.scenarios.isEmpty {
                Button(state.tr("前往配置添加场景", "Open configuration to add a scenario")) {
                    state.editorPosition.tab = 2
                    openSettingsWindow()
                }
            } else {
                HStack {
                    Text(state.tr("上网方式", "Routing")).font(.headline)
                    Spacer()
                    Toggle(state.tr("自动", "Automatic"), isOn: $state.automaticScenario)
                        .toggleStyle(.switch).controlSize(.small)
                }
                if state.automaticScenario {
                    Button {
                        showsScenarios.toggle()
                    } label: {
                        HomeRouteLabel(
                            name: state.activeScenario?.name ?? state.tr("未选择场景", "No scenario selected"),
                            reason: selectionReason,
                            symbol: state.activeScenario.map { ScenarioDescriber.symbol(for: $0, in: state.profile) } ?? "network",
                            expanded: showsScenarios
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(state.tr("当前选择，\(state.activeScenario?.name ?? "")", "Current selection, \(state.activeScenario?.name ?? "")"))
                    .accessibilityValue(selectionReason)
                    .accessibilityHint(state.tr("展开或收起场景", "Show or hide scenarios"))
                }
                if !state.automaticScenario || showsScenarios {
                    VStack(spacing: 6) {
                        ForEach(state.profile.scenarios) { scenario in
                            HomeScenarioCard(
                                id: scenario.id, name: scenario.name,
                                summary: ScenarioDescriber.summary(for: scenario, in: state.profile, isChinese: state.language == .zh),
                                symbol: ScenarioDescriber.symbol(for: scenario, in: state.profile),
                                isActive: scenario.id == state.profile.activeScenarioID,
                                requiresConfirmation: state.isConnected || state.isBusy,
                                compact: true, tr: state.tr
                            ) {
                                state.automaticScenario = false
                                state.selectHomeScenario(scenario.id)
                            }
                            .disabled(state.engine.status == "disconnecting")
                        }
                    }
                    .padding(.top, 6)
                }
            }
            if let line = homeAccountLine {
                Text(state.tr("账号", "Account")).font(.headline)
                Button {
                    openAccount(line.id)
                } label: {
                    HomeAccountLabel(name: line.name, detail: line.vpnUsername.isEmpty
                                     ? state.tr("登录账号", "Sign in") : line.vpnUsername)
                }
                .buttonStyle(.plain)
            }
        }
        .onChange(of: state.automaticScenario) { showsScenarios = false }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private var dialTitle: String {
        if state.surveyingRegion && !state.isBusy && !state.isConnected {
            return state.tr("正在选择场景…", "Choosing a scenario…")
        }
        if state.isBusy { return dialActivityTitle }
        if AnyConnectLoginFailure(message: state.statusText) != nil {
            return state.tr("VPN 连接失败", "VPN connection failed")
        }
        return state.statusText
    }

    private var dialHint: String {
        if state.engine.status == "disconnecting" { return state.tr("正在结束连接", "Finishing the connection") }
        if state.isBusy || state.scenarioSwitchTargetID != nil { return state.tr("点按拨盘取消", "Click the dial to cancel") }
        if state.isConnected { return state.tr("点按拨盘断开", "Click the dial to disconnect") }
        if state.surveyingRegion { return state.tr("正在检查网络出口", "Checking the network exit") }
        if state.activeScenario == nil { return state.tr("请先添加场景", "Add a scenario to connect") }
        if AnyConnectLoginFailure(message: state.statusText) != nil {
            return state.tr("点拨盘重新登录", "Click the dial to sign in again")
        }
        return state.tr("点按拨盘连接", "Click the dial to connect")
    }

    private var selectionReason: String {
        if let ssid = state.currentSSID, state.profile.scenario(matchingSSID: ssid) != nil {
            return state.tr("已连上 Wi-Fi「\(ssid)」", "Connected to Wi-Fi “\(ssid)”")
        }
        if let code = state.exitCountry, let target = state.regionScenarioTargets[code] ?? state.regionScenarioTargets["*"],
           state.profile.scenarios.contains(where: { $0.id == target }) {
            let locale = Locale(identifier: state.language == .zh ? "zh-Hans" : "en")
            let region = locale.localizedString(forRegionCode: code) ?? code
            return state.tr("网络出口在\(region)", "Network exits in \(region)")
        }
        return state.surveyingRegion ? state.tr("正在判断所在网络…", "Checking the network…")
            : state.tr("没判断出来，保持当前选择", "Network unrecognized. Keeping current selection.")
    }

    private var homeAccountLine: Line? {
        let lines = state.profile.lines.filter { $0.type == "vpn" && $0.enabled }
        let scenario = state.activeScenario
        let used = Set((scenario?.bindings.map(\.lineID) ?? []) + [scenario?.defaultLineID ?? ""])
        let leaves = Set(state.profile.leafLines(for: state.profile.lines.filter { used.contains($0.id) }).map(\.id))
        return lines.first { leaves.contains($0.id) } ?? lines.first
    }

    private func openAccount(_ id: String, connect: String? = nil) {
        openWindow(id: "account", value: HomeAccountRequest(lineID: id, connectScenarioID: connect))
        NSApp.activate(ignoringOtherApps: true)
    }

    private var dialActivityTitle: String {
        if state.scenarioSwitchTargetID != nil { return state.tr("切换中", "Switching") }
        switch state.engine.status {
        case "disconnecting": return state.tr("正在断开", "Disconnecting")
        case "reconnecting": return state.tr("正在重连", "Reconnecting")
        default: return state.tr("正在连接", "Connecting")
        }
    }

    private var dialPhase: DialPhase {
        if state.isBusy { return .working }
        if state.isConnected { return .connected }
        if state.presentedConnectionReport?.state == .failed || state.presentedConnectionReport?.error != nil || state.engine.lastError != nil { return .attention }
        return .idle
    }

    private var dialActionTitle: String {
        if state.scenarioSwitchTargetID != nil && state.isConnected { return state.tr("取消切换", "Cancel switch") }
        if state.engine.status == "disconnecting" { return state.statusText }
        if state.isBusy { return state.tr("取消连接", "Cancel connection") }
        if state.isConnected { return state.tr("断开", "Disconnect") }
        if dialPhase == .attention { return state.tr("重试", "Retry") }
        return state.tr("连接", "Connect")
    }

    private var statusBand: some View {
        HStack(spacing: 8) {
            if state.isBusy {
                Circle()
                    .fill(progressColor)
                    .frame(width: 8, height: 8)
                Text(state.statusText)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                if let report = connectionProgressReport,
                   !report.tasks.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsConnectionDetails.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(
                                state.tr(
                                    state.scenarioSwitchTargetID == nil
                                        ? "连接进度"
                                        : "切换进度",
                                    state.scenarioSwitchTargetID == nil
                                        ? "Connection progress"
                                        : "Switch progress"
                                )
                            )
                            Text(
                                "\(completedTaskCount(in: report))/"
                                    + "\(report.tasks.count)"
                            )
                            .monospacedDigit()
                            Image(
                                systemName: connectionDetailsSymbol
                            )
                            .font(.system(size: 8, weight: .semibold))
                        }
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(
                        connectionDetailsActionLabel
                    )
                    .accessibilityLabel(connectionDetailsActionLabel)
                }
            } else if state.configDirty && state.isConnected {
                if state.canConnect {
                    Button { state.reconnect() } label: {
                        dirtyStatusRow(showsAction: true)
                    }
                    .buttonStyle(.plain)
                    .help(
                        state.tr(
                            "应用已保存配置并重连",
                            "Apply saved changes and reconnect"
                        )
                    )
                    .accessibilityLabel(
                        state.tr(
                            "修改已保存，当前连接尚未应用",
                            "Saved changes are not applied"
                        )
                    )
                    .accessibilityHint(
                        state.tr(
                            "按下以应用配置并重连",
                            "Press to apply the configuration and reconnect"
                        )
                    )
                } else {
                    dirtyStatusRow(showsAction: false)
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            if state.configDirty && state.isConnected && !state.isBusy {
                LinearGradient(
                    colors: [
                        warningColor.opacity(0.075),
                        warningColor.opacity(0.025),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
        }
    }

    private func connectionBlockerBand(
        _ blocker: ConnectionConfigurationBlocker
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warningColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(blocker.title(state.tr))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                Text(blocker.detail(state.tr))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(blocker.actionTitle(state.tr)) {
                if let id = blocker.lineID { openAccount(id, connect: blocker.scenarioID) }
                else { state.revealConnectionBlocker(blocker); openSettingsWindow() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    warningColor.opacity(0.075),
                    warningColor.opacity(0.025),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    /// Automatic reconnect used up its budget on a network-related failure.
    /// The failure itself stays in the details below; this band only states
    /// that recovery is waiting for a network change and offers a retry with
    /// a fresh budget.
    private var parkedRecoveryBand: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "pause.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warningColor)
                .padding(.top, 1)
            Text(state.tr(
                "自动重连已暂停，网络变化时会再试",
                "Automatic reconnect paused; it will retry when the network changes"
            ))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary.opacity(0.82))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            Button(state.tr("立即重试", "Retry Now")) {
                state.retryAutomaticReconnectNow()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    warningColor.opacity(0.075),
                    warningColor.opacity(0.025),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
        .accessibilityElement(children: .contain)
    }

    private var ssidAccessWarningBand: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "location.slash.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warningColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.tr(
                    "Wi-Fi 自动切换不可用",
                    "Automatic Wi-Fi Switching Unavailable"
                ))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                Text(state.tr(
                    "允许读取 Wi-Fi 名称后，就能按 Wi-Fi 选择场景。",
                    "Allow access to Wi-Fi names to match scenarios by Wi-Fi."
                ))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(ssidAccessActionTitle) {
                state.requestSSIDAccess()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    warningColor.opacity(0.075),
                    warningColor.opacity(0.025),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func dirtyStatusRow(showsAction: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(warningColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    state.tr(
                        "修改已保存，当前连接尚未应用",
                        "Saved changes are not applied"
                    )
                )
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
                if !showsAction {
                    Text(dirtyConfigurationBlocker)
                        .font(.system(size: 9.5))
                        .foregroundStyle(warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if showsAction {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(actionColor)
                    .frame(width: 28, height: 28)
                    .background(actionColor.opacity(0.09), in: Circle())
            }
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private func scenarioSwitchFailureBand(
        _ projection: HostScenarioSwitchProjection
    ) -> some View {
        let sourceName = state.presentedConnectionReport?.scenario.name
            ?? scenarioName(for: projection.fromScenarioID)
        let targetName = projection.candidateReport.scenario.name.isEmpty
            ? scenarioName(for: projection.toScenarioID)
            : projection.candidateReport.scenario.name
        let title = projection.fromScenarioID == projection.toScenarioID
            ? state.tr("刷新“\(sourceName)”失败，原连接仍在使用", "Couldn’t refresh “\(sourceName)”. The existing connection is still active.")
            : state.tr("切换到“\(targetName)”失败，仍在使用“\(sourceName)”", "Couldn’t switch to “\(targetName)”; still using “\(sourceName)”")
        let detail = scenarioSwitchFailureDetail(projection)
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(dangerColor)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.88))
                .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                state.dismissScenarioSwitchFailure(
                    candidateTransactionID:
                        projection.candidateTransactionID
                )
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(state.tr("关闭切换错误", "Dismiss switch error"))
            .accessibilityLabel(
                state.tr("关闭切换错误", "Dismiss switch error")
            )
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                colors: [
                    dangerColor.opacity(0.075),
                    dangerColor.opacity(0.025),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    private func scenarioSwitchFailureDetail(
        _ projection: HostScenarioSwitchProjection
    ) -> String {
        if let message = projection.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        if let message = projection.candidateReport.error?.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }
        return state.tr("场景切换失败", "Scenario switch failed")
    }

    private func scenarioName(for id: String) -> String {
        state.profile.scenarios.first(where: { $0.id == id })?.name ?? id
    }

    private var dirtyConfigurationBlocker: String {
        if !state.installation.isReady {
            return state.tr("请先完成安装", "Complete setup first")
        }
        if state.activeScenario == nil {
            return state.tr("请先选择场景", "Choose a scenario first")
        }
        return state.tr(
            "请先完善当前场景",
            "Complete the current scenario first"
        )
    }

    private func connectionProgressDetails(
        _ report: ConnectionReport
    ) -> some View {
        FlowLayout(horizontalSpacing: 7, verticalSpacing: 7) {
            ForEach(report.tasks) { task in
                let color = progressStepColor(task.state)
                HStack(spacing: 5) {
                    Image(systemName: progressStepSymbol(task.state))
                        .font(.system(size: 8, weight: .semibold))
                    Text(task.name)
                        .fontWeight(.medium)
                    Text(progressStepStateText(task.state))
                        .foregroundStyle(color.opacity(0.84))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .frame(height: 25)
                .background(color.opacity(0.085), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(color.opacity(0.18), lineWidth: 0.5)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsStatusBand: Bool {
        state.isBusy || (state.configDirty && state.isConnected)
    }

    private var needsSSIDAccess: Bool {
        state.requiresSSIDAccess && state.wifiSSIDAccessState != .ready
            && state.wifiSSIDAccessState != .checking
    }

    private var ssidAccessActionTitle: String {
        switch state.wifiSSIDAccessState {
        case .checking:
            return state.tr("检查中", "Checking")
        case .permissionRequired:
            return state.tr(
                "开启位置权限",
                "Enable Location Access"
            )
        case .denied:
            return state.tr(
                "打开定位服务设置",
                "Open Location Settings"
            )
        case .unavailable:
            return state.tr("重试", "Retry")
        case .ready:
            return state.tr("完成", "Done")
        }
    }

    private var scenarioSwitchFailureProjection:
        HostScenarioSwitchProjection? {
        state.presentedScenarioSwitchFailureProjection
    }

    private var connectionDetailsSymbol: String {
        showsConnectionDetails ? "chevron.down" : "chevron.right"
    }

    private var connectionDetailsActionLabel: String {
        showsConnectionDetails
            ? state.tr("收起详情", "Collapse details")
            : state.tr("展开详情", "Expand details")
    }

    @ViewBuilder
    private func details(_ report: ConnectionReport) -> some View {
        if state.isConnected && report.state == .committed {
            connectedDetails(report)
        } else {
            failedDetails(report)
        }
    }

    private func connectedDetails(_ report: ConnectionReport) -> some View {
        let hasConnectionInfo = !lineTasks(in: report).isEmpty
            || !policyMappings(in: report).isEmpty
        return VStack(spacing: 0) {
            ZStack {
                HStack(spacing: 0) {
                    metric(
                        symbol: "arrow.down",
                        value: TrafficInfo.formatRate(
                            trafficInfo.downloadBytesPerSecond
                        )
                    )
                    Divider()
                        .frame(height: 14)
                        .padding(.horizontal, 7)
                    metric(
                        symbol: "arrow.up",
                        value: TrafficInfo.formatRate(
                            trafficInfo.uploadBytesPerSecond
                        )
                    )
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(
                    Color.primary.opacity(0.032),
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(
                            Color.primary.opacity(0.055),
                            lineWidth: 0.5
                        )
                }

                HStack {
                    Spacer(minLength: 0)
                    if hasConnectionInfo {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                showsConnectionDetails.toggle()
                            }
                        } label: {
                            Image(
                                systemName: connectionDetailsSymbol
                            )
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help(connectionDetailsActionLabel)
                        .accessibilityLabel(connectionDetailsActionLabel)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 54)

            if hasConnectionInfo && showsConnectionDetails {
                Divider()
                connectionOverview(report)
            }

            if let errorMessage = reportErrorMessage(in: report) {
                if hasConnectionInfo && showsConnectionDetails {
                    Divider()
                }
                factRow(
                    symbol: "exclamationmark.circle.fill",
                    text: errorMessage,
                    color: dangerColor
                )
            }
        }
    }

    private func connectionOverview(
        _ report: ConnectionReport
    ) -> some View {
        let hasLines = !lineTasks(in: report).isEmpty
        let hasPolicies = !policyMappings(in: report).isEmpty
        return VStack(alignment: .leading, spacing: 10) {
            if hasLines {
                lineOverview(report)
            }
            if hasLines && hasPolicies {
                Divider()
                    .opacity(0.55)
            }
            if hasPolicies {
                DisclosureGroup(isExpanded: $showsPolicyMappings) {
                    policyOverview(report).padding(.top, 6)
                } label: {
                    Text(state.tr("分流规则", "Routing rules"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(.automatic)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private func lineOverview(_ report: ConnectionReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(lineTasks(in: report)) { task in
                HStack(alignment: .center, spacing: 6) {
                LineAddressView(
                    name: task.name,
                    info: networkInfo.observation(
                        for: task.resourceID, transactionID: report.transactionID
                    ),
                    capability: LineConnectionSummaryProjection.addressFamilyCapability(
                        taskID: task.id, report: report
                    ),
                    language: state.language,
                    retry: { family in
                        state.retryLineAddress(
                            lineID: task.resourceID,
                            transactionID: report.transactionID,
                            family: family
                        )
                    }
                )
                .id(report.transactionID + ":" + task.id)
                if let line = state.profile.lines.first(where: { $0.id == task.resourceID }) {
                    LineLatencyView(store: state.lineLatencies, line: line, profileID: state.profileLibrary.activeProfileID)
                        .frame(width: 76, alignment: .trailing)
                }
                }
                .frame(height: 26)
                .contentShape(Rectangle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func policyOverview(_ report: ConnectionReport) -> some View {
        let mappings = policyMappings(in: report)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(mappings) { mapping in
                HStack(spacing: 5) {
                    Text(mapping.ruleName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    Text(mapping.lineName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(connectedColor)
                        .lineLimit(1)
                        .frame(width: 90, alignment: .leading)
                    if let line = state.profile.lines.first(where: { $0.id == mapping.lineID }) {
                        LineLatencyView(store: state.lineLatencies, line: line, profileID: state.profileLibrary.activeProfileID, allowsTesting: false)
                    }
                    if mapping.error != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(dangerColor)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .help(
                    mapping.error?.message
                        ?? "\(mapping.ruleName) → \(mapping.lineName)"
                    )
            }
        }
    }

    private func failedDetails(_ report: ConnectionReport) -> some View {
        let failure = failurePresentation(report)
        return VStack(spacing: 0) {
            failureBlock(failure)
                .id(report.transactionID)
            Divider().padding(.leading, 24)

            let ingress = report.tasks.first { $0.kind == "ingress" }
            factRow(
                symbol: "circle.fill",
                text: ingressFact(ingress),
                color: dangerColor
            )
            Divider().padding(.leading, 24)

            factRow(
                symbol: report.rollbackComplete
                    ? "checkmark.circle.fill"
                    : "exclamationmark.circle.fill",
                text: rollbackFact(report),
                color: report.rollbackComplete &&
                    report.systemTakeoverRemoved
                    ? successColor
                    : dangerColor
            )
        }
    }

    private func failureBlock(
        _ failure: FailurePresentation
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(dangerColor)
                .frame(width: 9, height: 9)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = failure.detail, !detail.isEmpty {
                    let message = Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if failure.collapsesDetail {
                        DisclosureGroup(state.tr("诊断详情", "Diagnostic details")) { message }
                    } else {
                        message
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func failurePresentation(
        _ report: ConnectionReport
    ) -> FailurePresentation {
        let error = report.error
        let rawMessage = error?.message
            ?? state.engine.lastError
            ?? state.tr("连接失败", "Connection failed")
        if let loginFailure = AnyConnectLoginFailure(message: rawMessage) {
            return FailurePresentation(title: loginFailure.reason(tr: state.tr),
                                       detail: rawMessage, collapsesDetail: true)
        }
        let taskName = error.flatMap { failure in
            report.tasks.first { $0.id == failure.taskID }?.name
        }?.trimmingCharacters(in: .whitespacesAndNewlines)

        let reason: String
        if rawMessage.localizedCaseInsensitiveContains("SERVFAIL")
            || rawMessage.localizedCaseInsensitiveContains("lookup ") {
            reason = state.tr(
                "服务器域名解析失败",
                "Server name resolution failed"
            )
        } else if rawMessage.localizedCaseInsensitiveContains(
            "context deadline exceeded"
        ) || rawMessage.localizedCaseInsensitiveContains("timed out") {
            reason = state.tr(
                "连接服务器超时",
                "Server connection timed out"
            )
        } else if rawMessage.localizedCaseInsensitiveContains(
            "connection refused"
        ) {
            reason = state.tr(
                "服务器拒绝连接",
                "Server refused the connection"
            )
        } else if rawMessage.localizedCaseInsensitiveContains("certificate")
            || rawMessage.localizedCaseInsensitiveContains("tls handshake") {
            reason = state.tr("TLS 验证失败", "TLS verification failed")
        } else if error?.code == ProxyResourceReadiness.lineFailureCode {
            reason = state.tr(
                "真实出口检查失败",
                "Real egress check failed"
            )
        } else if error?.code
            == ProxyResourceReadiness.subscriptionFailureCode {
            reason = state.tr(
                "订阅出口检查失败",
                "Subscription egress check failed"
            )
        } else {
            reason = state.tr("连接失败", "Connection failed")
        }

        let title: String
        if let taskName, !taskName.isEmpty {
            title = "\(taskName)：\(reason)"
        } else {
            title = reason
        }
        return FailurePresentation(
            title: title,
            detail: rawMessage == title ? nil : rawMessage
        )
    }

    private func metric(symbol: String, value: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
    }

    private func factRow(
        symbol: String,
        text: String,
        color: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 9))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
    }

    private var expandableReport: ConnectionReport? {
        guard let report = state.presentedConnectionReport else {
            return nil
        }
        if state.isConnected && !state.isBusy &&
            report.state == .committed {
            return report
        }
        if report.error != nil || report.state == .failed {
            return report
        }
        return nil
    }

    private var connectionProgressReport: ConnectionReport? {
        if
            let targetScenarioID = state.scenarioSwitchTargetID,
            let projection = state.engine.scenarioSwitchProjection,
            projection.inFlight,
            projection.toScenarioID == targetScenarioID,
            projection.candidateReport.scenario.id == targetScenarioID
        {
            return projection.candidateReport
        }
        guard state.isBusy,
              state.scenarioSwitchTargetID == nil else {
            return nil
        }
        return state.presentedConnectionReport
    }

    private func completedTaskCount(in report: ConnectionReport) -> Int {
        report.tasks.filter {
            switch $0.state {
            case .ready, .committed, .rolledBack, .skipped:
                true
            default:
                false
            }
        }.count
    }

    private func progressStepSymbol(
        _ taskState: ConnectionTaskState
    ) -> String {
        switch taskState {
        case .pending:
            return "circle"
        case .running, .committing:
            return "ellipsis"
        case .ready, .committed:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        case .rollingBack:
            return "arrow.uturn.backward"
        case .rolledBack:
            return "arrow.uturn.backward.circle"
        case .skipped:
            return "minus"
        }
    }

    private func progressStepColor(
        _ taskState: ConnectionTaskState
    ) -> Color {
        switch taskState {
        case .pending, .skipped:
            return Color.secondary.opacity(0.72)
        case .running, .committing:
            return progressColor
        case .ready, .committed:
            return successColor
        case .failed:
            return dangerColor
        case .rollingBack, .rolledBack:
            return Color.secondary.opacity(0.82)
        }
    }

    private func progressStepStateText(
        _ taskState: ConnectionTaskState
    ) -> String {
        switch taskState {
        case .pending:
            return state.tr("等待", "Waiting")
        case .running:
            return state.tr("进行中", "Running")
        case .ready:
            return state.tr("就绪", "Ready")
        case .failed:
            return state.tr("失败", "Failed")
        case .committing:
            return state.tr("提交中", "Committing")
        case .committed:
            return state.tr("已提交", "Committed")
        case .rollingBack:
            return state.tr("回滚中", "Rolling back")
        case .rolledBack:
            return state.tr("已回滚", "Rolled back")
        case .skipped:
            return state.tr("已跳过", "Skipped")
        }
    }

    private func lineTasks(
        in report: ConnectionReport
    ) -> [ConnectionTaskReport] {
        report.tasks.filter { $0.kind == "line" }
    }

    private func policyMappings(
        in report: ConnectionReport
    ) -> [PolicyMapping] {
        guard let scenario = state.profile.scenarios.first(where: {
            $0.id == report.scenario.id
        }) else {
            return []
        }

        var mappings = scenario.bindings.map { binding in
            let ruleName = state.profile.ruleSets.first {
                $0.id == binding.ruleSetID
            }?.name ?? binding.ruleSetID
            return PolicyMapping(
                id: "rule:\(binding.ruleSetID)",
                ruleName: ruleName,
                lineName: policyTargetName(
                    lineID: binding.lineID,
                    subscriptionID: binding.subscriptionID
                ),
                lineID: binding.lineID,
                error: policyError(binding, in: report)
            )
        }

        if !scenario.defaultLineID.isEmpty
            || !scenario.defaultSubscriptionID.isEmpty {
            mappings.append(
                PolicyMapping(
                    id: "default",
                    ruleName: state.tr("其他流量", "Other Traffic"),
                    lineName: policyTargetName(
                        lineID: scenario.defaultLineID,
                        subscriptionID: scenario.defaultSubscriptionID
                    ),
                    lineID: scenario.defaultLineID,
                    error: lineError(
                        lineID: scenario.defaultLineID,
                        in: report
                    )
                )
            )
        }
        return mappings
    }

    private func policyTargetName(
        lineID: String,
        subscriptionID: String
    ) -> String {
        if !subscriptionID.isEmpty {
            return state.profile.subscriptions.first {
                $0.id == subscriptionID
            }?.name ?? subscriptionID
        }
        return state.profile.lines.first {
            $0.id == lineID
        }?.name ?? lineID
    }

    private func policyError(
        _ binding: RuleBinding,
        in report: ConnectionReport
    ) -> ConnectionReportError? {
        report.tasks.first {
            $0.kind == "rule_set"
                && $0.resourceID == binding.ruleSetID
        }?.error ?? lineError(lineID: binding.lineID, in: report)
    }

    private func lineError(
        lineID: String,
        in report: ConnectionReport
    ) -> ConnectionReportError? {
        guard !lineID.isEmpty else { return nil }
        return report.tasks.first {
            $0.kind == "line" && $0.resourceID == lineID
        }?.error
    }

    private func reportErrorMessage(
        in report: ConnectionReport
    ) -> String? {
        report.error?.message
            ?? report.tasks.compactMap { $0.error?.message }.first
    }

    private func ingressFact(
        _ task: ConnectionTaskReport?
    ) -> String {
        guard let task else {
            return state.tr(
                "系统接管状态不可用",
                "System takeover state unavailable"
            )
        }
        switch task.state {
        case .committed:
            return state.tr(
                "系统接管已提交",
                "System takeover committed"
            )
        case .rolledBack:
            return state.tr(
                "系统接管已撤销",
                "System takeover removed"
            )
        default:
            return state.tr(
                "系统接管未提交",
                "System takeover not committed"
            )
        }
    }

    private func rollbackFact(_ report: ConnectionReport) -> String {
        if report.rollbackComplete && report.systemTakeoverRemoved {
            return state.tr(
                "已回滚，原网络可用",
                "Rolled back; original network available"
            )
        }
        if let rollbackError = report.rollbackError {
            return rollbackError.message
        }
        return state.tr(
            "回滚状态尚未确认",
            "Rollback state not confirmed"
        )
    }

    private func formatDuration(_ seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let hours = safeSeconds / 3_600
        let minutes = (safeSeconds % 3_600) / 60
        let remainingSeconds = safeSeconds % 60
        return String(
            format: "%02d:%02d:%02d",
            hours,
            minutes,
            remainingSeconds
        )
    }
}

private struct FlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let availableWidth = proposal.width
            ?? sizes.reduce(0) { $0 + $1.width }
                + CGFloat(max(0, sizes.count - 1)) * horizontalSpacing
        return arrangement(
            sizes: sizes,
            availableWidth: availableWidth
        ).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let result = arrangement(
            sizes: sizes,
            availableWidth: bounds.width
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(
                    x: bounds.minX + result.origins[index].x,
                    y: bounds.minY + result.origins[index].y
                ),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    private func arrangement(
        sizes: [CGSize],
        availableWidth: CGFloat
    ) -> (size: CGSize, origins: [CGPoint]) {
        guard !sizes.isEmpty else { return (.zero, []) }
        let lineWidth = max(0, availableWidth)
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > lineWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, max(0, x - horizontalSpacing))
        }
        return (
            CGSize(width: min(usedWidth, lineWidth), height: y + rowHeight),
            origins
        )
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
