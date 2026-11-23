import Foundation
import Libbox

/// A message from the setup engine in both languages; never contains secrets.
struct CloudHostMessage: Decodable, Equatable, Sendable, Error {
    let code: String
    let message: String
    let messageEN: String

    enum CodingKeys: String, CodingKey {
        case code, message
        case messageEN = "message_en"
    }

    init(code: String, message: String, messageEN: String) {
        self.code = code
        self.message = message
        self.messageEN = messageEN
    }

    func text(_ chinese: Bool) -> String { chinese ? message : messageEN }
}

struct CloudHostKey: Decodable, Equatable, Sendable {
    let fingerprint: String
    let algorithm: String
    let file: String?
}

struct CloudHostReport: Decodable, Equatable, Sendable {
    struct Existing: Decodable, Equatable, Sendable {
        let port: Int
        let method: String
        let active: Bool
    }

    let hostKey: CloudHostKey
    let system: String
    let architecture: String
    let privilege: String
    let singBoxVersion: String?
    let existing: Existing?
    let ufwActive: Bool
    let suggestedPort: Int
    let blocking: [CloudHostMessage]
    let notes: [CloudHostMessage]

    enum CodingKeys: String, CodingKey {
        case system, architecture, privilege, existing, blocking, notes
        case hostKey = "host_key"
        case singBoxVersion = "sing_box_version"
        case ufwActive = "ufw_active"
        case suggestedPort = "suggested_port"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostKey = try c.decode(CloudHostKey.self, forKey: .hostKey)
        system = try c.decodeIfPresent(String.self, forKey: .system) ?? ""
        architecture = try c.decodeIfPresent(String.self, forKey: .architecture) ?? ""
        privilege = try c.decodeIfPresent(String.self, forKey: .privilege) ?? ""
        singBoxVersion = try c.decodeIfPresent(String.self, forKey: .singBoxVersion)
        existing = try c.decodeIfPresent(Existing.self, forKey: .existing)
        ufwActive = try c.decodeIfPresent(Bool.self, forKey: .ufwActive) ?? false
        suggestedPort = try c.decodeIfPresent(Int.self, forKey: .suggestedPort) ?? 0
        blocking = try c.decodeIfPresent([CloudHostMessage].self, forKey: .blocking) ?? []
        notes = try c.decodeIfPresent([CloudHostMessage].self, forKey: .notes) ?? []
    }
}

struct CloudHostPlan: Decodable, Equatable, Sendable {
    struct Step: Decodable, Equatable, Sendable, Identifiable {
        let id: String
        let title: String
        let titleEN: String
        let detail: String?

        enum CodingKeys: String, CodingKey {
            case id, title, detail
            case titleEN = "title_en"
        }

        func text(_ chinese: Bool) -> String { chinese ? title : titleEN }
    }

    let port: Int
    let method: String
    let reuse: Bool
    let steps: [Step]

    init(from decoder: Decoder) throws {
        enum Keys: String, CodingKey { case port, method, reuse, steps }
        let c = try decoder.container(keyedBy: Keys.self)
        port = try c.decode(Int.self, forKey: .port)
        method = try c.decode(String.self, forKey: .method)
        reuse = try c.decodeIfPresent(Bool.self, forKey: .reuse) ?? false
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
    }
}

/// The proxy that setup created or found. `password` is the Shadowsocks key the
/// line keeps; it is saved only through the app's existing credential storage.
struct CloudHostResult: Decodable, Equatable, Sendable {
    let server: String
    let port: Int
    let method: String
    let password: String
    let reused: Bool
}

struct CloudHostMeasurement: Decodable, Equatable, Sendable {
    let latencyMS: Int
    let exitIP: String?
    let downloadBytes: Int64
    let downloadMS: Int64
    let mbps: Double

    enum CodingKeys: String, CodingKey {
        case mbps
        case latencyMS = "latency_ms"
        case exitIP = "exit_ip"
        case downloadBytes = "download_bytes"
        case downloadMS = "download_ms"
    }
}

struct CloudHostEvent: Decodable, Equatable, Sendable {
    let step: String
    let status: String
    let message: String?
}

/// What the app saves as a new line once the proxy is verified.
struct CloudHostLineDraft: Equatable, Sendable {
    var name: String
    let server: String
    let port: Int
    let method: String
    let password: String
}

private struct CloudHostReply<Payload: Decodable>: Decodable {
    let ok: Bool
    let data: Payload?
    let error: CloudHostMessage?
}

/// Owns the Go-side session. Calls block, so they run off the main actor;
/// the Go object serializes its own state.
private final class CloudHostBackend: @unchecked Sendable {
    private let setup: LibboxCloudHostSetup? = LibboxNewCloudHostSetup()

