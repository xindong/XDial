import XCTest

final class AnyConnectLoginFailureTests: XCTestCase {
    func testClassifiesOnlyTheTwoLoginFailures() {
        let prefix = "anyconnect dial: AnyConnect connect: "
        XCTAssertEqual(AnyConnectLoginFailure(message: prefix + "authentication completed without a session token"), .missingToken)
        XCTAssertEqual(AnyConnectLoginFailure(message: prefix + "tunnel negotiation failed 401 Cookie is not acceptable"), .rejectedSession)
        XCTAssertNil(AnyConnectLoginFailure(message: prefix + "auth error 401 Unauthorized"))
        XCTAssertNil(AnyConnectLoginFailure(message: prefix + "tunnel negotiation failed 403 Forbidden"))
        XCTAssertNil(AnyConnectLoginFailure(message: "subscription returned 401 Unauthorized"))
    }
}
