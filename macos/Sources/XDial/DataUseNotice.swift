import Foundation

/// Whether the user has confirmed the current data use notice. Only the App Store
/// build requires it; bump `version` when the notice changes materially so users
/// confirm again.
enum DataUseNoticeAcceptance {
    static let version = 5
    static let defaultsKey = "xdial.data-use-notice-version"

    static var requiredByBuild: Bool {
        #if XDIAL_STORE
        true
        #else
        false
        #endif
    }

    static func isAccepted(defaults: UserDefaults, required: Bool) -> Bool {
        !required || defaults.integer(forKey: defaultsKey) >= version
    }

    static func accept(defaults: UserDefaults) {
        defaults.set(version, forKey: defaultsKey)
    }
}

/// What the App Store build tells the user before it first goes online. Every
/// statement must match the code; the evidence is in docs/agent/app-store-privacy.md
/// (Mac section). Update both, and `DataUseNoticeAcceptance.version`, together.
enum MacDataUseNotice {
    struct Section: Equatable {
        let title: String
        let symbol: String
        let points: [String]
    }

    static func introduction(isChinese zh: Bool) -> String {
        zh ? "XDial 在这台 Mac 上接管网络连接，按你的场景把每个连接送到直连，或者你配置的线路（代理服务器、AnyConnect、Tailscale）。使用前请了解它会访问哪些服务、哪些数据只留在 Mac 上。"
           : "XDial takes over this Mac's network connections and sends each one either directly or through a line you configure (a proxy server, AnyConnect or Tailscale), according to your scenarios. Before you start, here is what it contacts and what stays on the Mac."
    }

