# 企业 RuleSet 预设示例

`RuleSetPresets.example.json` 只演示公开 schema，并仅使用保留的 HTTPS 示例域名，不应
写入凭据、私有域名或真实规则地址。该预设目录不声明普通 RuleSet 的本地文件输入能力；
订阅 GEOIP 规则的本地 `file://` 模板在各平台的订阅编辑器中另行配置。

实际构建配置应保存在仓库外或企业私有仓库中，并在构建时通过
`XDIAL_RULE_SET_PRESETS_FILE=/absolute/path/RuleSetPresets.json` 注入。未设置该变量时，
构建脚本只尝试读取被忽略的 `macos/PrivateConfig/RuleSetPresets.json`；两处都不存在时，
应用使用内建的空白预设。

## 预置 Profile

企业包可在构建时通过 `XDIAL_SEED_PROFILE_FILE=/absolute/path/<名称>.json` 注入一份可移植
Profile 文档（与「导出配置」格式相同）；未设置时只尝试读取被忽略的
`macos/PrivateConfig/SeedProfile/<名称>.json`。文件名即 Profile 名称，与「从文件导入」一致。
显式指定的文件不存在或不是 `.json` 时构建失败。

同名预置在共享配置目录的 `seed-profiles.json` 中记录它对应的 Profile 和内容指纹；该记录不写进
配置库，因为旧版本保存配置库时会丢弃不认识的字段。

- 配置库和旧版配置都不存在时，以它创建首个配置，场景保持原名。
- 已有配置库且尚未记录时，像「从文件导入」一样把它加在现有 Profile 旁边，场景以「<名称> · <场景>」
  加入；不改变当前场景、正在编辑的配置或运行中的连接。
- 已记录且内容变化时，像订阅刷新一样覆盖它拥有的线路、规则和场景路由，保留用户填写的密码等凭据、
  场景名称和图标；新增场景照常加入，预置不再声明的场景作为用户自己的场景保留。
- 用户删除了对应 Profile 时不再加入。
- 已被其他场景占用的 Wi-Fi 触发留在原场景，预置场景上去掉该触发。

文档不得包含密码等凭据，用户首次连接前在首页账号表单中填写。

## 与手机共用一份预置

企业包应只维护一份手机预置格式的 `Seed.json`（加可选的 `RuleSets/`），由 `XDIAL_PRIVATE_CONFIG_DIR`
指向（旧名 `XDIAL_IOS_PRIVATE_CONFIG_DIR` 仍可用）；iPhone、Mac 官网版和 App Store 版都从这个目录构建。
[`scripts/embed-private-seed.sh`](../scripts/embed-private-seed.sh) 把它嵌入为 `<profile_name>.json`：
`Seed.json` 顶层可选的 `profile_name` 就是 Mac 上的 Profile 名称（未写时为「Seed」），名称决定部署记录，
发版之间不要改。显式指定的 `XDIAL_SEED_PROFILE_FILE` 仍然优先。`RuleSets/` 随网络扩展安装
（官网版在系统扩展、App Store 版在 App 扩展），首次连接时为缺失的二进制规则提供离线副本。

手机预置格式与 iPhone 的更新方式相同：每个新 `revision` 只补齐缺少的线路、规则和场景，用户改过和删掉的
不动，当前场景不变；重复应用同一版不再改变配置。加在其他配置旁边的预置，后来补上的场景同样显示为「<名称> · <场景>」，与已有场景一致；
用户改过名的场景不动。预置在 `rule_set_history` 里记下改过内容的手动规则，用户没改过的那条换成新内容，改过的保留；`scenario_history` 对改过路由的场景同样处理，场景名称、图标和 Wi-Fi 触发不动（见[手机预置格式](../../ios/Examples/README.md#seedjson)）。唯一的例外是从旧桌面预置（没有 `revision` 的 Profile
文档）第一次换成手机预置时：Mac 45 及以前的内测包注入的是两场景的「公司」「国内」，这时对该预置创建过的
场景逐字段三方合并，名称、默认出口、规则与顺序、图标、Wi-Fi 触发仍等于旧预置时采用手机预置，用户改过的
字段保留，并在日志中逐个记下 `seed: <名称> kept the user's change: Scenario <ID> (<字段>)`，解释这台 Mac
为什么与手机不同。升级后得到与手机一致的「在公司」「在国内」「在国外」「在香港」和地区自动选择。

### 打包后检查

`cmd/xdial-seed` 按路由含义比较包内预置与来源，有差异就以非零状态退出：

```sh
go run ./cmd/xdial-seed check --authority <私有目录> --platform macos-store --bundle XDial.app --profile-name 心动
```

平台为 `ios`、`tvos`、`macos`（官网版）、`macos-store` 或 `desktop-legacy`（只认 Profile 文档的上游正式版）。
比较线路（不含凭据）、规则内容与顺序、场景的默认出口与绑定线路、地区对应和随包规则文件的 sha256。
只有平台声明的能力限制可以跳过，并在每次检查时打印；目前只有 `desktop-legacy` 声明了地区自动选择和随包规则。
`legacy-document` 从 `Seed.json` 生成这类旧版本使用的 Profile 文档，`--check` 发现手改漂移时失败。

### 安装与升级验收

预置或迁移逻辑有改动时，用一个 Debug 包（App Store 版需加 `SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG XDIAL_STORE"`）
在内存里跑一遍 App 启动时的预置决策，不读写钥匙串、配置库和预置记录：

```sh
XDial.app/Contents/MacOS/XDial --check-seed-acceptance <旧包的 SeedProfile 目录> <输出目录>
go run ./cmd/xdial-seed effective --report <输出目录>/upgrade.json
```

依次写出全新安装（`fresh`）、从旧包升级且用户填了账号并手动选过场景（`upgrade`）、旧包加在用户自己的配置旁边且改过
一个场景（`beside`）、用户删掉了旧预置（`deleted`）。每份报告都带着同一份预置按同一个 Profile 导入的结果，
`effective` 按路由含义比较两者；`beside` 只应在用户改过的场景上不同，并且 `notes` 列出保留的字段。
App Store 版是沙盒应用，旧预置目录和输出目录要放在它的容器里（`~/Library/Containers/<包名>/Data/tmp/`）。

未注入预置时，新安装使用起步线路，用户在设置中添加或导入场景。
