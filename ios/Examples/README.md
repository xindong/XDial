# 手机版企业预置示例

`Seed.example.json` 只演示格式，用的都是保留的示例域名，不应写入凭据、私有域名或真实规则地址。
实际的预置配置保存在仓库外或企业私有仓库里，打包时带进 App。

每条线路和规则都要写明 `enabled`；trojan、shadowsocks、vmess 线路还要写明端口（以及 shadowsocks 的 `ss_method`）。
这些字段省略时，手机和 Mac 读出的默认值不同（例如手机当作启用，Mac 当作停用），`xdial-seed check` 会拒绝这样的预置。
共享预置也只能用手机能读的内容：规则类型只有 `url` 和 `manual`，格式为 `auto`、`srs`、`json` 或 `text`，
不支持 `invert`、`no_resolve`、`fetch_line_id`、按应用/进程匹配、分组条件、场景的 `match_order` 和订阅。
Mac 能读得更多，但用了这些内容时手机会丢掉或拒绝整个预置，所以检查直接拒绝。
规则对象要写全 `id`、`name`、`type`、`enabled`、`url`、`format`、`domains`、`cidrs`（手机解码需要每一项，没有的写空值）；
线路类型写 `shadowsocks`，不要写简称 `ss`。检查还按手机的规则核对引用：每个场景有且只有一条存在的默认线路，
绑定的规则和线路都要存在且不重复，地区只能是 `*` 或两个字母且不重复，规则地址必须是远程 HTTPS。
iPhone、Apple TV 和 Mac 包里必须是 `xdial-mobile-seed` 格式；只有旧版桌面包用普通的配置文档。

## 放在哪儿

构建时依次查找：

1. 构建设置 `XDIAL_PRIVATE_CONFIG_DIR`（旧名 `XDIAL_IOS_PRIVATE_CONFIG_DIR`）指向的目录（必须存在）。
   Mac 构建读取同一个目录，见 [Mac 预置说明](../../macos/Examples/README.md#与手机共用一份预置)。
2. 被忽略的 `ios/PrivateConfig/`。

目录里可以有：

| 文件 | 作用 |
|---|---|
| `Seed.json` | 预置配置。没有这个文件就什么都不带，App 用空白起步配置。 |
| `RuleSets/manifest.json` | 随包规则清单：规则地址 → 同目录下的文件名。 |
| `RuleSets/*.srs` | 随包的规则文件。 |

## Seed.json

```
{
  "format": "xdial-mobile-seed",
  "schema_version": 1,
  "revision": 1,
  "region_scenarios": { "JP": "场景 ID", "*": "其它地区用的场景 ID" },
  "profile": { … }
}
```

- `profile` 与 App 里「导出配置」的 `profile` 相同，校验规则也相同。不得包含账号密码，
  用户首次连接前自己填写。
- `revision` 是预置的版本。预置内容有增删时加一，已经装了旧包的用户升级后会补上新内容。
- `region_scenarios` 可选：网络出口所在的地区（两位代码）对应哪个场景，`*` 是没列出的地区。
  留空时 App 只按场景登记的 Wi-Fi 自动选场景，也不会去查网络出口。
- `profile_name` 可选：Mac 版嵌入时用作 Profile 名称（手机忽略）。同一份文件供所有平台打包，不要另维护副本。
- `rule_set_history` 可选：预置改了已有手动规则的域名或网段时，在这里按规则 ID 列出之前各版发过的内容
  （只有 `domains` 和 `cidrs`，不计顺序和大小写）。例如把 `shop.example.com` 移出「公司内网」：

  ```json
  "rule_set_history": {
    "intranet": [{ "domains": ["corp.example.com", "shop.example.com"], "cidrs": ["10.0.0.0/8"] }]
  }
  ```

  旧条目不要删，下次再改时把当时的内容加进列表。
- `scenario_history` 可选：预置改了已有场景的路由（默认出口、规则绑定或它们的顺序）时，在这里按场景 ID
  列出之前各版发过的路由：`default_line_id` 加按顺序的 `bindings`（每条只有 `rule_set_id` 和 `line_id`），
  引用的线路和规则必须在当前预置里。顺序要和当时一致，第一条命中的规则决定出口。例如在「在国外」最前面加一条直连规则：

  ```json
  "scenario_history": {
    "overseas": [{ "default_line_id": "direct",
                   "bindings": [{ "rule_set_id": "intranet", "line_id": "vpn" }] }]
  }
  ```

  同样不要删旧条目。名称、图标和 Wi-Fi 触发不在比较范围内，用户改过它们不妨碍换新路由，也不会被覆盖。

App 怎么用它：

- 本机没有配置：预置直接成为默认配置。「恢复默认配置」也回到它。
- 本机已有配置、且这个 `revision` 还没加过：只添加缺的线路、规则和场景，用户自己建的、
  改过的和当前选中的场景都不动。预置线路如果和已有线路是同一类型、同一个服务器，
  就沿用已有的那条。每个 `revision` 只加一次，用户之后删掉的不会再回来。
- `rule_set_history` 里列出的规则：用户的这条规则仍等于之前某一版发的内容（没改过）时换成新内容；
  改过的保留，并在日志记 `seed: kept the user's edits to rule <ID>`。
- `scenario_history` 里列出的场景：用户的这个场景的路由仍等于之前某一版发的（App 自己维护的连接验收绑定不算）时，
  换成预置的新默认出口和规则绑定；用户换过出口、调过规则或顺序、用了订阅出口或规则条件的保留，
  并在日志记 `seed: kept the user's edits to scenario <ID>`。新增规则和场景照旧只补一次。
  iPhone、Apple TV 和 Mac 规则相同。

## 随包规则

远程规则平时在连接前现下。所在网络下不到、本机又没有缓存时，连接会直接失败。
把规则文件放进 `RuleSets/` 并在 `manifest.json` 里登记地址，App 会在连接前把它放进缓存，
之后引擎照常自己更新。

## 换一个开发者团队打包

工程默认的应用身份写在 `ios/project.yml` 顶部。企业包不要改这个文件，
打包时用 `xcodebuild -xcconfig <文件>` 覆盖：

```
DEVELOPMENT_TEAM = <团队 ID>
XDIAL_BUNDLE_ID = <主程序包名>
XDIAL_APP_GROUP = <App Group>
XDIAL_SHARED_KEYCHAIN_GROUP = <团队 ID>.<钥匙串分组>
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Apple Distribution
XDIAL_PROFILE_APP = <主程序描述文件名>
XDIAL_PROFILE_TUNNEL = <隧道扩展描述文件名>
XDIAL_PROFILE_WIDGETS = <小组件描述文件名>
```

隧道扩展和小组件的包名是主程序包名加 `.tunnel`、`.widgets`。
