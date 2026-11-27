import Darwin
import Foundation
import Network
import OSLog

/// 持有用户配置的本机 SOCKS5 端口。端口的生命周期属于 Provider，而不是某一代
/// sing-box：场景切换只改变新连接取得的会话入口，监听本身不动。
final class LocalSOCKSShareListener: @unchecked Sendable {
    private static let readyTimeout: DispatchTimeInterval = .seconds(5)

    private let queue: DispatchQueue
    private let accept: (NWConnection) -> Void
    private let logger: Logger
    private var listener: NWListener?
    private var listenerToken = UUID()
    private var status = LocalSOCKSShareStatus.off

    init(
        queueLabel: String,
        logger: Logger,
        accept: @escaping (NWConnection) -> Void
    ) {
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.logger = logger
        self.accept = accept
    }

    /// 同一端口已在监听时直接返回当前状态；其余情况重建监听并等到 ready 或失败。
    func configure(
        port: UInt16?,
        completion: @escaping (LocalSOCKSShareStatus) -> Void
    ) {
        queue.async {
            guard let port else {
                self.stopLocked()
                completion(self.status)
                return
            }
            if self.listener != nil,
               self.status == .listening(port) {
                completion(self.status)
                return
            }
            self.startLocked(port: port, completion: completion)
        }
    }

    func stop() {
        queue.sync { stopLocked() }
    }

    private func stopLocked() {
        listenerToken = UUID()
        listener?.cancel()
        listener = nil
        if status != .off {
            logger.notice("local-socks-share stopped")
        }
        status = .off
    }

    private func startLocked(
        port: UInt16,
        completion: @escaping (LocalSOCKSShareStatus) -> Void
    ) {
        stopLocked()
        let token = listenerToken
        var completed = false
        let finish: (LocalSOCKSShareStatus) -> Void = { status in
            guard !completed else { return }
            completed = true
            completion(status)
        }

        let parameters = NWParameters.tcp
        // 只绑回环，且不复用端口：被其他程序占用时必须如实失败，不能与之分流。
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: Network.NWEndpoint.Port(rawValue: port)!
        )
        parameters.acceptLocalOnly = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            status = .failed(port, code: (error as? NWError).map(
                LocalSOCKSShareStatus.failureCode(for:)
            ) ?? "listener-failed")
            finish(status)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listenerToken == token else { return }
            switch state {
            case .ready:
                self.status = .listening(port)
                self.logger.notice(
                    "local-socks-share listening port=\(port, privacy: .public)"
                )
                finish(self.status)
            case let .failed(error), let .waiting(error):
                self.fail(port: port, code: LocalSOCKSShareStatus.failureCode(for: error))
                finish(self.status)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.readyTimeout) { [weak self] in
            guard let self, self.listenerToken == token, !completed else { return }
            self.fail(port: port, code: "listener-timeout")
            finish(self.status)
        }
    }

    private func fail(port: UInt16, code: String) {
        listenerToken = UUID()
        listener?.cancel()
        listener = nil
        status = .failed(port, code: code)
        logger.error(
            "local-socks-share failed port=\(port, privacy: .public) code=\(code, privacy: .public)"
        )
    }
}

