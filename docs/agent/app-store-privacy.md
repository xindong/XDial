# App Store 隐私对账（iPhone）

公开版的数据使用说明（`ios/XDialIOS/DataUseNoticeView.swift`）、隐私政策与 App Store 隐私标签都以这份清单为准。
代码新增或改变对外请求时，同步更新这里、说明文案与 `AppState.dataUseNoticeVersion`。

## 自动访问的第三方服务

| 用途 | 目标 | 进程 | 何时 | 代码 |
|---|---|---|---|---|
| 域名解析 | Cloudflare 1.1.1.1:53，未加密 UDP；AnyConnect 线路改用其下发的 DNS；Tailscale 名称由 Tailscale 解析 | 扩展 | 连接期间的所有设备查询 | `core/config/generator.go`（公共 DNS）、`core/libbox/mobile_dns_transport.go` |
| 连通性检测 | `1.0.0.1/cdn-cgi/trace`、`1.1.1.1/cdn-cgi/trace`、`www.apple.com/library/test/success.html`；首个失败时 `223.5.5.5` | App | 每次连接与连接变差时 | `appletv/XDialTV/TunnelManager.swift`、`appletv/XDialTV/MobileProfile.swift` |
| 节点测速 | `www.gstatic.com/generate_204`（或订阅指定） | 扩展 | 连接期间每 300 秒（自动选节点） | `core/config/generator.go` |
| 出口地址 | `checkip.amazonaws.com`，其次 `1.1.1.1/cdn-cgi/trace` | 扩展 | 每次连接，按线路 | `core/libbox/libbox.go` |
| 出口地区 | `gspe1-ssl.ls.apple.com/pep/gcc`，其次 Cloudflare trace | App / 扩展 | 仅当预置带 `region_scenarios`（公开版没有，不会发生） | `core/libbox/exit_country_probe.go`、`ios/XDialIOS/ScenarioAutoPilot.swift` |
| 规则文件 | 配置写明的地址（如 `raw.githubusercontent.com`） | App | 连接时缺少缓存才下载 | `core/libbox/configgen.go` |
| 订阅 | 用户填写的地址 | App | 仅用户添加或刷新时 | `core/libbox/subscription.go` |

对方都能看到设备的 IP 地址。DNS、连通性检测、节点测速、出口地址与出口地区这些固定服务的请求不带账号、密码或配置内容。
规则文件与订阅按用户或服务提供方给出的地址原样请求：地址里的令牌、URL 账号密码会发给该地址的服务方
（订阅见 `core/libbox/subscription.go`），说明文案要如实写出这一点。

## 发往用户自己的服务器

- AnyConnect：按协议发送设备名、网卡地址与由它们生成的设备标识（`build/patched-go/sslcon`，补丁见 `patches/sslcon`）。
- Tailscale：设备名与标准节点信息发往 Tailscale 控制服务器；不上传日志（tailscale fork 固定 `NoLogsNoSupport`）。

## iCloud 同步的默认设置

三端默认开启同步。每台设备在确认新版说明后开始，用户可在继续前或之后关闭，并保留已保存的关闭选择。开启时主 App 将配置、订阅地址、VPN 凭据、已保存的 Wi-Fi 匹配规则和偏好写入同一 Apple 账号的 CloudKit 私有数据库。运行日志、系统授权、当前网络观测和 Tailscale 节点身份保存在本机。

## 本机存储

账号与密码在钥匙串；Wi-Fi 名称只在本机比对场景。可选的地点场景请求使用期间定位授权，在 VPN 连接期间支持后台匹配，所存地点不随配置导出。单独开启后台网速也会请求使用期间定位授权，VPN 连接时使用后台定位来保持采样，无需保存地点。连接时间线与诊断（含出口 IP）在 App Group，
只有用户导出或分享才离开设备；小组件、快捷指令、实时活动只显示连接状态和场景名；通知默认关闭、在本机产生。
客户端没有广告、分析、崩溃收集或追踪 SDK，也不向 XDial 开发者发送使用数据（说明里的承诺只限客户端）。公司 VPN 线路需要员工自己的账号，随包预置不含任何员工凭据；连接后由公司网关认证并转发流量，网关的记录、留存和访问权限以公司规定为准，说明不替公司作答。

