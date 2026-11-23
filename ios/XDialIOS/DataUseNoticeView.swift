import SwiftUI

/// The declaration App Review Guideline 5.4 asks a VPN app to show before the
/// service is used: what XDial sends where, and what stays on the device. It is
/// shown full screen until confirmed, and can be reread from Settings. Every
/// statement here must match the code; see DESIGN.md §8.3 for the evidence.
struct DataUseNoticeView: View {
    enum Mode { case firstUse, review }

    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let mode: Mode

    /// Set by the build (Info.plist XDialPrivacyPolicyURL); the same address as App Store Connect.
    static var privacyPolicyURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "XDialPrivacyPolicyURL") as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(app.tr(
                        "XDial 在这台设备上建立 VPN，按你的场景把每个连接送到直连，或者你配置的线路（代理服务器、AnyConnect、Tailscale）。使用前请了解它会访问哪些服务、哪些数据只留在设备上。",
                        "XDial sets up a VPN on this device and sends each connection either directly or through a line you configure (a proxy server, AnyConnect or Tailscale), according to your scenarios. Before you start, here is what it contacts and what stays on the device."
                    ))
                    .font(.body)
                    .foregroundStyle(XDialTheme.ink)

                    if mode == .firstUse {
                        CloudSyncNoticeToggle(sync: app.cloudSync, chinese: app.language == .zh)
                    }
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(section.title, systemImage: section.symbol)
                                .font(.headline)
                                .foregroundStyle(XDialTheme.ink)
                            ForEach(section.points, id: \.self) { point in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("•").foregroundStyle(XDialTheme.inkSecondary)
                                    Text(point)
                                        .font(.subheadline)
                                        .foregroundStyle(XDialTheme.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    if let url = Self.privacyPolicyURL {
                        Button(app.tr("阅读完整隐私政策", "Read the full privacy policy")) { openURL(url) }
                            .accessibilityIdentifier("data-use-privacy-policy")
                    }
                }
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                if mode == .firstUse {
                    Button {
                        app.acceptDataUseNotice()
                    } label: {
                        Text(app.tr("继续使用", "Continue"))
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(XDialTheme.accent)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                    .background(.bar)
                    .accessibilityIdentifier("data-use-accept")
                }
            }
            .navigationTitle(app.tr("数据使用说明", "How XDial Uses Data"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if mode == .review {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(app.tr("完成", "Done")) { dismiss() }
                    }
                }
            }
            .xdialGroupedBackground()
        }
        .interactiveDismissDisabled(mode == .firstUse)
    }

    private struct Section {
        let title: String
        let symbol: String
        let points: [String]
    }

    private var sections: [Section] {
        DataUseNotice.sections(isChinese: app.language == .zh, companyPreset: app.hasCompanyPreset)
            .map { Section(title: $0.title, symbol: $0.symbol, points: $0.points) }
    }
}

/// The notice's content, kept apart from the view so tests can check it.
enum DataUseNotice {
    struct Section: Equatable {
        let title: String
        let symbol: String
        let points: [String]
    }