/// 一条本机 SOCKS5 客户端连接：先在本机完成无认证握手，再以会话凭据接入当前
/// generation 的 sing-box 入口，之后双向转发 TCP 字节或中继 UDP 关联。
enum LocalSOCKSShareRelay {
    static func makeHandle(
        client: NWConnection,
        socksPort: UInt16,
        credentials: SOCKSCredentials,
        trialID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger,
        adoptUDPAssociation: @escaping @Sendable () -> Bool = { true }
    ) -> ProviderRelayHandle {
        let upstream = NWConnection(
            host: .ipv4(IPv4Address.loopback),
            port: Network.NWEndpoint.Port(rawValue: socksPort)!,
            using: .tcp
        )
        let resources = LocalSOCKSRelayResources(
            client: client,
            upstream: upstream
        )
        let shutdown = RelayTaskShutdown { error in
            resources.close(with: error)
        }
        return ProviderRelayHandle(
            shutdown: shutdown,
            operation: {
                var stage = "client-connect"
                // 已经给客户端回过失败应答时要正常关闭（FIN），强制重置会让
                // 客户端在读到应答前就收到 RST，看不到失败原因。
                var answered = false
                await withTaskCancellationHandler {
                    do {
                        try await TCPFlowSOCKSRelay.start(client)
                        let read: LocalSOCKSHandshake.Read = { count in
                            try await TCPFlowSOCKSRelay.receiveExactly(count, from: client)
                        }
                        stage = "client-greeting"
                        do {
                            try await LocalSOCKSHandshake.readGreeting(read)
                        } catch LocalSOCKSHandshake.Failure.noAcceptableMethod {
                            try await TCPFlowSOCKSRelay.send(
                                LocalSOCKSHandshake.rejectAllMethods,
                                to: client
                            )
                            answered = true
                            throw LocalSOCKSHandshake.Failure.noAcceptableMethod
                        }
                        try await TCPFlowSOCKSRelay.send(
                            LocalSOCKSHandshake.acceptNoAuthentication,
                            to: client
                        )
                        stage = "client-request"
                        let request: LocalSOCKSHandshake.Request
                        do {
                            request = try await LocalSOCKSHandshake.readRequest(read)
                        } catch let failure as LocalSOCKSHandshake.Failure {
                            if let code = failure.replyCode,
                               (try? await TCPFlowSOCKSRelay.send(
                                   LocalSOCKSHandshake.reply(code),
                                   to: client
                               )) != nil {
                                answered = true
                            }
                            throw failure
                        }
                        switch request {
                        case let .connect(destination):
                            stage = "control-connect"
                            do {
                                try await TCPFlowSOCKSRelay.start(upstream)
                                stage = "socks-negotiate"
                                try await TCPFlowSOCKSRelay.negotiateSOCKS(
                                    upstream,
                                    credentials: credentials,
                                    host: destination.host,
                                    port: destination.port,
                                    encodedFlowMetadata: nil
                                )
                            } catch {
                                let code: UInt8
                                if case let TCPFlowSOCKSRelay.RelayError.connectRejected(rejected) = error {
                                    code = rejected
                                } else {
                                    code = LocalSOCKSHandshake.generalFailure
                                }
                                if (try? await TCPFlowSOCKSRelay.send(
                                    LocalSOCKSHandshake.reply(code),
                                    to: client
                                )) != nil {
                                    answered = true
                                }
                                throw error
                            }
                            try await TCPFlowSOCKSRelay.send(
                                LocalSOCKSHandshake.reply(0x00),
                                to: client
                            )
                            stage = "relay"
                            try await relay(
                                client: client,
                                upstream: upstream,
                                shutdown: shutdown,
                                transactionID: trialID,
                                traffic: traffic
                            )
                            shutdown.finish(with: nil)

                        case let .udpAssociate(clientPort):
                            resources.markUDPAssociation()
                            let localUDP: LoopbackUDPSocket
                            let upstreamUDP: NWConnection
                            do {
                                stage = "adopt-association"
                                guard adoptUDPAssociation() else {
                                    throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
                                }
                                stage = "local-udp-bind"
                                let socket = try LoopbackUDPSocket()
                                guard resources.install(localUDP: socket) else {
                                    throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
                                }
                                localUDP = socket
                                stage = "control-connect"
                                try await TCPFlowSOCKSRelay.start(upstream)
                                stage = "socks-negotiate"
                                let relayEndpoint = try await negotiateUpstreamUDPAssociate(
                                    upstream,
                                    credentials: credentials
                                )
                                stage = "relay-connect"
                                let datagram = NWConnection(
                                    to: relayEndpoint,
                                    using: .udp
                                )
                                guard resources.install(upstreamUDP: datagram) else {
                                    throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
                                }
                                try await TCPFlowSOCKSRelay.start(datagram)
                                upstreamUDP = datagram
                            } catch {
                                let code: UInt8
                                if case let TCPFlowSOCKSRelay.RelayError.connectRejected(rejected) = error {
                                    code = rejected
                                } else {
                                    code = LocalSOCKSHandshake.generalFailure
                                }
                                if (try? await TCPFlowSOCKSRelay.send(
                                    LocalSOCKSHandshake.reply(code),
                                    to: client
                                )) != nil {
                                    answered = true
                                }
                                throw error
                            }
                            try await TCPFlowSOCKSRelay.send(
                                LocalSOCKSHandshake.udpAssociateReply(port: localUDP.port),
                                to: client
                            )
                            stage = "relay"
                            try await relayUDP(
                                clientControl: client,
                                upstreamControl: upstream,
                                localUDP: localUDP,
                                upstreamUDP: upstreamUDP,
                                expectedClientPort: clientPort,
                                shutdown: shutdown,
                                transactionID: trialID,
                                traffic: traffic,
                                logger: logger
                            )
                            shutdown.finish(with: nil)
                        }
                    } catch {
                        logger.debug(
                            "local-socks-share closed trial=\(trialID, privacy: .public) stage=\(stage, privacy: .public) code=\(diagnosticCode(error), privacy: .public)"
                        )
                        if answered {
                            await lingerAfterReply(client)
                        }
                        shutdown.finish(with: answered ? nil : error)
                    }
                } onCancel: {
                    shutdown.finish(with: CancellationError())
                }
            }
        )
    }

