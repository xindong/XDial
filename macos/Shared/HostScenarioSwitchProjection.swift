enum ScenarioSwitchCancellationReason: String {
    case superseded, userCancelled, disconnected, sleep, timeout
    case automaticModeChanged, wifiSettling, scenarioMatchChanged, unmatchedWiFi, underlayChanged, recovery
}

/// Separate host-side Switch fact projection. It deliberately does not replace
/// the authoritative committed ConnectionReport while a candidate is pending
/// or when that candidate fails.
struct HostScenarioSwitchProjection: Equatable {
    let status: String
    let fromScenarioID: String
    let toScenarioID: String
    let sourceCommittedTransactionID: String
    let candidateTransactionID: String
    let activeCommittedTransactionID: String
    let inFlight: Bool
    /// Credential-free task state for the candidate generation. It is a
    /// presentation sidecar, never the committed runtime fact.
    let candidateReport: ConnectionReport
    /// Public Line IDs only. Opaque runtime identities never leave Provider
    /// memory or enter this host/Debug projection.
    let reusedLineIDs: [String]
    let code: String?
    let message: String?

    static func failureStatus(code: String, cancellationRequested: Bool, timedOut: Bool) -> String {
        if timedOut { return "timed-out" }
        if cancellationRequested && code == "switch-cancelled" { return "cancelled" }
        return "failed"
    }

    /// Called only after the host has validated the Provider's committed report.
    static func committed(
        sourceReport: ConnectionReport,
        report: ConnectionReport
    ) -> HostScenarioSwitchProjection {
        HostScenarioSwitchProjection(
            status: "committed",
            fromScenarioID: sourceReport.scenario.id,
            toScenarioID: report.scenario.id,
            sourceCommittedTransactionID: sourceReport.transactionID,
            candidateTransactionID: report.transactionID,
            activeCommittedTransactionID: report.transactionID,
            inFlight: false,
            candidateReport: report,
            reusedLineIDs:
                ConnectionReportRuntimeFacts.reusedLineIDs(report: report),
            code: nil,
            message: nil
        )
    }
}
