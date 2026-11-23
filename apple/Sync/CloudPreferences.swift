import Foundation

extension AppState {
    func configureCloudSync(noticeAccepted: Bool) {
        cloudSync.configure(noticeAccepted: noticeAccepted, capture: { [weak self] in
            guard let self, self.dataUseNoticeAccepted else {
                throw CloudSyncIssue("请先确认数据使用说明 · Accept the data use notice first")
            }
            return try self.cloudConfiguration()
        }, apply: { [weak self] archive in
            guard let self else { throw CancellationError() }
            try self.applyCloudConfiguration(archive)
        })
    }

    func cloudPreferences() -> [String: String] {
        var settings = ["language": language.rawValue]
        #if os(macOS)
        settings["connectOnOpen"] = String(autoConnect)
        settings[ConnectionNotice.networkPreferenceKey] = String(ConnectionNotice.preferences.bool(forKey: ConnectionNotice.networkPreferenceKey))
        settings["macLaunchAtLogin"] = String(launchAtLogin)
        settings["appearance"] = appearance.rawValue
        settings["macSOCKSPort"] = String(localSOCKSShare.port)
        settings["macSOCKSEnabled"] = String(localSOCKSShare.isEnabled)
        settings["macIngressMode"] = localSOCKSShare.ingressMode.rawValue
        settings["menuTraffic"] = String(showsMenuBarTraffic)
        settings["automaticScenario"] = String(automaticScenario)
        #else
        settings["connectOnOpen"] = String(connectOnOpenEnabled)
        settings["autoReconnect"] = String(autoReconnectEnabled)
        #if os(iOS)
        settings["automaticScenario"] = String(ScenarioAutoPilot.isAutoEnabled)
        settings["iosLiveActivity"] = String(ConnectionActivityController.isEnabledByUser)
        settings["iosSystemOnDemand"] = String(systemOnDemandEnabled)
        #endif
        #endif
        #if !os(tvOS)
        for notice in [ConnectionNotice.disconnect, .scenario] {
            settings[notice.preferenceKey] = String(ConnectionNotice.preferences.bool(forKey: notice.preferenceKey))
        }
        #endif
        return settings
    }

    func applyCloudPreferences(_ settings: [String: String]) {
        if let code = settings["language"], let lang = Lang(rawValue: code) { language = lang }
        #if os(macOS)
        if let value = settings[ConnectionNotice.networkPreferenceKey].flatMap(Bool.init) {
            ConnectionNotice.preferences.set(value, forKey: ConnectionNotice.networkPreferenceKey)
        }
        if let value = settings["macLaunchAtLogin"].flatMap(Bool.init), value != launchAtLogin { launchAtLogin = value }
        if let value = settings["appearance"].flatMap(AppAppearance.init(rawValue:)) { appearance = value }
        if let value = settings["macSOCKSPort"].flatMap(Int.init) { localSOCKSShare.setPort(value) }
        if let value = settings["macSOCKSEnabled"].flatMap(Bool.init) { localSOCKSShare.isEnabled = value }
        if let mode = settings["macIngressMode"].flatMap(ConnectionIngress.Mode.init(rawValue:)) { localSOCKSShare.ingressMode = mode }
        if let value = settings["menuTraffic"].flatMap(Bool.init) { showsMenuBarTraffic = value }
        if let value = settings["connectOnOpen"].flatMap(Bool.init) { autoConnect = value }
        if let value = settings["automaticScenario"].flatMap(Bool.init), value != automaticScenario { automaticScenario = value }
        #else
        if let value = settings["connectOnOpen"].flatMap(Bool.init) { connectOnOpenEnabled = value }
        if let value = settings["autoReconnect"].flatMap(Bool.init) { autoReconnectEnabled = value }
        #if os(iOS)
        if let value = settings["iosLiveActivity"].flatMap(Bool.init), value != ConnectionActivityController.isEnabledByUser {
            ConnectionActivityController.isEnabledByUser = value
            MobileAppRuntime.connectionActivity?.preferenceChanged()
        }
        if let value = settings["iosSystemOnDemand"].flatMap(Bool.init), value != systemOnDemandEnabled { systemOnDemandEnabled = value }
        if let value = settings["automaticScenario"].flatMap(Bool.init) {
            UserDefaults.standard.set(value, forKey: ScenarioAutoPilot.autoEnabledKey)
        }
        #endif
        #endif
        #if !os(tvOS)
        for notice in [ConnectionNotice.disconnect, .scenario] {
            if let value = settings[notice.preferenceKey].flatMap(Bool.init) {
                ConnectionNotice.preferences.set(value, forKey: notice.preferenceKey)
            }
        }
        #endif
    }
}