    /// 失败应答发出后先半关闭（FIN），再读掉客户端已经发出的剩余字节。拒绝发生在
    /// 请求读完之前时（例如主机名非法、端口字节未读），带着未读数据关闭 TCP 会让
    /// 内核回 RST，客户端可能在读到应答前就看到连接被重置。等待有上限，客户端不关
    /// 也不会占住这条连接。
    static func lingerAfterReply(
        _ client: NWConnection,
        timeout: TimeInterval = 2
    ) async {
        try? await TCPFlowSOCKSRelay.finishSending(to: client)
        let deadline = DispatchWorkItem { client.cancel() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: deadline
        )
        defer { deadline.cancel() }
        while let result = try? await TCPFlowSOCKSRelay.receive(from: client),
              result.error == nil,
              !result.isComplete,
              !result.data.isEmpty {}
    }

    private static func diagnosticCode(_ error: Error) -> String {
        switch error {
        case LocalSOCKSHandshake.Failure.invalidVersion:
            return "client-invalid-version"
        case LocalSOCKSHandshake.Failure.noAcceptableMethod:
            return "client-no-acceptable-method"
        case LocalSOCKSHandshake.Failure.commandNotSupported:
            return "client-command-not-supported"
        case LocalSOCKSHandshake.Failure.addressTypeNotSupported:
            return "client-address-type-not-supported"
        case LocalSOCKSHandshake.Failure.invalidDestination:
            return "client-invalid-destination"
        case let posixError as POSIXError:
            return "posix-\(posixError.code.rawValue)"
        default:
            return TCPFlowSOCKSRelay.diagnosticCode(error)
        }
    }

    private static func relay(
        client: NWConnection,
        upstream: NWConnection,
        shutdown: RelayTaskShutdown,
        transactionID: String,
        traffic: ProviderTrafficLedger
    ) async throws {
        try await RelayTaskPair.run(
            first: {
                try await pump(from: client, to: upstream) {
                    traffic.recordUpload($0, transactionID: transactionID)
                }
            },
            second: {
                try await pump(from: upstream, to: client) {
                    traffic.recordDownload($0, transactionID: transactionID)
                }
            },
            shutdown: shutdown
        )
    }