    func call<Payload: Decodable>(_ type: Payload.Type, _ body: @escaping @Sendable (LibboxCloudHostSetup) -> String) async -> Result<Payload, CloudHostMessage> {
        guard let setup else { return .failure(CloudHostSetupModel.unavailable) }
        let raw = await Task.detached(priority: .userInitiated) { body(setup) }.value
        return Self.decode(type, raw)
    }

    static func decode<Payload: Decodable>(_ type: Payload.Type, _ raw: String) -> Result<Payload, CloudHostMessage> {
        guard let reply = try? JSONDecoder().decode(CloudHostReply<Payload>.self, from: Data(raw.utf8)) else {
            return .failure(CloudHostSetupModel.unavailable)
        }
        if reply.ok, let data = reply.data { return .success(data) }
        return .failure(reply.error ?? CloudHostSetupModel.unavailable)
    }

    func cancel() { setup?.cancel() }
    func close() { setup?.close() }
}

private final class CloudHostEventSink: NSObject, LibboxCloudHostListenerProtocol, @unchecked Sendable {
    let deliver: @Sendable (CloudHostEvent) -> Void

    init(deliver: @escaping @Sendable (CloudHostEvent) -> Void) { self.deliver = deliver }

    func onEvent(_ eventJSON: String?) {
        guard let eventJSON, let event = try? JSONDecoder().decode(CloudHostEvent.self, from: Data(eventJSON.utf8)) else { return }
        deliver(event)
    }
}

/// "Add my server": confirm the host key, inspect read-only, review the
/// changes, deploy, then test HTTPS and speed through the new proxy before the
/// line can be saved. The user's current connection is never touched.
@MainActor
final class CloudHostSetupModel: ObservableObject {
    enum Authentication: String, CaseIterable, Identifiable {
        case password, privateKey
        var id: String { rawValue }
    }

    enum Stage: Equatable {
        case server
        case scanning
        case confirmKey(CloudHostKey)
        case inspecting
        case review(CloudHostReport)
        case deploying
        case verifying(CloudHostResult)
        case verified(CloudHostResult, CloudHostMeasurement)
        case unverified(CloudHostResult, CloudHostMessage)
        case saved
    }

    nonisolated static let unavailable = CloudHostMessage(code: "unavailable", message: "暂时无法完成，请重试", messageEN: "This could not be completed; try again")

    @Published var host = ""
    @Published var sshPort = "22"
    @Published var user = "root"
    @Published var authentication: Authentication = .password
    @Published var password = ""
    @Published var privateKey = ""
    @Published var passphrase = ""
    /// Editing the port invalidates the plan built for the old one, so the
    /// deploy button can never apply a plan the user is no longer looking at.
    @Published var proxyPort = "" {
        didSet {
            if proxyPort != oldValue { invalidatePlan() }
        }
    }
    @Published var lineName = ""

    @Published private(set) var stage: Stage = .server
    @Published private(set) var error: CloudHostMessage?
    @Published private(set) var plan: CloudHostPlan?
    @Published private(set) var planError: CloudHostMessage?
    @Published private(set) var planning = false
    @Published private(set) var events: [CloudHostEvent] = []
    @Published private(set) var working = false

    private let backend = CloudHostBackend()
    private var confirmedKey: CloudHostKey?
    private var planGeneration = 0

    private func invalidatePlan() {
        planGeneration += 1
        planning = false
        plan = nil
        planError = nil
    }

    /// Only a current plan for exactly the port in the field can be deployed.
    var canDeploy: Bool {
        guard let plan, !working, !planning, case .review = stage else { return false }
        return Int(proxyPort) == plan.port
    }

