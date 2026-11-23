import Foundation

/// One bounded, redacted record of what a connection did and how long each step
/// took. The app and tunnel extension publish separate atomic snapshots so a
/// single exported report shows both sides under one session ID.
///
/// Never record passwords, tokens, cookies, private keys, server addresses, full
/// configuration or browsing history here. Callers pass stable stage codes and
/// short, already-safe details; `ConnectionTimeline.sanitized` is a backstop.
enum ConnectionTimeline {
    static let maxSessions = 6
    static let maxEventsPerSession = 120
    static let maxFileBytes = 256 * 1024
    static let maxDetailCharacters = 160
    static let fileName = "connection-timeline.json"

    enum StartOrigin: String {
        case user, appIntent, autoRetry, configurationChange, scenarioChange, system, launch
    }

    enum Source: String, Codable, Sendable {
        case app
        case tunnel
    }

    /// Stable outcome codes shared by every check so reports can be compared.
    enum Result: String, Codable, Sendable {
        case ok
        case timeout
        case dns
        case connect
        case tls
        case http
        case cancelled
        case notRun = "not-run"
        case inconclusive
        case failed
    }

    struct Event: Codable, Equatable, Sendable {
        /// Wall-clock milliseconds since 1970; comparable across the two processes.
        var t: Int64
        var src: Source
        /// Stable code such as `app.connect.requested` or `tunnel.engine_started`.
        var stage: String
        var result: Result?
        /// Duration of the step this event closes, in milliseconds.
        var ms: Int?
        var detail: String?
        var occurrences: Int?
        var lastAt: Int64?
    }

    struct Session: Codable, Equatable, Sendable {
        var id: String
        var startedAt: Int64
        var events: [Event]
        var droppedEvents: Int
        var startOrigin: String?
        var connectedAt: Int64?
        var systemConnectedAt: Int64?
        var stopRequestedAt: Int64?
        var stopReason: Event?
        var runtimeDisconnect: Event?

        mutating func record(_ event: Event) {
            if event.stage == "app.connection_established" { systemConnectedAt = event.t }
            if event.stage == "app.stop_requested" { stopRequestedAt = event.t }
            if event.stage == "tunnel.runtime_disconnected" { runtimeDisconnect = event }
            if event.stage == "tunnel.stop_reason" { stopReason = event }
            if event.occurrences != nil,
               let index = events.lastIndex(where: {
                   $0.stage == event.stage && $0.t == event.t && $0.detail == event.detail && $0.result == event.result
               }) {
                events[index] = event
                return
            }
            if events.count >= maxEventsPerSession {
                // Preserve startup and rotate the remaining slots for the latest evidence.
                events.remove(at: maxEventsPerSession / 4)
                droppedEvents += 1
            }
            events.append(event)
        }
    }

    struct File: Codable, Equatable, Sendable {
        var version = 1
        /// Session the tunnel extension is currently running, if any. The app
        /// attaches to it when the system started the tunnel on its own.
        var activeSessionID: String?
        var sessions: [Session] = []

        /// Reconcile only the exported copy with a fresh system status. The
        /// extension owns the persisted marker and may be starting concurrently.
        func reportingDisconnected() -> File {
            var report = self
            report.activeSessionID = nil
            return report
        }
    }

