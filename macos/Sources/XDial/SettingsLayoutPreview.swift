#if DEBUG
import AppKit
import SwiftUI

/// An offline layout check using production views and synthetic resources.
/// Entered before relocation, normal AppState setup or any connection lifecycle.
@MainActor
enum SettingsLayoutPreview {
    static var outputDirectory = ""
    static var state: AppState!

    /// Inspect the actual AppKit inputs used by AutoFill, including the field
    /// pairing and the secure editor. Use only the synthetic preview account.
    private static func checkAccountFields() {
        let hosting = NSHostingView(rootView: HomeAccountView(request: .init(lineID: "account-fixture"))
            .environmentObject(state!))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 380, height: 320),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        func inputs(_ view: NSView) -> [NSTextField] {
            if let field = view as? NSTextField { return [field] }
            return view.subviews.flatMap(inputs)
        }
        let fields = inputs(hosting)
        precondition(fields.contains { $0.contentType == .username })
        precondition(fields.contains { $0 is NSSecureTextField && $0.contentType == .password })
        print("Account layout: native username and secure password fields verified")
    }

    /// Uses production views in a window that is never shown. No relocation,
    /// user configuration, helper registration or networking is started.
    static func checkScenarioLayout() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let arguments = CommandLine.arguments
        let bindingCount = arguments.firstIndex(of: "--binding-count").flatMap { index in
            arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) : nil
        }.map { max(1, min(500, $0)) } ?? 6
        var library = ProfileLibrary()
        library.profiles[0].profile.lines += (0..<160).map {
            Line(id: "layout-line-\($0)", name: "线路 \($0)", type: "trojan",
                 trojanServer: "layout.example", trojanPort: 443)
        }
        library.profiles[0].profile.ruleSets = (0..<bindingCount).map {
            RuleSet(id: "layout-rule-\($0)", name: "匹配条件 \($0)", type: "manual", domains: ["layout.example"])
        }
        var scenario = Scenario(id: "layout-scenario", name: "场景布局检查",
            bindings: (0..<bindingCount).map { RuleBinding(ruleSetID: "layout-rule-\($0)", lineID: "layout-line-\($0 % 160)") },
            defaultLineID: "direct")
        scenario.matchSSIDs = ["Hotel Network", "Home Network 5G", "Phone Hotspot", "Office Network", "Guest Network"]
        library.scenarios = (0..<12).map { index in
            var item = scenario
            item.id = index == 2 ? scenario.id : "other-scenario-\(index)"
            item.name = "场景 \(index)"
            return item
        }
        if CommandLine.arguments.contains("--user-configuration") {
            do {
                library = try ProfileLibraryStore().load(readOnly: true).unwrap()
                let arguments = CommandLine.arguments
                let name = arguments.firstIndex(of: "--scenario-name").flatMap { index in
                    arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
                }
                scenario = try (library.scenarios.first { $0.name == name } ?? library.scenarios.first).unwrap()
            } catch {
                fputs("Cannot read the existing library without interaction; no data was changed.\n", stderr)
                exit(2)
            }
        }
        if !arguments.contains("--user-configuration") {
            library.profiles[0].profile.lines.append(Line(id: "account-fixture", name: "Test VPN", type: "vpn",
                                                         vpnServer: "vpn.example.com"))
        }
        state = AppState(previewLibrary: library)
        if !arguments.contains("--user-configuration") {
            state.profileLibraryLoaded = true
            checkAccountFields()
            let initialIntent = state.desiredConnectionStateForDiagnostics
            state.selectHomeScenario(scenario.id)
            precondition(state.activeScenario?.id == scenario.id)
            precondition(state.desiredConnectionStateForDiagnostics == initialIntent)
            precondition(!state.isBusy && !state.isConnected)
            let popover = NSHostingView(rootView: MainPopover(trafficInfo: TrafficInfo())
                .environmentObject(state!).environmentObject(AppUpdateChecker()))
            precondition(popover.fittingSize.width == 360 && popover.fittingSize.height > 0)
        }
        state.editorPosition.tab = 2
        let hosting = NSHostingView(rootView: SettingsView().environmentObject(state!))
        let window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: 620, height: 580),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        func settle(_ stage: String) {
            print("scenario-layout begin: \(stage)"); fflush(stdout)
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            }
            let deadline = Date().addingTimeInterval(0.15)
            while Date() < deadline { _ = RunLoop.current.run(mode: .default, before: deadline) }
            hosting.layoutSubtreeIfNeeded()
            print("scenario-layout settled: \(stage)"); fflush(stdout)
        }
        settle("collapsed")
        withAnimation(.easeInOut(duration: 0.2)) {
            state.editorPosition.expandedScenarioID = scenario.id
        }
        settle("expanded")
        func scrollViews(_ view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
        }
        let scrollers = scrollViews(hosting)
        print("scenario-layout scrollers: \(scrollers.count)"); fflush(stdout)
        for offset in [80, 140, 250, 420, 600, 300, 100, 0] {
            state.objectWillChange.send()
            for scroll in scrollers {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            settle("scroll \(offset)")
        }
        for width in [620, 800, 560, 620] {
            window.setContentSize(CGSize(width: width, height: 580))
            settle("width \(width)")
        }
        state.editorPosition.expandedScenarioID = nil
        settle("collapsed again")
        state.editorPosition.expandedScenarioID = scenario.id
        settle("expanded again")
        print("Scenario layout check passed without showing a window")
        exit(0)
    }

    static func run(directory: String) -> Never {
        outputDirectory = directory
        _ = NSApplication.shared
        var library = ProfileLibrary()
        library.profiles[0].name = "个人订阅"
        library.profiles[0].profile.lines.append(Line(id: "hk", name: "香港 01", type: "trojan", trojanServer: "proxy.example", trojanPort: 443))
        library.profiles[0].profile.ruleSets = [RuleSet(id: "media", name: "流媒体", type: "manual", domains: ["video.example"])]
        var company = ProfileRecord(id: "company", name: "公司配置", profile: Profile())
        company.profile.lines = [Line(id: "company-line", name: "公司代理", type: "trojan", trojanServer: "company.example", trojanPort: 443)]
        company.profile.ruleSets = [RuleSet(id: "work", name: "工作服务", type: "manual", domains: ["work.example"])]
        try! library.insert(company)
        library.editingProfileID = library.profiles[0].id
        var group = Line(id: "shared", name: "常用线路", type: "selector")
        group.groupMembers = ["hk", "company-line"]; group.groupDefault = "hk"
        library.groups = [group]
        library.scenarios = [Scenario(id: "daily", name: "日常", bindings: [RuleBinding(ruleSetID: "media", lineID: "shared")], defaultLineID: "direct"), Scenario(id: "work-scene", name: "办公", bindings: [RuleBinding(ruleSetID: "work", lineID: "company-line")], defaultLineID: "shared")]
        library.activeScenarioID = "daily"
        state = AppState(previewLibrary: library)
        state.editorPosition.expandedLineIDs.insert("shared")
        state.editorPosition.expandedScenarioID = "work-scene"
        SettingsLayoutPreviewApp.main()
        exit(0)
    }

    static func capture() async {
        do {
            try FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(700))
            let window = try NSApp.windows.first(where: { $0.contentView != nil }).unwrap()
            let initialWindow = window.windowNumber
            for (tab, name) in [(0, "lines"), (3, "groups"), (1, "rules"), (2, "scenarios"), (4, "general")] {
                state.editorPosition.tab = tab
                try await Task.sleep(for: .milliseconds(400))
                guard window.windowNumber == initialWindow else { throw CocoaError(.validationMissingMandatoryProperty) }
                let view = try window.contentView?.superview.unwrap()
                guard let view else { throw CocoaError(.fileReadUnknown) }
                view.layoutSubtreeIfNeeded()
                let bitmap = try view.bitmapImageRepForCachingDisplay(in: view.bounds).unwrap()
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try bitmap.representation(using: .png, properties: [:]).unwrap()
                try png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".png"))
            }
            print("Rendered five settings pages in one native window: \(outputDirectory)")
            try await captureCloudHost()
            exit(0)
        } catch {
            fputs("Layout preview failed: \(error)\n", stderr)
            exit(1)
        }
    }
}