    static func sections(isChinese zh: Bool, companyPreset: Bool) -> [Section] {
        func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
        var services = [
            t("域名解析：连接期间，这台设备的域名查询以未加密方式发往 Cloudflare 公共 DNS（1.1.1.1）；使用 AnyConnect 线路时改发给该 VPN 提供的 DNS，Tailscale 内的名称由 Tailscale 解析。",
              "Name resolution: while connected, this device's DNS queries are sent unencrypted to Cloudflare public DNS (1.1.1.1); with an AnyConnect line they go to the DNS that VPN provides, and Tailscale names are resolved by Tailscale."),
            t("连通性检测：每次连接时访问 Cloudflare（1.0.0.1、1.1.1.1）和 www.apple.com 的测试地址，第一处没有回应时再试阿里公共 DNS（223.5.5.5）；连接期间每隔几分钟经代理节点访问 www.gstatic.com，测出可用和最快的节点。",
              "Connectivity checks: on each connection XDial requests test addresses at Cloudflare (1.0.0.1, 1.1.1.1) and www.apple.com, and tries Alibaba public DNS (223.5.5.5) if the first one does not answer; while connected it requests www.gstatic.com through proxy nodes every few minutes to find working and fast nodes."),
            t("出口地址：每次连接时，经各条线路访问 checkip.amazonaws.com 和 Cloudflare，查出这条线路对外的 IP 地址，显示在 App 和诊断信息里。",
              "Exit address: on each connection XDial asks checkip.amazonaws.com and Cloudflare, through each line, for that line's public IP address, which it shows in the app and in diagnostics."),
            t("规则和订阅：配置引用的规则文件（例如托管在 GitHub 上的地区规则）在缺少缓存时下载；订阅地址只在你添加或刷新订阅时访问。这些地址由你或你的服务提供方给出，地址里带的令牌、账号或密码会随请求发给该地址的服务方。",
              "Rules and subscriptions: rule files your configuration refers to (for example region rules hosted on GitHub) are downloaded when no cached copy exists; subscription addresses are fetched only when you add or refresh a subscription. These addresses come from you or your provider; any token, account or password in an address is sent to the service at that address."),
        ]
        if companyPreset {
            services.append(t(
                "出口地区：按地区自动选场景时，向 Apple（gspe1-ssl.ls.apple.com）和 Cloudflare 查询当前网络出口所在的国家或地区，只用来选场景。",
                "Exit region: when scenarios are chosen by region, XDial asks Apple (gspe1-ssl.ls.apple.com) and Cloudflare which country or region the current network exits in, only to pick the scenario."
            ))
        }
        services.append(t(
            "这些服务都会看到你的 IP 地址。发给 DNS 和各项检测、查询服务的请求不含你的账号、密码或配置内容。",
            "All of these services see your IP address. Requests to the DNS and the check and lookup services carry no account, password or configuration content."
        ))
        return [
            Section(title: t("XDial 客户端不收集你的数据", "The XDial client does not collect your data"), symbol: "hand.raised", points: [
                t("XDial 客户端里没有广告、分析、崩溃收集或追踪 SDK，也不会把你的使用情况、浏览内容或访问记录发给 XDial 的开发者。",
                  "The XDial client contains no advertising, analytics, crash-reporting or tracking SDK, and does not send your usage, browsing or visit history to XDial's developers."),
            ]),
            Section(title: t("流量去向", "Where your traffic goes"), symbol: "arrow.triangle.branch", points: [
                t("网络流量按你的配置直接发往目标网站，或发往所选线路的服务器。",
                  "Traffic goes straight to its destination or to the server of the line you use, according to your configuration."),
                t("使用公司 VPN 线路时，需要你自己的公司账号，App 里不内置任何员工账号或密码。连接后，由公司的 VPN 网关负责认证，并转发经它的流量；网关会记录什么、保留多久、谁能查看，以公司的规定为准，不在本说明的范围内。",
                  "A company VPN line needs your own company account; the app ships with no employee account or password. Once connected, the company's VPN gateway authenticates you and forwards the traffic sent through it; what the gateway records, for how long and who can see it are governed by your company's policies and are outside this notice."),
                t("其他线路的服务器由你或你的服务提供方运营，如何处理数据以他们的政策为准。",
                  "Servers of other lines are run by you or your provider, whose own policies govern how they handle data."),
                t("连接 AnyConnect 线路时，按该协议向你的 VPN 服务器发送设备名、网卡地址和由它们生成的设备标识；使用 Tailscale 线路时，设备名会发给 Tailscale 的服务器。",
                  "With an AnyConnect line, XDial sends your VPN server the device name, network interface address and a device identifier derived from them, as that protocol requires; with a Tailscale line, the device name is sent to Tailscale's servers."),
            ]),
            Section(title: t("自动访问的公共服务", "Public services XDial contacts"), symbol: "network", points: services),
            Section(title: t("数据存储与同步", "Storage and sync"), symbol: "iphone", points: [
                t("iCloud 同步默认开启。确认本说明后，配置、已保存的 Wi-Fi 匹配规则、偏好、VPN 密码和订阅地址会同步到你的私人 iCloud，供同一 Apple 账号的设备使用。你可以在继续前或之后的设置中关闭同步。",
                  "iCloud Sync is on by default. After you confirm this notice, XDial syncs configuration, saved Wi-Fi matching rules, preferences, VPN passwords and subscription URLs to your private iCloud for devices using the same Apple Account. You can turn sync off before continuing or later in Settings."),
                t("Wi-Fi 名称仅在本机匹配。若启用地点场景，连接 VPN 时会在后台比对已保存地点。若启用后台网速，XDial 会使用后台定位来持续采样网速。坐标仅用于本机匹配，不随配置导出。",
                  "Wi-Fi names are matched on device. If you enable location scenarios, XDial checks saved places in the background while connected. If you enable background speed updates, XDial uses background location to keep sampling network speeds. Coordinates are matched locally and excluded from configuration exports."),
                t("连接记录和诊断信息（含出口 IP 地址）保存在本机，只有你主动导出或分享时才会离开设备。",
                  "Connection history and diagnostics (including exit IP addresses) stay on the device and leave it only when you export or share them."),
            ]),
            Section(title: CloudHostDisclosure.title(zh), symbol: "server.rack", points: CloudHostDisclosure.points(zh)),
            Section(title: t("快捷指令、控制中心和通知", "Shortcuts, Control Center and notifications"), symbol: "switch.2", points: [
                t("它们只能连接、断开、切换场景，显示连接状态和场景名，不读取你的流量；通知默认关闭，在本机产生。",
                  "They can only connect, disconnect, switch scenarios and show the connection status and scenario name; they do not read your traffic. Notifications are off by default and created on the device."),
            ]),
        ]
    }
}