    /// 单向转发到 EOF，再把 FIN 传给对端；另一方向继续工作，保留 TCP 半关闭。
    private static func pump(
        from source: NWConnection,
        to destination: NWConnection,
        record: @escaping @Sendable (Int) -> Void
    ) async throws {
        while !Task.isCancelled {
            let result = try await TCPFlowSOCKSRelay.receive(from: source)
            if !result.data.isEmpty {
                try await TCPFlowSOCKSRelay.send(result.data, to: destination)
                record(result.data.count)
            }
            if let error = result.error {
                throw error
            }
            if result.isComplete {
                try await TCPFlowSOCKSRelay.finishSending(to: destination)
                return
            }
            guard !result.data.isEmpty else {
                throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
            }
        }
    }

    private static func negotiateUpstreamUDPAssociate(
        _ connection: NWConnection,
        credentials: SOCKSCredentials
    ) async throws -> Network.NWEndpoint {
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x02]), to: connection)
        let greeting = try await TCPFlowSOCKSRelay.receiveExactly(2, from: connection)
        guard greeting == Data([0x05, 0x02]) else {
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("authentication rejected")
        }
        try await TCPFlowSOCKSRelay.authenticate(credentials, connection: connection)

        // 本机 SOCKS5 入口不携带系统接口绑定元数据，始终以 0.0.0.0:0 建立普通关联。
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
            to: connection
        )
        let header = try await TCPFlowSOCKSRelay.receiveExactly(4, from: connection)
        let base = header.startIndex
        guard header[base] == 0x05 else {
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("invalid response version")
        }
        guard header[base + 1] == 0x00 else {
            throw TCPFlowSOCKSRelay.RelayError.connectRejected(header[base + 1])
        }
        let host: Network.NWEndpoint.Host
        switch header[base + 3] {
        case 0x01:
            let raw = try await TCPFlowSOCKSRelay.receiveExactly(4, from: connection)
            let rawBase = raw.startIndex
            if raw == Data([0, 0, 0, 0]) {
                host = .ipv4(IPv4Address.loopback)
            } else {
                host = Network.NWEndpoint.Host(
                    "\(raw[rawBase]).\(raw[rawBase + 1]).\(raw[rawBase + 2]).\(raw[rawBase + 3])"
                )
            }
        case 0x03:
            let length = try await TCPFlowSOCKSRelay.receiveExactly(1, from: connection)
            let raw = try await TCPFlowSOCKSRelay.receiveExactly(
                Int(length[length.startIndex]),
                from: connection
            )
            guard let name = String(data: raw, encoding: .utf8), !name.isEmpty else {
                throw TCPFlowSOCKSRelay.RelayError.socksProtocol("invalid relay hostname")
            }
            host = Network.NWEndpoint.Host(name)
        case 0x04:
            let raw = try await TCPFlowSOCKSRelay.receiveExactly(16, from: connection)
            guard let address = IPv6Address(raw) else {
                throw TCPFlowSOCKSRelay.RelayError.socksProtocol("invalid IPv6 relay address")
            }
            host = address == IPv6Address.any
                ? .ipv6(IPv6Address.loopback)
                : .ipv6(address)
        default:
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("invalid relay address type")
        }
        let portBytes = try await TCPFlowSOCKSRelay.receiveExactly(2, from: connection)
        let portBase = portBytes.startIndex
        let port = UInt16(portBytes[portBase]) << 8 | UInt16(portBytes[portBase + 1])
        guard
            port != 0,
            let endpointPort = Network.NWEndpoint.Port(rawValue: port)
        else {
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("invalid relay port")
        }
        return .hostPort(host: host, port: endpointPort)
    }

    private static func relayUDP(
        clientControl: NWConnection,
        upstreamControl: NWConnection,
        localUDP: LoopbackUDPSocket,
        upstreamUDP: NWConnection,
        expectedClientPort: UInt16?,
        shutdown: RelayTaskShutdown,
        transactionID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async throws {
        let peerTracker = ClientUDPPeerTracker(expectedPort: expectedClientPort)
        try await RelayTaskGroup.run(
            operations: [
                {
                    try await monitorClientControl(clientControl)
                },
                {
                    try await monitorUpstreamControl(upstreamControl)
                },
                {
                    try await pumpUplinkUDP(
                        from: localUDP,
                        to: upstreamUDP,
                        peerTracker: peerTracker,
                        transactionID: transactionID,
                        traffic: traffic,
                        logger: logger
                    )
                },
                {
                    try await pumpDownlinkUDP(
                        from: upstreamUDP,
                        to: localUDP,
                        peerTracker: peerTracker,
                        transactionID: transactionID,
                        traffic: traffic,
                        logger: logger
                    )
                },
            ],
            shutdown: shutdown
        )
    }

    /// 客户端关闭 TCP 控制连接代表按 RFC 1928 正常结束 UDP 关联。
    private static func monitorClientControl(
        _ connection: NWConnection
    ) async throws {
        let result = try await TCPFlowSOCKSRelay.receive(from: connection)
        if let error = result.error {
            throw error
        }
        if !result.data.isEmpty {
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("unexpected UDP control payload")
        }
        if result.isComplete {
            return
        }
        throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
    }

    private static func monitorUpstreamControl(
        _ connection: NWConnection
    ) async throws {
        let result = try await TCPFlowSOCKSRelay.receive(from: connection)
        if let error = result.error {
            throw error
        }
        if !result.data.isEmpty {
            throw TCPFlowSOCKSRelay.RelayError.socksProtocol("unexpected upstream UDP control payload")
        }
        throw TCPFlowSOCKSRelay.RelayError.socksUnavailable
    }

    private static func pumpUplinkUDP(
        from localUDP: LoopbackUDPSocket,
        to upstreamUDP: NWConnection,
        peerTracker: ClientUDPPeerTracker,
        transactionID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async throws {
        for try await (packet, sender) in localUDP.packets {
            try Task.checkCancellation()
            guard let payloadCount = LocalSOCKSHandshake.clientUDPDatagramPayloadLength(packet) else {
                logger.debug(
                    "local-socks-udp-uplink-dropped trial=\(transactionID, privacy: .public) reason=invalid-header"
                )
                continue
            }
            guard peerTracker.acceptOrMatch(sender) else {
                logger.debug(
                    "local-socks-udp-uplink-dropped trial=\(transactionID, privacy: .public) reason=foreign-peer"
                )
                continue
            }
            try await TCPFlowSOCKSRelay.send(packet, to: upstreamUDP)
            traffic.recordUpload(payloadCount, transactionID: transactionID)
        }
    }

    private static func pumpDownlinkUDP(
        from upstreamUDP: NWConnection,
        to localUDP: LoopbackUDPSocket,
        peerTracker: ClientUDPPeerTracker,
        transactionID: String,
        traffic: ProviderTrafficLedger,
        logger: Logger
    ) async throws {
        while !Task.isCancelled {
            guard let packet = try await receiveUDPMessage(from: upstreamUDP) else {
                return
            }
            guard let payloadCount = LocalSOCKSHandshake.serverUDPDatagramPayloadLength(packet) else {
                logger.debug(
                    "local-socks-udp-downlink-dropped trial=\(transactionID, privacy: .public) reason=invalid-header"
                )
                continue
            }
            guard let peer = peerTracker.currentPeer() else {
                continue
            }
            if localUDP.send(packet, to: peer) {
                traffic.recordDownload(payloadCount, transactionID: transactionID)
            }
        }
    }

    private static func receiveUDPMessage(
        from connection: NWConnection
    ) async throws -> Data? {
        try await awaitRelayCallback { completion in
            connection.receiveMessage { data, _, isComplete, error in
                if let error {
                    completion(.failure(error))
                } else if let data {
                    completion(.success(data))
                } else if isComplete {
                    completion(.success(nil))
                } else {
                    completion(.failure(TCPFlowSOCKSRelay.RelayError.socksUnavailable))
                }
            }
        }
    }
}

private final class LocalSOCKSRelayResources: @unchecked Sendable {
    private let lock = NSLock()
    private let client: NWConnection
    private let upstream: NWConnection
    private var upstreamUDP: NWConnection?
    private var localUDP: LoopbackUDPSocket?
    private var isUDPAssociation = false
    private var closed = false

    init(client: NWConnection, upstream: NWConnection) {
        self.client = client
        self.upstream = upstream
    }

    func markUDPAssociation() {
        lock.lock()
        isUDPAssociation = true
        lock.unlock()
    }

    func install(localUDP socket: LoopbackUDPSocket) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            socket.close()
            return false
        }
        localUDP = socket
        lock.unlock()
        return true
    }

    func install(upstreamUDP connection: NWConnection) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            RelayConnectionCancellation.cancel(connection, error: CancellationError())
            return false
        }
        upstreamUDP = connection
        lock.unlock()
        return true
    }

    func close(with error: Error?) {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let udpMode = isUDPAssociation
        let datagram = upstreamUDP
        let socket = localUDP
        upstreamUDP = nil
        localUDP = nil
        lock.unlock()

        socket?.close()
        // UDP 关联在客户端关闭控制流时结束，此时上游套接字尚未收到 EOF，
        // 必须立即拆除回环连接以避免阻塞排空。
        let upstreamError = udpMode ? (error ?? CancellationError()) : error
        if let datagram {
            RelayConnectionCancellation.cancel(datagram, error: upstreamError)
        }
        RelayConnectionCancellation.cancel(upstream, error: upstreamError)
        RelayConnectionCancellation.cancel(client, error: error)
    }
}

