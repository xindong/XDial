import Foundation
import UserNotifications

#if os(iOS)
import NetworkExtension
#endif

enum ConnectionNotice {
    case disconnect, configurationDisabled, scenario

    #if os(macOS)
    case network(available: Bool)
    static let networkPreferenceKey = "xdial.notify.network"
    #endif

    var preferenceKey: String {
        switch self {
        case .disconnect, .configurationDisabled: "xdial.notify.disconnect"
        case .scenario: "xdial.notify.scenario"
        #if os(macOS)
        case .network: Self.networkPreferenceKey
        #endif
        }
    }

    #if os(iOS)
    static func forTunnelStop(_ reason: NEProviderStopReason, wasRunning: Bool,
                              appRequestedStop: @autoclosure () -> Bool) -> Self? {
        guard wasRunning else { return nil }
        switch reason {
        case .configurationDisabled: return appRequestedStop() ? nil : .configurationDisabled
        case .providerFailed, .noNetworkAvailable, .unrecoverableNetworkChange,
             .connectionFailed, .internalError, .idleTimeout: return .disconnect
        default: return nil
        }
    }
    #endif

    enum Submission: String { case submitted, disabled, failed }

    static var preferences: UserDefaults {
        #if os(iOS)
        UserDefaults(suiteName: XDialIdentity.appGroup)!
        #else
        xdialDefaults
        #endif
    }

    func post(scenarioName: String = "", completion: @escaping @Sendable (Submission) -> Void = { _ in }) {
        let defaults = Self.preferences
        guard defaults.bool(forKey: preferenceKey) else { completion(.disabled); return }
        let language = defaults.string(forKey: "xdial.language") ?? Locale.preferredLanguages.first
        let chinese = language?.hasPrefix("zh") == true
        let content = UNMutableNotificationContent()
        switch self {
        #if os(macOS)
        case let .network(available):
            content.title = chinese ? "系统网络已变化" : "Network changed"
            content.body = available ? (chinese ? "网络可用" : "Network available") :
                (chinese ? "网络不可用" : "Network unavailable")
        #endif
        case .disconnect:
            content.title = chinese ? "XDial 意外断线" : "XDial disconnected unexpectedly"
        case .configurationDisabled:
            content.title = chinese ? "XDial 已断开" : "XDial disconnected"
            content.body = chinese ? "系统已停用 XDial 的 VPN 配置，流量已停止通过 XDial。" :
                "The system disabled XDial’s VPN configuration. Traffic is no longer going through XDial."
        case .scenario:
            content.title = chinese ? "XDial 场景已切换" : "XDial switched scenarios"
            content.body = scenarioName
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("XDial notification failed: %@", error.localizedDescription)
                completion(.failed)
            } else {
                completion(.submitted)
            }
        }
    }
}
