import NetworkExtension
import Network
@preconcurrency import Libbox
import os.log

/// NetworkExtension 的 completion handler 尚未标注 Sendable，但 provider 必须把阻塞的
/// Go 引擎工作移出系统回调队列。这个小盒子只负责跨队列携带不可变闭包。
private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// NetworkExtension 要求 startTunnel 的 completion 恰好调用一次。启动取消、
/// Go 回调与 NE 设置回调可能并发到达，因此不能只靠分支约定保证一次性。
private final class StartCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Error?) -> Void)?

    init(_ completion: @escaping (Error?) -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish(_ error: Error?) -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?(error)
        return callback != nil
    }
}

private final class StopCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(_ completion: @escaping () -> Void) {
        self.completion = completion
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
        return callback != nil
    }
}

/// XDial iOS / tvOS 的 packet-tunnel 扩展。
///
/// 进程内跑 Libbox(sslcon + gVisor + sing-box):
///   - `startTunnel` 建立到 AnyConnect 的连接、把 NE 的 packetFlow 文件描述符交给
///     sing-box 的 TUN inbound、配置 NEPacketTunnelNetworkSettings 后放行。
///   - `handleAppMessage` 承接 App(GoEngine.swift 的 sendProviderMessage)发来的
///     控制请求(start/stop/status/parse-sub),回一段 DaemonResponse JSON。
///
/// 通信/存储约定(与 GoEngine.swift、AppState.swift、core/libbox 对齐):
///   - App Group:规则文件的共享容器；启动配置只通过 start options 一次性交付。
///   - Libbox 绑定:LibboxNew(cb) → LibboxLibbox;start(server,username,password,configJSON)、
///     setTunFD(_:)、stop()、status()、isRunning()(见 core/libbox/libbox.go 的
///     gomobile 导出面,方法名遵循 gomobile 首字母小写惯例)。
final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {

    private static let appGroupID = XDialIdentity.appGroup
    private static let subsystem = XDialIdentity.tunnelBundleIdentifier

    /// 仅用于读取并清理早期版本留在 App Group 的启动参数。
    /// 新版本不会再写这些 key，完整配置统一通过一次性 start options 交付。
    private static let configKey = "xdial.tunnel.config"
    private static let serverKey = "xdial.tunnel.server"
    private static let usernameKey = "xdial.tunnel.username"
    private static let passwordKey = "xdial.tunnel.password"
    private static let diagnosticKey = "xdial.tunnel.diagnostic"

    private let log = OSLog(subsystem: subsystem, category: "provider")

    /// 进程内引擎实例。startTunnel 时创建,stopTunnel 时置空。
    private var libbox: LibboxLibbox?

    /// 引擎最近一次通过 Callback 报上来的错误文本(用于 status 响应带出)。
    private var lastError: String?

    private enum AttemptPhase {
        case idle
        case starting
        case running
    }

    /// NE 回调、Go 回调与后台启动线程会并发触碰启动生命周期。generation 使已经
    /// 被 stop 或后续 start 取代的异步结果失效；资源只由摘除它的路径负责清理。
    private let lifecycleLock = NSLock()
    private var activeGeneration: UInt64 = 0
    private var attemptPhase: AttemptPhase = .idle
    private var activeGenerationUsesSecureEnvelope = false
    private var startCompletion: StartCompletionGate?
    /// 当前引擎实例的编号（见 EngineCallback.engineToken）。0 表示没有可回调的实例。
    private var activeEngineToken: UInt64 = 0
    private var lastEngineToken: UInt64 = 0
    /// sslcon 的会话是进程全局资源。创建、StartResolved 与 Stop 必须经过同一
    /// 串行队列，不能让新 generation 与旧会话在底层并发。
    private let engineOperationQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.engine")
    /// 出口探针（线路试拨、出口地区）不改变引擎生命周期：libbox 为每次探针租用运行中的
    /// outbound，停止时会等租约归还，停止后再借会直接报错。放进串行队列只会让连接验收
    /// 一条条排队、和自动选场景的出口探测互相等待，所以单独并发执行。
    private let outboundProbeQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tunnel.outbound-probe",
        qos: .utility,
        attributes: .concurrent
    )
    /// 设置 job 连同原始系统 completion 严格串行；失效路径会在同一提交锁下
    /// 排入 barrier，因此新 generation 不会越过旧 generation 的未决设置。
    private let networkSettingsSubmissionLock = NSLock()
    private let networkSettingsOperationQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tunnel.network-settings"
    )
    private let networkSettingsCallbackQueue = DispatchQueue(
        label: "com.kafeifei.xdial.tunnel.network-settings-callback"
    )

    /// sing-box 的 direct/DNS 出站必须使用 NWPath 给出的完整 Underlay。
    /// 下层 VPN 会以 utun/ipsec/ppp 出现，不能按接口名前缀删除；Go 平台层只排除
    /// 当前 XDial 会话通过 RegisterMyInterface 明确登记的 packet tunnel。
    private let pathMonitorQueue = DispatchQueue(label: "xdial.path-monitor")
    private var pathMonitor: NWPathMonitor?
    private var diagnosticStage = "idle"
    private var activeAttemptID = ""
    /// Shared app/extension timeline; see ConnectionTimeline. Guarded by diagnosticLock.
    private let timeline = ConnectionTimelineStore.shared(appGroup: PacketTunnelProvider.appGroupID, writer: .tunnel)
    private var timelineSessionID = ""
    private var defaultInterfaceName = ""
    private var defaultInterfaceIndex = -1
    private var diagnosticSensitiveValues: [String] = []
    /// 最近一次发布给引擎的 Underlay（接口快照与默认接口），场景切换准备候选时使用。
    private var latestUnderlay: UnderlaySnapshot?
    private let diagnosticLock = NSLock()

    #if os(iOS)
    // MARK: 场景切换（iOS）
    /// 以下状态由 scenarioLock 保护。
    private let scenarioLock = NSLock()
    /// 当前承载流量的启动包；切换成功后替换。
    private var runningBundle: StartBundle?
    /// 当前系统隧道设置里的远端地址（AnyConnect 服务器 IP，独立连接时为 127.0.0.1）。
    private var runningRemoteAddress = "127.0.0.1"
    private var scenarioState = TunnelScenarioState()
    private var scenarioStateLoaded = false
    private var scenarioSwitchActive = false
    /// 切换进行中又来了网络变化：切完再判断一次。
    private var scenarioEvaluationPending = false
    private var lastPathSignature: String?
    private var settledSurvey: ScenarioSurveyContext.Settled?
    private var scenarioEvaluationWorkItem: DispatchWorkItem?
    /// 自动判断串行执行；读 Wi-Fi 名称、查出口都在这里等待，不占用引擎队列。
    private let scenarioQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.scenario")
    #endif
    private let diagnosticWriteQueue = DispatchQueue(label: "com.kafeifei.xdial.tunnel.diagnostics")

    // MARK: - Libbox 回调

    /// 桥接 LibboxCallbackProtocol → 本 provider。gomobile 生成的回调协议方法名
    /// 见 DebugSmokeTest.swift 里的 TestCallback(onStatusChanged / onError)。
    private final class EngineCallback: NSObject, LibboxCallbackProtocol {
        weak var provider: PacketTunnelProvider?
        let generation: UInt64
        /// 同一次连接里可能先后换过引擎实例（场景切换退回到换引擎时）。只处理当前实例的回调，
        /// 主动停掉的旧实例报上来的「已断开」不能被当成掉线。
        let engineToken: UInt64

        init(provider: PacketTunnelProvider, generation: UInt64, engineToken: UInt64) {
            self.provider = provider
            self.generation = generation
            self.engineToken = engineToken
        }
        func onStatusChanged(_ statusJSON: String?) {
            guard provider?.isCurrentEngine(engineToken) == true else { return }
            provider?.handleEngineStatus(statusJSON, generation: generation)
            os_log("libbox status changed", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .info)
        }
        func onError(_ code: Int, message: String?) {
            guard provider?.isCurrentEngine(engineToken) == true else { return }
            provider?.handleEngineError(code: code, message: message, generation: generation)
            os_log("libbox error code=%d", log: OSLog(subsystem: PacketTunnelProvider.subsystem, category: "provider"),
                   type: .error, code)
        }
    }

    // MARK: - startTunnel

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = StartCompletionGate(completionHandler)
        let generation = beginLifecycleAttempt(completion: completion)
        beginAttempt(options?["attemptID"] as? String ?? "")
        recordDiagnostic("start_begin")
        os_log("startTunnel: begin", log: log, type: .info)

        // 1) 取凭据与 sing-box 配置。手动启动使用一次性 options；系统按需冷启动
        //    没有 options，只允许读取双方共享 Keychain 中本次连接意图的版本化启动包。
        guard let bundle = resolveStartBundle(options: options) else {
            let err = providerError(2, "缺少完整的安全启动配置")
            failAttempt(generation, error: err, diagnosticStage: "start_bundle_missing")
            os_log("startTunnel: missing credentials/config", log: log, type: .error)
            return
        }
        setSecureEnvelopeUsage(bundle.fromSecureEnvelope || (options?["onDemandEnvelopeSaved"] as? NSNumber)?.boolValue == true,
                               generation: generation)
        setDiagnosticSensitiveValues(from: bundle)
        recordDiagnostic("start_bundle_loaded")

        engineOperationQueue.async { [weak self] in
            guard let self else {
                completion.finish(providerErrorStatic(4, "provider deallocated"))
                return
            }
            var startBundle = bundle
            #if os(iOS)
            if let preferred = self.preferredColdStartBundle(for: bundle) {
                startBundle = preferred
                self.setDiagnosticSensitiveValues(from: preferred)
                self.recordDiagnostic("start_bundle_scenario_preferred")
            }
            #endif
            // Complete cold-cache acquisition before installing any capture settings.
            // The same secure intent lets the OS retry while the host is suspended.
            guard self.isAttemptStarting(generation) else { return }
            if !startBundle.preparationProfile.isEmpty {
                guard startBundle.preparationProfile.utf8.count <= OnDemandStartEnvelope.maxConfigBytes else {
                    self.failAttempt(generation, error: self.providerError(5, "连接配置过大"),
                        diagnosticStage: "preparation_failed")
                    return
                }
                let basePath = FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier: Self.appGroupID)?.path ?? ""
                #if os(iOS)
                let result = LibboxGenerateNESessionResult(startBundle.preparationProfile, startBundle.server, basePath)!
                #else
                let result = LibboxGenerateNEConfigResult(startBundle.preparationProfile, startBundle.server, basePath)!
                #endif
                guard self.isAttemptStarting(generation) else { return }
                if !result.message.isEmpty {
                    self.failAttempt(generation, error: self.providerError(5, result.message),
                        diagnosticStage: result.retryable ? "preparation_network_unavailable" : "preparation_failed")
                    return
                }
                #if os(iOS)
                guard let data = result.value.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let config = object["config_json"] as? String else {
                    self.failAttempt(generation, error: self.providerError(5, "连接配置无效"),
                        diagnosticStage: "preparation_failed")
                    return
                }
                startBundle.configJSON = config
                if let line = object["anyconnect"] as? [String: Any] {
                    startBundle.anyConnectLineID = line["line_id"] as? String ?? ""
                    startBundle.anyConnectRuntimeIdentity = line["runtime_identity"] as? String ?? ""
                }
                #else
                startBundle.configJSON = result.value
                #endif
                guard startBundle.configJSON.utf8.count <= OnDemandStartEnvelope.maxConfigBytes else {
                    self.failAttempt(generation, error: self.providerError(5, "连接配置过大"),
                        diagnosticStage: "preparation_failed")
                    return
                }
                self.setDiagnosticSensitiveValues(from: startBundle)
            }
            self.prepareAttempt(startBundle, generation: generation, completion: completion)
        }
    }

    private func prepareAttempt(
        _ bundle: StartBundle,
        generation: UInt64,
        completion: StartCompletionGate
    ) {
        dispatchPrecondition(condition: .onQueue(engineOperationQueue))
        guard isAttemptStarting(generation) else { return }

        // 2) 创建引擎实例。
        let engineToken = makeEngineToken()
        let cb = EngineCallback(provider: self, generation: generation, engineToken: engineToken)
        guard let lb = LibboxNew(cb) else {
            let err = providerError(4, "LibboxNew 返回 nil")
            failAttempt(generation, error: err, diagnosticStage: "engine_create_failed")
            os_log("startTunnel: LibboxNew returned nil", log: log, type: .error)
            return
        }
        // 连上后的「路由命中」自检要靠引擎记下两个测试地址各走了哪条线路。这个记录默认是关的，
        // 不打开的话自检永远查不到记录，每次连接都会被判成「自检未通过」。
        // 开销只是每条新连接多比较一次目标地址。
        lb.setDebugRoutingProbeEnabled(true)
        #if os(iOS)
        // 场景切换时新场景先在旁边准备，提交时才接手系统隧道（见 core/libbox/tun_handover.go）。
        lb.setSwitchTUNHandover(true)
        #endif
        guard installEngine(lb, generation: generation, engineToken: engineToken) else {
            // 当前就在全局会话串行队列上；必须先清掉这个尚未登记的实例，
            // 不能把 Stop 排到已经入队的新 prepare 后面。
            try? lb.stop()
            return
        }

        // 3) 在默认路由切进当前 utun 之前先取得已有 Underlay，并持续监听系统路径变化。
        //    sing-box 官方 Apple 客户端也用 NWPathMonitor 驱动平台接口监控。
        do {
            try startDefaultInterfaceMonitor(generation: generation)
            recordDiagnostic("underlay_interface_ready")
        } catch {
            failAttempt(generation, error: error, diagnosticStage: "underlay_interface_failed")
            os_log("startTunnel: Underlay interface unavailable",
                   log: log, type: .error)
            return
        }

        guard isAttemptStarting(generation) else { return }

        if !bundle.usesAnyConnect {
            prepareStandaloneAttempt(
                bundle,
                engine: lb,
                generation: generation,
                completion: completion
            )
            return
        }

        // 4) 在默认路由进入 utun 前解析控制连接地址。NETunnelNetworkSettings
        //    明确要求 tunnelRemoteAddress 是数值 IP，不能传 hostname；同一个 IP
        //    也会作为 /32 排除路由和 sslcon 的 socket 目标。原始域名仍由 sslcon
        //    用作 TLS SNI/证书校验与 HTTP Host。
        recordDiagnostic("remote_address_resolving")
        let resolution = LibboxResolveVPNServer(bundle.server)
        let remoteIPv4 = resolution?.value ?? ""
        guard IPv4Address(remoteIPv4) != nil else {
            let error = providerError(5, resolution?.message ?? "服务器地址未解析为有效 IPv4")
            let stage = resolution?.retryable == true ? "remote_address_lookup_unavailable" : "remote_address_resolution_failed"
            failAttempt(generation, error: error, diagnosticStage: stage)
            os_log("startTunnel: remote address resolution failed",
                   log: log, type: .error)
            return
        }
        recordDiagnostic("remote_address_resolved")

        // 5) 先配置 NE 网络设置(隧道地址/DNS/路由),再拨号。
        //    NE 要求在 completionHandler(nil) 之前必须 setTunnelNetworkSettings 一次,
        //    否则 packetFlow 不会真正建立、拿不到有效 fd。
        //    系统 DNS 始终指向隧道内合成地址；引擎启动前它会短暂 fail closed，
        //    启动后由 hijack-dns 交给移动 dispatcher。企业 DNS 地址只留在 Go
        //    bridge 内部，不能直接装进系统设置造成 Tailscale 分域失效。
        let settings = buildNetworkSettings(remoteAddress: remoteIPv4)
        guard setTunnelNetworkSettingsIfStarting(settings, generation: generation, completionHandler: { [weak self] settingsError in
            guard let self else {
                completion.finish(providerErrorStatic(4, "provider deallocated"))
                return
            }
            guard self.isAttemptStarting(generation) else { return }
            if let settingsError {
                self.failAttempt(
                    generation,
                    error: settingsError,
                    diagnosticStage: "network_settings_failed"
                )
                os_log("startTunnel: setTunnelNetworkSettings failed",
                       log: self.log, type: .error)
                return
            }
            self.recordDiagnostic("network_settings_applied")

            // 6) 把 packetFlow 对应的 tun fd 交给引擎(见下方 tunFileDescriptor 说明)。
            if let fd = self.tunFileDescriptor(), fd > 0 {
                lb.setTunFD(fd)
                self.recordDiagnostic("tun_ready")
                os_log("startTunnel: tun fd set = %d", log: self.log, type: .info, fd)
            } else {
                let error = self.providerError(4, "无法获取系统隧道接口")
                self.failAttempt(generation, error: error, diagnosticStage: "tun_unavailable")
                os_log("startTunnel: tun fd unavailable",
                       log: self.log, type: .error)
                return
            }

            // 7) 拨号 + 启动 sing-box。StartResolved 是阻塞调用，socket 直拨
            //    remoteIPv4；TLS/HTTP 身份仍使用 bundle.server 的原始域名。
            self.recordDiagnostic("engine_starting")
            let engineBox = UncheckedSendableBox(lb)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.isAttemptStarting(generation) else { return }
                let stage = engineBox.value.startupStage()
                guard !stage.isEmpty, self.isAttemptStarting(generation) else { return }
                self.recordDiagnostic(stage)
            }
            self.engineOperationQueue.async {
                dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
                guard self.isAttemptStarting(generation) else { return }
                do {
                    try self.startEngine(lb, bundle: bundle, dialAddress: remoteIPv4)
                    guard self.isAttemptStarting(generation) else { return }

                    // 握手 DNS 只用于确认企业 resolver 可用；系统继续查询合成
                    // 地址，由 dispatcher 把非 Tailscale 域名 fail-closed 地送入 bridge。
                    self.recordDiagnostic("dns_settings_applying")
                    let finalSettings = self.buildNetworkSettings(remoteAddress: remoteIPv4)
                    guard self.setTunnelNetworkSettingsIfStarting(
                        finalSettings,
                        generation: generation,
                        completionHandler: { dnsSettingsError in
                        guard self.isAttemptStarting(generation) else { return }
                        if let dnsSettingsError {
                            self.failAttempt(
                                generation,
                                error: dnsSettingsError,
                                diagnosticStage: "dns_settings_failed"
                            )
                            os_log("startTunnel: tunnel DNS settings failed",
                                   log: self.log, type: .error)
                            return
                        }
                        guard self.completeAttempt(generation) else { return }
                        self.recordDiagnostic("engine_started")
                        #if os(iOS)
                        self.recordRunningScenario(bundle, remoteAddress: remoteIPv4)
                        #endif
                        os_log("startTunnel: engine and tunnel DNS ready",
                               log: self.log, type: .info)
                    }) else { return }
                } catch {
                    self.failAttempt(generation, error: error, diagnosticStage: "engine_failed")
                    os_log("startTunnel: engine start failed",
                           log: self.log, type: .error)
                }
            }
        }) else { return }
    }

    private func prepareStandaloneAttempt(
        _ bundle: StartBundle,
        engine: LibboxLibbox,
        generation: UInt64,
        completion: StartCompletionGate
    ) {
        dispatchPrecondition(condition: .onQueue(engineOperationQueue))
        let settings = buildNetworkSettings(remoteAddress: "127.0.0.1")
        guard setTunnelNetworkSettingsIfStarting(
            settings,
            generation: generation,
            completionHandler: { [weak self] settingsError in
                guard let self else {
                    completion.finish(providerErrorStatic(4, "provider deallocated"))
                    return
                }
                guard self.isAttemptStarting(generation) else { return }
                if let settingsError {
                    self.failAttempt(
                        generation,
                        error: settingsError,
                        diagnosticStage: "network_settings_failed"
                    )
                    return
                }
                self.recordDiagnostic("network_settings_applied")
                guard let fd = self.tunFileDescriptor(), fd > 0 else {
                    self.failAttempt(
                        generation,
                        error: self.providerError(4, "无法获取系统隧道接口"),
                        diagnosticStage: "tun_unavailable"
                    )
                    return
                }
                engine.setTunFD(fd)
                self.recordDiagnostic("tun_ready")
                self.recordDiagnostic("engine_starting")
                let engineBox = UncheckedSendableBox(engine)
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.isAttemptStarting(generation) else { return }
                    let stage = engineBox.value.startupStage()
                    guard !stage.isEmpty, self.isAttemptStarting(generation) else { return }
                    self.recordDiagnostic(stage)
                }
                self.engineOperationQueue.async {
                    dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
                    guard self.isAttemptStarting(generation) else { return }
                    do {
                        try self.startEngine(engine, bundle: bundle, dialAddress: "")
                        guard self.completeAttempt(generation) else { return }
                        self.recordDiagnostic("engine_started")
                        #if os(iOS)
                        self.recordRunningScenario(bundle, remoteAddress: "127.0.0.1")
                        #endif
                        os_log("startTunnel: standalone engine ready",
                               log: self.log, type: .info)
                    } catch {
                        self.failAttempt(
                            generation,
                            error: error,
                            diagnosticStage: "engine_failed"
                        )
                    }
                }
            }
        ) else { return }
    }

    // MARK: - stopTunnel

    private static func stopDetail(_ reason: NEProviderStopReason) -> String {
        let name: String
        switch reason {
        case .none: name = "none"
        case .userInitiated: name = "userInitiated"
        case .providerFailed: name = "providerFailed"
        case .noNetworkAvailable: name = "noNetworkAvailable"
        case .unrecoverableNetworkChange: name = "unrecoverableNetworkChange"
        case .providerDisabled: name = "providerDisabled"
        case .authenticationCanceled: name = "authenticationCanceled"
        case .configurationFailed: name = "configurationFailed"
        case .idleTimeout: name = "idleTimeout"
        case .configurationDisabled: name = "configurationDisabled"
        case .configurationRemoved: name = "configurationRemoved"
        case .superceded: name = "superceded"
        case .userLogout: name = "userLogout"
        case .userSwitch: name = "userSwitch"
        case .connectionFailed: name = "connectionFailed"
        case .sleep: name = "sleep"
        case .appUpdate: name = "appUpdate"
        case .internalError: name = "internalError"
        @unknown default: name = "unknown"
        }
        return "reason=\(reason.rawValue) (\(name))"
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let completion = StopCompletionGate(completionHandler)
        diagnosticLock.lock()
        let sessionID = timelineSessionID
        diagnosticLock.unlock()
        // Cleanup can finish before afterCleanupQueued runs. Keep this session
        // alive until the notice result has been queued for its final snapshot.
        let stopRecorded = DispatchGroup()
        stopRecorded.enter()
        // 先原子失效所有启动回调并摘除资源，再等串行队列真正清理旧会话。
        // 极端情况下 StartResolved 可能长期不返回，兜底只放行系统 completion；
        // 引擎队列仍保持阻塞，后续 start 不会越过旧会话创建第二个 Libbox。
        cancelActiveAttempt(
            startError: providerError(7, "连接启动已取消"),
            afterCleanupQueued: { [weak self] wasRunning in
                self?.stopActivityUpdates()
                #if os(iOS)
                self?.clearRunningScenario()
                #endif
                self?.recordTimeline("stop_reason", detail: Self.stopDetail(reason))
                self?.recordDiagnostic("stopping")
                os_log("stopTunnel: reason=%d", log: self?.log ?? .default,
                       type: .info, reason.rawValue)
                #if os(iOS)
                if let notice = ConnectionNotice.forTunnelStop(reason, wasRunning: wasRunning,
                    appRequestedStop: self?.timeline?.appRequestedStop(session: sessionID) == true) {
                    notice.post { [timeline = self?.timeline] outcome in
                        timeline?.append(session: sessionID, source: .tunnel, stage: "tunnel.disconnect_notice",
                                         result: outcome == .failed ? .failed : (outcome == .disabled ? .notRun : .ok),
                                         detail: outcome.rawValue)
                        stopRecorded.leave()
                    }
                    return
                }
                #endif
                stopRecorded.leave()
            },
            cleanupCompletion: { [weak self] in
                self?.recordDiagnostic("stopped")
                os_log("stopTunnel: cleanup done", log: self?.log ?? .default, type: .info)
                stopRecorded.notify(queue: .global(qos: .utility)) { [timeline = self?.timeline] in
                    guard let timeline, !sessionID.isEmpty else { completion.finish(); return }
                    timeline.endActiveSession(sessionID) { _ = completion.finish() }
                }
            }
        )
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10) { [weak self] in
            if completion.finish() {
                os_log("stopTunnel: cleanup timeout", log: self?.log ?? .default, type: .error)
            }
        }
    }

    // MARK: - 启动生命周期

    private func beginLifecycleAttempt(completion: StartCompletionGate) -> UInt64 {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        let previousEngine = libbox
        let previousMonitor = pathMonitor
        let previousCompletion = startCompletion
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGeneration &+= 1
        let generation = activeGeneration
        attemptPhase = .starting
        activeGenerationUsesSecureEnvelope = false
        startCompletion = completion
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(previousEngine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        previousMonitor?.cancel()
        previousCompletion?.finish(providerError(7, "连接启动已被新的连接请求取代"))
        return generation
    }

    private func installEngine(_ engine: LibboxLibbox, generation: UInt64, engineToken: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        libbox = engine
        activeEngineToken = engineToken
        lifecycleLock.unlock()
        return true
    }

    private func makeEngineToken() -> UInt64 {
        lifecycleLock.lock()
        lastEngineToken &+= 1
        let token = lastEngineToken
        lifecycleLock.unlock()
        return token
    }

    fileprivate func isCurrentEngine(_ token: UInt64) -> Bool {
        lifecycleLock.lock()
        let current = token != 0 && activeEngineToken == token
        lifecycleLock.unlock()
        return current
    }

    private func setSecureEnvelopeUsage(_ enabled: Bool, generation: UInt64) {
        lifecycleLock.lock()
        if activeGeneration == generation, attemptPhase == .starting {
            activeGenerationUsesSecureEnvelope = enabled
        }
        lifecycleLock.unlock()
    }

    private func installPathMonitor(_ monitor: NWPathMonitor, generation: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        pathMonitor = monitor
        lifecycleLock.unlock()
        return true
    }

    private func isAttemptStarting(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        let matches = activeGeneration == generation && attemptPhase == .starting
        lifecycleLock.unlock()
        return matches
    }

    private func setTunnelNetworkSettingsIfStarting(
        _ settings: NEPacketTunnelNetworkSettings,
        generation: UInt64,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) -> Bool {
        let completion = UncheckedSendableBox(completionHandler)
        let settings = UncheckedSendableBox(settings)
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return false
        }
        networkSettingsOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.networkSettingsOperationQueue))
            guard self.isAttemptStarting(generation) else { return }

            let result = OneShotNetworkSettingsResult()
            let finished = DispatchSemaphore(value: 0)
            self.setTunnelNetworkSettings(settings.value) { error in
                if result.finish(error) {
                    finished.signal()
                }
            }
            // 原始系统 completion 只负责 signal；业务 completion 必须等本 job
            // 退出串行队列后再执行，避免回调反向等待同一 operation queue。
            if finished.wait(timeout: .now() + 15) == .timedOut {
                _ = result.finish(self.providerError(31, "应用系统网络设置超时"))
            }
            let outcome = result.snapshot()
            self.networkSettingsCallbackQueue.async {
                completion.value(outcome.error)
            }
        }
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()
        return true
    }

    private func completeAttempt(_ generation: UInt64) -> Bool {
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            return false
        }
        attemptPhase = .running
        let completion = startCompletion
        lifecycleLock.unlock()

        // 回调不能在 lifecycleLock 内执行；completion gate 与 stop/new start 竞争，
        // 只有先到的一方能决定结果，因此失效后不会再补一次成功。
        let completed = completion?.finish(nil) ?? false
        lifecycleLock.lock()
        if activeGeneration == generation, startCompletion === completion {
            startCompletion = nil
        }
        lifecycleLock.unlock()
        return completed
    }

    private func failAttempt(
        _ generation: UInt64,
        error: Error,
        diagnosticStage: String
    ) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .starting else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return
        }
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        let clearSecureEnvelope = activeGenerationUsesSecureEnvelope
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(engine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        if OnDemandStartEnvelopeFailurePolicy.shouldClear(
            startedFromSecureEnvelope: clearSecureEnvelope,
            startupStage: diagnosticStage
        ) {
            _ = OnDemandStartEnvelopeStore.clear()
        }
        setLastError(error.localizedDescription)
        recordDiagnostic(diagnosticStage)
        // iOS may terminate this extension immediately after the failure callback.
        timeline?.flush()
        monitor?.cancel()
        completion?.finish(error)
    }

    private func cancelActiveAttempt(
        startError: Error,
        afterCleanupQueued: ((Bool) -> Void)? = nil,
        cleanupCompletion: (() -> Void)? = nil
    ) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        let wasRunning = attemptPhase == .running
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(
            engine,
            after: settingsBarrier,
            completion: cleanupCompletion
        )
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        afterCleanupQueued?(wasRunning)
        monitor?.cancel()
        completion?.finish(startError)
    }

    /// 调用方必须同时持有 submission/lifecycle 锁，保证 barrier 排在此前设置 job 后。
    private func enqueueNetworkSettingsBarrierLocked() -> DispatchGroup {
        let barrier = DispatchGroup()
        barrier.enter()
        networkSettingsOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.networkSettingsOperationQueue))
            barrier.leave()
        }
        return barrier
    }

    /// 调用方必须持有 lifecycleLock；只做入队，不等待队列执行，也不触发外部回调。
    private func enqueueEngineCleanupLocked(
        _ engine: LibboxLibbox?,
        after settingsBarrier: DispatchGroup,
        completion: (() -> Void)? = nil
    ) {
        let completion = completion.map(UncheckedSendableBox.init)
        engineOperationQueue.async {
            dispatchPrecondition(condition: .onQueue(self.engineOperationQueue))
            if let engine {
                try? engine.stop()
            }
            settingsBarrier.wait()
            completion?.value()
        }
    }

    #if os(iOS)
    private let activityUpdater = TunnelActivityUpdater()
    #endif

    private func stopActivityUpdates() {
        #if os(iOS)
        activityUpdater.endActivities()
        #endif
    }

    private func currentEngine() -> LibboxLibbox? {
        lifecycleLock.lock()
        let engine = libbox
        lifecycleLock.unlock()
        return engine
    }

    private func engine(for generation: UInt64) -> LibboxLibbox? {
        lifecycleLock.lock()
        let engine = activeGeneration == generation && attemptPhase != .idle ? libbox : nil
        lifecycleLock.unlock()
        return engine
    }

    private func phase(for generation: UInt64) -> AttemptPhase? {
        lifecycleLock.lock()
        let phase = activeGeneration == generation ? attemptPhase : nil
        lifecycleLock.unlock()
        return phase
    }

    private func handleEngineError(code: Int, message: String?, generation: UInt64) {
        let detail = message.flatMap { $0.isEmpty ? nil : $0 }
            ?? "底层连接发生错误(代码 \(code))"
        let error = providerError(20 + code, detail)
        switch phase(for: generation) {
        case .starting:
            let stage = code == LibboxErrCodeTransientNetwork ? "engine_network_unavailable" : "engine_failed"
            failAttempt(generation, error: error, diagnosticStage: stage)
        case .running:
            terminateRunningAttempt(generation, error: error)
        case .idle, nil:
            break
        }
    }

    private func handleEngineStatus(_ statusJSON: String?, generation: UInt64) {
        guard let statusJSON,
              let data = statusJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["status"] as? String)?.lowercased() == "disconnected" else {
            return
        }
        let error = providerError(8, "底层连接意外断开")
        switch phase(for: generation) {
        case .starting:
            failAttempt(generation, error: error, diagnosticStage: "engine_disconnected")
        case .running:
            terminateRunningAttempt(generation, error: error)
        case .idle, nil:
            break
        }
    }

    private func terminateRunningAttempt(_ generation: UInt64, error: Error) {
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .running else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return
        }
        let engine = libbox
        let monitor = pathMonitor
        let completion = startCompletion
        libbox = nil
        pathMonitor = nil
        startCompletion = nil
        attemptPhase = .idle
        activeGenerationUsesSecureEnvelope = false
        activeGeneration &+= 1
        let settingsBarrier = enqueueNetworkSettingsBarrierLocked()
        enqueueEngineCleanupLocked(engine, after: settingsBarrier)
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()

        #if os(iOS)
        clearRunningScenario()
        // The same secure configuration already started this tunnel successfully.
        // Keep it for the next system reconnect after a transport drop.
        ConnectionNotice.disconnect.post()
        #endif
        setLastError(error.localizedDescription)
        recordDiagnostic("runtime_disconnected", detail: "code=\((error as NSError).code) " + ConnectionTimeline.failureKeywords(error.localizedDescription))
        monitor?.cancel()
        completion?.finish(error)
        cancelTunnelWithError(error)
    }

    // MARK: - handleAppMessage

    /// 处理 App(GoEngine.sendProviderMessage)发来的一段 JSON 请求,回一段
    /// DaemonResponse JSON。请求结构见 GoEngine.swift 的 sendRequest / sendSubRequest:
    ///   {"cmd":"start","profile":"<...>"}            // 目前扩展侧不再从 profile 拨号
    ///   {"cmd":"stop"}
    ///   {"cmd":"status"}
    ///   {"cmd":"parse-sub","sub_url":"...","sub_format":"...","sub_content":"..."}
    ///   {"cmd":"select-outbound","group_tag":"...","outbound_tag":"..."}
    ///   {"cmd":"test-outbound","outbound_tag":"...","test_url":"...","timeout_ms":"5000"}
    ///   {"cmd":"probe-outbound-address","outbound_tag":"...","timeout_ms":"7000"}
    ///   {"cmd":"probe-exit-country","timeout_ms":"8000"}      // 经 Direct 线路查出口地区
    ///   {"cmd":"routing-probe-snapshot"}
    ///   {"cmd":"traffic-snapshot"}
    ///   {"cmd":"tailscale-status","endpoint_tag":"tailscale-..."}
    /// 响应结构见 GoEngine.swift 的 DaemonResponse:{id?, ok?, message?, data?, event?}。
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let completionHandler else { return }
        let completion = UncheckedSendableBox(completionHandler)

        guard let obj = try? JSONSerialization.jsonObject(with: messageData) as? [String: Any],
              let cmd = obj["cmd"] as? String else {
            completion.value(encodeResponse(ok: false, message: "无法解析请求(缺少 cmd)"))
            return
        }
        os_log("handleAppMessage: cmd=%{public}@", log: log, type: .info, cmd)

        switch cmd {
        case "status":
            completion.value(handleStatus())

        case "start":
            // 扩展的真实启动由 NETunnelProviderManager.startVPNTunnel(options:) 触发
            // (走 startTunnel 而非本消息)。这里保留一条幂等语义的应答:若引擎已在跑
            // 回 ok,便于 App 在既有隧道上做「确认」。真正的拨号不在此路径完成。
            let running = currentEngine()?.isRunning() ?? false
            completion.value(encodeResponse(ok: true,
                message: running ? nil : "隧道由系统连接配置启动,非此消息路径",
                dataString: statusJSONString()))

        case "stop":
            // 与 start 对称:真正停止隧道应调 NETunnelProviderManager.stopVPNTunnel()。
            // 这里做一次尽力而为的引擎停止,并回 ok。
            cancelActiveAttempt(startError: providerError(7, "连接启动已取消"))
            completion.value(encodeResponse(ok: true, dataString: "{\"status\":\"disconnected\"}"))

        case "parse-sub":
            // 兼容旧 App 的消息。当前 App 已在主进程直接调用 Libbox 解析，不再依赖扩展会话。
            completion.value(encodeResponse(ok: false, message: "请更新 XDial 后重试订阅解析"))

        case "select-outbound":
            guard let groupTag = obj["group_tag"] as? String, !groupTag.isEmpty,
                  let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "线路选择参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    try engine.selectOutbound(groupTag, outboundTag: outboundTag)
                    completion.value(self.encodeResponse(ok: true))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法切换到所选线路"))
                }
            }

        case "test-outbound":
            guard let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "线路测试参数不完整"))
                return
            }
            let testURL = obj["test_url"] as? String ?? ""
            let timeoutMS = Int(obj["timeout_ms"] as? String ?? "") ?? 5_000
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var delay = 0
                    try engine.testOutbound(
                        outboundTag,
                        testURL: testURL,
                        timeoutMS: timeoutMS,
                        ret0_: &delay
                    )
                    completion.value(self.encodeResponse(ok: true, dataString: String(delay)))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "所选线路测试失败"))
                }
            }

        case "probe-outbound-address":
            guard let outboundTag = obj["outbound_tag"] as? String, !outboundTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "出口地址探测参数不完整"))
                return
            }
            let timeoutMS = Int(obj["timeout_ms"] as? String ?? "") ?? 7_000
            let queuedAt = ProcessInfo.processInfo.systemUptime
            outboundProbeQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                let startedAt = ProcessInfo.processInfo.systemUptime
                let kind = Self.outboundKind(outboundTag)
                do {
                    var probeError: NSError?
                    let address = engine.probeOutboundIP(
                        outboundTag,
                        timeoutMS: timeoutMS,
                        error: &probeError
                    )
                    if let probeError { throw probeError }
                    self.recordTimeline(
                        "line_probe", result: .ok,
                        ms: ConnectionTimeline.elapsedMilliseconds(since: startedAt),
                        detail: "\(kind) queued=\(Int((startedAt - queuedAt) * 1000))ms")
                    completion.value(self.encodeResponse(ok: true, dataString: address))
                } catch {
                    let failure = error.localizedDescription
                    self.recordTimeline(
                        "line_probe", result: ConnectionTimeline.classify(probeFailure: failure),
                        ms: ConnectionTimeline.elapsedMilliseconds(since: startedAt),
                        detail: "\(kind) queued=\(Int((startedAt - queuedAt) * 1000))ms "
                            + ConnectionTimeline.failureKeywords(failure))
                    completion.value(self.encodeResponse(
                        ok: false,
                        message: "无法确认所选线路的出口地址：\(error.localizedDescription)"
                    ))
                }
            }

        case "probe-exit-country":
            let timeoutMS = Int(obj["timeout_ms"] as? String ?? "") ?? 8_000
            outboundProbeQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                var probeError: NSError?
                let code = engine.probeOutboundCountry("direct", timeoutMS: timeoutMS, error: &probeError)
                if let probeError {
                    completion.value(self.encodeResponse(ok: false, message: probeError.localizedDescription))
                } else {
                    completion.value(self.encodeResponse(ok: true, dataString: code))
                }
            }

        case "routing-probe-snapshot":
            guard let engine = currentEngine(), engine.isRunning() else {
                completion.value(encodeResponse(ok: false, message: "连接引擎未运行"))
                return
            }
            completion.value(encodeResponse(
                ok: true,
                dataString: engine.routingProbeSnapshot()
            ))

        case "traffic-snapshot":
            // 全线路累计字节数，App 按相邻两次采样差值算实时速率。
            guard let engine = currentEngine(), engine.isRunning() else {
                completion.value(encodeResponse(ok: false, message: "连接引擎未运行"))
                return
            }
            completion.value(encodeResponse(
                ok: true,
                dataString: engine.trafficTotals()
            ))

        case "tailscale-status":
            guard let endpointTag = obj["endpoint_tag"] as? String, !endpointTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "Tailscale 状态参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var statusError: NSError?
                    let rawStatus = engine.tailscaleStatus(endpointTag, error: &statusError)
                    if let statusError { throw statusError }
                    guard !rawStatus.isEmpty else {
                        completion.value(self.encodeResponse(ok: false, message: "Tailscale 状态为空"))
                        return
                    }
                    if self.tailscaleBackendIsRunning(rawStatus) {
                        // reconfig 已原地更新 Tailscale DNS transport；清掉登录前
                        // 可能缓存的公共 NXDOMAIN 后，下一条查询立即按新分域选择。
                        try engine.refreshDNS()
                    }
                    completion.value(self.encodeResponse(ok: true, dataString: rawStatus))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法读取 Tailscale 状态"))
                }
            }

        case "tailscale-begin-login":
            guard let endpointTag = obj["endpoint_tag"] as? String, !endpointTag.isEmpty else {
                completion.value(encodeResponse(ok: false, message: "Tailscale 登录参数不完整"))
                return
            }
            engineOperationQueue.async { [weak self] in
                guard let self, let engine = self.currentEngine() else {
                    completion.value(self?.encodeResponse(ok: false, message: "连接引擎未运行"))
                    return
                }
                do {
                    var loginError: NSError?
                    let rawStatus = engine.beginTailscaleLogin(endpointTag, error: &loginError)
                    if let loginError { throw loginError }
                    guard !rawStatus.isEmpty else {
                        completion.value(self.encodeResponse(ok: false, message: "Tailscale 登录状态为空"))
                        return
                    }
                    completion.value(self.encodeResponse(ok: true, dataString: rawStatus))
                } catch {
                    completion.value(self.encodeResponse(ok: false, message: "无法启动 Tailscale 登录"))
                }
            }

        default:
            #if os(iOS)
            if handleScenarioMessage(cmd, obj, completion: { completion.value($0) }) { return }
            #endif
            completion.value(encodeResponse(ok: false, message: "未知命令: \(cmd)"))
        }
    }

    // MARK: - status 辅助

    private func handleStatus() -> Data {
        encodeResponse(ok: true, dataString: statusJSONString())
    }

    /// 组装 GoEngine.EngineStatus 期望的 JSON:{"status": "...", "error": "..."?}。
    /// EngineStatus 只解 status / scenario_id / connected_at / error；这里给 status(+error)。
    private func statusJSONString() -> String {
        let running = currentEngine()?.isRunning() ?? false
        var dict: [String: Any] = ["status": running ? "connected" : "disconnected"]
        #if os(iOS)
        if running, let scenarioID = runningScenarioID() {
            dict["scenario_id"] = scenarioID
        }
        #endif
        dict["diagnostics"] = diagnosticSnapshot(includeEngine: true)
        if let lastError = currentLastError(), !lastError.isEmpty {
            dict["error"] = lastError
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return running ? "{\"status\":\"connected\"}" : "{\"status\":\"disconnected\"}"
        }
        return s
    }

    // MARK: - 响应编码(对齐 GoEngine.DaemonResponse)

    /// DaemonResponse 里 data 是 String?(它自身是一段被转义的 JSON 文本,
    /// 比如 EngineStatus/ParseResult 的 JSON)。这里把 dataString 原样放进 data 字段。
    private func encodeResponse(ok: Bool, message: String? = nil, dataString: String? = nil) -> Data {
        var dict: [String: Any] = ["ok": ok]
        if let message { dict["message"] = message }
        if let dataString { dict["data"] = dataString }
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else {
            // 兜底:手写一个最小合法响应,保证 App 侧能解出 ok=false。
            return Data("{\"ok\":false,\"message\":\"响应编码失败\"}".utf8)
        }
        return data
    }

    // MARK: - 凭据/配置读取

    private struct StartBundle: Sendable {
        let fromSecureEnvelope: Bool
        let usesAnyConnect: Bool
        let server: String
        let username: String
        let password: String
        let allowInsecure: Bool
        var configJSON: String
        var preparationProfile = ""
        /// 以下字段来自新版 App；旧 App 的启动包没有，这时不能与切换候选共享线路。
        var scenarioID = ""
        var scenarioName = ""
        var anyConnectLineID = ""
        var anyConnectRuntimeIdentity = ""
        var tailscaleLineID = ""
        var tailscaleRuntimeIdentity = ""
        var acceptancePlanJSON = ""
        /// 来自场景目录或按需启动信封时的原文，切换成功后写回按需启动信封。
        var envelope: OnDemandStartEnvelope?

        var usesTailscale: Bool { !tailscaleLineID.isEmpty }

        init(
            fromSecureEnvelope: Bool,
            usesAnyConnect: Bool,
            server: String,
            username: String,
            password: String,
            allowInsecure: Bool,
            configJSON: String
        ) {
            self.fromSecureEnvelope = fromSecureEnvelope
            self.usesAnyConnect = usesAnyConnect
            self.server = server
            self.username = username
            self.password = password
            self.allowInsecure = allowInsecure
            self.configJSON = configJSON
        }

        mutating func readSwitchParameters(_ value: (String) -> String?) {
            preparationProfile = value("preparation_profile") ?? ""
            scenarioID = value("scenario_id") ?? ""
            scenarioName = value("scenario_name") ?? ""
            anyConnectLineID = value("anyconnect_line_id") ?? ""
            anyConnectRuntimeIdentity = value("anyconnect_runtime_identity") ?? ""
            tailscaleLineID = value("tailscale_line_id") ?? ""
            tailscaleRuntimeIdentity = value("tailscale_runtime_identity") ?? ""
            // 只有成对出现的线路与身份才算数。
            if anyConnectLineID.isEmpty || anyConnectRuntimeIdentity.isEmpty {
                anyConnectLineID = ""
                anyConnectRuntimeIdentity = ""
            }
            if tailscaleLineID.isEmpty || tailscaleRuntimeIdentity.isEmpty {
                tailscaleLineID = ""
                tailscaleRuntimeIdentity = ""
            }
        }

        /// 按需启动信封 → 启动包。信封不完整时返回 nil。
        static func from(envelope: OnDemandStartEnvelope, fromSecureEnvelope: Bool) -> StartBundle? {
            guard envelope.isValid,
                  ["anyconnect", "standalone"].contains(envelope.transport),
                  let acceptancePlan = envelope.parameters["acceptance_plan"],
                  let acceptanceData = acceptancePlan.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: acceptanceData)) is [String: Any] else {
                return nil
            }
            let usesAnyConnect = envelope.transport == "anyconnect"
            let server = envelope.parameters["server"] ?? ""
            let username = envelope.parameters["username"] ?? ""
            let password = envelope.parameters["password"] ?? ""
            guard !usesAnyConnect || (!server.isEmpty && !username.isEmpty && !password.isEmpty) else {
                return nil
            }
            var bundle = StartBundle(
                fromSecureEnvelope: fromSecureEnvelope,
                usesAnyConnect: usesAnyConnect,
                server: server,
                username: username,
                password: password,
                allowInsecure: envelope.parameters["allow_insecure"] == "true",
                configJSON: envelope.configJSON
            )
            bundle.readSwitchParameters { envelope.parameters[$0] }
            bundle.acceptancePlanJSON = acceptancePlan
            bundle.envelope = envelope
            return bundle
        }
    }

    /// 优先从一次性 options 读取；回退 App Group 只为兼容早期版本。
    /// 成功复制到内存后立即清理旧 key，避免敏感配置继续持久化。
    private func resolveStartBundle(options: [String: NSObject]?) -> StartBundle? {
        let defaults = UserDefaults(suiteName: Self.appGroupID)
        for key in [Self.serverKey, Self.usernameKey, Self.passwordKey, Self.configKey] {
            defaults?.removeObject(forKey: key)
        }

        let configJSON = options?["configJSON"] as? String
        let explicitAnyConnect = (options?["usesAnyConnect"] as? NSNumber)?.boolValue
        let server = options?["server"] as? String
        let username = options?["username"] as? String
        let password = options?["password"] as? String
        if OnDemandManualStartContract.isComplete(
            configJSON: configJSON,
            usesAnyConnect: explicitAnyConnect,
            server: server,
            username: username,
            password: password
        ), let configJSON, let explicitAnyConnect {
            var bundle = StartBundle(
                fromSecureEnvelope: false,
                usesAnyConnect: explicitAnyConnect,
                server: server ?? "",
                username: username ?? "",
                password: password ?? "",
                allowInsecure: (options?["allowInsecure"] as? NSNumber)?.boolValue ?? false,
                configJSON: configJSON
            )
            bundle.readSwitchParameters { options?[$0] as? String }
            bundle.acceptancePlanJSON = options?["acceptance_plan"] as? String ?? ""
            return bundle
        }

        // NetworkExtension 可能传入包含系统字段的非空 options。只要不满足主 App
        // 的完整手动契约，就必须按冷启动处理，不能误读为旧版手动启动。
        do {
            recordTimeline("start_envelope_read")
            switch OnDemandStartEnvelopeStore.load() {
            case .available(let envelope):
                let bundle = StartBundle.from(envelope: envelope, fromSecureEnvelope: true)
                recordTimeline("start_envelope_decoded", result: bundle == nil ? .failed : .ok)
                return bundle
            case .missing:
                recordTimeline("start_envelope_missing", result: .failed)
            case .unavailable(let status):
                recordTimeline("start_envelope_unavailable", result: .failed, detail: "keychain=\(status)")
            case .corrupt:
                recordTimeline("start_envelope_invalid", result: .failed)
            }
            return nil
        }
    }

    // MARK: - NE 网络设置

    /// 启动 Underlay 接口监控并同步等待首个结果。默认接口和完整候选列表必须在
    /// Libbox.Start 前发布，否则 route.auto_detect_interface 没有可用出口。
    private func startDefaultInterfaceMonitor(generation: UInt64) throws {
        let monitor = NWPathMonitor()
        let ready = DispatchSemaphore(value: 0)

        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            self?.updateDefaultInterface(path, generation: generation)
            ready.signal()
            monitor?.pathUpdateHandler = { [weak self] path in
                self?.updateDefaultInterface(path, generation: generation)
            }
        }
        guard installPathMonitor(monitor, generation: generation) else {
            throw providerError(7, "连接启动已取消")
        }
        monitor.start(queue: pathMonitorQueue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw providerError(5, "等待 Underlay 网络接口超时")
        }
        guard isAttemptStarting(generation) else {
            throw providerError(7, "连接启动已取消")
        }
        guard monitor.currentPath.status == .satisfied,
              selectDefaultInterface(from: monitor.currentPath) != nil else {
            throw providerError(5, "没有可用的 Underlay 网络接口")
        }
    }

    private struct PathInterfaceSnapshot: Codable {
        let name: String
        let index: Int
        let type: String
    }

    private struct UnderlaySnapshot: Sendable {
        let interfacesJSON: String
        let name: String
        let index: Int
    }

    private func currentUnderlay() -> UnderlaySnapshot? {
        diagnosticLock.lock()
        let snapshot = latestUnderlay
        diagnosticLock.unlock()
        return snapshot
    }

    private func updateDefaultInterface(_ path: NWPath, generation: UInt64) {
        guard let engine = engine(for: generation) else { return }
        #if os(iOS)
        notePathForScenario(path)
        #endif
        guard path.status == .satisfied, let interface = selectDefaultInterface(from: path) else {
            diagnosticLock.lock()
            latestUnderlay = nil
            diagnosticLock.unlock()
            setDefaultInterfaceDiagnostic(name: "", index: -1)
            try? engine.setNetworkInterfaces("[]")
            engine.setDefaultInterface("", index: -1)
            refreshDiagnostic()
            os_log("Underlay interface unavailable", log: log, type: .error)
            return
        }

        var seenInterfaceNames = Set<String>()
        let snapshots: [PathInterfaceSnapshot] = path.availableInterfaces.compactMap {
            candidate -> PathInterfaceSnapshot? in
            guard seenInterfaceNames.insert(candidate.name).inserted else { return nil }
            return PathInterfaceSnapshot(
                name: candidate.name,
                index: candidate.index,
                type: networkTypeName(candidate.type)
            )
        }
        do {
            let data = try JSONEncoder().encode(snapshots)
            guard let json = String(data: data, encoding: .utf8) else {
                throw providerError(5, "无法编码 Underlay 接口快照")
            }
            try engine.setNetworkInterfaces(json)
            diagnosticLock.lock()
            latestUnderlay = UnderlaySnapshot(interfacesJSON: json, name: interface.name, index: interface.index)
            diagnosticLock.unlock()
        } catch {
            setLastError("发布 Underlay 接口失败：\(error.localizedDescription)")
            os_log("publish Underlay interfaces failed: %{public}@",
                   log: log, type: .error, error.localizedDescription)
        }

        setDefaultInterfaceDiagnostic(name: interface.name, index: interface.index)
        engine.setDefaultInterface(interface.name, index: interface.index)
        refreshDiagnostic()
        os_log("default Underlay interface: %{public}@ (%d)", log: log, type: .info,
               interface.name, interface.index)
    }

    private func selectDefaultInterface(from path: NWPath) -> NWInterface? {
        path.availableInterfaces.first
    }

    private func networkTypeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi:
            return "wifi"
        case .cellular:
            return "cellular"
        case .wiredEthernet:
            return "ethernet"
        default:
            return "other"
        }
    }

    /// 构造 NEPacketTunnelNetworkSettings。
    /// 隧道地址与 core/config buildTUNInbound 对齐。IPv6 也必须进入 packetFlow，
    /// 即使远端仅支持 IPv4，也应在受控出口 fail closed，不能绕过默认路由直出。
    private func buildNetworkSettings(
        remoteAddress: String,
        alsoExcluding extraExcluded: [String] = []
    ) -> NEPacketTunnelNetworkSettings {
        // 调用方已用 IPv4Address 做过最终数值校验；不要在这里回退 hostname。
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddress)

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.254.0.0"]) // /15
        // 默认路由:全部流量进隧道,由 sing-box 的 route 规则再做分流。
        ipv4.includedRoutes = [NEIPv4Route.default()]
        // 控制连接必须始终走已有 Underlay，不能被刚安装的默认路由套回自身。
        // 场景切换期间新旧两条控制连接同时存在，两个服务器地址都要排除。
        ipv4.excludedRoutes = ([remoteAddress] + extraExcluded.filter { $0 != remoteAddress }).map {
            NEIPv4Route(destinationAddress: $0, subnetMask: "255.255.255.255")
        }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00::1"], networkPrefixLengths: [126])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: ["198.18.0.2"])
        dns.matchDomains = [""]
        dns.matchDomainsNoSearch = true
        if #available(iOS 26.0, tvOS 26.0, *) {
            dns.allowFailover = false
        }
        settings.dnsSettings = dns

        settings.mtu = 9000 // 与 buildTUNInbound 的 mtu 对齐

        return settings
    }

    private func validDNSServers(from json: String) -> [String]? {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        let validated = values.filter { IPv4Address($0) != nil }
        return validated.count == values.count ? validated : nil
    }

    private func tailscaleBackendIsRunning(_ rawStatus: String) -> Bool {
        guard let data = rawStatus.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = object["backend_state"] as? String else {
            return false
        }
        return state.caseInsensitiveCompare("running") == .orderedSame
    }

    // MARK: - 发布版诊断

    private struct DiagnosticState {
        let stage: String
        let attemptID: String
        let defaultInterfaceName: String
        let defaultInterfaceIndex: Int
        let lastError: String?
    }

    private func beginAttempt(_ attemptID: String) {
        // A system-initiated start (on-demand) carries no app attempt ID; the
        // extension then owns the session ID and the app attaches to it.
        let sessionID = attemptID.isEmpty ? "tunnel-" + UUID().uuidString : attemptID
        timeline?.beginSession(sessionID, markActive: true, origin: attemptID.isEmpty ? .system : nil)
        diagnosticLock.lock()
        timelineSessionID = sessionID
        activeAttemptID = attemptID
        lastError = nil
        diagnosticStage = "idle"
        defaultInterfaceName = ""
        defaultInterfaceIndex = -1
        diagnosticSensitiveValues = []
        diagnosticLock.unlock()
    }

    /// Coarse kind of an outbound tag; tags embed Line IDs that reports omit.
    static func outboundKind(_ tag: String) -> String {
        if tag == "direct" || tag == "vpn" { return tag }
        if tag.hasPrefix("tailscale-") { return "tailscale" }
        if tag.hasPrefix("proxy-") { return "proxy" }
        return "subscription"
    }

    private func setLastError(_ value: String?) {
        let safeValue = sanitizedDiagnosticText(value)
        diagnosticLock.lock()
        lastError = safeValue
        diagnosticLock.unlock()
    }

    private func currentLastError() -> String? {
        diagnosticLock.lock()
        let value = lastError
        diagnosticLock.unlock()
        return value
    }

    private func setDefaultInterfaceDiagnostic(name: String, index: Int) {
        diagnosticLock.lock()
        defaultInterfaceName = name
        defaultInterfaceIndex = index
        diagnosticLock.unlock()
    }

    private func captureDiagnosticState(updatingStage stage: String? = nil) -> DiagnosticState {
        diagnosticLock.lock()
        if let stage {
            diagnosticStage = stage
        }
        let state = DiagnosticState(
            stage: diagnosticStage,
            attemptID: activeAttemptID,
            defaultInterfaceName: defaultInterfaceName,
            defaultInterfaceIndex: defaultInterfaceIndex,
            lastError: lastError
        )
        diagnosticLock.unlock()
        return state
    }

    /// Appends one extension event to the shared connection timeline.
    private func recordTimeline(
        _ stage: String,
        result: ConnectionTimeline.Result? = nil,
        ms: Int? = nil,
        detail: String? = nil
    ) {
        diagnosticLock.lock()
        let sessionID = timelineSessionID
        diagnosticLock.unlock()
        guard !sessionID.isEmpty else { return }
        timeline?.append(
            session: sessionID, source: .tunnel, stage: "tunnel." + stage, result: result,
            ms: ms, detail: detail)
    }

    private func recordDiagnostic(_ stage: String, detail: String? = nil) {
        recordTimeline(stage, detail: detail)
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState(updatingStage: stage)
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
            os_log("diagnostic stage=%{public}@ interface=%{public}@",
                   log: log, type: .info, state.stage, state.defaultInterfaceName)
        }
    }

    /// 接口监控只刷新当前快照，不允许把已经推进的启动 stage 写回旧值。
    private func refreshDiagnostic() {
        diagnosticWriteQueue.sync {
            let state = captureDiagnosticState()
            persistDiagnostic(makeDiagnosticSnapshot(from: state, includeEngine: false))
        }
    }

    private func persistDiagnostic(_ snapshot: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: snapshot),
           let text = String(data: data, encoding: .utf8) {
            let defaults = UserDefaults(suiteName: Self.appGroupID)
            defaults?.set(text, forKey: Self.diagnosticKey)
            // 诊断的价值恰恰在进程异常退出时仍可读取；这里主动落盘，避免只留在缓存。
            defaults?.synchronize()
        }
    }

    private func diagnosticSnapshot(includeEngine: Bool) -> [String: Any] {
        makeDiagnosticSnapshot(from: captureDiagnosticState(), includeEngine: includeEngine)
    }

    private func makeDiagnosticSnapshot(
        from state: DiagnosticState,
        includeEngine: Bool
    ) -> [String: Any] {
        var snapshot: [String: Any] = [
            "stage": state.stage,
            "timestamp": Date().timeIntervalSince1970,
            "default_interface_name": state.defaultInterfaceName,
            "default_interface_index": state.defaultInterfaceIndex,
            // 旧 App 仍读取这两个键；完成桌面迁移并提升诊断 schema 后删除。
            "physical_interface_name": state.defaultInterfaceName,
            "physical_interface_index": state.defaultInterfaceIndex,
        ]
        if !state.attemptID.isEmpty {
            snapshot["attempt_id"] = state.attemptID
        }
        if let lastError = state.lastError, !lastError.isEmpty {
            snapshot["last_error"] = lastError
        }
        if includeEngine, let engineJSON = currentEngine()?.diagnostics(),
           let data = engineJSON.data(using: .utf8),
           let engine = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            snapshot["engine"] = sanitizedDiagnosticObject(engine)
        }
        return snapshot
    }

    private func setDiagnosticSensitiveValues(from bundle: StartBundle) {
        var values = Set([bundle.server, bundle.username, bundle.password])
        if let data = bundle.configJSON.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            collectDiagnosticSensitiveValues(from: object, key: nil, into: &values)
        }
        diagnosticLock.lock()
        diagnosticSensitiveValues = values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        diagnosticLock.unlock()
    }

    private func collectDiagnosticSensitiveValues(
        from object: Any,
        key: String?,
        into values: inout Set<String>
    ) {
        if let dictionary = object as? [String: Any] {
            for (childKey, child) in dictionary {
                collectDiagnosticSensitiveValues(from: child, key: childKey, into: &values)
            }
            return
        }
        if let array = object as? [Any] {
            for child in array {
                collectDiagnosticSensitiveValues(from: child, key: key, into: &values)
            }
            return
        }
        guard let value = object as? String, let key else { return }
        switch key.lowercased() {
        case "server", "server_name", "username", "password", "uuid", "url", "path":
            values.insert(value)
        default:
            break
        }
    }

    private func sanitizedDiagnosticText(_ value: String?) -> String? {
        guard var result = value, !result.isEmpty else { return value }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            for match in detector.matches(in: result, range: range).reversed() {
                guard let swiftRange = Range(match.range, in: result) else { continue }
                result.replaceSubrange(swiftRange, with: "<redacted-url>")
            }
        }
        diagnosticLock.lock()
        let sensitiveValues = diagnosticSensitiveValues
        diagnosticLock.unlock()
        for sensitive in sensitiveValues {
            result = result.replacingOccurrences(of: sensitive, with: "<redacted>")
        }
        return String(result.prefix(1_024))
    }

    private func sanitizedDiagnosticObject(_ object: Any) -> Any {
        if let dictionary = object as? [String: Any] {
            return dictionary.mapValues { sanitizedDiagnosticObject($0) }
        }
        if let array = object as? [Any] {
            return array.map { sanitizedDiagnosticObject($0) }
        }
        if let text = object as? String {
            return sanitizedDiagnosticText(text) ?? ""
        }
        return object
    }

    // MARK: - tun fd 获取

    /// 取 NE packetFlow 对应的文件描述符。
    ///
    /// NEPacketTunnelFlow 不公开暴露底层 fd。直接采用 sing-box Apple 客户端的
    /// 官方做法：扫描扩展进程持有的 utun control socket。不要先读私有 KVC keyPath；
    /// key 不存在时会抛 Objective-C exception，Swift 无法捕获并会让扩展直接退出。
    private func tunFileDescriptor() -> Int? {
        let discoveredFD = LibboxGetTunnelFileDescriptor()
        if discoveredFD > 0 { return Int(discoveredFD) }
        return nil
    }

    // MARK: - 引擎启动

    /// 冷启动与换引擎共用。带线路运行身份的启动包使用可被切换候选借用的入口。
    /// AnyConnect 启动后必须拿到企业 DNS，否则视为失败。
    private func startEngine(_ engine: LibboxLibbox, bundle: StartBundle, dialAddress: String) throws {
        if bundle.usesAnyConnect {
            if bundle.anyConnectRuntimeIdentity.isEmpty {
                try engine.startResolved(
                    withInsecure: bundle.server,
                    dialAddress: dialAddress,
                    username: bundle.username,
                    password: bundle.password,
                    allowInsecure: bundle.allowInsecure,
                    configJSON: bundle.configJSON
                )
            } else {
                try engine.startResolved(
                    withLineRuntimes: bundle.server,
                    dialAddress: dialAddress,
                    username: bundle.username,
                    password: bundle.password,
                    allowInsecure: bundle.allowInsecure,
                    anyConnectRuntimeIdentity: bundle.anyConnectRuntimeIdentity,
                    tailscaleLineID: bundle.tailscaleLineID,
                    tailscaleRuntimeIdentity: bundle.tailscaleRuntimeIdentity,
                    configJSON: bundle.configJSON
                )
            }
            guard let dnsServers = validDNSServers(from: engine.tunnelNameServers()),
                  !dnsServers.isEmpty else {
                throw providerError(6, "连接未下发可用的域名服务器")
            }
            return
        }
        if bundle.tailscaleRuntimeIdentity.isEmpty {
            try engine.startStandalone(bundle.configJSON)
        } else {
            try engine.startStandalone(
                withTailscaleLineID: bundle.tailscaleLineID,
                runtimeIdentity: bundle.tailscaleRuntimeIdentity,
                configJSON: bundle.configJSON
            )
        }
    }

    // MARK: - 错误构造

    private func providerError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: Self.subsystem, code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

