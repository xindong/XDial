import Foundation
import Network

/// 本机 SOCKS5 共享：其他本机程序经 `127.0.0.1:<port>` 使用当前已提交的场景。
///
/// 端口由 Provider 持有，只绑回环，只接受无认证的 TCP CONNECT 与 UDP ASSOCIATE。
/// 每条连接在接入时取得当前 generation 的会话入口，场景切换不改动监听端口；应用身份
/// 不经过这条入口，因此只走场景的普通规则。
enum LocalSOCKSSharePort {
    static let defaultValue = 5181
    static let range = 1024...65535

    static func isValid(_ port: Int) -> Bool {
        range.contains(port)
    }
}

/// 一笔连接的流量入口：接管系统流量，或只经本机 SOCKS5 端口（不接管系统）。
struct ConnectionIngress: Codable, Equatable {
    enum Mode: String, Codable, Equatable {
        case system
        case localSOCKS = "local-socks"
    }

    let mode: Mode
    /// 仅 `localSOCKS` 携带；端口是这笔连接的入口，属于连接事务。
    let localSOCKSPort: UInt16?

    static let system = ConnectionIngress(mode: .system, localSOCKSPort: nil)

    static func localSOCKS(port: UInt16) -> ConnectionIngress {
        ConnectionIngress(mode: .localSOCKS, localSOCKSPort: port)
    }

    var isValid: Bool {
        switch mode {
        case .system:
            return localSOCKSPort == nil
        case .localSOCKS:
            return localSOCKSPort.map { LocalSOCKSSharePort.isValid(Int($0)) } ?? false
        }
    }

    var takesOverSystem: Bool { mode == .system }

    enum CodingKeys: String, CodingKey {
        case mode
        case localSOCKSPort = "local_socks_port"
    }
}

struct LocalSOCKSShareRequest: Codable, Equatable {
    static let kind = "local-socks-share"
    static let version = 1

    let kind: String
    let version: Int
    let requestID: String
    let transactionID: String
    /// `nil` 表示关闭监听。
    let port: UInt16?

    init(transactionID: String, port: UInt16?) {
        kind = Self.kind
        version = Self.version
        requestID = UUID().uuidString
        self.transactionID = transactionID
        self.port = port
    }

    var isValid: Bool {
        kind == Self.kind && version == Self.version && !requestID.isEmpty
            && !transactionID.isEmpty
            && port.map { LocalSOCKSSharePort.isValid(Int($0)) } ?? true
    }
}

enum LocalSOCKSShareState: String, Codable, Equatable {
    case off
    case listening
    case failed
}

struct LocalSOCKSShareStatus: Codable, Equatable {
    let state: LocalSOCKSShareState
    let port: UInt16?
    /// `address-in-use`、`permission-denied`、`listener-failed`、`listener-timeout`。
    let code: String?

    static let off = LocalSOCKSShareStatus(state: .off, port: nil, code: nil)

    static func listening(_ port: UInt16) -> LocalSOCKSShareStatus {
        LocalSOCKSShareStatus(state: .listening, port: port, code: nil)
    }

    static func failed(_ port: UInt16, code: String) -> LocalSOCKSShareStatus {
        LocalSOCKSShareStatus(state: .failed, port: port, code: code)
    }

    static func failureCode(for error: NWError) -> String {
        switch error {
        case .posix(.EADDRINUSE):
            return "address-in-use"
        case .posix(.EACCES), .posix(.EPERM):
            return "permission-denied"
        default:
            return "listener-failed"
        }
    }
}

struct LocalSOCKSShareResponse: Codable, Equatable {
    let requestID: String
    let transactionID: String
    let code: String
    let status: LocalSOCKSShareStatus?
}

enum LocalSOCKSSharePolicy {
    static func rejection(
        request: LocalSOCKSShareRequest,
        transactionID: String,
        committed: Bool
    ) -> String? {
        guard request.isValid else { return "invalid-request" }
        guard request.transactionID == transactionID else {
            return "transaction-mismatch"
        }
        guard committed else { return "session-not-committed" }
        return nil
    }
}

/// 面向客户端的 SOCKS5 握手与 UDP 报头校验。
///
/// 会话入口接受 Provider 的 flow metadata（以 NUL 开头的域名信封），这里在握手与
/// 每个 UDP 数据报上都只放行普通主机名，客户端不能借本机端口伪造接口绑定或原始地址。
enum LocalSOCKSHandshake {
    enum Failure: Error, Equatable {
        case invalidVersion
        case noAcceptableMethod
        case commandNotSupported
        case addressTypeNotSupported
        case invalidDestination

        /// RFC 1928 §6 的 REP 字段；握手阶段的失败没有 REP。
        var replyCode: UInt8? {
            switch self {
            case .invalidVersion, .noAcceptableMethod:
                return nil
            case .commandNotSupported:
                return 0x07
            case .addressTypeNotSupported:
                return 0x08
            case .invalidDestination:
                return 0x01
            }
        }
    }

    struct Destination: Equatable {
        let host: String
        let port: UInt16
    }

    enum Request: Equatable {
        case connect(Destination)
        /// `clientPort` 仅在客户端显式声明本机回环非零源端口时填入（RFC 1928 §6）。
        case udpAssociate(clientPort: UInt16?)
    }

    typealias Read = (Int) async throws -> Data