private final class ClientUDPPeerTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var peer: sockaddr_in?

    init(expectedPort: UInt16? = nil) {
        if let expectedPort, expectedPort != 0 {
            var expected = sockaddr_in()
            expected.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            expected.sin_family = sa_family_t(AF_INET)
            expected.sin_port = expectedPort.bigEndian
            expected.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
            self.peer = expected
        }
    }

    func acceptOrMatch(_ candidate: sockaddr_in) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let existing = peer {
            return existing.sin_addr.s_addr == candidate.sin_addr.s_addr
                && existing.sin_port == candidate.sin_port
        }
        peer = candidate
        return true
    }

    func currentPeer() -> sockaddr_in? {
        lock.lock()
        defer { lock.unlock() }
        return peer
    }
}

/// 仅绑定 `127.0.0.1:0` 的回环 UDP 中继套接字。
///
/// 在收到 TCP 请求阶段立即同步完成 `bind`，确保客户端收到 `BND.PORT` 后紧接着
/// 连发的首批数据报直接进入内核接收队列，不会等待连接态建链而丢包。
private final class LoopbackUDPSocket: @unchecked Sendable {
    private final class Core: @unchecked Sendable {
        enum State {
            case open
            case cancelling
            case closed
        }

        let fd: Int32
        let lock = NSLock()
        var state: State = .open
        var retainedSource: DispatchSourceRead?
        let continuation: AsyncThrowingStream<(Data, sockaddr_in), Error>.Continuation

