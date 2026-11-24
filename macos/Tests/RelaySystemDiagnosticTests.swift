import Foundation
import Network
import NetworkExtension
import XCTest

final class RelaySystemDiagnosticTests: XCTestCase {
    func testSameCodeKeepsKnownErrorOrigin() {
        for (domain, expected) in [(NEAppProxyErrorDomain, "ne-app-proxy-1"), (NSPOSIXErrorDomain, "posix-1"), (NSURLErrorDomain, "url-1")] {
            let error = NSError(domain: domain, code: 1)
            XCTAssertEqual(RelaySystemDiagnostic.code(for: error), expected)
            XCTAssertEqual(TCPFlowSOCKSRelay.diagnosticCode(error), expected)
        }
        XCTAssertEqual(RelaySystemDiagnostic.code(for: NWError.posix(.ENOBUFS)), "posix-\(ENOBUFS)")
    }

    func testUnknownDomainAndUserInfoNeverEnterLog() {
        let error = NSError(domain: "private.test", code: 17, userInfo: [NSLocalizedDescriptionKey: "sensitive"])
        XCTAssertEqual(RelaySystemDiagnostic.code(for: error), "other-17")
    }
}