    static let acceptNoAuthentication = Data([0x05, 0x00])
    static let rejectAllMethods = Data([0x05, 0xFF])
    static let generalFailure: UInt8 = 0x01

    /// 读取 greeting，客户端必须提供“无认证”方法。
    static func readGreeting(_ read: Read) async throws {
        let header = try await read(2)
        guard header[header.startIndex] == 0x05 else {
            throw Failure.invalidVersion
        }
        let count = Int(header[header.startIndex + 1])
        guard count > 0 else { throw Failure.noAcceptableMethod }
        let methods = try await read(count)
        guard methods.contains(0x00) else { throw Failure.noAcceptableMethod }
    }

    static func readRequest(_ read: Read) async throws -> Request {
        let header = try await read(4)
        let base = header.startIndex
        guard header[base] == 0x05, header[base + 2] == 0x00 else {
            throw Failure.invalidVersion
        }
        let command = header[base + 1]
        guard command == 0x01 || command == 0x03 else {
            throw Failure.commandNotSupported
        }
        let host: String
        let isLoopbackHint: Bool
        switch header[base + 3] {
        case 0x01:
            guard let address = IPv4Address(try await read(4)) else {
                throw Failure.invalidDestination
            }
            host = "\(address)"
            isLoopbackHint = address == .loopback
        case 0x04:
            guard let address = IPv6Address(try await read(16)) else {
                throw Failure.invalidDestination
            }
            host = "\(address)"
            // 中继套接字固定绑定 IPv4 127.0.0.1，客户端若原持 IPv6 套接字在收到
            // IPv4 BND.ADDR 后可能另开 IPv4 临时端口发包，仅对 127.0.0.1 预锁端口。
            isLoopbackHint = false
        case 0x03:
            let length = try await read(1)
            let count = Int(length[length.startIndex])
            guard count > 0 else { throw Failure.invalidDestination }
            guard let name = hostname(try await read(count)) else {
                throw Failure.invalidDestination
            }
            host = name
            isLoopbackHint = false
        default:
            throw Failure.addressTypeNotSupported
        }
        let portBytes = try await read(2)
        let port = UInt16(portBytes[portBytes.startIndex]) << 8
            | UInt16(portBytes[portBytes.startIndex + 1])
        if command == 0x01 {
            guard port != 0 else { throw Failure.invalidDestination }
            return .connect(Destination(host: host, port: port))
        }
        let hintedPort = (isLoopbackHint && port != 0) ? port : nil
        return .udpAssociate(clientPort: hintedPort)
    }

    /// 只放行可打印的主机名字节；NUL、空白与控制字符一律拒绝。
    static func hostname(_ bytes: Data) -> String? {
        guard
            (1...255).contains(bytes.count),
            bytes.allSatisfy({ $0 >= 0x80 || (0x21...0x7E).contains($0) }),
            let name = String(data: bytes, encoding: .utf8)
        else {
            return nil
        }
        return name
    }

    /// 校验客户端发来的 SOCKS5 UDP 请求包（RFC 1928 §7），返回数据载荷字节数。
    ///
    /// 拒绝分片包、端口 0 与含控制字符的域名，防止客户端经 UDP 帧头注入
    /// Provider 专用的 flow metadata 或绑定接口标记包。
    static func clientUDPDatagramPayloadLength(_ packet: Data) -> Int? {
        udpDatagramPayloadLength(packet, requireNonZeroPort: true)
    }

    /// 校验会话入口回传的 SOCKS5 UDP 响应包，返回数据载荷字节数。
    static func serverUDPDatagramPayloadLength(_ packet: Data) -> Int? {
        udpDatagramPayloadLength(packet, requireNonZeroPort: false)
    }

    private static func udpDatagramPayloadLength(
        _ packet: Data,
        requireNonZeroPort: Bool
    ) -> Int? {
        guard packet.count >= 7 else { return nil }
        let base = packet.startIndex
        guard
            packet[base] == 0x00,
            packet[base + 1] == 0x00,
            packet[base + 2] == 0x00
        else {
            return nil
        }
        let portOffset: Int
        switch packet[base + 3] {
        case 0x01:
            portOffset = 4 + 4
        case 0x04:
            portOffset = 4 + 16
        case 0x03:
            guard packet.count > 4 else { return nil }
            let length = Int(packet[base + 4])
            guard
                length > 0,
                packet.count >= 5 + length + 2,
                hostname(packet.subdata(in: (base + 5)..<(base + 5 + length))) != nil
            else {
                return nil
            }
            portOffset = 5 + length
        default:
            return nil
        }
        guard packet.count >= portOffset + 2 else { return nil }
        let port = UInt16(packet[base + portOffset]) << 8
            | UInt16(packet[base + portOffset + 1])
        if requireNonZeroPort, port == 0 {
            return nil
        }
        return packet.count - (portOffset + 2)
    }

    /// 回给客户端的 CONNECT 或错误结果。绑定地址指向本机会话入口，对客户端没有意义，
    /// 统一填 0.0.0.0:0。
    static func reply(_ code: UInt8) -> Data {
        Data([0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    /// 回给客户端的 UDP ASSOCIATE 成功结果，指向本机回环 UDP 中继端口。
    static func udpAssociateReply(port: UInt16) -> Data {
        Data([
            0x05, 0x00, 0x00, 0x01,
            127, 0, 0, 1,
            UInt8(port >> 8), UInt8(port & 0xFF),
        ])
    }
}
