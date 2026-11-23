import Foundation
import XCTest

final class HostUnderlayCaptureDiagnosticsTests: XCTestCase {
    func testClassifiesUnsatisfiedPathBeforeRouteFacts() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "unsatisfied",
            routeInterface: "",
            routeError: "",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .pathUnsatisfied)
        XCTAssertEqual(evidence?.pathStatus, "unsatisfied")
    }

    func testClassifiesDefaultRouteFailure() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "",
            routeError: "default route has no interface",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .defaultRouteUnavailable)
        XCTAssertEqual(
            evidence?.routeError,
            "default route has no interface"
        )
    }

    func testClassifiesRoutePathMismatch() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "utun7",
            routeError: "",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )

        XCTAssertEqual(evidence?.reason, .routePathMismatch)
        XCTAssertEqual(evidence?.routeInterface, "utun7")
        XCTAssertEqual(evidence?.candidateInterfaces, ["en0"])
    }

    func testClassifiesMissingInterfaceIndex() {
        let evidence = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "en0",
            routeError: "",
            candidateInterfaces: ["en0", "utun7"],
            indexedInterfaces: ["utun7"]
        )

        XCTAssertEqual(evidence?.reason, .interfaceIndexUnavailable)
        XCTAssertEqual(evidence?.invalidCandidateInterfaces, ["en0"])
    }

    func testReturnsNoFailureForCoherentSnapshot() {
        XCTAssertNil(HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "satisfied",
            routeInterface: "en0",
            routeError: "",
            candidateInterfaces: ["en0", "utun7"],
            indexedInterfaces: ["en0", "utun7"]
        ))
    }

    func testMissingPathUpdateHasStableStructuredReason() {
        XCTAssertEqual(
            HostUnderlayCaptureEvidence.missingPathUpdate.reason,
            .pathUpdateMissing
        )
        XCTAssertEqual(
            HostUnderlayCaptureEvidence.missingPathUpdate.pathStatus,
            "unknown"
        )
    }

    func testEvidenceRoundTripsThroughConnectionFailure() throws {
        let evidence = HostUnderlayCaptureEvidence(
            schemaVersion: 1,
            reason: .routePathMismatch,
            pathStatus: "satisfied",
            routeInterface: "utun7",
            candidateInterfaces: ["en0"],
            invalidCandidateInterfaces: [],
            routeError: ""
        )
        let failureEvidence = ConnectionFailureEvidence(
            underlayCapture: evidence
        )

        let data = try JSONEncoder().encode(failureEvidence)
        XCTAssertEqual(
            try JSONDecoder().decode(
                ConnectionFailureEvidence.self,
                from: data
            ),
            failureEvidence
        )
    }

    func testDeadlineAfterSuccessfulCaptureIsNotATimeout() {
        var resolution = HostUnderlayCaptureResolution()

        XCTAssertTrue(resolution.resolve())
        XCTAssertNil(resolution.expire())
        XCTAssertFalse(resolution.resolve())
    }

    func testDeadlineReportsLatestEvidenceWhenCaptureIsOpen() {
        var resolution = HostUnderlayCaptureResolution()
        let unsatisfied = HostUnderlayCaptureDiagnosticClassifier.classify(
            pathStatus: "unsatisfied",
            routeInterface: "",
            routeError: "",
            candidateInterfaces: ["en0"],
            indexedInterfaces: ["en0"]
        )!
        resolution.observe(unsatisfied)

        XCTAssertEqual(resolution.expire(), unsatisfied)
        // The deadline resolved the capture; a late path cannot deliver.
        XCTAssertFalse(resolution.resolve())
        XCTAssertNil(resolution.expire())
    }

    func testDeadlineWithoutAnyPathReportsMissingPathUpdate() {
        var resolution = HostUnderlayCaptureResolution()

        XCTAssertEqual(resolution.expire(), .missingPathUpdate)
    }
}

final class UnderlayResolverSelectionTests: XCTestCase {
    /// Tailscale MagicDNS 这类接管会把全局 DNS 换成只在自己 utun 上可达的地址。
    /// Underlay 的 resolver 必须来自启动前默认接口所属的服务。
    func testPrefersTheDefaultInterfaceScopedResolver() {
        XCTAssertEqual(
            UnderlayResolverSelection.serverAddresses(
                interfaceName: "en1",
                primaryInterface: "en1",
                primaryService: "SERVICE",
                scopedAddresses: ["202.180.64.10", "202.180.64.11"],
                globalAddresses: ["100.100.100.100"]
            ),
            ["202.180.64.10", "202.180.64.11"]
        )
    }

    /// 快照选定的默认接口不是系统主接口时不猜：退回既有的全局 DNS 语义。
    func testFallsBackWhenTheSnapshotInterfaceIsNotPrimary() {
        XCTAssertEqual(
            UnderlayResolverSelection.serverAddresses(
                interfaceName: "en1",
                primaryInterface: "utun16",
                primaryService: "SERVICE",
                scopedAddresses: ["100.100.100.100"],
                globalAddresses: ["203.0.113.53"]
            ),
            ["203.0.113.53"]
        )
    }

    func testFallsBackWhenTheScopedResolverIsMissing() {
        XCTAssertEqual(
            UnderlayResolverSelection.serverAddresses(
                interfaceName: "en1",
                primaryInterface: "en1",
                primaryService: "SERVICE",
                scopedAddresses: nil,
                globalAddresses: ["203.0.113.53"]
            ),
            ["203.0.113.53"]
        )
    }

    /// 不带接口的采样（运行期重新取样）仍然优先作用域 resolver。
    func testUnscopedSamplingStillPrefersThePrimaryService() {
        XCTAssertEqual(
            UnderlayResolverSelection.serverAddresses(
                interfaceName: nil,
                primaryInterface: "en1",
                primaryService: "SERVICE",
                scopedAddresses: ["202.180.64.10"],
                globalAddresses: ["100.100.100.100"]
            ),
            ["202.180.64.10"]
        )
    }

    func testReturnsNilWhenNoResolverIsAvailable() {
        XCTAssertNil(
            UnderlayResolverSelection.serverAddresses(
                interfaceName: "en1",
                primaryInterface: "en1",
                primaryService: "SERVICE",
                scopedAddresses: [],
                globalAddresses: []
            )
        )
    }
}
