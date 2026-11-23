import Darwin
import Foundation
import Network

/// A non-blocking BSD socket for the Provider's legs to the in-process
/// sing-box SOCKS ingress (TCP control streams and UDP relay datagrams).
///
/// Network.framework runs the internal work of every `NWConnection` in a
/// process on one shared context, and its per-connection cost grows with the
/// number of live connections. The Provider opens one loopback connection per
/// captured TCP flow and two per UDP association, so a burst of a few hundred
/// new flows (an app opening many sockets at once, Tailscale fanning DNS out
/// to every resolver) saturates that context: connection results stop being
/// delivered, every captured flow stalls, and the backlog only grows while
/// sing-box itself keeps accepting. Plain sockets driven by GCD sources have
/// no shared serialization point; the kernel completes loopback connects in
/// well under a millisecond regardless of how many are live.
///
/// Errors are surfaced as `NWError.posix` so relay diagnostics and
/// `AppProxyFlowCloseError` keep classifying them exactly as before.
/// At most one receive and one send/connect may be outstanding at a time,
/// which is how the relays use a socket.
final class RelaySocket: @unchecked Sendable {
    enum Kind {
        case stream
        case datagram
    }

    /// A numeric socket address. Relay endpoints are the addresses sing-box
    /// listens on; host names are never resolved here.
    struct Endpoint: Equatable, CustomStringConvertible {
        enum Address: Equatable {
            case ipv4([UInt8])
            case ipv6([UInt8])
        }

        let address: Address
        let port: UInt16

        static func loopbackIPv4(port: UInt16) -> Endpoint {
            Endpoint(address: .ipv4([127, 0, 0, 1]), port: port)
        }

        var description: String {
            switch address {
            case let .ipv4(bytes):
                return bytes.map(String.init).joined(separator: ".")
                    + ":\(port)"
            case let .ipv6(bytes):
                var groups: [String] = []
                for index in stride(from: 0, to: 16, by: 2) {
                    let value = UInt16(bytes[index]) << 8
                        | UInt16(bytes[index + 1])
                    groups.append(String(value, radix: 16))
                }
                return "[" + groups.joined(separator: ":") + "]:\(port)"
            }
        }
    }

    struct Received {
        let data: Data
        let isComplete: Bool
        let error: Error?
    }

    /// Buffer capacity for a UDP payload and the longest SOCKS5 header.
    /// The kernel still enforces the IPv4 or IPv6 datagram size limit.
    static let maximumDatagramLength = 65_535 + 262

    private static let targetQueue = DispatchQueue.global(
        qos: .userInitiated
    )

    let kind: Kind
    let endpoint: Endpoint

    private let queue: DispatchQueue
    private let fd: Int32
    private let creationError: Int32
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readSuspended = true
    private var writeSuspended = true
    private var pendingRead: PendingOperation?
    private var pendingWrite: PendingOperation?
    private var connectState: ConnectState = .idle
    private var closed = false

    #if XDIAL_TESTING
    var hasPendingWrite: Bool {
        queue.sync { pendingWrite != nil }
    }
    #endif

    private enum ConnectState {
        case idle
        case connecting
        case connected
    }

    /// One outstanding read or write. `attempt` performs the syscall and
    /// returns true once it has completed the operation (successfully or
    /// not); false means the socket would block and the source must fire.
    private struct PendingOperation {
        let attempt: () -> Bool
        let fail: (Error) -> Void
    }

