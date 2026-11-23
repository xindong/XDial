import SwiftUI
import UserNotifications

final class ConnectionNoticePresenter: NSObject, UNUserNotificationCenterDelegate {
    @MainActor static let shared = ConnectionNoticePresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

struct ConnectionNoticeSettings: View {
    let chinese: Bool
    @AppStorage(ConnectionNotice.disconnect.preferenceKey, store: ConnectionNotice.preferences) private var disconnect = false
    @AppStorage(ConnectionNotice.scenario.preferenceKey, store: ConnectionNotice.preferences) private var scenario = false
    #if os(macOS)
    @AppStorage(ConnectionNotice.networkPreferenceKey, store: ConnectionNotice.preferences) private var network = false
    #else
    private let network = false
    #endif
    @Environment(\.scenePhase) private var scenePhase
    @State private var denied = false
    @State private var requestFailed = false

    var body: some View {
        Toggle(chinese ? "意外断线时通知" : "Notify on unexpected disconnect", isOn: $disconnect)
            .task(id: scenePhase) {
                denied = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
            }
            .onChange(of: disconnect) { _, enabled in if enabled { requestPermission() } }
        Toggle(chinese ? "场景切换时通知" : "Notify on scenario change", isOn: $scenario)
            .onChange(of: scenario) { _, enabled in if enabled { requestPermission() } }
        #if os(macOS)
        Toggle(chinese ? "网络变化时通知" : "Notify on network change", isOn: $network)
            .onChange(of: network) { _, enabled in if enabled { requestPermission() } }
        #endif
        if disconnect || scenario || network {
            if denied {
                Text(chinese ? "请在系统通知设置中允许 XDial 发送通知。" : "Allow XDial in system notification settings.")
                    .font(.footnote)
            } else if requestFailed {
                Text(chinese ? "请求通知权限失败，请在系统设置中检查通知权限。" : "Couldn't request permission. Check system notification settings.")
                    .font(.footnote)
            }
        }

    }

    private func requestPermission() {
        Task {
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
                denied = !granted
                requestFailed = false
            } catch {
                requestFailed = true
            }
        }
    }
}
