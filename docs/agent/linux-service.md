# Linux 原生服务构建与安装预览

本入口把共享 Profile/Scenario 编译、内核进程归因、TProxy、连接事务与捕获 journal 接在同一长期服务进程里。它是正在完成的桌面适配入口，**不是完整 Linux 图形客户端或多发行版发行版**。

## 构建（不安装、不改变网络）

使用 go.mod 指定的 Go 与已组装补丁：

```sh
bash scripts/prepare-patched-go-mod.sh
scripts/build-linux-service.sh amd64
```

产物在 `build/linux-service/amd64/`，另有 `xdial-service-linux-amd64.tar.gz`、SHA256、来源 manifest。`arm64` 是可选构建目标；没有实际运行证据时不能把交叉编译视作验收。manifest 如实包含 HEAD、dirty、工具链与各文件摘要；打包不会隐式签名、安装或发布。

## 明确的安装策略

包中的 `install.sh` 提供首次安装、升级、升级恢复和精确移除。运行前由管理员审查并预留 **两个不同的单 bit mark、空路由表、规则优先级和 IPv4 loopback 监听端口**，选择一个允许控制服务的非 root UID。源码不默认占用固定资源。连接时仍会检查冲突，不能以管理员预留替代内核检查。

安装脚本参数为 `install UID CAPTURE_BIT BYPASS_BIT TABLE PRIORITY LISTENER`；不提供可误用于用户网络的固定资源示例。它验证包摘要、安装父目录、并发锁和策略格式，写入 root 私有 `/var/lib/xdial-service/policy.json`，安装 `/usr/local/libexec/xdial-service` 与 systemd unit，执行 daemon-reload，**不会启动服务**。首次安装失败回滚本事务文件。已有安装必须使用独立的升级事务，不能重复 `install` 覆盖。

审查后管理员可执行 `systemctl enable --now xdial-service`。服务启动恢复 journal、开放本地控制接口，保持未连接；不保存 Profile 明文、不自动恢复连接。unit 需要 systemd；已在完整 Debian 13 来宾中执行首次安装、正常重启、强杀恢复和连接中移除，见[完整发行版证据](../verification/linux-distro-systemd.md)。Fedora 45（SELinux Enforcing）与 Arch 的安装、resolved 分域 DNS、生命周期、正常升级与启动失败回滚已在完整来宾验收，见[多发行版](../verification/linux-multidistro.md)；原生 NSS 路径仍待实现。

## 升级事务

管理员将审查过的新包解压到 root 所有且其他用户不可写的绝对目录，再从该包执行
`./install.sh upgrade`。这不是用户控制接口：普通用户不能提交包路径或安装操作。
包内 SHA256SUMS 用于完整性检查，不代替可信下载渠道或发行签名。

升级核对已安装二进制、unit、安装摘要及文件元数据；发现替换、drop-in（仅放行发行版
`/usr/lib/systemd/system/service.d/*.conf` 这类对所有 service 生效的 root 文件）、非普通
enabled/disabled 状态或已有恢复记录时拒绝。它保留 policy/cache 和 enablement，
将旧/新文件及恢复记录写入 root 私有目录并 fsync，然后停止服务、恢复捕获事务、
逐文件原子替换。原来运行中的服务重新启动后必须发出 systemd READY 通知才提交；
原来停止的服务保持停止，不能把这种情况称为新版本启动已验收。重启从未连接开始，
不恢复 VPN 连接意图。失败自动还原旧文件；回滚自身失败则保留记录供恢复。

进程被强杀后，从同一审查过的新包执行 `./install.sh recover-upgrade`。未提交的
事务还原旧版；已提交的事务核对新版本并清理备份。显式恢复保持服务停止，随后
管理员可自行启动。仅有提交前暂存文件时，恢复只清理暂存，不停止未被修改的旧服务。
未知文件、摘要或归属变化不会被覆盖或删除。重复恢复是幂等操作。

安装器持全局安装锁和状态目录独占锁；连接/场景切换持共享状态锁。未完成记录在
安装器退出后仍阻止新版服务的新连接，返回 `maintenance_required`；查询和主动断开不受此限制。
`remove` 也参与这两个锁，并拒绝跳过未完成升级。升级可执行程序必须来自新包，
不能依赖安装路径在半途已被替换后的程序。
首次从没有维护锁的旧版迁移时，旧进程在被停止前仍遵守旧版请求协议；停止与恢复
捕获完成后才替换文件，不能声称已给运行中的旧程序补上新锁。

完整 Debian 已验证实际包命令、启动失败回滚、九处强杀、安装文件被外部替换时拒绝、
维护期间用户断开、停止状态保留，以及最终包 TCP/DNS/卸载回归，见[升级证据](../verification/linux-upgrade.md)。

## 普通用户操作

允许的 UID 通过 `xdial-service status` 获取 `payload.instance` 和 `payload.revision`，再把两者传给修改请求：