#if os(iOS)
// MARK: - 场景切换与后台判断（iOS）

/// 已连接期间，场景由扩展独自判断和切换，系统 VPN 不断开。
///
/// 切换有两种做法：
/// - 新场景在旁边准备：线路身份相同或只有一边用到 AnyConnect / Tailscale 时，候选 Box 先完整启动
///   并确认出口可达，提交时才接手系统隧道；准备失败时旧场景照常承载流量。
/// - 换引擎：其他情况下先停旧引擎，在同一个 NE 会话里起新引擎；新引擎失败时用旧场景再起一次。
///
/// 启动包来自 App 写进共享 Keychain 的场景目录（ScenarioSwitchCatalog）。
extension PacketTunnelProvider {
    private struct ScenarioSwitchOutcome {
        let bundle: StartBundle
        let remoteAddress: String
        let mode: TunnelScenarioState.SwitchRecord.Mode
    }

    private func scenarioError(_ message: String) -> NSError {
        providerError(40, message)
    }

    // MARK: 状态

    private func withScenarioState<T>(_ body: (inout TunnelScenarioState) -> T) -> T {
        scenarioLock.lock()
        if !scenarioStateLoaded {
            scenarioStateLoaded = true
            if let stored = TunnelScenarioStateStore.load(appGroup: Self.appGroupID) {
                scenarioState = stored
            }
        }
        let result = body(&scenarioState)
        scenarioLock.unlock()
        return result
    }

