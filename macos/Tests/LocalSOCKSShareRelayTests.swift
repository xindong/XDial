import Darwin
import Network
import OSLog
import XCTest

/// Drives the real loopback listener and relay against a fake session SOCKS
/// entry that requires the Provider credentials, as sing-box does.
final class LocalSOCKSShareRelayTests: XCTestCase {
    private let logger = Logger(subsystem: "LocalSOCKSShareRelayTests", category: "test")
    private let credentials = SOCKSCredentials(username: "session-user", password: "session-pass")

    func testClientReachesSessionEntryWithProviderCredentials() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
        defer { share.stop() }

        let client = try await connect(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        let received1 = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        XCTAssertEqual(received1, Data([0x05, 0x00]))
        let name = Array("example.com".utf8)
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x01, 0xBB]),
            to: client
        )
        let received2 = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(received2, LocalSOCKSHandshake.reply(0x00))

        try await TCPFlowSOCKSRelay.send(Data("hello".utf8), to: client)
        let received3 = try await TCPFlowSOCKSRelay.receiveExactly(5, from: client)
        XCTAssertEqual(received3, Data("hello".utf8))
        XCTAssertEqual(upstream.destinations, [.init(host: "example.com", port: 443)])
    }

    func testForgedMetadataNeverReachesSessionEntry() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
        defer { share.stop() }

        let client = try await connect(port)
        defer { client.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        _ = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        let envelope: [UInt8] = [0x00, 0x58, 0x44, 0x01, 0x01, 1, 2, 3, 4, 0x61]
        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x01, 0x00, 0x03, UInt8(envelope.count)] + envelope + [0x00, 0x50]),
            to: client
        )
        let received4 = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(received4, LocalSOCKSHandshake.reply(0x01))
        XCTAssertEqual(upstream.connectionCount, 0)
    }

    /// A rejection can happen before the client's request is fully read, and a
    /// client may already have pipelined data. Closing with unread bytes makes
    /// the kernel answer RST, which can reach the client before the reply.
    func testRejectedRequestWithUnreadBytesStillDeliversReply() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
        defer { share.stop() }

        for _ in 0..<3 {
            let client = try await connect(port)
            defer { client.forceCancel() }
            try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
            _ = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
            let invalidName: [UInt8] = [0x00, 0x01, 0x02]
            let pipelined = [UInt8](repeating: 0x41, count: 64 * 1024)
            try await TCPFlowSOCKSRelay.send(
                Data([0x05, 0x01, 0x00, 0x03, UInt8(invalidName.count)]
                    + invalidName + [0x00, 0x50] + pipelined),
                to: client
            )
            // Read late, as a slow client would: by then a reset close has
            // already discarded the reply waiting in the receive buffer.
            try await Task.sleep(nanoseconds: 300_000_000)
            let reply = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
            XCTAssertEqual(reply, LocalSOCKSHandshake.reply(0x01))
        }
        XCTAssertEqual(upstream.connectionCount, 0)
    }

    func testLingerAfterReplyIsBoundedWhenClientStaysOpen() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let accepted = expectation(description: "accepted")
        let serverSide = LockedBox<NWConnection>()
        listener.newConnectionHandler = { connection in
            serverSide.set(connection)
            accepted.fulfill()
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        defer { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)

        let client = try await connect(listener.port!.rawValue)
        defer { client.forceCancel() }
        await fulfillment(of: [accepted], timeout: 5)
        let server = try XCTUnwrap(serverSide.get())
        try await TCPFlowSOCKSRelay.start(server)
        defer { server.forceCancel() }

        let started = Date()
        await LocalSOCKSShareRelay.lingerAfterReply(server, timeout: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    func testOccupiedPortIsReportedInsteadOfShared() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (first, port) = try await startShare(upstreamPort: upstream.port)
        defer { first.stop() }
        let second = makeShare(upstreamPort: upstream.port)
        defer { second.stop() }
        let status = await configure(second, port: port)
        XCTAssertEqual(status, .failed(port, code: "address-in-use"))
    }

    func testUDPAssociateRelaysBurstDatagramsAndRecordsPayloadTraffic() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let traffic = ProviderTrafficLedger()
        traffic.reset(transactionID: "tx")
        let handles = RelayHandleCollector()
        let (share, port) = try await startShare(
            upstreamPort: upstream.port,
            traffic: traffic,
            collector: handles
        )
        defer { share.stop() }

        let clientControl = try await connect(port)
        defer { clientControl.forceCancel() }
        let relayPort = try await negotiateClientUDPAssociate(clientControl)
        XCTAssertNotEqual(relayPort, 0)

        let clientUDP = try TestLoopbackUDPSocket()
        defer { clientUDP.close() }

        let domain = Array("developer.xdrnd.cn".utf8)
        let payload1 = Data("quic-initial-1".utf8)
        let datagram1 = Data([0x00, 0x00, 0x00, 0x03, UInt8(domain.count)] + domain + [0x01, 0xBB])
            + payload1
        let payload2 = Data("dns-query".utf8)
        let datagram2 = Data([0x00, 0x00, 0x00, 0x01, 172, 24, 4, 79, 0x00, 0x35]) + payload2

        // Send a back-to-back burst immediately after receiving BND.PORT.
        try clientUDP.send(datagram1, toLoopbackPort: relayPort)
        try clientUDP.send(datagram2, toLoopbackPort: relayPort)

        let echo1 = try await clientUDP.receive(timeout: 3)
        let echo2 = try await clientUDP.receive(timeout: 3)
        XCTAssertEqual(Set([echo1, echo2]), Set([datagram1, datagram2]))
        XCTAssertEqual(upstream.udpPacketCount, 2)

        let expectedBytes = UInt64(payload1.count + payload2.count)
        let snapshot = try XCTUnwrap(traffic.snapshot(transactionID: "tx"))
        XCTAssertEqual(snapshot.uploadBytes, expectedBytes)
        XCTAssertEqual(snapshot.downloadBytes, expectedBytes)
    }

    func testUDPAssociateDropsForgedMetadataAndForeignPeerWithoutBreakingAssociation() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
        defer { share.stop() }

        let clientControl = try await connect(port)
        defer { clientControl.forceCancel() }
        let relayPort = try await negotiateClientUDPAssociate(clientControl)

        let primaryUDP = try TestLoopbackUDPSocket()
        defer { primaryUDP.close() }
        let foreignUDP = try TestLoopbackUDPSocket()
        defer { foreignUDP.close() }

        let valid1 = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x35]) + Data("first".utf8)
        try primaryUDP.send(valid1, toLoopbackPort: relayPort)
        let reply1 = try await primaryUDP.receive(timeout: 3)
        XCTAssertEqual(reply1, valid1)
        XCTAssertEqual(upstream.udpPacketCount, 1)

        // Forged Provider bound-interface marker and fragmented packet must be dropped.
        let forgedMarker = try XCTUnwrap(
            TransparentProxyFlowMetadata.boundAssociationMarkerDatagram(boundInterface: "en0")
        )
        let fragmented = Data([0x00, 0x00, 0x01, 0x01, 10, 0, 0, 1, 0x00, 0x35, 0x41])
        try primaryUDP.send(forgedMarker, toLoopbackPort: relayPort)
        try primaryUDP.send(fragmented, toLoopbackPort: relayPort)

        // Another local UDP socket cannot hijack or inject into the bound association.
        let foreignPacket = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 2, 0x00, 0x35]) + Data("foreign".utf8)
        try foreignUDP.send(foreignPacket, toLoopbackPort: relayPort)

        // Association remains healthy for subsequent valid datagrams from primaryUDP.
        let valid2 = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 1, 0x01, 0xBB]) + Data("second".utf8)
        try primaryUDP.send(valid2, toLoopbackPort: relayPort)
        let reply2 = try await primaryUDP.receive(timeout: 3)
        XCTAssertEqual(reply2, valid2)
        XCTAssertEqual(upstream.udpPacketCount, 2)
    }

    func testClosingClientTCPControlTearsDownUDPAssociation() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let handles = RelayHandleCollector()
        let (share, port) = try await startShare(
            upstreamPort: upstream.port,
            collector: handles
        )
        defer { share.stop() }

        let clientControl = try await connect(port)
        let relayPort = try await negotiateClientUDPAssociate(clientControl)
        let clientUDP = try TestLoopbackUDPSocket()
        defer { clientUDP.close() }

        let packet = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x35, 0xAA])
        try clientUDP.send(packet, toLoopbackPort: relayPort)
        _ = try await clientUDP.receive(timeout: 3)

        try await TCPFlowSOCKSRelay.finishSending(to: clientControl)
        clientControl.cancel()

        let finished = await handles.waitForAllFinished(timeout: 3)
        XCTAssertTrue(finished)
        let upstreamClosed = await upstream.waitForUDPAssociationClose(timeout: 3)
        XCTAssertTrue(upstreamClosed)
    }

    func testProviderCancellationTearsDownActiveUDPAssociation() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let handles = RelayHandleCollector()
        let (share, port) = try await startShare(
            upstreamPort: upstream.port,
            collector: handles
        )
        defer { share.stop() }

        let clientControl = try await connect(port)
        defer { clientControl.forceCancel() }
        _ = try await negotiateClientUDPAssociate(clientControl)

        handles.cancelAll()
        let finished = await handles.waitForAllFinished(timeout: 3)
        XCTAssertTrue(finished)
    }

    func testUDPAssociateReclassifiesAsAssociationAndFailsClosedAfterHandoff() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let registry = ProviderRelayRegistry<UInt16>()
        registry.activate(generation: "A", endpoint: upstream.port)

        let share = LocalSOCKSShareListener(queueLabel: "local-socks-handoff-test", logger: logger) { [credentials, logger] connection in
            guard let reservation = registry.reserve() else {
                connection.forceCancel()
                return
            }
            let handle = LocalSOCKSShareRelay.makeHandle(
                client: connection,
                socksPort: reservation.endpoint,
                credentials: credentials,
                trialID: reservation.generation,
                traffic: ProviderTrafficLedger(),
                logger: logger,
                adoptUDPAssociation: {
                    registry.reclassify(reservation, owning: .association)
                }
            )
            guard registry.attach(handle, to: reservation) else {
                handle.cancel(with: AppProxyFlowCloseError.aborted)
                return
            }
            _ = handle.start(onFinish: {
                registry.finish(reservation)
            })
        }
        defer { share.stop() }

        var chosenPort: UInt16 = 0
        for _ in 0..<20 {
            let candidate = UInt16.random(in: 40_000...59_000)
            if await configure(share, port: candidate) == .listening(candidate) {
                chosenPort = candidate
                break
            }
            share.stop()
        }
        XCTAssertNotEqual(chosenPort, 0)

        let activeClient = try await connect(chosenPort)
        defer { activeClient.forceCancel() }
        _ = try await negotiateClientUDPAssociate(activeClient)

        // Start a second connection before handoff, then handoff before its 0x03 request.
        let lateClient = try await connect(chosenPort)
        defer { lateClient.forceCancel() }
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: lateClient)
        let greeting = try await TCPFlowSOCKSRelay.receiveExactly(2, from: lateClient)
        XCTAssertEqual(greeting, Data([0x05, 0x00]))

        let sourceDrain = registry.handoff(generation: "B", endpoint: upstream.port)
        // Active UDP association is classified under .association, not .flow.
        XCTAssertEqual(sourceDrain.subset(owning: .association).count, 1)

        try await TCPFlowSOCKSRelay.send(
            Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
            to: lateClient
        )
        let rejectedReply = try await TCPFlowSOCKSRelay.receiveExactly(10, from: lateClient)
        XCTAssertEqual(rejectedReply, LocalSOCKSHandshake.reply(0x01))

        sourceDrain.cancel()
        XCTAssertTrue(sourceDrain.wait(timeout: 3))
    }

    func testUDPAssociateHonorsExplicitClientPortHintAgainstPreemption() async throws {
        let upstream = try await FakeSessionEntry.start(credentials: credentials)
        defer { upstream.stop() }
        let (share, port) = try await startShare(upstreamPort: upstream.port)
        defer { share.stop() }

        let primaryUDP = try TestLoopbackUDPSocket()
        defer { primaryUDP.close() }
        let foreignUDP = try TestLoopbackUDPSocket()
        defer { foreignUDP.close() }

        let clientControl = try await connect(port)
        defer { clientControl.forceCancel() }
        let relayPort = try await negotiateClientUDPAssociate(
            clientControl,
            hintedClientPort: primaryUDP.port
        )

        // Foreign local socket sends first before primaryUDP ever transmits.
        let preemptAttempt = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 9, 0x00, 0x35])
            + Data("preempt".utf8)
        try foreignUDP.send(preemptAttempt, toLoopbackPort: relayPort)

        let legitimate = Data([0x00, 0x00, 0x00, 0x01, 10, 0, 0, 1, 0x00, 0x35])
            + Data("legit".utf8)
        try primaryUDP.send(legitimate, toLoopbackPort: relayPort)
        let reply = try await primaryUDP.receive(timeout: 3)
        XCTAssertEqual(reply, legitimate)
        XCTAssertEqual(upstream.udpPacketCount, 1)
    }

    private func negotiateClientUDPAssociate(
        _ client: NWConnection,
        hintedClientPort: UInt16? = nil
    ) async throws -> UInt16 {
        try await TCPFlowSOCKSRelay.send(Data([0x05, 0x01, 0x00]), to: client)
        let greeting = try await TCPFlowSOCKSRelay.receiveExactly(2, from: client)
        XCTAssertEqual(greeting, Data([0x05, 0x00]))
        let request: Data
        if let hintedClientPort {
            request = Data([
                0x05, 0x03, 0x00, 0x01,
                127, 0, 0, 1,
                UInt8(hintedClientPort >> 8), UInt8(hintedClientPort & 0xFF),
            ])
        } else {
            request = Data([0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        }
        try await TCPFlowSOCKSRelay.send(request, to: client)
        let reply = try await TCPFlowSOCKSRelay.receiveExactly(10, from: client)
        XCTAssertEqual(reply.prefix(8), Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1]))
        return UInt16(reply[8]) << 8 | UInt16(reply[9])
    }

    private func makeShare(
        upstreamPort: UInt16,
        traffic: ProviderTrafficLedger = ProviderTrafficLedger(),
        collector: RelayHandleCollector? = nil
    ) -> LocalSOCKSShareListener {
        return LocalSOCKSShareListener(queueLabel: "local-socks-share-test", logger: logger) { [credentials, logger] connection in
            let handle = LocalSOCKSShareRelay.makeHandle(
                client: connection, socksPort: upstreamPort, credentials: credentials,
                trialID: "tx", traffic: traffic, logger: logger)
            collector?.track(handle)
            _ = handle.start(onFinish: {
                collector?.noteFinished()
            })
        }
    }

    private func configure(_ share: LocalSOCKSShareListener, port: UInt16) async -> LocalSOCKSShareStatus {
        await withCheckedContinuation { continuation in
            share.configure(port: port) { continuation.resume(returning: $0) }
        }
    }

    private func startShare(
        upstreamPort: UInt16,
        traffic: ProviderTrafficLedger = ProviderTrafficLedger(),
        collector: RelayHandleCollector? = nil
    ) async throws -> (LocalSOCKSShareListener, UInt16) {
        for _ in 0..<20 {
            let port = UInt16.random(in: 40_000...59_000)
            let share = makeShare(
                upstreamPort: upstreamPort,
                traffic: traffic,
                collector: collector
            )
            if await configure(share, port: port) == .listening(port) {
                return (share, port)
            }
            share.stop()
        }
        throw CocoaError(.featureUnsupported)
    }

    private func connect(_ port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await TCPFlowSOCKSRelay.start(connection)
        return connection
    }
}