        init(
            fd: Int32,
            continuation: AsyncThrowingStream<(Data, sockaddr_in), Error>.Continuation
        ) {
            self.fd = fd
            self.continuation = continuation
        }

        private var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state == .open
        }

        func drainReadable(into buffer: inout [UInt8]) {
            // 该串行队列专属于当前套接字；一旦 beginClose() 置为 .cancelling，
            // 立即退出循环让出队列以执行 cancelHandler，平时则读至 EAGAIN 满足 kqueue 边沿语义。
            while isOpen {
                var sender = sockaddr_in()
                var msgFlags: Int32 = 0
                let readResult = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                    guard let baseAddress = rawBuffer.baseAddress else { return -1 }
                    return withUnsafeMutablePointer(to: &sender) { senderPtr in
                        var iov = iovec(iov_base: baseAddress, iov_len: rawBuffer.count)
                        return withUnsafeMutablePointer(to: &iov) { iovPtr in
                            var header = msghdr()
                            header.msg_name = UnsafeMutableRawPointer(senderPtr)
                            header.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
                            header.msg_iov = iovPtr
                            header.msg_iovlen = 1
                            let count = Darwin.recvmsg(fd, &header, 0)
                            msgFlags = header.msg_flags
                            return count
                        }
                    }
                }
                if readResult < 0 {
                    let code = errno
                    if code == EINTR {
                        continue
                    }
                    if code == EAGAIN || code == EWOULDBLOCK {
                        return
                    }
                    continuation.finish(
                        throwing: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
                    )
                    return
                }
                guard
                    (msgFlags & MSG_TRUNC) == 0,
                    sender.sin_family == sa_family_t(AF_INET),
                    sender.sin_addr.s_addr == INADDR_LOOPBACK.bigEndian,
                    sender.sin_port != 0
                else {
                    continue
                }
                let data = Data(bytes: buffer, count: readResult)
                continuation.yield((data, sender))
            }
        }

        func send(_ data: Data, to peer: sockaddr_in) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state == .open else { return false }
            var destination = peer
            return data.withUnsafeBytes { rawBuffer in
                withUnsafePointer(to: &destination) { destPtr in
                    destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { addrPtr in
                        var sent: Int
                        repeat {
                            sent = Darwin.sendto(
                                fd,
                                rawBuffer.baseAddress,
                                rawBuffer.count,
                                0,
                                addrPtr,
                                socklen_t(MemoryLayout<sockaddr_in>.size)
                            )
                        } while sent < 0 && errno == EINTR
                        return sent == rawBuffer.count
                    }
                }
            }
        }

        func beginClose() -> DispatchSourceRead? {
            lock.lock()
            guard state == .open else {
                lock.unlock()
                return nil
            }
            state = .cancelling
            let source = retainedSource
            lock.unlock()
            return source
        }

        func finishCancel() {
            lock.lock()
            state = .closed
            Darwin.close(fd)
            retainedSource = nil
            lock.unlock()
            continuation.finish()
        }
    }

    let port: UInt16
    let packets: AsyncThrowingStream<(Data, sockaddr_in), Error>
    private let core: Core

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var one: Int32 = 1
        _ = Darwin.setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &one,
            socklen_t(MemoryLayout<Int32>.size)
        )
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            throw POSIXError(code)
        }

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &bindAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            throw POSIXError(code)
        }

        var assigned = sockaddr_in()
        var assignedLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.getsockname(descriptor, raw, &assignedLen)
            }
        }
        let assignedPort = UInt16(bigEndian: assigned.sin_port)
        guard named == 0, assignedPort != 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            Darwin.close(descriptor)
            throw POSIXError(code)
        }

        self.port = assignedPort

        var capturedContinuation: AsyncThrowingStream<(Data, sockaddr_in), Error>.Continuation!
        self.packets = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { cont in
            capturedContinuation = cont
        }
        let socketCore = Core(fd: descriptor, continuation: capturedContinuation)
        self.core = socketCore

        let queue = DispatchQueue(
            label: "com.xd.xdial.local-socks-udp.\(assignedPort)",
            qos: .userInitiated
        )
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        socketCore.retainedSource = source

        var buffer = [UInt8](repeating: 0, count: 65536)
        source.setEventHandler {
            socketCore.drainReadable(into: &buffer)
        }
        source.setCancelHandler {
            socketCore.finishCancel()
        }
        source.resume()
    }

    deinit {
        close()
    }

    func send(_ data: Data, to peer: sockaddr_in) -> Bool {
        core.send(data, to: peer)
    }

    func close() {
        core.beginClose()?.cancel()
    }
}
