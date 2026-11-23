import Foundation

/// Classify only failures at the AnyConnect login/CONNECT boundary.
/// A 401 from a subscription or a different VPN request has a different remedy.
enum AnyConnectLoginFailure {
    case missingToken
    case rejectedSession

    init?(message: String) {
        let prefix = "AnyConnect connect: "
        if message.contains(prefix + "authentication completed without a session token") {
            self = .missingToken
        } else if let range = message.range(of: prefix + "tunnel negotiation failed 401"),
                  message[range.upperBound...].first.map({ $0.isWhitespace }) ?? true {
            self = .rejectedSession
        } else {
            return nil
        }
    }

    func reason(tr: (String, String) -> String) -> String {
        switch self {
        case .missingToken:
            tr("VPN 登录后未取得会话凭据", "VPN sign-in returned no session token")
        case .rejectedSession:
            tr("VPN 网关拒绝了本次会话", "The VPN gateway rejected this session")
        }
    }
}
