# macOS 构建与安装

## Apple 平台的 TestFlight 身份

iOS、原生 macOS 和 tvOS使用同一条 XDial App Store Connect 记录（Apple ID `6835229250`）。
各平台商店构建的宿主 bundle ID 均为 `com.xd.xdial.ios`。扩展保留各自的子标识。
macOS Developer ID 独立分发版沿用 `com.xd.xdial.app`，Debug 使用 `com.xd.xdial.debug`。

macOS 平台已在该记录中建立，首个版本为 0.1.0。验证交付时须按平台查看 TestFlight 构建，
确认列出 macOS 以及目标测试组。iOS 构建可在 Apple 芯片 Mac 上运行，两者在后台分别列出。

商店构建使用 `macos/store.yml`，将桌面透明代理打为随宿主交付的 app extension。
宿主与扩展通过 App Group 交换事务记录，分别写入计划与 Provider 的实际进度。宿主进程内运行
Tailscale 登录会话，设置窗口由菜单栏主程序显示。Developer ID 与 Debug 的系统级安装流程独立维护。

构建时先运行 `make libbox-macos-xcframework` 和 `cd macos && xcodegen generate --spec store.yml`，
再通过 `XDialStore` scheme 归档。传入 `CURRENT_PROJECT_VERSION` 与 `XDIAL_SOURCE_REVISION`。
企业种子与 iPhone 共用私有打包仓库的同一个目录（`XDIAL_PRIVATE_CONFIG_DIR`），由
`macos/scripts/embed-private-seed.sh` 嵌入，归档后用 `cmd/xdial-seed check` 核对，见 [Mac 预置说明](../../macos/Examples/README.md#与手机共用一份预置)。宿主、扩展分别使用
Mac App Store 描述文件及 Apple Distribution 签名，上传包使用 Mac Installer Distribution 签名。

商店构建分两种配置，`ios/project.yml` 和 `macos/store.yml` 相同：
- **TestFlight**：用 `Release` 配置，主程序和 iOS 隧道扩展预填 `ITSAppUsesNonExemptEncryption = false`，上传后不再询问出口合规。
- **正式上架**：用 `-configuration AppStore` 归档。它与 `Release` 相同，只是各目标都不写这个键，由 App Store Connect 按实际发行地区回答。

预填 `false` 的前提是只用标准加密，并且不在法国商店分发；正式归档不能沿用它。


Apple TV 正式包定位为公司内部使用，保留企业预置；从 `appletv/project.yml` 生成。
先用 `make libbox-xcframework` 构建 tvOS 引擎，将与实际链接版本核对过的许可文本放入
`appletv/StoreResources/ThirdPartyNotices.txt`，再运行 `xcodegen generate --spec appletv/project.yml`。
使用 `XDialTV` scheme、Release、`generic/platform=tvOS` 和获授权的 tvOS 签名配置归档。
通过构建设置 `XDIAL_PRIVATE_CONFIG_DIR=<授权私有目录>` 注入与手机同来源的 `Seed.json`、可选 `RuleSets/`；
不指定时生成无预置包，且清除上次构建留下的预置。私有内容、签名配置与凭据不得提交公开仓库。

启动时由 `MobileSeed` 读取包内预置并传给 AppState，首启采用它；升级按 `revision` 添加缺失对象，
保留用户凭据、修改和当前场景，使用 `rule_set_history` 与 `scenario_history` 保护已修改的规则和场景路由，每个 revision 成功落盘后才记账。
连接前随包规则进入同一引擎缓存。Release 使用真实引擎；模拟器 Debug 的演示数据不得覆盖公司预置。
tvOS 当前不执行手机的按出口地区自动选场景；`region_scenarios` 随同来源保留并校验，电视上由用户选择场景。

分发前对归档和解开的 IPA **分别**验实际 `.app`，不能只检查构建设置或来源目录：

```sh
# 公司包：必须提供授权来源，严格核对 seed（含 revision/迁移历史）与规则内容
python3 scripts/verify-tvos-store-app.py <XDialTV.app> --seed-authority <授权私有目录>
# 无预置包：独立路径，必须不含 seed、随包规则或签名私密输入
python3 scripts/verify-tvos-store-app.py <XDialTV.app>
```

两种路径均核对宿主与扩展的 XD 身份、签名、真实引擎、图标、隐私清单和无 LAN 实验。
公司模式同时运行 `cmd/xdial-seed check --platform tvos` 校验移动格式和同来源规则，不能跳过 seed 校验。
新公司正式包必须重新构建并采用新构建号，不得把旧 tvOS 70 当作最终交付。
分发渠道由 Dash 另选；真机 VPN 授权、连接和断开、GPL 与版权仍需独立核实，脚本通过不等于已获分发许可。

Android 的固定工具链、可安装测试包、签名校验与事件驱动 CI 见
[Android 构建与测试分发](android-release.md)。两端构建入口不互相安装或重启。

日常 Debug 由 `make app`（等同 `make app-debug`）生成 `build/XDial Debug.app`，使用 Apple Development 签名，
不提交公证。`FormalDevelopment` 保留正式身份，仅用于该身份的专项验证。
正式归档由 `make release` 生成，签名、公证与发布机制见 [updates.md](updates.md)。
编译期只有 Debug 与正式两个身份；beta 发布使用正式身份，不另设构建配置。`make app` 只接受
`DEVELOPMENT_CHANNEL=debug`（默认值），传入其他值直接报错。

## 通道身份

| 所有权 | Debug | 正式身份 |
|---|---|---|
| 安装路径 | `/Applications/XDial Debug.app` | `/Applications/XDial.app` |
| 系统设置显示名（App / 网络扩展） | `XDial Debug` / `XDial Debug Network Extension` | `XDial` / `XDial Network Extension` |
| Host | `com.xd.xdial.debug` | `com.xd.xdial.app` |
| Settings UI / Extension / Helper / Daemon | Host 加 `.settings-ui` / `.transparent-proxy` / `.helper` / `.daemon` | 同左 |
| 通道偏好域 | `com.kafeifei.xdial.debug` | `com.kafeifei.xdial` |
| 通道运行目录 | `~/.xdial-debug` | `~/.xdial` |
| 新版共享配置 / 密钥 service | `~/.xdial/configuration/profiles.enc` / `com.xd.xdial.configuration` | 同左 |
| helper 状态目录 | `/Library/Application Support/XDial Debug` | `/Library/Application Support/XDial` |
| App Group | `SX9RG894L5.com.xd.xdial.debug.network` | `SX9RG894L5.com.xd.xdial.network` |
| helper socket | `/tmp/xdial-debug.sock` | `/tmp/xdial.sock` |
| 诊断 HTTP | `127.0.0.1:19877` | 当前构建不包含；旧正式身份 Debug 可能使用 `19876` |

新版 Profile 库跨通道共享，首次转换和显式删除数据的边界见 [Profile 配置库](profiles.md)。
系统组件及运行目录仍独立，Debug 不消费正式更新包。身份定义在
[XDialBuildIdentity.swift](../../macos/Shared/XDialBuildIdentity.swift)；通道隔离合同见
[ARCHITECTURE.md](../../ARCHITECTURE.md)。独立安装不表示两个数据面同时接管已经过验证。
显示名只来自 `XDIAL_PRODUCT_DISPLAY_NAME`，各组件的 `.lproj/InfoPlist.strings` 不得定义名字键，所以中文系统里扩展名也是英文；
开发构建、CI 构建和正式归档都经 [verify-macos-component-names.py](../../scripts/verify-macos-component-names.py) 只读核对。

## 签名与构建产物

Debug 的开发证书与 host、extension provisioning profiles 必须匹配 Debug identity。
已登录开发者账号的 Xcode 可通过下列构建参数创建或更新签名资源，该参数会访问 Apple
开发者账号服务：

```sh
make app-debug MACOS_DEBUG_XCODEBUILD_FLAGS=-allowProvisioningUpdates
```

Xcode 没有登录账号时，也可以用团队的 App Store Connect API 密钥代替账号（密钥文件不进仓库）：

```sh
make app-debug MACOS_DEBUG_XCODEBUILD_FLAGS="-allowProvisioningUpdates \
  -authenticationKeyPath <AuthKey_XXXX.p8> -authenticationKeyID <密钥 ID> -authenticationKeyIssuerID <Issuer ID>"
```

首次安装 Debug 时，App 只放进 `/Applications` 并启动，不会自动安装 helper 和网络扩展；
需要在菜单栏的 XDial Debug 里点安装，并在系统设置中批准后台项目和系统扩展。在此之前
`make restart` 会停在「runtime did not converge」，这不是构建问题。

开发构建入口末尾的 [verify-macos-debug-app.py](../../scripts/verify-macos-debug-app.py)
校验嵌套组件身份、签名、开发 profile、App Group、daemon plist 与 helper 编译通道，
不启动 App。host、Settings UI 和 extension 使用同次构建的 `DEBUG_BUILD_VERSION`，
默认取 Unix 时间戳；构建号用于系统识别扩展升级，不等于源码提交。

## 安装命令的实际效果

| 入口 | 实际效果 |
|---|---|
| `make app` / `make app-debug` | 构建并校验 Debug 开发候选包，不替换 `/Applications`，不启动 App |
| 候选包的 `Contents/MacOS/XDial --install-only` | 安装到该通道的 `/Applications` 路径；替换时终止同通道旧 App，并维护旧 helper；不启动后继 App |
| `make restart` | 完整构建 Debug 后退出旧 Debug、安装、启动最终 App，等待安装与连接意图收敛 |
| 从 `/Applications` 外正常启动 App | 自动定位、替换同通道安装并启动最终 App，不是隔离的源码运行 |

`make restart` 在构建前和安装前各运行一次只读的 [check-debug-rollback.sh](../../scripts/check-debug-rollback.sh)：
已装 Debug 的 `XDialSourceRevision` 不是当前 HEAD 的祖先时，列出会被丢掉的提交并停止；读不到修订或本地没有该提交时同样停止
（后者先 `git fetch`）。被拒时，这些提交都已在 `origin/main` 上，就先合入最新 main；否则它们属于别的分支尚未合入的工作，
或本分支 amend / rebase 前的旧提交（列表用 `=` 标出 HEAD 已有同样改动的提交），不要合进当前工作分支，
先和用户确认，再设 `ALLOW_DEBUG_ROLLBACK=1` 显式放行。修订取构建时的 HEAD，不记录未提交的改动。

Debug 曾安装为 `/Applications/XDail Debug.app`。新包发现该路径上签名相同的 Debug 时，先结束旧 App，
由新包注销旧容器注册的 helper，再装到新路径；新版 helper 与 System Extension 就绪后才把旧包移入废纸篓，
仍有进程占用时留给下一次安装事务。正式版按新旧两个路径识别 Debug；此前发布的版本只认旧路径，
新 Debug 运行期间它们的 helper 维护会因进程状态未知而停止，退出 Debug 后恢复。

替换安装总是先请求注销旧 helper，因为新包读到的注册状态可能看不到旧容器的注册。
旧 helper 根本没有注册时，macOS 会以 `SMAppServiceErrorDomain Code=1` 拒绝注销；只有前后
状态都是未注册、没有属于该 bundle 的 helper 进程、且 `launchctl print system/<label>`
明确返回不存在（113）时，才接受这次拒绝并继续替换。任一事实未知仍保留原应用并停止。

`--install-only` 不提供保留旧进程或连接的安装能力。实现见
[ApplicationRelocator.swift](../../macos/Sources/XDial/ApplicationRelocator.swift)；
既有重启脚本的交接和验收见 [restart-macos-app.sh](../../scripts/restart-macos-app.sh)。
该脚本在新事务提交后执行一次 HTTPS 检查，目标由 `XDIAL_RESTART_PROBE_URL` 指定，
未设置时为 `https://www.apple.com/`；这次访问仅反映该目标的当前路径结果。

daemon plist 使用标准 `Program` 指向各通道的固定安装路径，保留 SMAppService 的
注册、批准和签名检查。App 在注册前已完成 `/Applications` 定位，不使用依赖后台项目
容器记录的 `BundleProgram` 路径解析。构建门禁校验这一路径与通道身份一致。

不要另写临时脚本交换正在注册的 App 容器来代替产品安装事务。保留运行中的版本时，
先保留已验证候选包，等允许升级时通过安装入口完成旧服务退出、文件替换及新服务验证。
磁盘替换和签名通过均不能替代这笔事务；服务报告 ready 还需实际 PID 和运行 hash 匹配。

候选包校验、磁盘安装、Host 进程与实际运行的 Provider 是不同状态。新扩展代码只有在
系统激活对应扩展后才生效；安装报告与运行态字段见 [debug-server.md](debug-server.md)。

## 开发机 Next 残留清理

Next 身份已移除，产品不再把它当作已知的兄弟版本；它从未分发，只可能残留在开发机上。
Next 的旧配置仍是首次只读迁移的来源，也仍在“删除数据”的清单里，所以下面只做定点清理。
以下路径记录已退役版本的历史身份，不随当前产品的团队和包名迁移。

1. 先只读自查，有输出才需要处理：

   ```sh
   ls -d "/Applications/XDial Next.app" ~/.xdial-next ~/Library/Preferences/com.kafeifei.xdial.next.plist \
     ~/Library/Logs/"XDial Next" ~/Library/"Application Support"/"XDial Next" \
     "/Library/Application Support/XDial Next" \
     ~/Library/"Group Containers"/UVZM439VGU.com.kafeifei.xdial.next.network \
     ~/Library/"Application Scripts"/UVZM439VGU.com.kafeifei.xdial.next.network 2>/dev/null
   ls -a /Applications | grep '^\.XDial-next\.'
   sudo ls -d "/private/var/root/Library/Group Containers/UVZM439VGU.com.kafeifei.xdial.next.network" 2>/dev/null
   find /tmp/ -maxdepth 1 -name 'xdial-next*'
   security find-generic-password -s com.kafeifei.xdial.next >/dev/null 2>&1 && echo "keychain item present"
   systemextensionsctl list | grep -F com.kafeifei.xdial.next
   launchctl print system/com.kafeifei.xdial.next.daemon >/dev/null 2>&1 && echo "daemon loaded"
   launchctl print-disabled system | grep -F com.kafeifei.xdial.next
   pgrep -fl 'XDial Next\.app|xdial-next|xdial\.next'
   ```

   `/Applications` 下以 `.XDial-next.` 开头的是安装锁，以及安装事务中断后留下的 `.install-*`、`.backup-*`、
   `.transaction-*`。`pgrep` 要同时匹配 App、Settings UI、扩展和 root 常驻的 helper：helper 的命令行只有
   `xdial-daemon daemon --socket /tmp/xdial-next.sock`，不含 `XDial Next.app`。

2. `XDial Next.app` 还在时，用它自己的卸载流程卸载，**不要勾选“同时删除新旧版本的配置与密码”**。
   这一步会注销 Next 的 helper。
3. 卸载后扩展可能显示 `terminated waiting to uninstall on reboot`，重启后由系统移除。
4. 删 Next 的旧配置前，在 Debug 或正式版的配置窗口确认 Next 用过的 Profile 都已在共享库里；共享库已经存在时也要确认。
   共享库只在 `~/.xdial/configuration/profiles.enc` 不存在时由首启转换建立一次：整库复制 `.xdial`、`.xdial-debug`、
   `.xdial-next` 中修改时间最新的 `profiles.enc`（用对应身份的钥匙串项解密），建立后不再读 `~/.xdial-next`。
   共享库当初从 `.xdial` 或 `.xdial-debug` 转换而来时，Next 的多 Profile 配置库从没进过共享库。
   `ls ~/.xdial/configuration/profiles.enc` 没有输出时，先启动一次 Debug 或正式版完成首启转换，再确认。
5. 不要用任何版本的“卸载并删除数据”清理 Next：它会同时删掉所有版本共用的配置库、正式版与 Debug
   的旧数据和全部配置密钥，还会卸载执行它的那个 App。只用定点命令。第 4 步确认 Profile 都在时：

   ```sh
   rm -rf ~/.xdial-next
   defaults delete com.kafeifei.xdial.next
   security delete-generic-password -s com.kafeifei.xdial.next   # 重复执行，直到提示找不到
   ```

   缺 Profile 或无法确认时不要删：`~/.xdial-next`、它的偏好设置和钥匙串项可能是 Next 配置库仅有的一份，
   删掉无法恢复。只把目录改名备份，偏好设置和钥匙串项都先保留；备份里的 `profiles.enc` 要用钥匙串项
   `com.kafeifei.xdial.next` 里的密钥解密：

   ```sh
   mv ~/.xdial-next ~/.xdial-next.bak-$(date +%Y%m%d)
   ```

   保留备份期间，卸载任何版本都不要勾选“同时删除新旧版本的配置与密码”，它会删掉这个钥匙串项。确认不再需要备份后，
   再删除备份目录，并执行上面的 `defaults delete` 和 `security delete-generic-password`。

6. 其余路径按第 1 步的结果手动删除：两处 App Group 容器（root 那份需要 `sudo`）及
   `~/Library/Application Scripts` 下的同名目录、`~/Library/Logs/XDial Next`、`~/Library/Application Support/XDial Next`、
   root 属主的 `/Library/Application Support/XDial Next`、`/Applications` 下以 `.XDial-next.` 开头的文件和目录，
   以及 `/tmp/xdial-next*`。`launchctl print-disabled` 里只剩的启用记录不对应已加载的服务，可以不处理。
7. 升级 Debug 或正式版前，确认第 1 步的 `pgrep` 没有输出。Next 不再是已知的兄弟身份，它的 App 和 helper
   都会让 helper 维护停在“进程状态未知”；这只暂停维护，不会结束任何进程。Next 的 helper 是 KeepAlive 的
   root daemon，退出 App 不会停止它，用 Next 自己的卸载流程注销 helper 后才恢复。`XDial Next.app` 已被直接删除、
   helper 仍在运行时，重启 Mac：helper 的 launchd plist 和程序都在已删除的包里，重启后不会再被拉起（按
   SMAppService 的机制推断）。

另外：Apple 开发者后台里 Next 的 App ID、App Group 和两份 Developer ID profile 可以作废；
tailnet 里 `xdial-next-*` 的陈旧设备可以手动删除；本地 `build/` 下名字含 `next` 的目录可以删除。


## 包体测量

iOS、tvOS 和 Mac 商店版将同一架构的 Libbox 动态框架嵌入宿主一次，网络扩展通过宿主的 Frameworks 路径加载。每个进程仍有独立的 Go 运行时。框架 dSYM 随 xcarchive 归档。核对依赖许可时，对新包运行 `go version -m <app>/Frameworks/Libbox.framework/Libbox`（Mac 在 Contents/Frameworks），旧静态包仍从宿主及扩展可执行文件取清单。独立分发的 Mac System Extension 由系统另行安装，继续静态链接。

CI 摘要比较同平台、同产物与 PR 基线的 MB 差值，并列出最大的三个文件。Apple 的压缩数是未加密 App 的 ZIP 估算值，商店设备下载和安装数以 App Store Connect 为准；Android 使用单架构 APK，Linux 使用服务 tar.gz。Windows 首个可分发 ZIP 可复用 `scripts/package-size.py`；目前没有安装包基线。