    init(kind: Kind, endpoint: Endpoint) {
        self.kind = kind
        self.endpoint = endpoint
        queue = DispatchQueue(
            label: "app.xdial.relay-socket",
            target: Self.targetQueue
        )
        let family: Int32
        switch endpoint.address {
        case .ipv4:
            family = AF_INET
        case .ipv6:
            family = AF_INET6
        }
        let descriptor = socket(
            family,
            kind == .stream ? SOCK_STREAM : SOCK_DGRAM,
            0
        )
        guard descriptor >= 0 else {
            fd = -1
            creationError = errno
            return
        }
        if kind == .datagram {
            // Darwin checks atomic writes against SO_SNDBUF. The default
            // buffer is too small even for valid UDP datagrams.
            var sendBufferSize = Int32(Self.maximumDatagramLength)
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDBUF,
                &sendBufferSize,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                creationError = errno
                fd = -1
                Darwin.close(descriptor)
                return
            }
        }
        fd = descriptor
        creationError = 0
        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout<Int32>.size)
        )
        if kind == .stream {
            _ = setsockopt(
                descriptor,
                IPPROTO_TCP,
                TCP_NODELAY,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        installSources(descriptor)
    }

    deinit {
        // Relays always close explicitly; this only guards against leaking
        // the descriptor if an owner is dropped without doing so.
        if !closed {
            cancelSources()
        }
    }

    /// Connects the socket. A stream connect to a loopback listener either
    /// completes at once or after one writability event; a datagram connect
    /// only fixes the peer address.
    func connect() async throws {
        let _: Void = try await awaitRelayCallback { completion in
            self.queue.async {
                self.beginConnect(completion)
            }
        }
    }

    /// Writes all of `data` (stream) or sends it as one datagram.
    func send(_ data: Data) async throws {
        let _: Void = try await awaitRelayCallback { completion in
            self.queue.async {
                switch self.kind {
                case .stream:
                    self.enqueueStreamWrite(data, completion)
                case .datagram:
                    self.enqueueDatagramWrite(data, completion)
                }
            }
        }
    }

    /// Sends FIN while keeping the receive direction open.
    func finishSending() async throws {
        let _: Void = try await awaitRelayCallback { completion in
            self.queue.async {
                guard !self.closed, self.fd >= 0 else {
                    completion(.failure(Self.closedError))
                    return
                }
                if Darwin.shutdown(self.fd, SHUT_WR) == 0 || errno == ENOTCONN {
                    completion(.success(()))
                } else {
                    completion(.failure(Self.posixError(errno)))
                }
            }
        }
    }

    /// Reads up to `maximumLength` bytes. EOF is `isComplete` with empty data;
    /// a socket error is returned in `error`, mirroring `NWConnection.receive`.
    func receive(maximumLength: Int) async throws -> Received {
        precondition(kind == .stream)
        return try await awaitRelayCallback { completion in
            self.queue.async {
                self.enqueueRead(completion) { descriptor in
                    let length = max(
                        1,
                        min(maximumLength, Self.pendingByteCount(descriptor))
                    )
                    var buffer = Data(count: length)
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.read(descriptor, $0.baseAddress, length)
                    }
                    if count > 0 {
                        buffer.count = count
                        return .success(
                            Received(data: buffer, isComplete: false, error: nil)
                        )
                    }
                    if count == 0 {
                        return .success(
                            Received(data: Data(), isComplete: true, error: nil)
                        )
                    }
                    let code = errno
                    if Self.wouldBlock(code) {
                        return nil
                    }
                    return .success(
                        Received(
                            data: Data(),
                            isComplete: false,
                            error: Self.posixError(code)
                        )
                    )
                }
            }
        }
    }

    /// Receives one datagram.
    func receiveDatagram() async throws -> Data {
        precondition(kind == .datagram)
        return try await awaitRelayCallback { completion in
            self.queue.async {
                self.enqueueRead(completion) { descriptor in
                    var buffer = Data(count: Self.maximumDatagramLength)
                    let count = buffer.withUnsafeMutableBytes {
                        Darwin.recv(
                            descriptor,
                            $0.baseAddress,
                            Self.maximumDatagramLength,
                            0
                        )
                    }
                    if count >= 0 {
                        return .success(Data(buffer.prefix(count)))
                    }
                    let code = errno
                    if Self.wouldBlock(code) {
                        return nil
                    }
                    return .failure(Self.posixError(code))
                }
            }
        }
    }

    /// Closes the socket and fails any outstanding operation. An abortive
    /// close resets a stream (SO_LINGER 0) instead of sending FIN, matching
    /// `NWConnection.forceCancel()` for a relay whose peer may be gone.
    func close(abortive: Bool) {
        queue.async {
            guard !self.closed else {
                return
            }
            self.closed = true
            if abortive, self.kind == .stream, self.fd >= 0 {
                var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
                _ = setsockopt(
                    self.fd,
                    SOL_SOCKET,
                    SO_LINGER,
                    &linger,
                    socklen_t(MemoryLayout<Darwin.linger>.size)
                )
            }
            let read = self.pendingRead
            let write = self.pendingWrite
            self.pendingRead = nil
            self.pendingWrite = nil
            self.cancelSources()
            read?.fail(Self.closedError)
            write?.fail(Self.closedError)
        }
    }

    // MARK: - Operations (on `queue`)

    private func beginConnect(
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard !closed else {
            completion(.failure(Self.closedError))
            return
        }
        guard fd >= 0 else {
            completion(.failure(Self.posixError(creationError)))
            return
        }
        guard connectState == .idle, pendingWrite == nil else {
            completion(.failure(Self.posixError(EALREADY)))
            return
        }
        let result = withSocketAddress(endpoint) { address, length in
            Darwin.connect(fd, address, length)
        }
        if result == 0 {
            connectState = .connected
            completion(.success(()))
            return
        }
        let code = errno
        guard code == EINPROGRESS || code == EINTR else {
            completion(.failure(Self.posixError(code)))
            return
        }
        connectState = .connecting
        let descriptor = fd
        pendingWrite = PendingOperation(
            attempt: { [weak self] in
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                let status = getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &length
                )
                if status != 0 {
                    socketError = errno
                }
                if socketError == 0 {
                    self?.connectState = .connected
                    completion(.success(()))
                } else {
                    completion(.failure(Self.posixError(socketError)))
                }
                return true
            },
            fail: { completion(.failure($0)) }
        )
        resumeWrite()
    }

    private func enqueueStreamWrite(
        _ data: Data,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var offset = 0
        let descriptor = fd
        enqueueWrite(completion) {
            while offset < data.count {
                let written = data.withUnsafeBytes { raw -> Int in
                    let base = raw.baseAddress!.advanced(by: offset)
                    return Darwin.write(descriptor, base, data.count - offset)
                }
                if written > 0 {
                    offset += written
                    continue
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                if Self.wouldBlock(code) {
                    return nil
                }
                return .failure(Self.posixError(code))
            }
            return .success(())
        }
    }

    private func enqueueDatagramWrite(
        _ data: Data,
        _ completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let descriptor = fd
        enqueueWrite(completion) {
            while true {
                let sent = data.withUnsafeBytes { raw in
                    Darwin.send(descriptor, raw.baseAddress, data.count, 0)
                }
                if sent >= 0 {
                    return .success(())
                }
                let code = errno
                if code == EINTR {
                    continue
                }
                if Self.wouldBlock(code) {
                    return nil
                }
                return .failure(Self.posixError(code))
            }
        }
    }

    private func enqueueWrite(
        _ completion: @escaping (Result<Void, Error>) -> Void,
        _ step: @escaping () -> Result<Void, Error>?
    ) {
        guard !closed, fd >= 0 else {
            completion(.failure(Self.closedError))
            return
        }
        guard connectState == .connected, pendingWrite == nil else {
            completion(.failure(Self.posixError(
                connectState == .connected ? EALREADY : ENOTCONN
            )))
            return
        }
        if let result = step() {
            completion(result)
            return
        }
        pendingWrite = PendingOperation(
            attempt: {
                guard let result = step() else {
                    return false
                }
                completion(result)
                return true
            },
            fail: { completion(.failure($0)) }
        )
        resumeWrite()
    }

    private func enqueueRead<Value>(
        _ completion: @escaping (Result<Value, Error>) -> Void,
        _ step: @escaping (Int32) -> Result<Value, Error>?
    ) {
        guard !closed, fd >= 0 else {
            completion(.failure(Self.closedError))
            return
        }
        guard connectState == .connected, pendingRead == nil else {
            completion(.failure(Self.posixError(
                connectState == .connected ? EALREADY : ENOTCONN
            )))
            return
        }
        let descriptor = fd
        if let result = step(descriptor) {
            completion(result)
            return
        }
        pendingRead = PendingOperation(
            attempt: {
                guard let result = step(descriptor) else {
                    return false
                }
                completion(result)
                return true
            },
            fail: { completion(.failure($0)) }
        )
        resumeRead()
    }

    // MARK: - Sources (on `queue`)

    private func installSources(_ descriptor: Int32) {
        let closer = DescriptorCloser(descriptor)
        let read = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        let write = DispatchSource.makeWriteSource(
            fileDescriptor: descriptor,
            queue: queue
        )
        read.setEventHandler { [weak self] in
            self?.readReady()
        }
        write.setEventHandler { [weak self] in
            self?.writeReady()
        }
        // The descriptor is closed only after both sources stopped watching
        // it, so a reused descriptor number can never receive our events.
        read.setCancelHandler { closer.sourceCancelled() }
        write.setCancelHandler { closer.sourceCancelled() }
        // Activate, then keep each source suspended until an operation waits.
        read.activate()
        read.suspend()
        write.activate()
        write.suspend()
        readSource = read
        writeSource = write
    }

    private func readReady() {
        guard let operation = pendingRead else {
            suspendRead()
            return
        }
        if operation.attempt() {
            pendingRead = nil
            suspendRead()
        }
    }

    private func writeReady() {
        guard let operation = pendingWrite else {
            suspendWrite()
            return
        }
        if operation.attempt() {
            pendingWrite = nil
            suspendWrite()
        }
    }

    private func resumeRead() {
        guard readSuspended, let readSource else { return }
        readSuspended = false
        readSource.resume()
    }

    private func suspendRead() {
        guard !readSuspended, let readSource else { return }
        readSuspended = true
        readSource.suspend()
    }

    private func resumeWrite() {
        guard writeSuspended, let writeSource else { return }
        writeSuspended = false
        writeSource.resume()
    }

    private func suspendWrite() {
        guard !writeSuspended, let writeSource else { return }
        writeSuspended = true
        writeSource.suspend()
    }

    /// A suspended source never runs its cancel handler, so resume first.
    private func cancelSources() {
        if let readSource {
            readSource.cancel()
            if readSuspended {
                readSuspended = false
                readSource.resume()
            }
        }
        if let writeSource {
            writeSource.cancel()
            if writeSuspended {
                writeSuspended = false
                writeSource.resume()
            }
        }
        readSource = nil
        writeSource = nil
    }

    // MARK: - Helpers

    static let closedError: Error = NWError.posix(.ECANCELED)

    static func posixError(_ code: Int32) -> Error {
        NWError.posix(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private static func wouldBlock(_ code: Int32) -> Bool {
        code == EAGAIN || code == EWOULDBLOCK || code == EINTR
    }

    /// Bytes readable right now; sizes the read buffer to what is queued.
    private static func pendingByteCount(_ descriptor: Int32) -> Int {
        var count: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NREAD,
            &count,
            &length
        ) == 0 else {
            return 0
        }
        return Int(count)
    }

    private func withSocketAddress<Result>(
        _ endpoint: Endpoint,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Result
    ) -> Result {
        switch endpoint.address {
        case let .ipv4(bytes):
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = endpoint.port.bigEndian
            withUnsafeMutableBytes(of: &address.sin_addr) {
                $0.copyBytes(from: bytes.prefix(4))
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        case let .ipv6(bytes):
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = endpoint.port.bigEndian
            withUnsafeMutableBytes(of: &address.sin6_addr) {
                $0.copyBytes(from: bytes.prefix(16))
            }
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    body($0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
}

/// Closes a descriptor once both of its dispatch sources were cancelled.
private final class DescriptorCloser: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private var remaining = 2

    init(_ descriptor: Int32) {
        self.descriptor = descriptor
    }

    func sourceCancelled() {
        lock.lock()
        remaining -= 1
        let shouldClose = remaining == 0
        lock.unlock()
        if shouldClose {
            Darwin.close(descriptor)
        }
    }
}
