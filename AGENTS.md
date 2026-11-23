# XDial

macOS 菜单栏网络分流工具；iOS / tvOS 共用 Go 核心。

修改完成后合入最新 main，验证后直接覆盖安装并重启 Debug；`make restart` 会拒绝回退已装 Debug 里尚未进 main 的提交。

## 仓库关系

- 本仓库（`xindong/XDial`，remote `origin`）独立维护：工作分支推到这里，PR 只开向这里的 `main`。
- 上游 `kafeifei/XDial`（remote `upstream`）只作参考：需要时把它的改动合进来，不向它推送、不向它提 PR。
  fork 里 `gh pr create` 默认指向上游，必须显式带 `--repo xindong/XDial`。
- 本仓库的 macOS / iOS 产品使用 XD Entertainment 的签名身份；公开的团队 ID、包名和 App Group 随源码维护。
  这是本仓库独立维护的产品身份，不要求上游采用；其他打包方仍可覆盖构建设置。
- 企业专属的预置 Profile、随包规则和私有签名覆盖配置保存在企业私有仓库，打包时注入，不进本仓库。
  证书私钥、API 密钥、公证凭据和描述文件不进本仓库。提交前跑 `make public-content-gate`。

## 分支

| 分支 | 用途 | 规则 |
|---|---|---|
| `main` | 正式版基线，`vX.Y.Z` 从这里发布 | 只经 PR 合入；新工作从这里拉出 |
| 工作分支：`claude/*`、`codex/*`、`cindy/*`、`feature/*` | 单个修复或功能 | 从 main 拉出，PR 只开向 main；修复直接进 main，实验功能另合进 `xdial-beta` |
| `xdial-beta` | beta 线：main 加上实验功能，与正式版同一身份、靠更新源区分 | 只接收 main 和工作分支的合并，不从它拉分支、不合回 main；打 `vX.Y.Z-beta.N` 标签由 CI 构建 prerelease，`make publish RELEASE_CHANNEL=beta` 写入 beta.json，见[更新与发布](docs/agent/updates.md#beta-发布机制) |

Debug 从正在验证的工作分支构建（已合入最新 main），没有 Debug 专用分支；确需回退已装 Debug 时设 `ALLOW_DEBUG_ROLLBACK=1`。
main 回滚过的功能要进 beta，先在 `xdial-beta` 上撤销那次回滚，再合入该功能分支。

## 核心边界

- 各端共有的连接行为在 Go 核心维护。平台适配负责上报网络事实、执行系统连接事务和展示状态；新增恢复规则要覆盖所有已有连接入口。
- XDial 表达、编译和托管；sing-box 独占 DNS、路由和转发裁决。平台层只提供系统接入与网络事实。
- Ingress / Line / RuleSet / Scenario 正交；Scenario 是用户流量的唯一绑定点，声明不等于生效。
- 已知目标先确定 Line，再经该 Line 解析和连接；资源获取与 MagicDNS 的窄例外见架构。
- 启动前的系统网络是完整、不透明的 Underlay；XDial 不识别网络产品、不重排接口、不散落 DNS / 路由策略。
- 安装、连接、场景切换各有独立事务。候选切换准备期间，旧连接继续承载流量。
- 各版本共享用户 Profile 配置库；首次只读转换旧配置，旧文件不写回。勾选卸载删除数据时清理新旧配置及凭据。
- Debug 与正式版的系统组件、运行状态和维护事务仍独立；不得因配置迁移重启或改变现有网络。

## 项目资料

| 内容 | 来源 |
|---|---|
| 所有权、DNS、Underlay、事务与协议边界 | [ARCHITECTURE.md](ARCHITECTURE.md) |
| 产品表面、状态和交互 | [DESIGN.md](DESIGN.md) |
| 构建产物、签名与安装副作用 | [本地开发](docs/agent/development-builds.md)、[Makefile](Makefile) |
| 更新协议与发布机制 | [更新与发布](docs/agent/updates.md) |
| 诊断接口与运行事实 | [Debug Server](docs/agent/debug-server.md)、[Tailscale 证据](docs/verification/tailscale.md) |
| 架构不变量 | [core/config/invariants_test.go](core/config/invariants_test.go) |
| 历史事故 | [docs/incidents/](docs/incidents/) |

上游依赖版本见 [go.mod](go.mod)；本地差异由 [补丁构建入口](scripts/prepare-patched-go-mod.sh) 组装，`third_party/` 保留上游源码。