```sh
xdial-service connect --instance INSTANCE_FROM_STATUS --revision REVISION_FROM_STATUS < profile.json
xdial-service switch --instance INSTANCE_FROM_STATUS --revision REVISION_FROM_STATUS < next-profile.json
xdial-service disconnect --instance INSTANCE_FROM_STATUS --revision REVISION_FROM_STATUS
```

Profile 由普通用户进程读取并通过有界 IPC 传递；服务不接受任意文件路径、shell、系统规则或裸 sing-box 配置。首次拨号时缺少可用网络会返回 `waiting_network`。服务在内存保留 Profile，网络恢复后重新检查维护锁、解析器和捕获条件再连接。手动断开会取消等待。服务重启产生新 instance；过期 instance/revision 不执行。`switch` 仍由共享核心一次提交 DNS/route，旧流有界排空。

IPC 使用 Unix seqpacket。每条消息验证内核 SCM_CREDENTIALS，连接时核对 SO_PEERCRED；移交/继承的连接不能借用原用户身份。客户端在发送 Profile 前固定核对服务 UID 0。socket 父目录 root 所有且不可写，独立端点锁防止不同 state 目录抢占，帧上限 64KiB/5 秒/32 连接。服务仅允许四种操作，不按客户端自报 PID/UID 授权。

## 停止、移除与恢复

停止先撤销捕获，再停核心；SIGKILL 后由内核撤掉 socket-owned nft 表，下一次启动按 journal 精确恢复剩余策略路由。恢复不是重新连接。发生所有权冲突保留现场并返回失败。

包中的 `install.sh remove` 先验证已安装二进制/unit 摘要，停止并禁用 unit，运行 `xdial-service recover --state /var/lib/xdial-service`，成功后才删除对应二进制和 unit。策略与缓存目录保留供审查，不按名称批量清规则、杀进程或删除用户配置。未执行过本任务宿主安装/卸载。

## 当前能力和明确缺口

- 实现 IPv4 TCP/UDP 透明接入；应用路径/路径前缀/精确进程名交给 sing-box 原生进程搜索器，不信客户端归因。macOS Bundle 和进程名通配符尚未适配，明确拒绝。
- Direct DNS 与代理服务器 bootstrap 使用捕获的系统 resolver；应用代理 DNS 仍由共享编译器绑定精确 Line。标记套接字由内核按目标选择完整 Underlay，不虚构默认网卡、不重排路由。
- 普通 resolver 文件仍仅支持一个非 loopback IPv4 nameserver；另外支持标准 `/run/systemd/resolve/stub-resolv.conf` 链接和真实 systemd-resolved 服务，保留系统的 per-link/split DNS。仅支持 DNS socket 入口；`nss-resolve`、未知 NSS hosts 模块和 nscd 共享缓存返回 `unsupported_native_resolver_ingress`，不能把共享进程查询冒充原应用身份。原生 NSS 适配仍待完成，服务不会替用户改写这些系统配置。
- resolved 模式只豁免经系统总线、PID 1、内核进程、stub socket 与 cgroup v2 验证的 resolver 依赖套接字，不按 UID 豁免；不接受客户端指定 resolver PID、cgroup 或接口。网络事实变化时先撤销旧捕获，再使用新快照恢复；解析器租约失效或出现不支持的 NSS 时结束连接。租约验证失败返回 `unsupported_resolver_dependency`，不回退公共 DNS。
- 仅允许经过共享编译和验证的离线规则缓存；尚无服务缓存导入/在线资源事务。客户端本地 file URL 和 NativeOptions 文件访问能力被拒绝，不能让 root 读取用户指定私有文件。
- AnyConnect/Tailscale 协议套接字与冷资源租约、IPv6、现有 mark/iptables 共存、GUI、完整配置库接线、多发行版安装/更新仍待完成。保留这些目标，不能将当前拒绝当作最终产品取舍。
- systemd unit 需要 `CAP_NET_BIND_SERVICE`，用于透明 UDP 回包绑定原目标的特权端口（如 DNS 53）；完整 Debian 负面/正面对照已验证。安装脚本不改变系统低端口阈值。

### 原生 DNS 后端边界

当前锁定 sing-box 的 `dns/transport/local/local_resolved_linux.go` 会读取默认接口的
resolved Link DNS，并为其创建绑定该接口的 transport；不能把直接启用这个 `local`
实现当作保留整个 Underlay 的 split DNS。本后端使用受保护的标准 stub，保留系统
域路由和 resolver 缓存；关闭盒内第二层 DNS cache，避免域路由变化后保留旧答案。
完整 Debian 中实际 split DNS、域路由变化、解析器重启和非 resolver cgroup 同 UID
进程的验收见[原生 resolver 证据](../verification/linux-resolved.md)。原生 NSS/显式
D-Bus/Varlink 请求的应用归因不在这份 DNS socket 证据内，不能声称默认 NSS 已适配。