    static func nowMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1000).rounded())
    }

    static func elapsedMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int(((ProcessInfo.processInfo.systemUptime - start) * 1000).rounded()))
    }

    /// Backstop redaction: one line, bounded, no URL credentials, no long
    /// token-like runs. It does not make arbitrary text safe to log.
    static func sanitized(_ text: String?) -> String? {
        guard var value = text?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        value = value.replacingOccurrences(
            of: #"://[^/\s@]+@"#, with: "://<redacted>@", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"(?i)(password|passwd|token|secret|cookie|authorization|auth[_-]?key|private[_-]?key)\s*[:=]\s*\S+"#,
            with: "$1=<redacted>", options: .regularExpression)
        value = value.replacingOccurrences(
            of: #"[A-Za-z0-9+/_=-]{32,}"#, with: "<redacted>", options: .regularExpression)
        // Addresses can identify a server even after its configured name was
        // removed; timeline details never need them.
        value = value.replacingOccurrences(
            of: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, with: "<ip>", options: .regularExpression)
        value = redactingIPv6(value)
        if value.count > maxDetailCharacters {
            value = String(value.prefix(maxDetailCharacters - 1)) + "…"
        }
        return value
    }

    /// Replaces every substring that parses as an IPv6 address (optionally in
    /// brackets or with a zone) with `<ip>`; clock times do not parse.
    static func redactingIPv6(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\[?[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%[A-Za-z0-9]+)?\]?"#) else { return text }
        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            var candidate = String(result[range])
            candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            if let zone = candidate.firstIndex(of: "%") { candidate = String(candidate[..<zone]) }
            var address = in6_addr()
            if candidate.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 {
                result.replaceSubrange(range, with: "<ip>")
            }
        }
        return result
    }

    /// Stable keywords extracted from a free-text failure. The text itself may
    /// carry server names or resolved addresses, so only these keywords are kept.
    static func failureKeywords(_ text: String?) -> String {
        guard let lower = text?.lowercased(), !lower.isEmpty else { return "none" }
        let table: [(String, String)] = [
            ("deadline exceeded", "deadline"), ("i/o timeout", "io-timeout"), ("timeout", "timeout"),
            ("超时", "timeout"), ("connection refused", "refused"), ("connection reset", "reset"),
            ("no route", "no-route"), ("network is unreachable", "unreachable"),
            ("dns-failed", "dns-failed"), ("dns-unavailable", "dns-unavailable"),
            ("dns-wrong-family", "dns-wrong-family"), ("no such host", "no-such-host"),
            ("certificate", "certificate"), ("tls", "tls"), ("handshake", "handshake"),
            ("eof", "eof"), ("request-failed", "request-failed"), ("invalid-address", "invalid-address"),
            ("service-backoff", "backoff"), ("connection is not running", "engine-stopped"),
            ("连接引擎未运行", "engine-stopped"), ("outbound is unavailable", "outbound-missing"),
            ("connection changed", "connection-changed"), ("响应无效", "bad-reply"),
            ("不可用", "unavailable"), ("cancel", "cancelled"),
        ]
        var found: [String] = []
        for (needle, keyword) in table where lower.contains(needle) && !found.contains(keyword) {
            found.append(keyword)
        }
        if let range = lower.range(of: #"status (\d{3})"#, options: .regularExpression) {
            found.append("http-" + lower[range].suffix(3))
        }
        return found.isEmpty ? "other" : found.joined(separator: ",")
    }

    /// Maps a URLSession error onto the shared outcome codes.
    static func classify(_ error: Error) -> Result {
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return .failed }
        switch nsError.code {
        case NSURLErrorCancelled:
            return .cancelled
        case NSURLErrorTimedOut:
            return .timeout
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return .dns
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .tls
        case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
             NSURLErrorDataNotAllowed, NSURLErrorCannotLoadFromNetwork:
            return .connect
        case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource,
             NSURLErrorCannotParseResponse:
            return .http
        default:
            return .failed
        }
    }

    /// Classifies the free-text failure the extension returns for an outbound
    /// probe. The core reports stable codes inside that text where it can.
    static func classify(probeFailure text: String?) -> Result {
        guard let text = text?.lowercased(), !text.isEmpty else { return .failed }
        if text.contains("timeout") || text.contains("deadline") || text.contains("超时") { return .timeout }
        if text.contains("dns") || text.contains("resolv") || text.contains("lookup") { return .dns }
        if text.contains("tls") || text.contains("certificate") || text.contains("handshake") { return .tls }
        if text.contains("http") || text.contains("status") { return .http }
        if text.contains("refused") || text.contains("unreachable") || text.contains("reset")
            || text.contains("dial") || text.contains("connect") { return .connect }
        if text.contains("cancel") || text.contains("取消") { return .cancelled }
        return .failed
    }
}

/// Each process owns one snapshot. A suspended app never holds a filesystem
/// lock needed by the extension. Serialize all store instances in this process.
final class ConnectionTimelineStore: @unchecked Sendable {
    private let directory: URL
    private let writer: ConnectionTimeline.Source
    private static let queue = DispatchQueue(label: "com.kafeifei.xdial.connection-timeline", qos: .utility)

