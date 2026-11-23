# Android 构建与测试分发

Android 与现有 Apple UI 共用 Go 核心，使用原生 VpnService。此文的构建/签名入口
不会安装 App、修改本机 VPN、上传文件或触发应用商店发布。

## 可重现构建入口

固定版本：Go 由 `go.mod` 指定；gomobile 由 Go module 指定；Gradle 9.4.1（wrapper
包含官方 SHA-256）、AGP 9.2.1、JDK 17、SDK platform 36、build-tools 36.0.0、NDK
27.1.12297006。完整 JDK 版本随产物记录。SDK 许可应在构建机器预先完成，脚本不会
代答许可或修改全局 SDK 设置。CI 使用 GitHub runner 已配置的 SDK 环境。

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/Android/sdk
# PATH 包含 go.mod 指定的 Go。Python >= 3.9。
python3 scripts/build-android.py --mode ci
```

该命令构建双 ABI AAR、通用 Debug APK、分别供 arm64-v8a 和 x86_64 侧载的 Release APK，并生成未签名 Play App Bundle。Release 两个 APK 分别验签、检查 ABI 和对齐；签名测试模式对两个包逐一签名。AAB 位于 `android/app/build/outputs/bundle/release/app-release.aab`，由 CI 单独归档。单独构建使用
`--mode debug` 或 `--mode unsigned`。Go 链接器剥离符号表与 DWARF，编译启用 trimpath，关闭路径相关的 VCS
自动元数据；源码 revision、dirty 状态及工具版本写入旁侧 manifest。

产物位于 `build/android/artifacts/` 的不可变子目录，包含 APK、`manifest.json`、
`SHA256SUMS`。目录名包含 APK 和 provenance 摘要；重复打包会校验既有文件，不能
覆盖先前交付。流水线只上传此目录，不上传工作区、规则缓存、凭据、签名文件或日志。

检查包括 APK CRC、实际包名/版本、API 26/36、arm64-v8a/x86_64、debuggable 标志、
16 KiB zipalign 和 apksigner 校验。Debug 可安装；unsigned Release 不可安装，不得
将其称为已签名测试包。`manifest.json` 中的 `distribution=local-artifact-only`
表示没有完成外部分发。CI 的 Debug key 可能随 runner 改变，不能作为长期更新身份。

“固定构建步骤”不等于跨机器字节完全相同：JDK 补丁版本、主机架构、签名材料也会影响
结果。本地连续两次构建的 APK 哈希已比对，跨主机字节复现仍须独立验证。

## 版本规则

- `android/version.properties` 保存人工版本名和本地 versionCode。所有 Gradle 入口
  使用同一份数据；版本覆盖仅接受有效 `XDIAL_ANDROID_VERSION_CODE/NAME`。
- CI code = `ciVersionCodeBase + GITHUB_RUN_NUMBER * 100 + GITHUB_RUN_ATTEMPT`。
  attempt 仅接受 1–99，code 上限 2100000000，越界拒绝，不能取模回退。
- 本地可用 `--version-code N` 指定候选编号。长期签名模式要求干净源码及显式编号
  （CI 则按上述公式）。先前 CI 工作流历史编号可能有间隔，不能假定从 1 开始。
- 签名渠道启用前，核对已发出的最大 code；以后若拆/重建 workflow 或更改 code base，
  必须继续高于已发出的值。不要重置同一应用身份的版本序列。
- main 与 beta 共享同一 CI 计数空间；PR 的编号不代表发布。后续发布器必须核对当前
  main SHA 和最大已发布 code，不能由较旧、晚完成的 job 回退“最新”下载入口。
- Debug 包名 `com.xd.xdial.android.debug`；Release/签名测试包名
  `com.xd.xdial.android`。二者系统 VPN、凭据和应用目录隔离；签名不会改变包名。

## 长期签名

用户于 2026-11-17 明确选择**复用已有 Android 签名和内部渠道**，不新建长期签名。
随后用户指定先参照 Cindy 或火炬 2 的安卓版；不再要求用户重新查找资产。
已只读核查两者当前本地源码和非秘密配置描述，结果如下：

- Cindy 的 `apps/mobile/scripts/build-android.mjs` 使用仓库外 keystore 自签 APK，
  `self-host-regions.json` 持非秘密签名描述，密码通过区域环境变量传入；构建与
  OSS/CDN 分发分开。当前本机主副本及已登记 worktree 未找到填好的 Android
  签名描述，不能把公开配置模板当作已经取得的内部发布渠道。
- 火炬 2 开发 APK 使用独立 debug key；Google Play 流程另有已存在的上传 keystore
  和服务账号。上传签名与 Play 安装包的应用签名是不同资产，不能把它视为 XDial
  已有的覆盖升级身份，也不能复用火炬 2 的包名或 Play listing。
- 可以复用仓库外资产、环境注入、独立证书指纹校验及“先构建、后分发”的方式；
  实际采用的证书和 XDial 专属受限下载位置仍须定位并核验。未复制私钥/密码，未调用
  商店上传、创建应用或改变现有渠道。具体机器位置不写入本公开仓库。

接入前核对证书指纹、包名、已分发最大版本号和下载访问控制。现有 Debug key 不能
升级为正式身份；有 CDN 地址也不等于有受限渠道。
密码通过主机保密输入或环境注入，不放聊天、源码、命令参数或 Gradle 配置。

签名候选需要以下环境变量（只给 apksigner 进程，构建子进程会剥除它们）：

| 变量 | 内容 |
|---|---|
| `XDIAL_ANDROID_KEYSTORE` | 仓库外的受保护 keystore 文件 |
| `XDIAL_ANDROID_KEY_ALIAS` | 证书别名 |
| `XDIAL_ANDROID_STORE_PASSWORD` | keystore 密码 |
| `XDIAL_ANDROID_KEY_PASSWORD` | 私钥密码 |
| `XDIAL_ANDROID_CERT_SHA256` | 预先确认的完整证书 SHA-256；不接受短指纹 |

```sh
# 先通过保密机制提供上表变量；此处不包含秘密。
python3 scripts/build-android.py --mode signed --version-code 100101
```

脚本签名已对齐 unsigned APK 的副本，再用 apksigner 验证并比对证书指纹，匹配后才
生成产物目录。Gradle 不接收签名密码，不将其保存在 daemon。错证书、签名失败或
APK 被修改均拒绝交付。日志只指向构建日志，不输出 signer 的错误详情/秘密。

签名契约测试使用临时目录的一天期测试证书，执行真实 keytool/apksigner，验证成功、
错误证书拒绝与签名后篡改拒绝；退出后删除，既不发布也不当作 XDial 的长期身份：

```sh
for abi in arm64-v8a x86_64; do
  XDIAL_ANDROID_TEST_ABI="$abi" \
  XDIAL_ANDROID_TEST_APK="$PWD/android/app/build/outputs/apk/release/app-$abi-release-unsigned.apk" \
    python3 -m unittest discover -s scripts/tests -p 'test_android_build.py' || exit 1
