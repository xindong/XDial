import Combine
import CoreLocation
import SwiftUI

/// A saved place stays on this iPhone. The tunnel receives only the matched scenario ID.
struct ScenarioPlace: Codable, Equatable {
    let scenarioID: String
    let latitude: Double
    let longitude: Double

    static let radius = 300.0

    func distance(from location: CLLocation) -> Double {
        location.distance(from: CLLocation(latitude: latitude, longitude: longitude))
    }

    static func match(_ location: CLLocation, in places: [Self], previous: String?) -> String? {
        // Keep the previous match while the accuracy circle crosses its boundary.
        if let place = places.first(where: { $0.scenarioID == previous }),
           place.distance(from: location) - location.horizontalAccuracy <= radius {
            return previous
        }
        return places.filter { $0.distance(from: location) + location.horizontalAccuracy <= radius }
            .min { $0.distance(from: location) < $1.distance(from: location) }?.scenarioID
    }
}

@MainActor
final class LocationScenarios: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = LocationScenarios()
    private let manager = CLLocationManager()
    // One-shot fixes do not disturb the continuous background location session.
    private let renewalManager = CLLocationManager()
    private var renewalTimer: Timer?
    private static let placesKey = "xdial.location-scenarios.places"
    private static let enabledKey = "xdial.location-scenarios.enabled"
    private static let defaults: UserDefaults = {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-XDialUITestingLocation") {
            let suite = "xdial.ui-tests.location"
            let store = UserDefaults(suiteName: suite)!
            store.removePersistentDomain(forName: suite)
            return store
        }
        #endif
        return .standard
    }()
    @Published private(set) var enabled = defaults.bool(forKey: enabledKey)
    @Published private(set) var places = (defaults.data(forKey: placesKey)
        .flatMap { try? JSONDecoder().decode([ScenarioPlace].self, from: $0) }) ?? []
    @Published private(set) var saving: String?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var precise = true
    @Published private(set) var failed = false
    private(set) var match: ScenarioAutoPolicy.PlaceMatch?
    private weak var app: AppState?
    private var subscriptions: Set<AnyCancellable> = []
    private var tracking = false
    private var requestedSpeedAuthorization = false
    private var saveTimeout: Task<Void, Never>?

    func attach(_ app: AppState) {
        guard self.app == nil else { return }
        self.app = app
        authorization = manager.authorizationStatus
        precise = manager.accuracyAuthorization == .fullAccuracy
        manager.delegate = self
        renewalManager.delegate = self
        renewalManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 50
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        app.engine.statusPublisher.combineLatest(app.$profile, app.$dataUseNoticeAccepted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reconcile() }
            .store(in: &subscriptions)
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        Self.defaults.set(on, forKey: Self.enabledKey)
        if !on { saving = nil }
        if on && manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        reconcile()
    }

    func saveHere(for id: String) {
        cancelSave()
        saving = id
        failed = false
        saveTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.saving == id else { return }
            self.failed = true
            self.cancelSave()
        }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        reconcile()
        if tracking, let last = manager.location { accept(last) }
    }

    func cancelSave() {
        saveTimeout?.cancel()
        saveTimeout = nil
        saving = nil
        reconcile()
    }

    func remove(_ id: String) {
        places.removeAll { $0.scenarioID == id }
        persist()
        if match?.scenarioID == id { publish(nil) }
        reconcile()
    }

    private func persist() {
        Self.defaults.set(try? JSONEncoder().encode(places), forKey: Self.placesKey)
    }

    private var eligiblePlaces: [ScenarioPlace] {
        guard let app else { return [] }
        let ids = Set(app.profile.scenarios.map(\.id))
        return places.filter { ids.contains($0.scenarioID) }
    }

    private var shouldMonitor: Bool {
        enabled && app?.dataUseNoticeAccepted == true && Self.keepsMonitoring(status: app?.engine.status ?? "", alreadyTracking: tracking)
            && ScenarioAutoPilot.isAutoEnabled && !eligiblePlaces.isEmpty
    }

    static func keepsMonitoring(status: String, alreadyTracking: Bool) -> Bool {
        status == "connected" || status == "action-required"
            || (alreadyTracking && status == "reconnecting")
    }

    func reconcile() {
        let speedEnabled = app?.dataUseNoticeAccepted == true
            && ConnectionActivityController.isEnabledByUser
            && UserDefaults.standard.bool(forKey: ConnectionActivityController.backgroundSpeedKey)
        if speedEnabled, manager.authorizationStatus == .notDetermined {
            if !requestedSpeedAuthorization, UIApplication.shared.applicationState == .active {
                requestedSpeedAuthorization = true
                manager.requestWhenInUseAuthorization()
            }
        } else {
            requestedSpeedAuthorization = false
        }
        let authorized = authorization == .authorizedWhenInUse || authorization == .authorizedAlways
        if authorization == .denied || authorization == .restricted || (authorized && !precise) { saving = nil }
        let monitor = shouldMonitor && authorized && precise
        let status = app?.engine.status
        let backgroundSpeed = speedEnabled && authorized
            && (status == "connected" || (tracking && status == "reconnecting"))
        let background = monitor || backgroundSpeed
        let want = background || (saving != nil && authorized)
        if !monitor || !eligiblePlaces.contains(where: { $0.scenarioID == match?.scenarioID }) { publish(nil) }
        manager.allowsBackgroundLocationUpdates = background
        manager.desiredAccuracy = monitor || saving != nil ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyKilometer
        if want && !tracking && UIApplication.shared.applicationState == .active {
            tracking = true
            manager.startUpdatingLocation()
        } else if !want && tracking {
            manager.stopUpdatingLocation()
            tracking = false
        }
        if tracking && monitor && renewalTimer == nil {
            renewalTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.shouldMonitor, self.precise else { return }
                    self.renewalManager.requestLocation()
                }
            }
        } else if !monitor && renewalTimer != nil {
            renewalTimer?.invalidate()
            renewalTimer = nil
            renewalManager.stopUpdatingLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            authorization = self.manager.authorizationStatus
            precise = self.manager.accuracyAuthorization == .fullAccuracy
            reconcile()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in accept(last) }
    }

    private func accept(_ location: CLLocation) {
        guard tracking, (0...100).contains(location.horizontalAccuracy),
              (0...60).contains(-location.timestamp.timeIntervalSinceNow) else { return }
        if let id = saving {
            saveTimeout?.cancel()
            saving = nil
            places.removeAll { $0.scenarioID == id }
            places.append(.init(scenarioID: id, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude))
            persist()
            reconcile()
        }
        guard shouldMonitor, precise else { return }
        let id = ScenarioPlace.match(location, in: eligiblePlaces, previous: match?.scenarioID)
        // Renew only periodically; ordinary samples should not rebuild the tunnel catalog.
        if id == match?.scenarioID, let match, match.expires.timeIntervalSinceNow > 300 { return }
        publish(id.map { .init(scenarioID: $0, expires: location.timestamp.addingTimeInterval(600)) })
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            if saving != nil { saving = nil; failed = true }
            reconcile()
        }
    }

    private func publish(_ next: ScenarioAutoPolicy.PlaceMatch?) {
        guard next != match else { return }
        let needsEvaluation = next?.scenarioID != match?.scenarioID
            || (next != nil && (match?.expires ?? .distantPast) <= Date())
        match = next
        app?.updateScenarioAutoPolicy()
        if needsEvaluation { app?.refreshScenarioCatalog() }
    }
}