    var canScan: Bool {
        !working && !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !user.trimmingCharacters(in: .whitespaces).isEmpty
            && Int(sshPort).map { (1...65535).contains($0) } == true
            && (authentication == .password ? !password.isEmpty : !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func targetJSON(fingerprint: String?) -> String {
        var target: [String: Any] = [
            "host": host.trimmingCharacters(in: .whitespacesAndNewlines),
            "port": Int(sshPort) ?? 22,
            "user": user.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        switch authentication {
        case .password:
            target["password"] = password
        case .privateKey:
            target["private_key"] = privateKey
            if !passphrase.isEmpty { target["passphrase"] = passphrase }
            // sudo may still need the login password on accounts with one.
            if !password.isEmpty { target["password"] = password }
        }
        if let fingerprint { target["host_key_fingerprint"] = fingerprint }
        let data = (try? JSONSerialization.data(withJSONObject: target)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    func scanHostKey() async {
        guard canScan else { return }
        working = true
        error = nil
        stage = .scanning
        let request = targetJSON(fingerprint: nil)
        let result = await backend.call(CloudHostKey.self) { $0.scanHostKey(request) }
        working = false
        switch result {
        case .success(let key): stage = .confirmKey(key)
        case .failure(let message):
            error = message
            stage = .server
        }
    }

    /// Signs in only with the fingerprint the user just confirmed.
    func confirmHostKey(_ key: CloudHostKey) async {
        confirmedKey = key
        working = true
        error = nil
        stage = .inspecting
        let request = targetJSON(fingerprint: key.fingerprint)
        let result = await backend.call(CloudHostReport.self) { $0.connectAndInspect(request) }
        working = false
        switch result {
        case .success(let report):
            // A new inspection supersedes any plan built from the previous one.
            invalidatePlan()
            proxyPort = String(report.suggestedPort)
            stage = .review(report)
            if report.blocking.isEmpty { await refreshPlan() }
        case .failure(let message):
            error = message
            stage = message.code == "host_key_changed" ? .server : .confirmKey(key)
        }
    }

    func refreshPlan() async {
        planGeneration += 1
        let generation = planGeneration
        guard let port = Int(proxyPort), (1024...65535).contains(port) else {
            plan = nil
            planning = false
            planError = CloudHostMessage(code: "port_invalid", message: "请填写 1024–65535 之间的端口", messageEN: "Enter a port between 1024 and 65535")
            return
        }
        planning = true
        let result = await backend.call(CloudHostPlan.self) { $0.plan(port) }
        // A newer edit or refresh owns the plan now; drop this stale answer.
        guard generation == planGeneration else { return }
        planning = false
        switch result {
        case .success(let value):
            plan = value
            planError = nil
        case .failure(let message):
            plan = nil
            planError = message
        }
    }

    func deploy() async {
        guard canDeploy, let plan else { return }
        working = true
        error = nil
        events = []
        stage = .deploying
        let sink = CloudHostEventSink { [weak self] event in
            Task { @MainActor in self?.events.append(event) }
        }
        let port = plan.port
        let result = await backend.call(CloudHostResult.self) { $0.deploy(port, listener: sink) }
        working = false
        switch result {
        case .success(let deployed):
            if lineName.isEmpty { lineName = defaultLineName }
            await verify(deployed)
        case .failure(let message):
            error = message
            // The engine already rolled back; inspect again so the review is current.
            if let confirmedKey { await confirmHostKey(confirmedKey) }
            error = message
        }
    }

    /// One row per step, showing its latest status, in the order steps started.
    var stepProgress: [CloudHostEvent] {
        var order: [String] = []
        var latest: [String: CloudHostEvent] = [:]
        for event in events {
            if latest[event.step] == nil { order.append(event.step) }
            latest[event.step] = event
        }
        return order.compactMap { latest[$0] }
    }

    func cancel() { backend.cancel() }

    /// Tests the proxy with real HTTPS requests through it; only then can it be saved.
    func verify(_ deployed: CloudHostResult) async {
        working = true
        stage = .verifying(deployed)
        let line: [String: Any] = [
            "id": "cloud-host-check", "name": "check", "type": "shadowsocks", "enabled": true,
            "ss_server": deployed.server, "ss_port": deployed.port, "ss_method": deployed.method, "ss_password": deployed.password,
        ]
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: line)) ?? Data(), as: UTF8.self)
        let raw = await Task.detached(priority: .userInitiated) { LibboxProbeStandaloneLineThroughput(json, 40000) }.value
        working = false
        switch CloudHostBackend.decode(CloudHostMeasurement.self, raw) {
        case .success(let measurement): stage = .verified(deployed, measurement)
        case .failure(let message): stage = .unverified(deployed, message)
        }
    }

    /// Set by the host to match the app language.
    var lineNamePrefix = "云主机"

    var defaultLineName: String {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? lineNamePrefix : lineNamePrefix + " · " + name
    }

    func draft() -> CloudHostLineDraft? {
        guard case .verified(let deployed, _) = stage else { return nil }
        let name = lineName.trimmingCharacters(in: .whitespacesAndNewlines)
        return CloudHostLineDraft(name: name.isEmpty ? defaultLineName : name, server: deployed.server,
                                  port: deployed.port, method: deployed.method, password: deployed.password)
    }

    func markSaved() {
        stage = .saved
        forgetCredentials()
    }

    func back() {
        error = nil
        stage = .server
    }

    /// Ends the session and clears everything typed for it.
    func close() {
        backend.cancel()
        backend.close()
        forgetCredentials()
    }

    private func forgetCredentials() {
        password = ""
        privateKey = ""
        passphrase = ""
        backend.close()
    }

    #if DEBUG
    /// Synthetic states for offscreen layout previews; never used by the app flow.
    func preview(stage: Stage, plan: CloudHostPlan? = nil, events: [CloudHostEvent] = []) {
        self.stage = stage
        self.plan = plan
        self.events = events
    }

    static func previewDecode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // swiftlint:disable:next force_try
        try! JSONDecoder().decode(type, from: Data(json.utf8))
    }
    #endif
}
