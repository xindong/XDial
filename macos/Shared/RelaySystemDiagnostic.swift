import Foundation
import Network
import NetworkExtension

enum RelaySystemDiagnostic {
    static func code(for error: Error) -> String {
        if let network = error as? NWError {
            switch network {
            case let .posix(code): return "posix-\(code.rawValue)"
            case let .dns(code): return "dns-\(code)"
            case let .tls(code): return "tls-\(code)"
#if compiler(>=6.2)
            case .wifiAware: return "wifi-aware"
#endif
            @unknown default: return "network-unknown"
            }
        }
        let system = error as NSError
        let source: String
        switch system.domain {
        case NEAppProxyErrorDomain: source = "ne-app-proxy"
        case NSPOSIXErrorDomain: source = "posix"
        case NSURLErrorDomain: source = "url"
        case NSCocoaErrorDomain: source = "cocoa"
        case NSOSStatusErrorDomain: source = "osstatus"
        default: source = "other"
        }
        return "\(source)-\(system.code)"
    }
}