struct LocationScenarioSettings: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var location = LocationScenarios.shared

    var body: some View {
        Form {
            Section {
                Toggle(app.tr("按地点切换场景", "Switch scenarios by location"), isOn: Binding(
                    get: { location.enabled }, set: { location.setEnabled($0) }))
                    .accessibilityIdentifier("place-enabled")
            } footer: {
                Text(app.tr("开启自动场景并连接 VPN 后，在后台匹配已保存地点。地点优先于 Wi-Fi 和出口地区。位置仅在本机使用。后台定位可能增加耗电。",
                            "While automatic scenarios and the VPN are on, match saved places in the background. Places take priority over Wi-Fi and exit region. Location stays on this device. Background location may increase battery use."))
            }
            if location.enabled {
                if location.authorization == .denied || location.authorization == .restricted {
                    Text(app.tr("需要在系统设置中允许 XDial 使用位置。", "Allow location access for XDial in Settings."))
                } else if location.authorization != .notDetermined && !location.precise {
                    Text(app.tr("300 米地点匹配需要在系统设置中打开「精确位置」。", "Turn on Precise Location in Settings to match places within 300 metres."))
                } else {
                    Section {
                        ForEach(app.profile.scenarios, id: \.id) { scenario in
                            VStack(alignment: .leading) {
                                Text(scenario.name)
                                if location.places.contains(where: { $0.scenarioID == scenario.id }) {
                                    Button(app.tr("移除地点", "Remove place"), role: .destructive) { location.remove(scenario.id) }
                                        .accessibilityIdentifier("remove-place-" + scenario.id)
                                } else {
                                    Button(app.tr("使用当前位置", "Use current location")) { location.saveHere(for: scenario.id) }
                                        .accessibilityIdentifier("save-place-" + scenario.id)
                                        .disabled(location.saving != nil)
                                }
                            }
                        }
                        if location.saving != nil {
                            ProgressView(app.tr("正在获取精确位置…", "Waiting for an accurate location…"))
                            Button(app.tr("取消", "Cancel")) { location.cancelSave() }
                        }
                        if location.failed { Text(app.tr("未能获取精确位置，请检查系统定位和精确位置设置后重试。", "Check Location Services and Precise Location, then try again.")) }
                    } footer: {
                        Text(app.tr("每个场景可登记一个地点，半径 300 米。", "Save one place per scenario, with a radius of 300 metres."))
                    }
                }
            }
        }
        .navigationTitle(app.tr("地点场景", "Location scenarios"))
        .onDisappear { location.cancelSave() }
    }
}
