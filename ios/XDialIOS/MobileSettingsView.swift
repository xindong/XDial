import SwiftUI
import UniformTypeIdentifiers

struct MobileSettingsView: View {
    @EnvironmentObject private var app: AppState
    /// 为 true 时，打开后直接弹出「导入配置」并复位。用绑定读取弹出时的当前值。
    var startsImport: Binding<Bool>? = nil

    @ObservedObject private var location = LocationScenarios.shared
    @State private var timelineSnapshot: ConnectionTimeline.File?
    @State private var exportDocument: MobileJSONDocument?
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var showingDataUseNotice = false
    @State private var isConfirmingReset = false
    @State private var isConfirmingProfileRemoval = false
    @State private var notice: SettingsNotice?
    @State private var signInTarget: SettingsAccountTarget?
    @AppStorage(ConnectionActivityController.preferenceKey) private var showsLiveActivity = true
    @AppStorage(ConnectionActivityController.backgroundSpeedKey) private var updatesBackgroundSpeed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { CloudConfigurationSettings(sync: app.cloudSync, chinese: app.language == .zh) }
                if let line = app.accountLine {
                    Section(app.tr("账号", "Account")) {
                        Button {
                            signInTarget = SettingsAccountTarget(id: line.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle.fill")
                                    .font(.title)
                                    .foregroundStyle(XDialTheme.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.name.isEmpty
                                         ? (app.hasCompanyPreset ? app.tr("公司 VPN", "Company VPN") : app.tr("VPN 账号", "VPN Account"))
                                         : line.name)
                                        .foregroundStyle(XDialTheme.ink)
                                    Text(app.accountIsIncomplete
                                         ? app.tr("未登录", "Not signed in")
                                         : line.vpnUsername)
                                        .font(.subheadline)
                                        .foregroundStyle(XDialTheme.inkSecondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(XDialTheme.inkTertiary)
                            }
                        }
                        .accessibilityIdentifier("settings-account")
                    }
                }

                Section {
                    Toggle(
                        app.tr("打开 XDial 后自动连接", "Connect when XDial opens"),
                        isOn: $app.connectOnOpenEnabled
                    )
                    .accessibilityIdentifier("settings-connect-on-open")
                    Toggle(
                        app.tr("掉线后自动重连", "Reconnect after a drop"),
                        isOn: $app.autoReconnectEnabled
                    )
                    Toggle(
                        app.tr("换网络后自动连回", "Reconnect when the network changes"),
                        isOn: $app.systemOnDemandEnabled
                    )
                    .accessibilityIdentifier("system-on-demand-reconnect")
                    Toggle(
                        app.tr("在灵动岛和锁屏显示", "Show in Dynamic Island and Lock Screen"),
                        isOn: $showsLiveActivity
                    )
                    .onChange(of: showsLiveActivity) { _, _ in
                        location.reconcile()
                        MobileAppRuntime.connectionActivity?.preferenceChanged()
                    }
                    .accessibilityIdentifier("settings-live-activity")
                    Toggle(isOn: $updatesBackgroundSpeed) {
                        Text(app.tr("在后台持续更新网络速度", "Keep network speed updated in the background"))
                        Text(app.tr(
                            "连接 VPN 时使用后台定位，尽量保持网速更新，可能增加耗电。无需设置地点场景。",
                            "Uses background location while the VPN is connected to keep speeds updating when possible. This may use more battery. No saved places are needed."
                        ))
                    }
                    .disabled(!showsLiveActivity)
                    .onChange(of: updatesBackgroundSpeed) { _, _ in
                        location.reconcile()
                        MobileAppRuntime.connectionActivity?.refreshSampling()
                    }
                    .accessibilityIdentifier("settings-background-speed")
                    if showsLiveActivity && updatesBackgroundSpeed && (location.authorization == .denied || location.authorization == .restricted) {
                        Text(app.tr("后台网速需要定位权限。请在系统设置中允许 XDial 使用位置。", "To keep speeds updating in the background, allow location access for XDial in Settings."))
                    }
                    NavigationLink(app.tr("地点场景", "Location scenarios")) { LocationScenarioSettings() }
                        .accessibilityIdentifier("settings-place-scenarios")
                    if showsSystemOnDemandStatus {
                        LabeledContent(app.tr("当前状态", "Status")) {
                            Text(systemOnDemandStatusText)
                                .accessibilityIdentifier("system-on-demand-status")
                        }
                    }
                } header: {
                    Text(app.tr("连接", "Connection"))
                } footer: {
                    Text(app.tr(
                        "打开 XDial 时连接一次；手动断开后，切到后台再回来不会重新连接。开启「换网络后自动连回」后，首次连接遇到断网或超时，iOS 也会在网络恢复时按需重连。手动断开会取消。",
                        "XDial connects once when it opens; after a manual disconnect, returning to it does not reconnect. With network-change reconnect enabled, iOS also retries on demand after an initial network failure. Disconnect manually to cancel."
                    ))
                }

                Section(app.tr("通知", "Notifications")) {
                    ConnectionNoticeSettings(chinese: app.language == .zh)
                }

                Section {
                    NavigationLink {
                        ConfigurationView()
                    } label: {
                        Label(app.tr("线路与规则", "Lines & Rules"), systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("settings-advanced")

                    Button {
                        prepareExport()
                    } label: {
                        Label(app.tr("导出配置", "Export Configuration"), systemImage: "square.and.arrow.up")
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label(app.tr("导入配置", "Import Configuration"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                } header: {
                    Text(app.tr("高级", "Advanced"))
                } footer: {
                    Text(app.tr(
                        "一般不用改。导出的文件不含账号和密码。",
                        "You rarely need these. Exports never include accounts or passwords."
                    ))
                }

                Section(app.tr("帮助", "Help")) {
                    NavigationLink {
                        MobileDiagnosticsDetailView(
                            title: app.tr("诊断信息", "Diagnostics"),
                            shareTitle: app.tr("分享诊断", "Share diagnostics"),
                            report: diagnosticReport
                        )
                        .task { timelineSnapshot = await app.connectionTimelineSnapshot() }
                    } label: {
                        Label(app.tr("诊断信息", "Diagnostics"), systemImage: "stethoscope")
                    }
                    .accessibilityIdentifier("settings-diagnostics")

                    Button {
                        showingDataUseNotice = true
                    } label: {
                        Label(app.tr("数据使用说明", "How XDial Uses Data"), systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("settings-data-use")
                    if let url = DataUseNoticeView.privacyPolicyURL {
                        Link(destination: url) {
                            Label(app.tr("隐私政策", "Privacy Policy"), systemImage: "doc.text")
                        }
                        .accessibilityIdentifier("settings-privacy-policy")
                    }

                    Picker(selection: $app.language) {
                        Text("简体中文").tag(Lang.zh)
                        Text("English").tag(Lang.en)
                    } label: {
                        Label(app.tr("语言", "Language"), systemImage: "globe")
                    }

                    LabeledContent {
                        Text(version)
                    } label: {
                        Label(app.tr("版本", "Version"), systemImage: "info.circle")
                    }
                }

                Section {
                    if app.helperInstalled {
                        Button(role: .destructive) {
                            isConfirmingProfileRemoval = true
                        } label: {
                            Label(app.tr("移除系统 VPN 配置", "Remove System VPN Profile"), systemImage: "trash")
                        }
                        .disabled(app.hasActiveTunnel || app.isBusy)
                    }
                    Button(role: .destructive) {
                        isConfirmingReset = true
                    } label: {
                        Label(app.tr("恢复默认配置", "Restore Default Configuration"), systemImage: "arrow.counterclockwise")
                    }
                    .disabled(app.hasActiveTunnel || app.isBusy)
                } footer: {
                    Text(app.hasCompanyPreset ? app.tr(
                        "恢复默认会回到公司预置的线路和场景，账号需要重新登录。连接期间不可用。",
                        "Restoring returns to the company's lines and scenarios; you will sign in again. Unavailable while connected."
                    ) : app.tr(
                        "恢复默认会清空线路、规则和场景。连接期间不可用。",
                        "Restoring clears lines, rules and scenarios. Unavailable while connected."
                    ))
                }
            }
            .xdialGroupedBackground()
            .navigationTitle(app.tr("设置", "Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(app.tr("完成", "Done")) { dismiss() }
                        .accessibilityIdentifier("settings-done")
                }
            }
            .sheet(item: $signInTarget) { target in
                SignInSheet(lineID: target.id)
                    .environmentObject(app)
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "XDial-configuration"
            ) { result in
                if case .failure(let error) = result {
                    showError(app.tr("导出失败", "Export failed"), error: error)
                }
                exportDocument = nil
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showingDataUseNotice) {
                DataUseNoticeView(mode: .review).environmentObject(app)
            }
            .task {
                // 设置页弹出的动画还没结束时，系统会忽略再弹出的文件选择。
                guard let startsImport, startsImport.wrappedValue else { return }
                startsImport.wrappedValue = false
                guard !app.hasActiveTunnel else { return }
                try? await Task.sleep(for: .milliseconds(600))
                isImporting = true
            }
            .confirmationDialog(
                app.tr("恢复默认配置？", "Restore the default configuration?"),
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button(app.tr("恢复默认", "Restore Defaults"), role: .destructive) {
                    resetConfiguration()
                }
                Button(app.tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(app.hasCompanyPreset ? app.tr(
                    "线路、规则和场景会回到公司默认配置，当前配置不会保留。",
                    "Lines, rules and scenarios return to the company defaults. The current configuration is not kept."
                ) : app.tr(
                    "线路、规则和场景会被清空，当前配置不会保留。",
                    "Lines, rules and scenarios are cleared. The current configuration is not kept."
                ))
            }
            .confirmationDialog(
                app.tr("移除系统 VPN 配置？", "Remove the system VPN profile?"),
                isPresented: $isConfirmingProfileRemoval,
                titleVisibility: .visible
            ) {
                Button(app.tr("移除", "Remove"), role: .destructive) {
                    removeSystemProfile()
                }
                Button(app.tr("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(app.tr(
                    "下次连接时系统会再问一次是否允许添加。XDial 里的配置和账号不受影响。",
                    "iOS will ask for permission again on the next connection. Your XDial configuration and account are kept."
                ))
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text(app.tr("好", "OK")))
                )
            }
        }
        .tint(XDialTheme.accent)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var diagnosticStatus: String {
        switch app.engine.status {
        case "connected": return app.tr("已连接", "Connected")
        case "connecting": return app.tr("正在连接", "Connecting")
        case "action-required": return app.tr("需要登录 Tailscale", "Tailscale sign-in required")
        case "disconnecting": return app.tr("正在断开", "Disconnecting")
        case "reconnecting": return app.tr("正在重连", "Reconnecting")
        default: return app.tr("未连接", "Not connected")
        }
    }

    private var showsSystemOnDemandStatus: Bool {
        if case .failed = app.systemOnDemandState { return true }
        return app.systemOnDemandEnabled
    }

    private var systemOnDemandStatusText: String {
        switch app.systemOnDemandState {
        case .disabled:
            return app.tr("未启用", "Disabled")
        case .pending:
            return app.tr("等待系统接管", "Waiting for system reconnect")
        case .active:
            return app.tr("系统已启用", "Enabled by system")
        case .failed(let message):
            return systemOnDemandFailureText(message, isChinese: app.language == .zh)
        }
    }

    private var diagnosticReport: String {
        let stage = app.engine.dataPathRechecking
            ? app.tr("正在重新检测出口与分流", "Rechecking connectivity and routing")
            : app.engine.dataPathSummary
        let warning = LineProbeReading.warning(app.engine.lineProbeReadings, isChinese: app.language == .zh)
        let probeSummary = [stage, warning].compactMap { $0 }.joined(separator: " · ")
        return MobileDiagnosticsService.report(
            version: version,
            status: diagnosticStatus,
            systemProfileInstalled: app.helperInstalled,
            profile: app.profile,
            lastError: app.engine.lastError,
            dataPathSummary: probeSummary.isEmpty ? nil : probeSummary,
            autoScenarioSummary: autoScenarioSummary,
            onDemandStatus: systemOnDemandStatusText,
            connectOnOpen: app.connectOnOpenEnabled,
            environment: MobileDiagnosticsService.environmentSummary(version: version),
            scenarioName: app.activeScenario?.name,
            timeline: timelineSnapshot,
            isChinese: app.language == .zh
        )
    }

    /// 已连接时以 VPN 扩展的最近一次判断为准，并带上最近一次场景切换的结果。
    private var autoScenarioSummary: String? {
        let isChinese = app.language == .zh
        let tunnelState = app.isConnected ? app.tunnelScenarioState : nil
        // App 与 VPN 扩展各自的最近一次判断分开写：已连接时以扩展为准，没连接时只有 App。
        var parts: [String] = []
        if let record = ScenarioAutoPilot.lastRecord {
            parts.append("App " + record.summary(isChinese: isChinese))
        }
        if app.isConnected {
            let tunnelSummary = tunnelState?.lastSurvey?.summary(isChinese: isChinese)
                ?? (tunnelState == nil
                    ? (isChinese ? "VPN 扩展未回应" : "VPN extension did not respond")
                    : (isChinese ? "VPN 扩展尚未判断" : "VPN extension has not checked yet"))
            parts.append(tunnelSummary)
        }
        if let lastSwitch = tunnelState?.lastSwitch {
            let mode: String
            switch lastSwitch.mode {
            case .staged?: mode = isChinese ? "旁路准备后接手" : "staged"
            case .restart?: mode = isChinese ? "换引擎" : "engine restart"
            case nil: mode = isChinese ? "未切换" : "not switched"
            }
            let outcome = lastSwitch.succeeded
                ? (isChinese ? "成功" : "succeeded")
                : (isChinese ? "失败" : "failed") + (lastSwitch.failure.map { isChinese ? "：\($0)" : ": \($0)" } ?? "")
            parts.append(isChinese
                ? "最近一次切换（\(mode)）\(outcome)"
                : "Last switch (\(mode)) \(outcome)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ｜ ")
    }

    private func prepareExport() {
        do {
            exportDocument = MobileJSONDocument(data: try MobileConfigurationService.exportData(for: app.profile))
            isExporting = true
        } catch {
            showError(app.tr("导出失败", "Export failed"), error: error)
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        guard !app.hasActiveTunnel, !app.isBusy else {
            notice = SettingsNotice(
                title: app.tr("当前不可导入", "Import unavailable"),
                message: app.tr("请先断开连接并等待当前操作结束。", "Disconnect and wait for the current operation to finish.")
            )
            return
        }

        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            if let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.intValue > MobileConfigurationService.maxImportBytes {
                throw MobileConfigurationError.fileTooLarge
            }

            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            let imported = try MobileConfigurationService.importProfile(from: data)
            let previousProfile = app.profile
            app.engine.lastError = nil
            guard app.replaceProfileAndSave(imported) else {
                app.profile = previousProfile
                notice = SettingsNotice(
                    title: app.tr("导入失败", "Import failed"),
                    message: app.tr(
                        "配置未能安全保存，原配置仍保留。请解锁设备后重试。",
                        "The configuration could not be saved securely. Your previous configuration is still available. Unlock the device and try again."
                    )
                )
                return
            }
            notice = SettingsNotice(
                title: app.tr("导入成功", "Import complete"),
                message: app.tr(
                    "配置已保存。请重新填写账号、密码、节点密钥、订阅地址和远程规则地址。",
                    "The configuration was saved. Re-enter accounts, passwords, node keys, subscription URLs, and remote-rule URLs."
                )
            )
        } catch {
            showError(app.tr("导入失败", "Import failed"), error: error)
        }
    }

    private func resetConfiguration() {
        guard !app.hasActiveTunnel, !app.isBusy else { return }
        let previousProfile = app.profile
        app.engine.lastError = nil
        guard app.replaceProfileAndSave(app.defaultProfile) else {
            app.profile = previousProfile
            notice = SettingsNotice(
                title: app.tr("重置失败", "Reset failed"),
                message: app.tr(
                    "配置未能安全保存，原配置仍保留。请解锁设备后重试。",
                    "The configuration could not be saved securely. Your previous configuration is still available. Unlock the device and try again."
                )
            )
            return
        }
        notice = SettingsNotice(
            title: app.tr("已重置", "Reset complete"),
            message: app.tr("配置已恢复为初始状态。", "The initial configuration has been restored.")
        )
    }

    private func removeSystemProfile() {
        app.removeTunnelProfile { result in
            Task { @MainActor in
                switch result {
                case .success:
                    notice = SettingsNotice(
                        title: app.tr("已移除", "Profile removed"),
                        message: app.tr("系统描述文件已移除。", "The system profile was removed.")
                    )
                case .failure(let error):
                    showError(app.tr("移除失败", "Removal failed"), error: error)
                }
            }
        }
    }

    private func showError(_ title: String, error: Error) {
        notice = SettingsNotice(title: title, message: configurationErrorMessage(error))
    }

    private func configurationErrorMessage(_ error: Error) -> String {
        guard let error = error as? MobileConfigurationError else {
            let productText = userFacingConnectionText(error.localizedDescription)
            return MobileDiagnosticsService.redacted(productText, using: app.profile)
                ?? app.tr("操作失败，请重试。", "The operation failed. Please try again.")
        }
        switch error {
        case .invalidJSON:
            return app.tr("所选文件不是有效的 XDial JSON 配置。", "The selected file is not a valid XDial JSON configuration.")
        case .unsupportedFormat:
            return app.tr("不支持这个 XDial 配置格式或版本。", "This XDial configuration format or version is not supported.")
        case .missingField(let field):
            return app.tr("配置缺少必要字段：\(field)。", "The configuration is missing the required field: \(field).")
        case .invalidIdentifier(let kind):
            return app.tr("配置中有空的 \(kind) 标识。", "The configuration contains an empty \(kind) identifier.")
        case .duplicateIdentifier(let kind):
            return app.tr("配置中有重复的 \(kind) 标识。", "The configuration contains a duplicate \(kind) identifier.")
        case .unsupportedLineType(let type):
            return app.tr("配置包含不支持的线路类型：\(type)。", "The configuration contains an unsupported line type: \(type).")
        case .invalidActiveScenario:
            return app.tr("当前场景在导入配置中不存在。", "The active scenario does not exist in this configuration.")
        case .invalidReference(let reference):
            return app.tr("配置包含无效引用：\(reference)。", "The configuration contains an invalid reference: \(reference).")
        case .fileTooLarge:
            return app.tr("配置文件超过 2 MB，已拒绝导入。", "The configuration is larger than 2 MB and was not imported.")
        }
    }
}

private struct MobileDiagnosticsDetailView: View {
    let title: String
    let shareTitle: String
    let report: String

    var body: some View {
        ScrollView {
            Text(report)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: report, subject: Text("XDial Diagnostics")) {
                Label(shareTitle, systemImage: "square.and.arrow.up")
            }
        }
    }
}

private struct SettingsNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct SettingsAccountTarget: Identifiable {
    let id: String
}