    static func sections(isChinese zh: Bool, companyPreset: Bool) -> [Section] {
        func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
        var services = [
            t("域名解析：连接期间，直连的域名由这台 Mac 自己的 DNS 服务器解析（未加密）；走代理的域名经该代理以加密方式（DoH）向 Cloudflare（1.1.1.1）查询；代理服务器自己的域名以加密方式向阿里公共 DNS（223.5.5.5）查询。AnyConnect 线路使用该 VPN 提供的 DNS，Tailscale 内的名称在本机解析。",
              "Name resolution: while connected, names that go direct are resolved by this Mac's own DNS server (unencrypted); names that go through a proxy are looked up over encrypted DNS (DoH) at Cloudflare (1.1.1.1) through that proxy; proxy server names are looked up over encrypted DNS at Alibaba public DNS (223.5.5.5). AnyConnect lines use the DNS that VPN provides, and Tailscale names are resolved on the Mac."),
            t("连通性检测：每次连接时，与 Cloudflare（1.1.1.1 及其 IPv6 地址）和 Google 公共 DNS 的 IPv6 地址做一次加密握手，检查 IPv6 和每条线路是否可用，不发送任何内容。",
              "Connectivity checks: on each connection XDial completes an encrypted handshake with Cloudflare (1.1.1.1 and its IPv6 address) and Google public DNS's IPv6 address to check IPv6 and each line; no content is sent."),
            t("出口地址：每次连接时，经各条线路向 Cloudflare 查询这条线路对外的 IP 地址；查询公网 IPv4 地址时还可能访问腾讯（r.inews.qq.com/api/ip2city），只取其中的 IP 地址，不读取城市；订阅和 Tailscale 线路还会查询 checkip.amazonaws.com。这些请求不发送定位坐标或 Wi-Fi 名称，结果显示在 App 和诊断信息里。",
              "Exit address: on each connection XDial asks Cloudflare, through each line, for that line's public IP address; for the public IPv4 address it may also ask Tencent (r.inews.qq.com/api/ip2city) and reads only the IP address, not the city; subscription and Tailscale lines also ask checkip.amazonaws.com. These requests carry no location coordinates or Wi-Fi name; the result is shown in the app and in diagnostics."),
            t("线路测速：当前场景用到的线路会经该线路访问 www.gstatic.com（或线路组指定的测试地址）测延迟，未连接时也会测一次；连接期间自动选择的线路组每隔几分钟测一次。",
              "Line tests: lines used by the current scenario request www.gstatic.com (or the test address a line group names) through that line to measure latency, once even while disconnected; while connected, automatically selected line groups are tested every few minutes."),
            t("规则和订阅：规则文件在连接时缺少缓存或缓存超过一天时下载；订阅按你设定的间隔自动刷新（默认每天一次）。这些地址由你或你的服务提供方给出，地址里带的令牌、账号或密码会随请求发给该地址的服务方。",
              "Rules and subscriptions: rule files are downloaded when you connect if no cached copy exists or the copy is more than a day old; subscriptions refresh automatically at the interval you set (daily by default). These addresses come from you or your provider; any token, account or password in an address is sent to the service at that address."),
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
                t("XDial 客户端里没有广告、分析、崩溃收集或追踪 SDK，也不会把你的使用情况、浏览内容或访问记录发给 XDial 的开发者；商店版也不自行检查更新。",
                  "The XDial client contains no advertising, analytics, crash-reporting or tracking SDK, and does not send your usage, browsing or visit history to XDial's developers; the App Store edition does not check for updates by itself."),
            ]),
            Section(title: t("流量去向", "Where your traffic goes"), symbol: "arrow.triangle.branch", points: [
                t("网络流量按你的配置直接发往目标网站，或发往所选线路的服务器。",
                  "Traffic goes straight to its destination or to the server of the line you use, according to your configuration."),
                t("使用公司 VPN 线路时，需要你自己的公司账号，App 里不内置任何员工账号或密码。连接后，由公司的 VPN 网关负责认证，并转发经它的流量；网关会记录什么、保留多久、谁能查看，以公司的规定为准，不在本说明的范围内。",
                  "A company VPN line needs your own company account; the app ships with no employee account or password. Once connected, the company's VPN gateway authenticates you and forwards the traffic sent through it; what the gateway records, for how long and who can see it are governed by your company's policies and are outside this notice."),
                t("其他线路的服务器由你或你的服务提供方运营，如何处理数据以他们的政策为准。",
                  "Servers of other lines are run by you or your provider, whose own policies govern how they handle data."),
                t("连接 AnyConnect 线路时，按该协议向你的 VPN 服务器发送电脑名称、系统名称和版本、这台 Mac 的硬件标识，以及网卡的 MAC 地址；使用 Tailscale 线路时，一个随机生成的设备名和标准节点信息会发给 Tailscale 的服务器。",
                  "With an AnyConnect line, XDial sends your VPN server the computer name, the system name and version, this Mac's hardware identifier and the network adapter's MAC address, as that protocol requires; with a Tailscale line, a randomly generated device name and standard node information are sent to Tailscale's servers."),
            ]),
            Section(title: t("自动访问的公共服务", "Public services XDial contacts"), symbol: "network", points: services),
            Section(title: t("数据存储与同步", "Storage and sync"), symbol: "desktopcomputer", points: [
                t("iCloud 同步默认开启。确认本说明后，配置、已保存的 Wi-Fi 匹配规则、偏好、VPN 密码和订阅地址会同步到你的私人 iCloud，供同一 Apple 账号的设备使用。你可以在继续前或之后的设置中关闭同步。",
                  "iCloud Sync is on by default. After you confirm this notice, XDial syncs configuration, saved Wi-Fi matching rules, preferences, VPN passwords and subscription URLs to your private iCloud for devices using the same Apple Account. You can turn sync off before continuing or later in Settings."),
                t("当前连接的 Wi-Fi 名称只在这台 Mac 上用来匹配场景，不会发出去。macOS 读取 Wi-Fi 名称需要定位权限：只有你在前台主动设置时，XDial 才会申请「使用期间」的定位权限，也不读取位置。",
                  "The current Wi-Fi name is used on this Mac only, to match scenarios, and is never sent. macOS requires location access to read it: XDial asks for location access while in use only when you set this up in the foreground, and does not read your location."),
                t("连接记录和诊断信息（含出口 IP 地址）保存在本机，只有你主动导出或分享时才会离开 Mac；导出的配置文件包含你为场景登记的 Wi-Fi 名称。",
                  "Connection history and diagnostics (including exit IP addresses) stay on the Mac and leave it only when you export or share them; an exported configuration includes the Wi-Fi names you registered for scenarios."),
                t("通知和登录时启动默认关闭，只在你打开后生效；通知在本机产生。",
                  "Notifications and launch at login are off until you turn them on; notifications are created on the Mac."),
            ]),
            Section(title: CloudHostDisclosure.title(zh), symbol: "server.rack", points: CloudHostDisclosure.points(zh)),
        ]
    }
}