extension SettingsLayoutPreview {
    /// Renders the "add my server" sheet in each stage with synthetic data.
    static func captureCloudHost() async throws {
        let key = CloudHostKey(fingerprint: "SHA256:VeZpVFtrjNbE0TOrxV6LXNvckf9dPyH81cI9y0/RewU", algorithm: "ssh-ed25519", file: "/etc/ssh/ssh_host_ed25519_key.pub")
        let report = CloudHostSetupModel.previewDecode(CloudHostReport.self, """
        {"host_key":{"fingerprint":"\(key.fingerprint)","algorithm":"ssh-ed25519"},"system":"Ubuntu 24.04.1 LTS","architecture":"x86_64",
         "privilege":"sudo-password","ufw_active":true,"suggested_port":43111,"blocking":[],
         "notes":[{"code":"ufw_active","message":"服务器开着 ufw 防火墙。XDial 只为代理端口添加一条放行规则，回滚时删除。","message_en":""},
                  {"code":"security_group","message":"如果服务商有安全组或防火墙面板，需要在那里放行代理端口（TCP 和 UDP）；XDial 无法替你修改。","message_en":""}]}
        """)
        let plan = CloudHostSetupModel.previewDecode(CloudHostPlan.self, """
        {"port":43111,"method":"2022-blake3-aes-128-gcm","reuse":false,"steps":[
         {"id":"apt_key","title":"添加 sing-box 官方软件源的签名密钥","title_en":"","detail":"/etc/apt/keyrings/xdial-sagernet.asc"},
         {"id":"apt_source","title":"添加 sing-box 官方软件源","title_en":"","detail":"/etc/apt/sources.list.d/xdial-sagernet.sources (https://deb.sagernet.org/)"},
         {"id":"install","title":"用 apt 安装 sing-box（校验软件包签名）","title_en":"","detail":"apt-get install sing-box"},
         {"id":"config","title":"写入代理配置：Shadowsocks 2022，端口 43111，新生成的密钥","title_en":"","detail":"/etc/xdial-proxy/config.json"},
         {"id":"unit","title":"添加独立的系统服务 xdial-proxy","title_en":"","detail":"/etc/systemd/system/xdial-proxy.service"},
         {"id":"ufw","title":"在 ufw 里只放行端口 43111（TCP 和 UDP）","title_en":"","detail":"ufw allow 43111/tcp, 43111/udp"},
         {"id":"start","title":"启动服务并确认它在端口 43111 上监听","title_en":""}]}
        """)
        let deployed = CloudHostResult(server: "203.0.113.10", port: 43111, method: "2022-blake3-aes-128-gcm", password: "", reused: false)
        let measurement = CloudHostSetupModel.previewDecode(CloudHostMeasurement.self,
            #"{"latency_ms":206,"exit_ip":"203.0.113.10","download_bytes":10000000,"download_ms":241,"mbps":331.3}"#)
        let events = ["prepare", "apt_key", "apt_source", "install"].map { CloudHostEvent(step: $0, status: $0 == "install" ? "running" : "done", message: nil) }
        let stages: [(String, CloudHostSetupModel.Stage, [CloudHostEvent])] = [
            ("cloud-host-1-server", .server, []),
            ("cloud-host-2-fingerprint", .confirmKey(key), []),
            ("cloud-host-3-review", .review(report), []),
            ("cloud-host-4-deploying", .deploying, events),
            ("cloud-host-5-verified", .verified(deployed, measurement), []),
            ("cloud-host-6-unverified", .unverified(deployed, CloudHostMessage(code: "proxy_unreachable",
                message: "经这条线路的 HTTPS 请求没有成功。请确认服务商的安全组或防火墙已放行代理端口（TCP 和 UDP），然后重新测试。", messageEN: "")), []),
        ]
        for (name, stage, events) in stages {
            let model = CloudHostSetupModel()
            model.host = "203.0.113.10"
            model.user = "ubuntu"
            model.password = "preview"
            model.proxyPort = "43111"
            model.lineName = "云主机 · 203.0.113.10"
            model.preview(stage: stage, plan: plan, events: events)
            let root = NavigationStack {
                CloudHostSetupView(model: model, chinese: true, onSave: { _ in true }, onClose: {})
            }
            // Taller than the real sheet so a page renders without scrolling.
            .frame(width: 560, height: 1180)
            .preferredColorScheme(.light)
            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 560, height: 1180),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = hosting
            window.orderFrontRegardless()
            try await Task.sleep(for: .milliseconds(600))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds).unwrap()
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try bitmap.representation(using: .png, properties: [:]).unwrap()
            try png.write(to: URL(fileURLWithPath: outputDirectory).appendingPathComponent(name + ".png"))
            window.orderOut(nil)
        }
        print("Rendered the add-my-server sheet: \(outputDirectory)")
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else { throw CocoaError(.fileReadUnknown) }
        return value
    }
}

private struct SettingsLayoutPreviewApp: App {
    @StateObject private var state = SettingsLayoutPreview.state!
    @State private var started = false
    var body: some Scene {
        Window("XDial Settings Preview", id: "settings-preview") {
            SettingsView().environmentObject(state)
                .background(SettingsWindowChrome())
                .preferredColorScheme(.light)
                .task {
                    guard !started else { return }
                    started = true
                    await SettingsLayoutPreview.capture()
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
#endif