/// Minimal session SOCKS entry: username/password auth, CONNECT or UDP ASSOCIATE, then echo.
private final class FakeSessionEntry: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var recorded: [LocalSOCKSHandshake.Destination] = []
    private var accepted = 0
    private var udpDatagrams = 0
    private var activeUDPAssociations = 0
    private var sawUDPAssociation = false
    let port: UInt16

    var destinations: [LocalSOCKSHandshake.Destination] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    var connectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return accepted
    }

    var udpPacketCount: Int {
        lock.lock(); defer { lock.unlock() }
        return udpDatagrams
    }

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start(credentials: SOCKSCredentials) async throws -> FakeSessionEntry {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.take() { continuation.resume(returning: listener.port!.rawValue) }
                case let .failed(error):
                    if once.take() { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: .global())
        }
        let entry = FakeSessionEntry(listener: listener, port: port)
        listener.newConnectionHandler = { connection in
            Task { await entry.serve(connection, credentials: credentials) }
        }
        return entry
    }

    func stop() {
        listener.cancel()
    }

    func waitForUDPAssociationClose(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isUDPAssociationClosed { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private var isUDPAssociationClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sawUDPAssociation && activeUDPAssociations == 0
    }

    private func noteAccepted() {
        lock.lock(); accepted += 1; lock.unlock()
    }

    private func record(_ destination: LocalSOCKSHandshake.Destination) {
        lock.lock(); recorded.append(destination); lock.unlock()
    }

    private func noteUDPPacket() {
        lock.lock(); udpDatagrams += 1; lock.unlock()
    }

    private func beginUDPAssociation() {
        lock.lock()
        sawUDPAssociation = true
        activeUDPAssociations += 1
        lock.unlock()
    }

    private func endUDPAssociation() {
        lock.lock()
        activeUDPAssociations -= 1
        lock.unlock()
    }

    private func serve(_ connection: NWConnection, credentials: SOCKSCredentials) async {
        noteAccepted()
        do {
            try await TCPFlowSOCKSRelay.start(connection)
            let read: LocalSOCKSHandshake.Read = { try await TCPFlowSOCKSRelay.receiveExactly($0, from: connection) }
            guard try await read(3) == Data([0x05, 0x01, 0x02]) else { throw CocoaError(.coderInvalidValue) }
            try await TCPFlowSOCKSRelay.send(Data([0x05, 0x02]), to: connection)
            let user = try await read(Int(try await read(2).last!))
            let pass = try await read(Int(try await read(1).first!))
            guard String(decoding: user, as: UTF8.self) == credentials.username,
                  String(decoding: pass, as: UTF8.self) == credentials.password else {
                try await TCPFlowSOCKSRelay.send(Data([0x01, 0x01]), to: connection)
                throw CocoaError(.coderInvalidValue)
            }
            try await TCPFlowSOCKSRelay.send(Data([0x01, 0x00]), to: connection)
            let request = try await LocalSOCKSHandshake.readRequest(read)
            switch request {
            case let .connect(destination):
                record(destination)
                try await TCPFlowSOCKSRelay.send(LocalSOCKSHandshake.reply(0x00), to: connection)
                while true {
                    let result = try await TCPFlowSOCKSRelay.receive(from: connection)
                    if !result.data.isEmpty {
                        try await TCPFlowSOCKSRelay.send(result.data, to: connection)
                    }
                    if result.isComplete || result.error != nil || result.data.isEmpty { break }
                }

            case .udpAssociate:
                beginUDPAssociation()
                defer { endUDPAssociation() }
                let echoSocket = try TestLoopbackUDPSocket()
                defer { echoSocket.close() }
                echoSocket.startEcho { [weak self] in
                    self?.noteUDPPacket()
                }
                try await TCPFlowSOCKSRelay.send(
                    LocalSOCKSHandshake.udpAssociateReply(port: echoSocket.port),
                    to: connection
                )
                while true {
                    let result = try await TCPFlowSOCKSRelay.receive(from: connection)
                    if result.isComplete || result.error != nil || result.data.isEmpty { break }
                }
            }
        } catch {}
        connection.forceCancel()
    }
}

