import Foundation
import SystemConfiguration

struct NetworkChangeNoticeBaseline {
    struct Path: Equatable {
        let available: Bool
        let usesWiFi: Bool
        var interfaces: [String]
        var gateways: [String]
    }

    private var lastPath: Path?
    private var lastSSID: String?

    mutating func changed(path: Path, ssid: String?) -> Bool {
        let previousPath = lastPath
        let previousSSID = lastSSID
        lastPath = path
        // A missing SSID can mean location access is unavailable. Compare
        // names only within the same Wi-Fi path, across readable samples.
        lastSSID = path.usesWiFi ? (ssid ?? (path == previousPath ? previousSSID : nil)) : nil
        guard let previousPath else { return false }
        if previousPath != path { return true }
        guard path.usesWiFi, let previousSSID, let ssid else { return false }
        return ssid != previousSSID
    }
}

/// Observes the same global keys used to sample routers, including while idle.
/// The callback only feeds the host's existing notice settlement task.
final class NetworkGatewayNoticeMonitor {
    private var store: SCDynamicStore?

    private final class Callback {
        let changed: @MainActor () -> Void
        init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
    }

    private static let keys = [
        "State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
    ]

    init(onChange: @escaping @MainActor () -> Void) {
        let callback = Unmanaged.passRetained(Callback(onChange))
        var context = SCDynamicStoreContext(
            version: 0, info: callback.toOpaque(), retain: nil,
            release: { info in Unmanaged<Callback>.fromOpaque(info).release() },
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(
            nil, "XDial network notices" as CFString,
            { _, _, info in
                guard let info else { return }
                let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async { callback.changed() }
            }, &context
        ) else {
            callback.release()
            return
        }
        guard SCDynamicStoreSetNotificationKeys(store, Self.keys as CFArray, nil),
              SCDynamicStoreSetDispatchQueue(store, .main) else { return }
        self.store = store
    }

    deinit {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }

    struct Facts {
        var interfaces: [String] = []
        var gateways: [String] = []
    }

    static func currentFacts(
        readState: (String) -> [String: Any]? = {
            SCDynamicStoreCopyValue(nil, $0 as CFString) as? [String: Any]
        }
    ) -> Facts {
        var facts = Facts()
        for (key, property) in zip(keys, [kSCPropNetIPv4Router, kSCPropNetIPv6Router]) {
            let state = readState(key)
            if let interface = state?[kSCDynamicStorePropNetPrimaryInterface as String] as? String {
                facts.interfaces.append(key + "=" + interface)
            }
            if let router = state?[property as String] as? String {
                facts.gateways.append(key + "=" + router)
            }
        }
        return facts
    }
}
