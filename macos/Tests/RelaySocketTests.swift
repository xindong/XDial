import Darwin
import Network
import XCTest

final class RelaySocketTests: XCTestCase {
    /// 2026-11-23: a burst of loopback NWConnections stopped completing (800
    /// of them: 2 ready after 20 s) while the listener kept accepting, which
    /// took every captured flow down. The relay transport must complete such
    /// a burst promptly.
    func testBurstOfLoopbackConnectsCompletes() async throws {
        try raiseDescriptorLimit(to: 8192)
        let listener = try LoopbackTCPListener(echo: false)
        defer { listener.stop() }
        let count = 1000
        let start = Date()
        let sockets = try await withThrowingTaskGroup(
            of: RelaySocket.self
        ) { group in
            for _ in 0..<count {
                group.addTask {
                    let socket = RelaySocket(
                        kind: .stream,
                        endpoint: .loopbackIPv4(port: listener.port)
                    )
                    try await socket.connect()
                    return socket
                }
            }
            var connected: [RelaySocket] = []
            for try await socket in group {
                connected.append(socket)
            }
            return connected
        }
        XCTAssertEqual(sockets.count, count)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        for socket in sockets {
            socket.close(abortive: true)
        }
    }

    func testStreamRoundTripAndHalfClose() async throws {
        let listener = try LoopbackTCPListener(echo: true)
        defer { listener.stop() }
        let socket = RelaySocket(
            kind: .stream,
            endpoint: .loopbackIPv4(port: listener.port)
        )
        try await socket.connect()
        let payload = Data((0..<100_000).map { UInt8($0 % 251) })
        try await socket.send(payload)
        try await socket.finishSending()
        var echoed = Data()
        while true {
            let received = try await socket.receive(maximumLength: 64 * 1024)
            XCTAssertNil(received.error)
            echoed.append(received.data)
            if received.isComplete {
                break
            }
        }
        XCTAssertEqual(echoed, payload)
        socket.close(abortive: false)
    }

    func testConnectRefusedSurfacesPOSIXError() async throws {
        let port = try LoopbackTCPListener.unusedPort()
        let socket = RelaySocket(
            kind: .stream,
            endpoint: .loopbackIPv4(port: port)
        )
        do {
            try await socket.connect()
            XCTFail("connect to a closed port succeeded")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.ECONNREFUSED))
        }
        socket.close(abortive: true)
    }

    func testCloseFailsPendingReceive() async throws {
        let listener = try LoopbackTCPListener(echo: false)
        defer { listener.stop() }
        let socket = RelaySocket(
            kind: .stream,
            endpoint: .loopbackIPv4(port: listener.port)
        )
        try await socket.connect()
        let pending = Task {
            try await socket.receive(maximumLength: 16)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        socket.close(abortive: true)
        do {
            _ = try await pending.value
            XCTFail("receive survived close")
        } catch let error as NWError {
            XCTAssertEqual(error, .posix(.ECANCELED))
        }
    }

    func testDatagramRoundTrip() async throws {
        let server = try LoopbackUDPEcho()
        defer { server.stop() }
        let socket = RelaySocket(
            kind: .datagram,
            endpoint: .loopbackIPv4(port: server.port)
        )
        try await socket.connect()
        for size in [1, 512, 9_000] {
            let payload = Data((0..<size).map { UInt8($0 % 199) })
            try await socket.send(payload)
            let reply = try await socket.receiveDatagram()
            XCTAssertEqual(reply, payload, "size=\(size)")
        }
        socket.close(abortive: true)
    }

    /// Each relay owns one descriptor; a provider that leaked them would
    /// exhaust its table after enough flows.
    func testClosedSocketsReleaseTheirDescriptors() async throws {
        try raiseDescriptorLimit(to: 4096)
        let baseline = openDescriptorCount()
        let listener = try LoopbackTCPListener(echo: false)
        let udp = try LoopbackUDPEcho()
        var sockets: [RelaySocket] = []
        for index in 0..<200 {
            let datagram = index.isMultiple(of: 4)
            let socket = RelaySocket(
                kind: datagram ? .datagram : .stream,
                endpoint: .loopbackIPv4(
                    port: datagram ? udp.port : listener.port
                )
            )
            try await socket.connect()
            sockets.append(socket)
        }
        // A socket that never connected must release its descriptor too.
        sockets.append(
            RelaySocket(
                kind: .stream,
                endpoint: .loopbackIPv4(port: listener.port)
            )
        )
        for (index, socket) in sockets.enumerated() {
            socket.close(abortive: index.isMultiple(of: 2))
        }
        sockets.removeAll()
        listener.stop()
        udp.stop()
        let deadline = Date().addingTimeInterval(5)
        while openDescriptorCount() > baseline, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertLessThanOrEqual(openDescriptorCount(), baseline)
    }

    func testEndpointDescription() {
        XCTAssertEqual(
            RelaySocket.Endpoint.loopbackIPv4(port: 1080).description,
            "127.0.0.1:1080"
        )
        XCTAssertEqual(
            RelaySocket.Endpoint(
                address: .ipv6(Array(repeating: 0, count: 15) + [1]),
                port: 53
            ).description,
            "[0:0:0:0:0:0:0:1]:53"
        )
    }

    private func openDescriptorCount() -> Int {
        var count = 0
        for descriptor in 0..<getdtablesize()
        where fcntl(descriptor, F_GETFD) != -1 {
            count += 1
        }
        return count
    }

    private func raiseDescriptorLimit(to value: rlim_t) throws {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            throw XCTSkip("getrlimit failed")
        }
        guard limit.rlim_cur < value else { return }
        limit.rlim_cur = min(value, limit.rlim_max)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0,
              limit.rlim_cur >= value
        else {
            throw XCTSkip("cannot raise the descriptor limit to \(value)")
        }
    }
}

/// A blocking BSD listener on 127.0.0.1 served by one thread. With `echo`,
/// each connection echoes until EOF and then closes; otherwise accepted
/// connections are held open until `stop()`.
private final class LoopbackTCPListener: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var accepted: [Int32] = []
    private var stopped = false

    init(echo: Bool) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, 4)
        port = try Self.bindLoopback(fd)
        guard listen(fd, SOMAXCONN) == 0 else { throw POSIXError(.EADDRINUSE) }
        let fd = self.fd
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard let self else { close(client); return }
                if echo {
                    Thread.detachNewThread {
                        Self.echo(client)
                    }
                } else {
                    self.lock.lock()
                    if self.stopped {
                        self.lock.unlock()
                        close(client)
                        return
                    }
                    self.accepted.append(client)
                    self.lock.unlock()
                }
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        let clients = accepted
        accepted = []
        lock.unlock()
        shutdown(fd, SHUT_RDWR)
        close(fd)
        clients.forEach { close($0) }
    }

    static func unusedPort() throws -> UInt16 {
        let probe = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(probe) }
        return try bindLoopback(probe)
    }

    static func bindLoopback(_ fd: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: address.sin_port)
    }

    private static func echo(_ client: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(client, &buffer, buffer.count)
            guard count > 0 else { break }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes {
                    write(client, $0.baseAddress!.advanced(by: offset), count - offset)
                }
                guard written > 0 else { close(client); return }
                offset += written
            }
        }
        close(client)
    }
}

/// A UDP echo server on 127.0.0.1 served by one thread.
private final class LoopbackUDPEcho: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        port = try LoopbackTCPListener.bindLoopback(fd)
        let fd = self.fd
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var peer = sockaddr_storage()
            while true {
                var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
                    }
                }
                guard count >= 0 else { return }
                _ = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer, count, 0, $0, length)
                    }
                }
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}