## 隐私清单（PrivacyInfo.xcprivacy）

App 与 Packet Tunnel 扩展声明：UserDefaults（App：CA92.1、1C8F.1；扩展：1C8F.1）、SystemBootTime 35F9.1
（`ProcessInfo.systemUptime` 与 Go 运行时的 `mach_absolute_time`，用于计时）、FileTimestamp C617.1
（App Group 内缓存与状态文件的 `stat` 系列）。不收集数据类型，不追踪。

移动端 Libbox 以 `xdial_omit_tailssh` 标签构建（`Makefile` 的 `MOBILE_LIBBOX_TAGS`，
补丁 `patches/sing-box/0018`），不链接 Tailscale SSH 服务端，因此不含 SFTP 的磁盘空间 API（`statfs`）；
`make check-mobile-libbox-deps` 发现 `github.com/pkg/sftp` 时失败。核对方法：对 Release 真机包的
`XDial` 与 `XDialIOSTunnel` 运行 `xcrun nm -u`，只应出现已声明类别的符号。

## 我的云主机（仅在用户使用时）

用户在 iPhone 或 Mac 上使用「我的云主机」时：App 用用户填写的账号经 SSH 登录其服务器，凭据只在内存里；确认后服务器从
`deb.sagernet.org` 安装 sing-box；部署后的测试经该服务器请求 `www.gstatic.com/generate_204`、`1.1.1.1/cdn-cgi/trace` 和
`speed.cloudflare.com`（最多 10 MB、12 秒），这些服务看到的是服务器的 IP。数据使用说明有单独一节（版本 5），见
[添加我的云主机](cloud-host.md)。

# App Store 隐私对账（Mac）

Mac 商店版（`macos/store.yml`，`XDIAL_STORE`）的数据使用说明在 `macos/Sources/XDial/DataUseNotice.swift`。
它在启动时打开，确认前不准备系统组件、不连接、不做自动测速、订阅刷新和出口地区判断（`AppState.dataUseNoticeAccepted`）。
其他 Mac 版本仅在 iCloud 同步前要求确认说明。代码改变对外请求时，同步更新这里、说明文案与 `DataUseNoticeAcceptance.version`。

## 自动访问的第三方服务

| 用途 | 目标 | 进程 | 何时 | 代码 |
|---|---|---|---|---|
| 域名解析 | 直连域名与出站默认：本机系统 DNS（未加密）；走代理的域名：经该代理 DoH `1.1.1.1`；代理服务器域名：直连 DoH `223.5.5.5`；AnyConnect 规则用其下发的 DNS；Tailscale 用内存 MagicDNS | 扩展 | 连接期间 | `core/config/generator.go`（`1366-1437`、`538-546`） |
| 连通性检测 | 仅 TLS 握手：`[2606:4700:4700::1111]:443`、`[2001:4860:4860::8888]:443`（IPv6）；经各线路 `1.1.1.1:443`、`[2606:4700:4700::1111]:443` | 扩展 | 每次连接 | `macos/TransparentProxyExtension/UnderlayIPv6TLSProbe.swift`、`core/libbox/outbound_tls_probe.go` |
| 出口地址 | IPv4：`1.1.1.1/cdn-cgi/trace` 与 `r.inews.qq.com/api/ip2city`（`parseTencentProbeAddress` 只检查 `ret` 并取 `ip`，不读城市）；IPv6：Cloudflare trace；订阅、Tailscale、规则下载线路另用 `checkip.amazonaws.com`。不发送定位坐标或 SSID | 扩展 | 每次连接，按线路（含直连） | `core/libbox/libbox.go`（`outboundAddressProbeEndpoints*`）、`AppState.synchronizeLineObservations` |
| 线路测速 | `www.gstatic.com/generate_204`（或线路组指定） | App（未连接时临时实例）/ 扩展 | 当前场景的线路未连接时测一次；连接后自动组每 3–5 分钟 | `LineLatencyStore.ensureScenarioMeasurements`、`StandaloneLineLatencyService.swift`、`core/config/generator.go` |
| 出口地区 | `gspe1-ssl.ls.apple.com/pep/gcc`，其次 Cloudflare trace | App / 扩展 | 仅当预置带地区场景（公开版没有） | `UnderlayCountryLookup.swift`、`core/libbox/exit_country_probe.go` |
| 规则文件 | 规则集写明的地址 | 扩展 | 连接时缺少缓存，或缓存超过 24 小时 | `core/libbox/configgen.go` |
| 订阅 | 用户填写的地址 | App | 按订阅间隔自动刷新（默认 24 小时） | `ProfileDocumentService.refreshDueProfiles` |
| 更新 | 无 | — | 商店版不检查更新（`allowsAutomaticUpdates = false`） | `macos/Shared/XDialBuildIdentity.swift` |

