import XCTest

final class HostScenarioSwitchProjectionTests: XCTestCase {
    func testOnlyAcknowledgedCancellationsAreQuiet() {
        XCTAssertEqual(HostScenarioSwitchProjection.failureStatus(code: "switch-cancelled", cancellationRequested: true, timedOut: false), "cancelled")
        XCTAssertEqual(HostScenarioSwitchProjection.failureStatus(code: "switch-cancelled", cancellationRequested: true, timedOut: true), "timed-out")
        XCTAssertEqual(HostScenarioSwitchProjection.failureStatus(code: "switch-cancelled", cancellationRequested: false, timedOut: false), "failed")
        XCTAssertEqual(HostScenarioSwitchProjection.failureStatus(code: "switch-settings-failed", cancellationRequested: true, timedOut: false), "failed")
    }

    func testRestoredSourceCannotConfirmCancellation() {
        for timedOut in [false, true] {
            let code = ProviderScenarioSwitchReconciliation
                .sourceRestoredFailureCode(timedOut: timedOut)
            for requested in [false, true] {
                XCTAssertEqual(
                    HostScenarioSwitchProjection.failureStatus(
                        code: code, cancellationRequested: requested,
                        timedOut: timedOut
                    ),
                    timedOut ? "timed-out" : "failed"
                )
            }
        }
        XCTAssertEqual(
            ProviderScenarioSwitchRejectedError.cancelled.code,
            "switch-cancelled"
        )
    }

    func testCommittedProjectionUsesCompleteProviderReport() {
        let source = report(id: "source", scenario: "old")
        var target = report(id: "target", scenario: "new")
        target.state = .preparing
        let lastProgress = target
        target.state = .committed
        target.tasks[0].state = .ready
        target.events.append(ConnectionReportEvent(
            sequence: 1, timestamp: Date(), type: "diagnostic",
            state: "ready", taskID: "line:shared",
            code: "line-runtime-reused", message: "reused",
            facts: ["reused": true]
        ))

        // Both the direct response and reconciliation adopt this terminal
        // projection, even when the last progress poll only saw preparation.
        let projection = HostScenarioSwitchProjection.committed(
            sourceReport: source, report: target
        )

        XCTAssertEqual(projection.status, "committed")
        XCTAssertFalse(projection.inFlight)
        XCTAssertEqual(projection.fromScenarioID, "old")
        XCTAssertEqual(projection.toScenarioID, "new")
        XCTAssertEqual(projection.sourceCommittedTransactionID, "source")
        XCTAssertEqual(projection.candidateTransactionID, "target")
        XCTAssertEqual(projection.activeCommittedTransactionID, "target")
        XCTAssertEqual(projection.candidateReport, target)
        XCTAssertNotEqual(projection.candidateReport, lastProgress)
        XCTAssertEqual(projection.reusedLineIDs, ["shared"])
        XCTAssertNil(projection.code)
        XCTAssertNil(projection.message)
        XCTAssertEqual(source.state, .committed)
        XCTAssertEqual(lastProgress.state, .preparing)
    }

    private func report(id: String, scenario: String) -> ConnectionReport {
        var report = ConnectionReport(
            transactionID: id,
            plan: ConnectionPlan(
                schemaVersion: 3,
                scenario: ConnectionPlanScenario(id: scenario, name: scenario),
                tasks: [ConnectionPlanTask(
                    id: "line:shared", kind: "line", name: "Shared",
                    preparation: "required", resourceID: "shared"
                )]
            )
        )
        report.state = .committed
        return report
    }
}