    // Only the extension produces survey events. All state below belongs to queue.
    private var surveySession = ""
    private var survey: ConnectionTimeline.Event?
    private var surveyDirty = false
    private var checkpoint: DispatchWorkItem?

    init(directory: URL, writer: ConnectionTimeline.Source) {
        self.directory = directory
        self.writer = writer
    }

    private func url(for source: ConnectionTimeline.Source) -> URL {
        // The extension inherits the original history and active-session marker.
        // After upgrade the app only reads this atomically replaced snapshot.
        directory.appendingPathComponent(source == .tunnel ? ConnectionTimeline.fileName : "connection-timeline-app.json")
    }

    static func shared(appGroup: String, writer: ConnectionTimeline.Source) -> ConnectionTimelineStore? {
        guard let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Diagnostics", isDirectory: true) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ConnectionTimelineStore(directory: directory, writer: writer)
    }

    /// Starts (or reuses) a session and makes it the active tunnel session when
    /// `markActive` is true.
    func beginSession(_ id: String, markActive: Bool, origin: ConnectionTimeline.StartOrigin? = nil) {
        let now = ConnectionTimeline.nowMilliseconds()
        Self.queue.async { [self] in
            finishSurvey()
            mutate { file in
                if !file.sessions.contains(where: { $0.id == id }) {
                    file.sessions.append(ConnectionTimeline.Session(
                        id: id, startedAt: now, events: [], droppedEvents: 0))
                }
                if let origin, let index = file.sessions.firstIndex(where: { $0.id == id }) {
                    file.sessions[index].startOrigin = origin.rawValue
                }
                if markActive { file.activeSessionID = id }
            }
        }
    }

    func endActiveSession(_ id: String, completion: @escaping @Sendable () -> Void = {}) {
        Self.queue.async { [self] in
            finishSurvey()
            mutate { file in
                if file.activeSessionID == id { file.activeSessionID = nil }
            }
            completion()
        }
    }

    func append(
        session id: String,
        preferActiveSession: Bool = false,
        source: ConnectionTimeline.Source,
        stage: String,
        result: ConnectionTimeline.Result? = nil,
        ms: Int? = nil,
        detail: String? = nil,
        at timestamp: Int64? = nil
    ) {
        let event = ConnectionTimeline.Event(
            t: timestamp ?? ConnectionTimeline.nowMilliseconds(), src: source, stage: stage,
            result: result, ms: ms, detail: ConnectionTimeline.sanitized(detail))
        Self.queue.async { [self] in
            if event.stage == "tunnel.scenario_decision", !preferActiveSession {
                if var previous = survey, id == surveySession,
                   previous.detail == event.detail, previous.result == event.result {
                    previous.occurrences = (previous.occurrences ?? 1) + 1
                    previous.lastAt = event.t
                    previous.ms = event.ms
                    survey = previous
                    surveyDirty = true
                    if checkpoint == nil {
                        let item = DispatchWorkItem { [weak self] in self?.persistSurvey() }
                        checkpoint = item
                        Self.queue.asyncAfter(deadline: .now() + 60, execute: item)
                    }
                    return
                }
                finishSurvey()
                surveySession = id
                survey = event
            } else {
                finishSurvey()
            }
            persist(event, session: id, preferActiveSession: preferActiveSession)
        }
    }

    private func persistSurvey() {
        checkpoint?.cancel()
        checkpoint = nil
        if surveyDirty, let survey {
            persist(survey, session: surveySession)
            surveyDirty = false
        }
    }

    private func finishSurvey() {
        persistSurvey()
        survey = nil
    }

    private func persist(_ event: ConnectionTimeline.Event, session id: String, preferActiveSession: Bool = false) {
        mutate { file in
            let activeID = preferActiveSession ? (writer == .tunnel ? file.activeSessionID : read(.tunnel).activeSessionID) : nil
            let id = activeID ?? id
            guard !id.isEmpty else { return }
            if let index = file.sessions.firstIndex(where: { $0.id == id }) {
                file.sessions[index].record(event)
            } else {
                var session = ConnectionTimeline.Session(id: id, startedAt: event.t, events: [], droppedEvents: 0)
                session.record(event)
                file.sessions.append(session)
            }
        }
    }