对方都能看到 Mac 的 IP 地址。固定服务的请求不带账号、密码或配置内容；规则和订阅地址里的令牌、URL 账号密码会发给该地址的服务方。

## 与 iPhone 的差别

- AnyConnect 走桌面路径（`sslcon/auth/hostinfo_other.go`）：发送电脑名、系统名称与版本、硬件 UUID 和网卡 MAC 地址。
- Tailscale 设备名是随机的 `xdial-xxxxxxxx`；不上传日志。
- Wi-Fi 名称只在本机匹配场景。读取它需要定位权限：只在 App 位于前台、用户点「设置…」或为场景登记 Wi-Fi 时申请「使用期间」定位权限，不读取位置；导出配置时 Wi-Fi 名称随场景导出。
- 确认说明之前，手动更新或添加订阅、手动测速和自动恢复连接也都不会联网。升级时接管的已运行会话保持不变，但不切换场景、不查出口地址、不测速，确认后再补做。被说明拦下的连接在点「继续使用」后接着发起，选「稍后」则不再继续。
- 系统提示：首次连接时添加代理配置；通知和登录时启动只在用户打开后请求。

# App Store 隐私对账（Apple TV）

Apple TV 与 iPhone 共用 `appletv/XDialTV` 的 `AppState`、`TunnelManager` 和隧道扩展，自动访问的服务与上面 iPhone 的表格相同，以下几点除外：
- 不设置 `scenarioAutoPolicyProvider`，不按 Wi-Fi 或地区自动选场景，所以没有出口地区查询，也不读取 Wi-Fi 名称、不请求定位权限。
- 没有快捷指令、控制中心和通知。
- AnyConnect 走 `sslcon/auth/hostinfo_ios.go`：发送设备名（取不到时为 `xdial-appletv`）、设备类型 `Apple TV`、由它们算出的标识，以及网卡地址。

数据使用说明在 `appletv/XDialTV/TVDataUseNotice.swift`，首次打开时全屏显示，确认前不能连接（与 iPhone 共用 `AppState.dataUseNoticeAccepted`）。
Apple TV 没有浏览器，隐私政策地址以文字显示在说明页和设置 › 隐私里。

隐私清单：`appletv/XDialTV/PrivacyInfo.xcprivacy` 声明 UserDefaults CA92.1（`.standard`）与 1C8F.1（App Group）、SystemBootTime 35F9.1（`ProcessInfo.systemUptime` 计时、Go 运行时的 `mach_absolute_time`）、FileTimestamp C617.1（Go 的 `stat` 系列、`BundledRuleSets` 改写容器内规则文件的修改时间）；`appletv/XDialTVTunnel/PrivacyInfo.xcprivacy` 声明 UserDefaults 1C8F.1（只用 App Group）、SystemBootTime、FileTimestamp。
从 main 构建的 Release 二进制只引用 `fstat`、`fstatat`、`lstat`、`stat`、`mach_absolute_time` 与 `NSUserDefaults`；`statfs` 已随 #41 的 `xdial_omit_tailssh` 一起去掉（build 48 仍有，它早于 #41）。
