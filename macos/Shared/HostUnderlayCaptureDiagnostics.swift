import Foundation

enum HostUnderlayCaptureFailureReason: String, Codable, Equatable {
    case pathUpdateMissing = "underlay-path-update-missing"
    case pathUnsatisfied = "underlay-path-unsatisfied"
    case defaultRouteUnavailable = "underlay-default-route-unavailable"
    case routePathMismatch = "underlay-route-path-mismatch"
    case interfaceIndexUnavailable =
        "underlay-interface-index-unavailable"
    case snapshotEncodingFailed =
        "underlay-interface-snapshot-encoding-failed"
}

struct HostUnderlayCaptureEvidence: Codable, Equatable {
    let schemaVersion: Int
    let reason: HostUnderlayCaptureFailureReason
    let pathStatus: String
    let routeInterface: String
    let candidateInterfaces: [String]
    let invalidCandidateInterfaces: [String]
    let routeError: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case reason
        case pathStatus = "path_status"
        case routeInterface = "route_interface"
        case candidateInterfaces = "candidate_interfaces"
        case invalidCandidateInterfaces =
            "invalid_candidate_interfaces"
        case routeError = "route_error"
    }

    static let missingPathUpdate = HostUnderlayCaptureEvidence(
        schemaVersion: 1,
        reason: .pathUpdateMissing,
        pathStatus: "unknown",
        routeInterface: "",
        candidateInterfaces: [],
        invalidCandidateInterfaces: [],
        routeError: ""
    )

    var logSummary: String {
        [
            "reason=\(reason.rawValue)",
            "path-status=\(pathStatus)",
            "route-interface=\(routeInterface.isEmpty ? "-" : routeInterface)",
            "candidates=\(candidateInterfaces.joined(separator: ","))",
            "invalid-candidates=\(invalidCandidateInterfaces.joined(separator: ","))",
            "route-error=\(routeError.isEmpty ? "-" : routeError)",
        ].joined(separator: " ")
    }
}

enum HostUnderlayCaptureDiagnosticClassifier {
    static func classify(
        pathStatus: String,
        routeInterface: String,
        routeError: String,
        candidateInterfaces: [String],
        indexedInterfaces: [String]
    ) -> HostUnderlayCaptureEvidence? {
        let reason: HostUnderlayCaptureFailureReason?
        if pathStatus != "satisfied" {
            reason = .pathUnsatisfied
        } else if !routeError.isEmpty || routeInterface.isEmpty {
            reason = .defaultRouteUnavailable
        } else if !candidateInterfaces.contains(routeInterface) {
            reason = .routePathMismatch
        } else if !indexedInterfaces.contains(routeInterface) {
            reason = .interfaceIndexUnavailable
        } else {
            reason = nil
        }
        guard let reason else { return nil }
        return HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: reason,
            pathStatus: pathStatus,
            routeInterface: routeInterface,
            candidateInterfaces: candidateInterfaces,
            invalidCandidateInterfaces: candidateInterfaces.filter {
                !indexedInterfaces.contains($0)
            },
            routeError: routeError
        )
    }
}

/// One host Underlay capture resolves exactly once: with the first usable
/// path, or with the evidence held when its deadline fires. A deadline that
/// fires after the capture already resolved is not a timeout.
struct HostUnderlayCaptureResolution {
    private(set) var isResolved = false
    private var latestEvidence: HostUnderlayCaptureEvidence?

    mutating func observe(_ evidence: HostUnderlayCaptureEvidence) {
        guard !isResolved else { return }
        latestEvidence = evidence
    }

    /// True only for the call that resolves the capture.
    mutating func resolve() -> Bool {
        guard !isResolved else { return false }
        isResolved = true
        return true
    }

    /// Timeout evidence when the deadline resolves the capture; nil when a
    /// path or an earlier failure already did.
    mutating func expire() -> HostUnderlayCaptureEvidence? {
        guard resolve() else { return nil }
        return latestEvidence ?? .missingPathUpdate
    }
}

/// 选出 Underlay 的 resolver。
///
/// Underlay 的 DNS 是**启动前默认接口作用域**的那一份，不是
/// `State:/Network/Global/DNS`。全局 DNS 可以被另一个虚拟网络接管——例如
/// Tailscale MagicDNS 会把它改写成只在自己的 utun 上可达的 100.100.100.100。
/// XDial 不识别网络产品，但一旦把这种地址当成 Underlay 的系统 DNS，凡是本次
/// 事务没有承载那个虚拟接口的场景，归直连裁决的域名就会整片解析进黑洞，而走
/// 其它线路解析的域名看起来一切正常。
///
/// 取不到作用域 resolver 时退回全局 DNS，保持既有行为：宁可沿用旧语义，也不
/// 让连接因为读不到一个 SCDynamicStore 键而失败。
enum UnderlayResolverSelection {
    /// - Parameters:
    ///   - interfaceName: 本次快照已经选定的默认接口。传 nil 表示不校验主接口，
    ///     直接采信系统当前的主服务。
    ///   - primaryInterface: `State:/Network/Global/IPv4` 的 PrimaryInterface。
    ///   - primaryService: `State:/Network/Global/IPv4` 的 PrimaryService。
    ///   - scopedAddresses: 主服务作用域 DNS 的 ServerAddresses。
    ///   - globalAddresses: `State:/Network/Global/DNS` 的 ServerAddresses。
    static func serverAddresses(
        interfaceName: String?,
        primaryInterface: String?,
        primaryService: String?,
        scopedAddresses: [String]?,
        globalAddresses: [String]?
    ) -> [String]? {
        if let scoped = scopedAddresses,
           !scoped.isEmpty,
           let service = primaryService,
           !service.isEmpty,
           interfaceName == nil || primaryInterface == interfaceName {
            return scoped
        }
        guard let global = globalAddresses, !global.isEmpty else {
            return nil
        }
        return global
    }
}