    // Publish the intent before changing VPN preferences: the extension can be
    // stopped by iOS as soon as the preferences change.
    func recordAppStopRequest(fallbackSession id: String) {
        let event = ConnectionTimeline.Event(t: ConnectionTimeline.nowMilliseconds(), src: .app,
                                             stage: "app.stop_requested")
        Self.queue.sync { persist(event, session: id, preferActiveSession: true) }
    }

    func appRequestedStop(session id: String) -> Bool {
        Self.queue.sync { read(.app).sessions.first { $0.id == id }?.stopRequestedAt != nil }
    }

    /// Wait for queued writes before returning a startup failure to the system.
    func flush() {
        Self.queue.sync {}
    }

    func snapshot() -> ConnectionTimeline.File {
        Self.queue.sync { mergedSnapshot() }
    }

    /// UI callers suspend instead of blocking the main actor on disk IO.
    func loadSnapshot() async -> ConnectionTimeline.File {
        await withCheckedContinuation { continuation in
            Self.queue.async { [self] in
                continuation.resume(returning: mergedSnapshot())
            }
        }
    }

    // MARK: - File access (on `queue`)

    private func mutate(_ change: (inout ConnectionTimeline.File) -> Void) {
        var file = read(writer)
        change(&file)
        Self.enforceLimits(&file)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url(for: writer), options: .atomic)
    }

    private func mergedSnapshot() -> ConnectionTimeline.File {
        var report = read(.tunnel)
        for app in read(.app).sessions {
            guard let index = report.sessions.firstIndex(where: { $0.id == app.id }) else {
                report.sessions.append(app)
                continue
            }
            var session = report.sessions[index]
            session.startedAt = min(session.startedAt, app.startedAt)
            session.startOrigin = app.startOrigin ?? session.startOrigin
            session.systemConnectedAt = app.systemConnectedAt ?? session.systemConnectedAt
            session.stopRequestedAt = app.stopRequestedAt ?? session.stopRequestedAt
            session.events = app.events + session.events
            session.events.sort { $0.t < $1.t }
            let excess = max(0, session.events.count - ConnectionTimeline.maxEventsPerSession)
            let keepStart = ConnectionTimeline.maxEventsPerSession / 4
            if excess > 0 { session.events.removeSubrange(keepStart..<(keepStart + excess)) }
            session.droppedEvents += app.droppedEvents + excess
            report.sessions[index] = session
        }
        Self.enforceLimits(&report)
        return report
    }

    static func enforceLimits(_ file: inout ConnectionTimeline.File) {
        file.sessions.sort { $0.startedAt < $1.startedAt }
        while file.sessions.count > ConnectionTimeline.maxSessions {
            let removed = file.sessions.removeFirst()
            if file.activeSessionID == removed.id { file.activeSessionID = nil }
        }
        while let data = try? JSONEncoder().encode(file),
              data.count > ConnectionTimeline.maxFileBytes, file.sessions.count > 1 {
            let removed = file.sessions.removeFirst()
            if file.activeSessionID == removed.id { file.activeSessionID = nil }
        }
    }

    private func read(_ source: ConnectionTimeline.Source) -> ConnectionTimeline.File {
        guard let data = try? Data(contentsOf: url(for: source)),
              data.count <= ConnectionTimeline.maxFileBytes * 2,
              let file = try? JSONDecoder().decode(ConnectionTimeline.File.self, from: data),
              file.version == 1 else {
            return ConnectionTimeline.File()
        }
        return file
    }
}