    @discardableResult
    private func updateScenarioState(_ body: (inout TunnelScenarioState) -> Void) -> TunnelScenarioState {
        let snapshot = withScenarioState { state -> TunnelScenarioState in
            body(&state)
            state.updatedAt = Date()
            return state
        }
        TunnelScenarioStateStore.save(snapshot, appGroup: Self.appGroupID)
        return snapshot
    }

    func currentScenarioState() -> TunnelScenarioState {
        withScenarioState { $0 }
    }

    func runningScenarioID() -> String? {
        scenarioLock.lock()
        let id = runningBundle?.scenarioID
        scenarioLock.unlock()
        return id.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 连接建立后记下承载流量的启动包。按需冷启动的连接接着做一次完整判断（含出口地区）。
    private func recordRunningScenario(_ bundle: StartBundle, remoteAddress: String) {
        scenarioLock.lock()
        runningBundle = bundle
        settledSurvey = nil
        runningRemoteAddress = remoteAddress
        scenarioLock.unlock()
        updateScenarioState { state in
            state.runningScenarioID = bundle.scenarioID.isEmpty ? nil : bundle.scenarioID
            state.switchingTo = nil
        }
        if bundle.fromSecureEnvelope {
            scheduleScenarioEvaluation(after: 2)
        }
    }

    /// 隧道结束：App 不能再把旧状态当成正在运行的场景。
    func clearRunningScenario() {
        scenarioLock.lock()
        runningBundle = nil
        settledSurvey = nil
        scenarioEvaluationWorkItem?.cancel()
        scenarioEvaluationWorkItem = nil
        scenarioLock.unlock()
        updateScenarioState { state in
            state.runningScenarioID = nil
            state.switchingTo = nil
        }
    }

    // MARK: 场景目录

    private func catalogBundle(
        for scenarioID: String,
        expectedRevision: String?
    ) -> Result<StartBundle, Error> {
        guard case .available(let catalog) = ScenarioSwitchCatalogStore.load() else {
            return .failure(scenarioError("没有可用的场景启动配置，请打开 XDial 后重试"))
        }
        if let expectedRevision, catalog.revision != expectedRevision {
            return .failure(scenarioError("场景启动配置已更新，请重试"))
        }
        guard let data = catalog.entries[scenarioID],
              let envelope = try? JSONDecoder().decode(OnDemandStartEnvelope.self, from: data),
              var bundle = StartBundle.from(envelope: envelope, fromSecureEnvelope: false),
              bundle.scenarioID == scenarioID else {
            return .failure(scenarioError("缺少这个场景的启动配置，请打开 XDial 后重试"))
        }
        bundle.envelope = envelope
        return .success(bundle)
    }

    // MARK: 切换

    /// 切换到 scenarioID。同一时刻只有一个切换；completion 在切换结束后调用一次。
    func switchScenario(
        to scenarioID: String,
        origin: TunnelScenarioState.SwitchRecord.Origin,
        expectedRevision: String?,
        reapply: Bool = false,
        deadline: ScenarioSwitchDeadline = ScenarioSwitchDeadline(),
        decisionNetwork: String? = nil,
        automaticValidation: (@Sendable () -> Bool)? = nil,
        completion: @escaping @Sendable (Result<TunnelScenarioState, Error>) -> Void
    ) {
        lifecycleLock.lock()
        let generation = activeGeneration
        let running = attemptPhase == .running
        lifecycleLock.unlock()
        guard running else {
            completion(.failure(scenarioError("连接尚未建立")))
            return
        }
        scenarioLock.lock()
        guard !scenarioSwitchActive else {
            scenarioLock.unlock()
            completion(.failure(scenarioError("正在切换场景，请稍后再试")))
            return
        }
        guard let source = runningBundle else {
            scenarioLock.unlock()
            completion(.failure(scenarioError("当前连接由旧版 XDial 建立，请重新连接后再切换")))
            return
        }
        if source.scenarioID == scenarioID && !reapply {
            scenarioLock.unlock()
            completion(.success(currentScenarioState()))
            return
        }
        scenarioSwitchActive = true
        let sourceRemote = runningRemoteAddress
        scenarioLock.unlock()
        updateScenarioState { $0.switchingTo = scenarioID }
        let from = ScenarioNetworkIdentity.opaqueToken(source.scenarioID)
        let to = ScenarioNetworkIdentity.opaqueToken(scenarioID)
        recordDiagnostic("scenario_switch_begin", detail:
            "origin=\(origin.rawValue) action=\(reapply ? "reapply" : "switch") from=\(from) to=\(to)")

        let completionBox = UncheckedSendableBox(completion)
        engineOperationQueue.async { [weak self] in
            guard let self else { return }
            let outcome = self.runScenarioSwitch(
                from: source,
                sourceRemote: sourceRemote,
                to: scenarioID,
                expectedRevision: expectedRevision,
                generation: generation,
                deadline: deadline,
                automaticValidation: automaticValidation
            )
            let state = self.finishScenarioSwitch(
                from: source,
                to: scenarioID,
                origin: origin,
                decisionNetwork: decisionNetwork,
                outcome: outcome
            )
            switch outcome {
            case .success:
                completionBox.value(.success(state))
            case .failure(let error):
                completionBox.value(.failure(error))
            }
            self.runPendingScenarioEvaluation()
        }
    }

    private func finishScenarioSwitch(
        from source: StartBundle,
        to scenarioID: String,
        origin: TunnelScenarioState.SwitchRecord.Origin,
        decisionNetwork: String?,
        outcome: Result<ScenarioSwitchOutcome, Error>
    ) -> TunnelScenarioState {
        scenarioLock.lock()
        if case .success(let switched) = outcome {
            runningBundle = switched.bundle
            runningRemoteAddress = switched.remoteAddress
        }
        scenarioSwitchActive = false
        scenarioLock.unlock()

        if case .success(let switched) = outcome {
            setDiagnosticSensitiveValues(from: switched.bundle)
            // 系统按需冷启动以后也用新场景。只在 App 开启了按需连接（信封存在）时写。
            if let envelope = switched.bundle.envelope,
               case .available = OnDemandStartEnvelopeStore.load() {
                OnDemandStartEnvelopeStore.save(envelope)
            }
            if source.scenarioID != scenarioID {
                ConnectionNotice.scenario.post(scenarioName: switched.bundle.scenarioName)
            }
            recordDiagnostic("scenario_switch_\(switched.mode.rawValue)")
            if !switched.bundle.scenarioName.isEmpty {
                activityUpdater.updateScenarioName(switched.bundle.scenarioName)
            }
        } else if case .failure(let error) = outcome {
            recordDiagnostic("scenario_switch_failed", detail: ConnectionTimeline.failureKeywords(error.localizedDescription))
        }
        return updateScenarioState { state in
            state.switchingTo = nil
            switch outcome {
            case .success(let switched):
                state.runningScenarioID = scenarioID
                state.lastSwitch = .init(
                    from: source.scenarioID, to: scenarioID, origin: origin, mode: switched.mode,
                    at: Date(), succeeded: true, failure: nil
                )
                if origin == .automatic {
                    state.guardState.note(from: source.scenarioID, to: scenarioID, network: decisionNetwork)
                }
                if state.suggestedScenarioID == scenarioID {
                    state.suggestedScenarioID = nil
                }
            case .failure(let error):
                state.lastSwitch = .init(
                    from: source.scenarioID, to: scenarioID, origin: origin, mode: nil,
                    at: Date(), succeeded: false, failure: sanitizedDiagnosticText(error.localizedDescription)
                )
            }
        }
    }

    private func runScenarioSwitch(
        from source: StartBundle,
        sourceRemote: String,
        to scenarioID: String,
        expectedRevision: String?,
        generation: UInt64,
        deadline: ScenarioSwitchDeadline,
        automaticValidation: (@Sendable () -> Bool)?
    ) -> Result<ScenarioSwitchOutcome, Error> {
        dispatchPrecondition(condition: .onQueue(engineOperationQueue))
        do { _ = try deadline.probeTimeoutMS() } catch { return .failure(error) }
        guard let engine = engine(for: generation), phase(for: generation) == .running else {
            return .failure(scenarioError("连接已结束"))
        }
        let target: StartBundle
        switch catalogBundle(for: scenarioID, expectedRevision: expectedRevision) {
        case .success(let bundle): target = bundle
        case .failure(let error): return .failure(error)
        }
        guard let underlay = currentUnderlay() else {
            return .failure(scenarioError("当前没有可用的网络"))
        }

        // 新 AnyConnect 服务器的地址在旧引擎还提供 DNS 时解析。
        var targetRemote = "127.0.0.1"
        if target.usesAnyConnect {
            var resolveError: NSError?
            let address = LibboxResolveServerIPv4(target.server, &resolveError)
            guard resolveError == nil, IPv4Address(address) != nil else {
                return .failure(scenarioError(
                    "无法解析新场景的服务器地址：\(resolveError?.localizedDescription ?? "地址无效")"
                ))
            }
            targetRemote = address
        }
        guard automaticValidation?() != false else {
            return .failure(scenarioError("自动判断已失效"))
        }
        let remoteChanges = targetRemote != sourceRemote
        return ScenarioSwitchNetworkTransaction.run {
            if remoteChanges, let error = applyRunningNetworkSettings(
                buildNetworkSettings(remoteAddress: targetRemote, alsoExcluding: [sourceRemote]),
                generation: generation
            ) {
                throw error
            }
        } operation: {
            _ = try deadline.probeTimeoutMS()
            let mode: TunnelScenarioState.SwitchRecord.Mode
            if canStageScenarioSwitch(from: source, to: target) {
                try stagedScenarioSwitch(
                    engine, to: target, dialAddress: targetRemote, underlay: underlay,
                    generation: generation, deadline: deadline, automaticValidation: automaticValidation
                ).get()
                mode = .staged
            } else {
                try restartScenarioSwitch(
                    engine, from: source, sourceDialAddress: sourceRemote,
                    to: target, targetDialAddress: targetRemote, underlay: underlay,
                    generation: generation, deadline: deadline, automaticValidation: automaticValidation
                ).get()
                mode = .restart
            }
            return ScenarioSwitchOutcome(bundle: target, remoteAddress: targetRemote, mode: mode)
        } settle: { committed in
            guard remoteChanges, phase(for: generation) == .running else { return }
            // One owner restores source settings for every failure, including preparation
            // and deadline failures. Successful commits drop the old server exclusion.
            _ = applyRunningNetworkSettings(
                buildNetworkSettings(remoteAddress: committed ? targetRemote : sourceRemote),
                generation: generation
            )
        }
    }

    /// 新场景能不能在旧场景旁边准备：两边用到的 AnyConnect / Tailscale 要么只有一边有，
    /// 要么运行身份完全相同（借用已连接的会话）。
    private func canStageScenarioSwitch(from source: StartBundle, to target: StartBundle) -> Bool {
        if target.usesAnyConnect {
            guard !target.anyConnectRuntimeIdentity.isEmpty else { return false }
            if source.usesAnyConnect,
               source.anyConnectRuntimeIdentity != target.anyConnectRuntimeIdentity {
                return false
            }
        }
        let sourceEndpoints = tailscaleEndpointTags(in: source.configJSON)
        let targetEndpoints = tailscaleEndpointTags(in: target.configJSON)
        if !sourceEndpoints.isEmpty, !targetEndpoints.isEmpty {
            // 同一 Profile 的 Tailscale 共用一份状态目录。只有两边都只用同一条、由进程持有的
            // Tailscale 线路时才能并存；其他情况旧代与候选会争同一份状态。
            let shared = target.usesTailscale
                && source.usesTailscale
                && source.tailscaleRuntimeIdentity == target.tailscaleRuntimeIdentity
                && sourceEndpoints == ["tailscale-" + source.tailscaleLineID]
                && targetEndpoints == ["tailscale-" + target.tailscaleLineID]
            if !shared { return false }
        }
        if target.usesTailscale, target.tailscaleRuntimeIdentity.isEmpty {
            return false
        }
        return true
    }

    private func tailscaleEndpointTags(in configJSON: String) -> Set<String> {
        guard let data = configJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let endpoints = object["endpoints"] as? [[String: Any]] else { return [] }
        return Set(endpoints.compactMap { endpoint in
            endpoint["type"] as? String == "tailscale" ? endpoint["tag"] as? String : nil
        })
    }

    /// Both switching paths use the same complete acceptance plan. Engine startup alone
    /// does not prove Tailscale authentication or an outbound's reachability.
    private func verifyScenarioLines(_ engine: LibboxLibbox, bundle: StartBundle, prepared: Bool, deadline: ScenarioSwitchDeadline) throws {
        guard let data = bundle.acceptancePlanJSON.data(using: .utf8),
              let plan = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let targets = plan["targets"] as? [[String: Any]], !targets.isEmpty else {
            throw scenarioError("场景缺少线路验收计划")
        }
        for tag in tailscaleEndpointTags(in: bundle.configJSON).sorted() {
            var statusError: NSError?
            let raw = prepared
                ? engine.preparedSwitchTailscaleStatus(tag, error: &statusError)
                : engine.tailscaleStatus(tag, error: &statusError)
            if let statusError { throw statusError }
            guard tailscaleBackendIsRunning(raw) else { throw scenarioError("Tailscale 尚未就绪") }
        }
        for target in targets {
            guard let tag = target["tag"] as? String, !tag.isEmpty else {
                throw scenarioError("场景线路验收计划无效")
            }
            let timeoutMS = try deadline.probeTimeoutMS()
            var error: NSError?
            let address = prepared
                ? engine.probePreparedSwitchOutboundIP(tag, timeoutMS: timeoutMS, error: &error)
                : engine.probeOutboundIP(tag, timeoutMS: timeoutMS, error: &error)
            guard error == nil, !address.isEmpty else {
                throw scenarioError("新场景的线路暂时不可用：\(error?.localizedDescription ?? "出口无回应")")
            }
        }
    }

    private func stagedScenarioSwitch(
        _ engine: LibboxLibbox,
        to target: StartBundle,
        dialAddress: String,
        underlay: UnderlaySnapshot,
        generation: UInt64,
        deadline: ScenarioSwitchDeadline,
        automaticValidation: (@Sendable () -> Bool)?
    ) -> Result<Void, Error> {
        do {
            if target.usesAnyConnect {
                try engine.prepareSwitch(
                    withAnyConnectAndLineRuntimeIDs: target.server,
                    dialAddress: dialAddress,
                    username: target.username,
                    password: target.password,
                    allowInsecure: target.allowInsecure,
                    anyConnectLineID: target.anyConnectLineID,
                    anyConnectRuntimeIdentity: target.anyConnectRuntimeIdentity,
                    tailscaleLineID: target.tailscaleLineID,
                    tailscaleRuntimeIdentity: target.tailscaleRuntimeIdentity,
                    configJSON: target.configJSON,
                    networkInterfacesJSON: underlay.interfacesJSON,
                    defaultInterfaceName: underlay.name,
                    defaultInterfaceIndex: underlay.index
                )
            } else {
                try engine.prepareSwitch(
                    withLineRuntimeIDs: target.configJSON,
                    anyConnectLineID: "",
                    anyConnectRuntimeIdentity: "",
                    tailscaleLineID: target.tailscaleLineID,
                    tailscaleRuntimeIdentity: target.tailscaleRuntimeIdentity,
                    networkInterfacesJSON: underlay.interfacesJSON,
                    defaultInterfaceName: underlay.name,
                    defaultInterfaceIndex: underlay.index
                )
            }
        } catch {
            return .failure(scenarioError("新场景没能准备好：\(error.localizedDescription)"))
        }
        recordDiagnostic("scenario_switch_prepared")
        do { try verifyScenarioLines(engine, bundle: target, prepared: true, deadline: deadline) }
        catch {
            try? engine.abortPreparedSwitch()
            return .failure(error)
        }
        guard automaticValidation?() != false else {
            try? engine.abortPreparedSwitch()
            return .failure(scenarioError("自动判断已失效"))
        }
        guard phase(for: generation) == .running, self.engine(for: generation) === engine else {
            try? engine.abortPreparedSwitch()
            return .failure(scenarioError("连接已结束"))
        }
        do {
            _ = try deadline.probeTimeoutMS()
        } catch {
            try? engine.abortPreparedSwitch()
            return .failure(error)
        }
        recordTimeline("scenario_switch_handover")
        do {
            try engine.commitPreparedSwitch()
        } catch {
            // 隧道两边都没接上时 Go 已经报告错误，Provider 会结束这次连接。
            try? engine.abortPreparedSwitch()
            return .failure(scenarioError("新场景没能接手连接：\(error.localizedDescription)"))
        }
        try? engine.retireCommittedSwitch()
        return .success(())
    }

    private func restartScenarioSwitch(
        _ engine: LibboxLibbox,
        from source: StartBundle,
        sourceDialAddress: String,
        to target: StartBundle,
        targetDialAddress: String,
        underlay: UnderlaySnapshot,
        generation: UInt64,
        deadline: ScenarioSwitchDeadline,
        automaticValidation: (@Sendable () -> Bool)?
    ) -> Result<Void, Error> {
        // 先让旧实例的回调失效，再停它：停止时报上来的「已断开」不是掉线。
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .running, libbox === engine else {
            lifecycleLock.unlock()
            return .failure(scenarioError("连接已结束"))
        }
        activeEngineToken = 0
        lifecycleLock.unlock()
        try? engine.stop()
        recordDiagnostic("scenario_switch_restarting")

        switch startReplacementEngine(target, dialAddress: targetDialAddress, underlay: underlay, generation: generation,
                                      verifyLines: true, deadline: deadline, automaticValidation: automaticValidation) {
        case .success:
            return .success(())
        case .failure(let targetError):
            if case .failure(let restoreError) = startReplacementEngine(
                source, dialAddress: sourceDialAddress, underlay: underlay, generation: generation
            ) {
                recordTimeline("scenario_switch_restore_failed", detail: ConnectionTimeline.failureKeywords(restoreError.localizedDescription))
                terminateRunningAttempt(generation, error: providerError(
                    41,
                    "切换场景失败，原来的场景也没能恢复：\(restoreError.localizedDescription)"
                ))
            } else {
                recordTimeline("scenario_switch_restored")
            }
            return .failure(scenarioError("新场景没能连上：\(targetError.localizedDescription)"))
        }
    }

    /// 在当前 NE 会话里起一个新引擎实例并接手隧道。
    private func startReplacementEngine(
        _ bundle: StartBundle,
        dialAddress: String,
        underlay: UnderlaySnapshot,
        generation: UInt64,
        verifyLines: Bool = false,
        deadline: ScenarioSwitchDeadline? = nil,
        automaticValidation: (@Sendable () -> Bool)? = nil
    ) -> Result<Void, Error> {
        do { _ = try deadline?.probeTimeoutMS() } catch { return .failure(error) }
        guard let fd = tunFileDescriptor(), fd > 0 else {
            return .failure(providerError(4, "无法获取系统隧道接口"))
        }
        let token = makeEngineToken()
        let callback = EngineCallback(provider: self, generation: generation, engineToken: token)
        guard let replacement = LibboxNew(callback) else {
            return .failure(providerError(4, "LibboxNew 返回 nil"))
        }
        replacement.setDebugRoutingProbeEnabled(true)
        replacement.setSwitchTUNHandover(true)
        replacement.setTunFD(fd)
        try? replacement.setNetworkInterfaces(underlay.interfacesJSON)
        replacement.setDefaultInterface(underlay.name, index: underlay.index)
        do {
            try startEngine(replacement, bundle: bundle, dialAddress: dialAddress)
        } catch {
            try? replacement.stop()
            return .failure(error)
        }
        let installed = pathMonitorQueue.sync { () -> Bool in
            lifecycleLock.lock()
            guard activeGeneration == generation, attemptPhase == .running else {
                lifecycleLock.unlock()
                return false
            }
            libbox = replacement
            activeEngineToken = token
            lifecycleLock.unlock()
            // Serialized with path delivery: replay the latest facts after publication.
            let latest = currentUnderlay()
            try? replacement.setNetworkInterfaces(latest?.interfacesJSON ?? "[]")
            replacement.setDefaultInterface(latest?.name ?? "", index: latest?.index ?? -1)
            return true
        }
        guard installed else {
            try? replacement.stop()
            return .failure(scenarioError("连接已结束"))
        }
        do {
            if verifyLines, let deadline {
                try verifyScenarioLines(replacement, bundle: bundle, prepared: false, deadline: deadline)
            }
            _ = try deadline?.probeTimeoutMS()
            guard automaticValidation?() != false else { throw scenarioError("自动判断已失效") }
        } catch {
            lifecycleLock.lock()
            if activeEngineToken == token { activeEngineToken = 0 }
            lifecycleLock.unlock()
            try? replacement.stop()
            return .failure(error)
        }
        return .success(())
    }

    /// 连接运行期间更新系统隧道设置（AnyConnect 服务器地址变化时）。在引擎队列上同步等待。
    private func applyRunningNetworkSettings(
        _ settings: NEPacketTunnelNetworkSettings,
        generation: UInt64
    ) -> Error? {
        let result = OneShotNetworkSettingsResult()
        let done = DispatchSemaphore(value: 0)
        let settingsBox = UncheckedSendableBox(settings)
        networkSettingsSubmissionLock.lock()
        lifecycleLock.lock()
        guard activeGeneration == generation, attemptPhase == .running else {
            lifecycleLock.unlock()
            networkSettingsSubmissionLock.unlock()
            return scenarioError("连接已结束")
        }
        networkSettingsOperationQueue.async {
            guard self.phase(for: generation) == .running else {
                _ = result.finish(self.scenarioError("连接已结束"))
                done.signal()
                return
            }
            let finished = DispatchSemaphore(value: 0)
            self.setTunnelNetworkSettings(settingsBox.value) { error in
                if result.finish(error) { finished.signal() }
            }
            if finished.wait(timeout: .now() + 15) == .timedOut {
                _ = result.finish(self.providerError(31, "应用系统网络设置超时"))
            }
            done.signal()
        }
        lifecycleLock.unlock()
        networkSettingsSubmissionLock.unlock()
        done.wait()
        return result.snapshot().error
    }

    // MARK: 后台判断

    /// 物理网络（接口或网关）变化后稳定 1.5 秒再判断。VPN 自己的虚拟网卡不算。
    func notePathForScenario(_ path: NWPath) {
        let physical = path.availableInterfaces
            .filter { $0.type == .wifi || $0.type == .cellular || $0.type == .wiredEthernet }
            .map { "\($0.type):\($0.name)" }
            .sorted().joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        let signature = "\(path.status):\(physical):\(gateways)"
        scenarioLock.lock()
        let previous = lastPathSignature
        if signature != previous { settledSurvey = nil }
        lastPathSignature = signature
        let running = runningBundle != nil
        scenarioLock.unlock()
        guard running, previous != nil, path.status == .satisfied else { return }
        scheduleScenarioEvaluation(after: 1.5, pathNotification: true)
    }

    func scheduleScenarioEvaluation(after delay: TimeInterval, pathNotification: Bool = false) {
        let work = DispatchWorkItem { [weak self] in
            self?.performScenarioEvaluation(pathNotification: pathNotification) { _ in }
        }
        scenarioLock.lock()
        scenarioEvaluationWorkItem?.cancel()
        scenarioEvaluationWorkItem = work
        scenarioLock.unlock()
        scenarioQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func runPendingScenarioEvaluation() {
        scenarioLock.lock()
        let pending = scenarioEvaluationPending
        scenarioEvaluationPending = false
        scenarioLock.unlock()
        if pending { scheduleScenarioEvaluation(after: 0.5) }
    }

    /// App 回到前台或打开「自动」时主动刷新，不复用路径通知的结果。
    func evaluateScenario(
        deadline: ScenarioSwitchDeadline = ScenarioSwitchDeadline(),
        completion: (@Sendable (TunnelScenarioState) -> Void)?
    ) {
        let completionBox = UncheckedSendableBox(completion)
        scenarioQueue.async { [weak self] in
            guard let self else { return }
            self.performScenarioEvaluation(pathNotification: false, deadline: deadline) { state in completionBox.value?(state) }
        }
    }

    private func performScenarioEvaluation(pathNotification: Bool, deadline: ScenarioSwitchDeadline = ScenarioSwitchDeadline(), completion: @escaping @Sendable (TunnelScenarioState) -> Void) {
        dispatchPrecondition(condition: .onQueue(scenarioQueue))
        guard case .available(let catalog) = ScenarioSwitchCatalogStore.load(),
              catalog.policy.enabled,
              let engine = currentEngine(), engine.isRunning() else {
            completion(currentScenarioState())
            return
        }
        scenarioLock.lock()
        let busy = scenarioSwitchActive
        if busy { scenarioEvaluationPending = true }
        let runningID = runningBundle?.scenarioID ?? ""
        let network = lastPathSignature
        scenarioLock.unlock()
        guard !busy, !runningID.isEmpty else {
            completion(currentScenarioState())
            return
        }

        let surveyStart = ProcessInfo.processInfo.systemUptime
        let previousSwitch = currentScenarioState().lastSwitch
        let policy = catalog.policy
        let ssid = readCurrentSSID()
        let place = policy.placePick()
        let decisionNetwork = ScenarioNetworkIdentity.key(path: network, ssid: ssid)
            + (place.map { ":place:" + $0.scenarioID } ?? "")
        let context = ScenarioSurveyContext(network: decisionNetwork, revision: catalog.revision,
                                            policy: policy, runningID: runningID)
        scenarioLock.lock()
        let duplicate = pathNotification && settledSurvey?.covers(context, now: surveyStart) == true
        // A new SSID can share its predecessor’s interface and gateway. Read it
        // before deduplicating, off the path monitor and engine queues.
        if !duplicate { settledSurvey = nil }
        scenarioLock.unlock()
        if duplicate {
            completion(currentScenarioState())
            return
        }
        let ssidRead = !(ssid?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        var pick = place ?? ScenarioAutoDecision.wifiPick(ssid: ssid, rules: policy.wifiRules)
        var exit: ScenarioSurveyRecord.ExitLookup = .notNeeded
        let networkToken = ScenarioNetworkIdentity.diagnosticToken(path: network, ssid: ssid)
        var evidence = RegionProbeEvidence()
        var probeDetail = ""
        var probeResult: ConnectionTimeline.Result?
        if pick == nil, !policy.regionScenarios.isEmpty {
            var probeError: NSError?
            let regionStartedAt = ProcessInfo.processInfo.systemUptime
            let raw = engine.probeOutboundCountryEvidence("direct", timeoutMS: 8_000, error: &probeError)
            evidence = RegionProbeEvidence.decode(raw)
            evidence.ms = evidence.ms ?? ConnectionTimeline.elapsedMilliseconds(since: regionStartedAt)
            let code = evidence.code ?? ""
            let basis = "path=direct service=\(evidence.endpoint ?? "none")"
                + (evidence.attempts.isEmpty ? "" : " failed=\(evidence.attempts)")
            if let probeError {
                let failure = probeError.localizedDescription
                probeResult = ConnectionTimeline.classify(probeFailure: failure)
                probeDetail = ConnectionTimeline.failureKeywords(failure) + " " + basis
            } else {
                probeResult = .ok
                probeDetail = "region=\(code) " + basis
            }
            if probeError == nil, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isUppercase }) {
                exit = .found(code: code, viaTunnel: true)
                pick = ScenarioAutoDecision.regionPick(
                    countryCode: code,
                    regionScenarios: policy.regionScenarios,
                    scenarioIDs: policy.scenarioIDs
                )
            } else {
                exit = .failed(viaTunnel: true, reason: probeError.map { sanitizedDiagnosticText($0.localizedDescription) ?? "" })
            }
        }
        let choice = pick.map { picked in
            picked.scenarioID == runningID ? "current" : "other-" + ScenarioNetworkIdentity.opaqueToken(picked.scenarioID)
        } ?? "none"
        let decision = "network=\(networkToken) ssid=\(ssidRead ? "read" : "unread") pick=\(choice)"
            + " running=\(ScenarioNetworkIdentity.opaqueToken(runningID))"
        recordTimeline(
            "scenario_decision", result: probeResult, ms: ConnectionTimeline.elapsedMilliseconds(since: surveyStart),
            detail: decision + " " + probeDetail)
        let record = ScenarioSurveyRecord(
            at: Date(),
            ssidRead: ssidRead,
            ssidMatched: pick.map { if case .wifi = $0.reason { return true } else { return false } } ?? false,
            exit: exit,
            picked: pick != nil,
            byTunnel: true
        )
        var survey = record
        survey.exitEndpoint = evidence.endpoint
        survey.exitAttempts = evidence.attempts.isEmpty ? nil : evidence.attempts
        survey.exitMS = evidence.ms
        survey.networkToken = networkToken

        let validation: @Sendable () -> Bool = { [weak self] in
            guard let self, case .available(let latest) = ScenarioSwitchCatalogStore.load(),
                  latest.revision == catalog.revision, latest.policy.hasSameRules(as: policy), latest.policy.enabled, latest.policy.placePick() == place,
                  self.currentEngine()?.isRunning() == true else { return false }
            self.scenarioLock.lock()
            let valid = self.runningBundle?.scenarioID == runningID && self.lastPathSignature == network
            self.scenarioLock.unlock()
            return valid && self.currentScenarioState().lastSwitch == previousSwitch && self.readCurrentSSID() == ssid
        }
        guard validation() else {
            recordTimeline("scenario_decision_discarded", result: .cancelled,
                           detail: "network or catalog changed during the lookup")
            completion(currentScenarioState())
            return
        }
        var shouldSwitch = false
        let state = updateScenarioState { state in
            if pick?.scenarioID == runningID && self.lastPathSignature == network {
                self.settledSurvey = .init(context: context, at: surveyStart)
            }
            state.lastSurvey = survey
            guard let pick else {
                state.suggestedScenarioID = nil
                return
            }
            state.lastPick = pick
            guard pick.scenarioID != runningID else {
                state.suggestedScenarioID = nil
                return
            }
            // 目录里没有这个场景（比如它的配置还不完整）：只提示，由用户在 App 里切换。
            guard catalog.entries[pick.scenarioID] != nil else {
                state.suggestedScenarioID = pick.scenarioID
                return
            }
            if state.guardState.mayAutoSwitch(to: pick.scenarioID, network: decisionNetwork) {
                shouldSwitch = true
            } else {
                state.suggestedScenarioID = pick.scenarioID
            }
        }
        guard shouldSwitch, let pick else {
            completion(state)
            return
        }
        // 切换在引擎队列上进行；判断队列等它结束，避免两次判断交错。
        let finished = DispatchSemaphore(value: 0)
        // 判断与提交必须使用同一份目录和规则。
        switchScenario(to: pick.scenarioID, origin: .automatic, expectedRevision: catalog.revision,
                       deadline: deadline, decisionNetwork: decisionNetwork, automaticValidation: validation) { _ in
            finished.signal()
        }
        finished.wait()
        completion(currentScenarioState())
    }

    /// 读当前 Wi-Fi 名称。扩展声明了「访问 Wi-Fi 信息」；读不到时只按出口地区判断。
    private func readCurrentSSID() -> String? {
        final class Box: @unchecked Sendable { var ssid: String? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        NEHotspotNetwork.fetchCurrent { network in
            box.ssid = network?.ssid
            done.signal()
        }
        guard done.wait(timeout: .now() + 3) == .success else { return nil }
        return box.ssid
    }

    /// 按需冷启动时（系统换网络后自动拉起），先按 Wi-Fi 名称挑场景再拨号；
    /// 出口地区要等连上以后才查得到，由连接后的那次判断处理。
    private func preferredColdStartBundle(for bundle: StartBundle) -> StartBundle? {
        guard bundle.fromSecureEnvelope,
              case .available(let catalog) = ScenarioSwitchCatalogStore.load(),
              catalog.policy.enabled,
              let pick = ScenarioAutoDecision.wifiPick(ssid: readCurrentSSID(), rules: catalog.policy.wifiRules),
              pick.scenarioID != bundle.scenarioID,
              let data = catalog.entries[pick.scenarioID],
              let envelope = try? JSONDecoder().decode(OnDemandStartEnvelope.self, from: data),
              let preferred = StartBundle.from(envelope: envelope, fromSecureEnvelope: true),
              preferred.scenarioID == pick.scenarioID else { return nil }
        updateScenarioState { state in
            state.lastPick = pick
            state.lastSurvey = ScenarioSurveyRecord(
                at: Date(), ssidRead: true, ssidMatched: true, exit: .notNeeded, picked: true, byTunnel: true
            )
        }
        return preferred
    }

    // MARK: App 消息

    func handleScenarioMessage(
        _ cmd: String,
        _ object: [String: Any],
        completion: @escaping @Sendable (Data?) -> Void
    ) -> Bool {
        switch cmd {
        case "scenario-state":
            completion(scenarioStateResponse(currentScenarioState()))
        case "scenario-evaluate":
            evaluateScenario(deadline: ScenarioSwitchDeadline(requested: object[ScenarioSwitchDeadline.requestKey] as? TimeInterval)) { [weak self] state in
                completion(self?.scenarioStateResponse(state))
            }
        case "scenario-switch", "scenario-reapply":
            guard let scenarioID = object["scenario_id"] as? String, !scenarioID.isEmpty else {
                completion(encodeResponse(ok: false, message: "场景切换参数不完整"))
                return true
            }
            switchScenario(
                to: scenarioID,
                origin: .app,
                expectedRevision: object["catalog_revision"] as? String,
                reapply: cmd == "scenario-reapply",
                deadline: ScenarioSwitchDeadline(requested: object[ScenarioSwitchDeadline.requestKey] as? TimeInterval)
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let state):
                    completion(self.scenarioStateResponse(state))
                case .failure(let error):
                    completion(self.encodeResponse(
                        ok: false,
                        message: error.localizedDescription,
                        dataString: self.currentScenarioState().encoded().flatMap { String(data: $0, encoding: .utf8) }
                    ))
                }
            }
        default:
            return false
        }
        return true
    }

    private func scenarioStateResponse(_ state: TunnelScenarioState) -> Data {
        encodeResponse(ok: true, dataString: state.encoded().flatMap { String(data: $0, encoding: .utf8) })
    }
}
#endif

/// 静态版错误构造:供 startTunnel 内 `[weak self]` 闭包在 self 已释放时使用。
private func providerErrorStatic(_ code: Int, _ message: String) -> NSError {
    return NSError(domain: XDialIdentity.tunnelBundleIdentifier, code: code,
            userInfo: [NSLocalizedDescriptionKey: message])
}

/// Evidence for one region lookup, decoded from `ProbeOutboundCountryEvidence`.
struct RegionProbeEvidence {
    var code: String?
    var endpoint: String?
    /// "service:code" for each attempt that failed before the answer.
    var attempts = ""
    var ms: Int?

    static func decode(_ raw: String) -> RegionProbeEvidence {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return RegionProbeEvidence()
        }
        var evidence = RegionProbeEvidence()
        evidence.code = (object["code"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        evidence.endpoint = (object["endpoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        evidence.attempts = (object["attempts"] as? [String] ?? []).joined(separator: ",")
        evidence.ms = (object["duration_ms"] as? NSNumber)?.intValue
        return evidence
    }
}