done
```

若候选 code 有覆盖，同时传 `XDIAL_ANDROID_TEST_CODE=N`；CI 自动读取同一 run 规则。

## 与 iOS 同步的事件路径

`.github/workflows/ci.yml` 现有 `push(main, xdial-beta)` 和 `pull_request` 增加 Android
job，使用同一 commit 事件构建双 ABI，并保存 7 天的 Debug/unsigned Release 产物。
没有定时轮询、额外 webhook、iOS 上传器或 App Store/Play 分发动作。PR job 不接触
长期签名；签名模式明确拒绝 `pull_request` 环境。

既有 GitHub App 驱动 iOS TestFlight 任务
`8b99a267-df49-432a-885b-668d36bd396a` / 自动化
`5bf44400-3dfc-4fca-8c3a-56bcab855db0` 保持不变。合入 main 后，Android CI 与该任务
对应同一 SHA；协调器将来只需关联 SHA 与各端产物，不能新增第二个 iOS 上传器。

**公共仓库的 Actions artifact 不是受限/私有分发。** 当前仅构建公开源码且不注入公司
配置；长期签名不接入此上传步骤。下一步的具体方案是：接入用户指定的已有 Android 签名，
受保护构建环境按 main 事件签名，再将通过完整检查的 APK/manifest 送至用户确认的
受限下载渠道。签名资产与渠道确认前，不开启该分发步骤，不发布 Play 正式版，也不
改变任何 Apple 分发范围。此分支尚未推送，因此仓库内 CI 改动尚无 GitHub 执行证据。

参考：[Android 构建产物](https://developer.android.com/build/build-for-release)、
[apksigner](https://developer.android.com/tools/apksigner)、
[Gradle 官方校验和](https://services.gradle.org/distributions/gradle-9.4.1-bin.zip.sha256)。