/// Plain-text rendering for the shareable diagnostics report. Times are relative
/// to the session start so the two processes line up without exposing clocks.
enum ConnectionTimelineReport {
    /// Keep the previous ending and current start together even when either trace is full.
    static func reconnectSummary(_ file: ConnectionTimeline.File, isChinese: Bool) -> String? {
        let sessions = file.sessions.sorted { $0.startedAt > $1.startedAt }
        guard let latest = sessions.first else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        func time(_ ms: Int64) -> String {
            formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
        }
        var lines: [String] = []
        func ending(_ session: ConnectionTimeline.Session, previous: Bool) {
            let label = previous ? (isChinese ? "上次连接" : "Previous session") : (isChinese ? "本次连接" : "Latest session")
            if let t = session.stopRequestedAt ?? session.events.last(where: { $0.stage == "app.stop_requested" })?.t {
                lines.append("\(label) · \(time(t)) · " + (isChinese ? "App 请求断开" : "App requested stop"))
            }
            if let event = session.runtimeDisconnect ?? session.events.last(where: { $0.stage == "tunnel.runtime_disconnected" }) {
                lines.append("\(label) · \(time(event.t)) · " + (isChinese ? "引擎断开" : "Engine disconnected")
                             + (event.detail.map { " " + $0 } ?? ""))
            }
            if let event = session.stopReason ?? session.events.last(where: { $0.stage == "tunnel.stop_reason" }) {
                lines.append("\(label) · \(time(event.t)) · " + (isChinese ? "系统停止原因 " : "System stop reason ") + (event.detail ?? "?"))
            } else if session.id != file.activeSessionID {
                let last = session.events.map { $0.lastAt ?? $0.t }.max() ?? session.startedAt
                lines.append("\(label) · " + (isChinese ? "最后记录 " : "Last record ") + time(last)
                             + (isChinese ? " · 停止原因未知" : " · stop reason unknown"))
            }
        }
        if sessions.count > 1 { ending(sessions[1], previous: true) }
        let origin: String
        switch latest.startOrigin.flatMap(ConnectionTimeline.StartOrigin.init(rawValue:)) {
        case .user: origin = isChinese ? "用户连接" : "User connect"
        case .appIntent: origin = "App Intent"
        case .autoRetry: origin = isChinese ? "App 自动重试" : "App automatic retry"
        case .configurationChange: origin = isChinese ? "应用配置后重连" : "Reconnect after configuration change"
        case .scenarioChange: origin = isChinese ? "切换场景后重连" : "Reconnect after scenario change"
        case .system: origin = isChinese ? "系统启动" : "System start"
        case .launch: origin = isChinese ? "打开 App 时自动连接" : "Connect on open"
        case nil: origin = isChinese ? "来源未知" : "Unknown origin"
        }
        lines.append((isChinese ? "本次启动" : "Latest start") + " · \(time(latest.startedAt)) · \(origin)")
        if let connected = latest.systemConnectedAt ?? latest.events.first(where: { $0.stage == "app.connection_established" })?.t {
            lines.append((isChinese ? "已连接" : "Connected") + " · " + time(connected))
        }
        ending(latest, previous: false)
        return lines.joined(separator: "\n")
    }

    static func render(
        _ file: ConnectionTimeline.File,
        latest count: Int = 3,
        isChinese: Bool
    ) -> String {
        let sessions = file.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(count)
        guard !sessions.isEmpty else {
            return isChinese ? "（还没有连接记录）" : "(No connection recorded yet)"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines: [String] = []
        for (index, session) in sessions.enumerated() {
            let started = formatter.string(from: Date(timeIntervalSince1970: Double(session.startedAt) / 1000))
            let active = session.id == file.activeSessionID
                ? (isChinese ? " · 进行中" : " · active") : ""
            let title = isChinese ? "连接 \(index + 1)" : "Connection \(index + 1)"
            lines.append("\(title) · \(started) · \(shortID(session.id))\(active)")
            for event in session.events.sorted(by: { $0.t < $1.t }) {
                lines.append("  " + renderEvent(event, sessionStart: session.startedAt))
            }
            if session.droppedEvents > 0 {
                lines.append(isChinese
                    ? "  （另有 \(session.droppedEvents) 条事件因上限省略）"
                    : "  (\(session.droppedEvents) earlier events omitted at capacity)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func renderEvent(_ event: ConnectionTimeline.Event, sessionStart: Int64) -> String {
        let offset = Double(event.t - sessionStart) / 1000
        var parts = [String(format: "+%.1fs", offset), event.src.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0), event.stage]
        if let result = event.result { parts.append(result.rawValue) }
        if let ms = event.ms { parts.append(String(format: "%.1fs", Double(ms) / 1000)) }
        if let count = event.occurrences, let last = event.lastAt {
            parts.append(String(format: "×%d → +%.1fs", count, Double(last - sessionStart) / 1000))
        }
        if let detail = event.detail { parts.append(detail) }
        return parts.joined(separator: " ")
    }

    static func shortID(_ id: String) -> String {
        let uuid = id.hasPrefix("tunnel-") ? String(id.dropFirst("tunnel-".count)) : id
        return String(uuid.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
    }
}