private final class RelayHandleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [ProviderRelayHandle] = []
    private var activeCount = 0

    func track(_ handle: ProviderRelayHandle) {
        lock.lock()
        handles.append(handle)
        activeCount += 1
        lock.unlock()
    }

    func noteFinished() {
        lock.lock()
        activeCount -= 1
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let snapshot = handles
        lock.unlock()
        for handle in snapshot {
            handle.cancel(with: AppProxyFlowCloseError.aborted)
        }
    }

    func waitForAllFinished(timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if allFinished { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private var allFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !handles.isEmpty && activeCount == 0
    }
}

private final class TestLoopbackUDPSocket: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var readSource: DispatchSourceRead?

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let flags = Darwin.fcntl(descriptor, F_GETFL, 0)
        _ = Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
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
        _ = withUnsafeMutablePointer(to: &assigned) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                Darwin.getsockname(descriptor, raw, &assignedLen)
            }
        }
        self.fd = descriptor
        self.port = UInt16(bigEndian: assigned.sin_port)
    }

    func send(_ data: Data, toLoopbackPort targetPort: UInt16) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = targetPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_LOOPBACK.bigEndian)
        try send(data, to: addr)
    }

    private func send(_ data: Data, to destination: sockaddr_in) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw CocoaError(.fileWriteUnknown) }
        var dest = destination
        let sent = data.withUnsafeBytes { rawBuf in
            withUnsafePointer(to: &dest) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.sendto(
                        fd,
                        rawBuf.baseAddress,
                        rawBuf.count,
                        0,
                        sockPtr,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sent == data.count else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func receive(timeout: TimeInterval) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline {
            let count: Int = buffer.withUnsafeMutableBytes { rawBuf in
                lock.lock()
                defer { lock.unlock() }
                guard !closed else { return -1 }
                return Darwin.recv(fd, rawBuf.baseAddress, rawBuf.count, 0)
            }
            if count > 0 {
                return Data(bytes: buffer, count: count)
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    func startEcho(onPacket: @escaping @Sendable () -> Void) {
        let queue = DispatchQueue(label: "test-udp-echo.\(port)")
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = [UInt8](repeating: 0, count: 65536)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            while true {
                var sender = sockaddr_in()
                var senderLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let count = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                    self.lock.lock()
                    defer { self.lock.unlock() }
                    guard !self.closed else { return -1 }
                    return withUnsafeMutablePointer(to: &sender) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            Darwin.recvfrom(self.fd, rawBuf.baseAddress, rawBuf.count, 0, sockPtr, &senderLen)
                        }
                    }
                }
                guard count > 0 else { break }
                onPacket()
                let packet = Data(bytes: buffer, count: count)
                try? self.send(packet, to: sender)
            }
        }
        let descriptor = fd
        source.setCancelHandler { [weak self] in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            self.lock.lock()
            if !self.closed {
                self.closed = true
                Darwin.close(self.fd)
            }
            self.lock.unlock()
        }
        lock.lock()
        readSource = source
        lock.unlock()
        source.resume()
    }

    func close() {
        lock.lock()
        if let source = readSource {
            readSource = nil
            lock.unlock()
            source.cancel()
            return
        }
        if !closed {
            closed = true
            Darwin.close(fd)
        }
        lock.unlock()
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !taken else { return false }
        taken = true
        return true
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
