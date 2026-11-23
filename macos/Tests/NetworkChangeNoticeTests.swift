import XCTest

final class NetworkChangeNoticeTests: XCTestCase {
    private let wifi = NetworkChangeNoticeBaseline.Path(available: true, usesWiFi: true, interfaces: ["en0"], gateways: ["router"])
    private let offline = NetworkChangeNoticeBaseline.Path(available: false, usesWiFi: false, interfaces: [], gateways: [])

    func testSSIDAppearingAndTemporaryPermissionGap() {
        var baseline = NetworkChangeNoticeBaseline()
        XCTAssertFalse(baseline.changed(path: wifi, ssid: nil))
        XCTAssertFalse(baseline.changed(path: wifi, ssid: "Office"))
        XCTAssertFalse(baseline.changed(path: wifi, ssid: nil))
        XCTAssertTrue(baseline.changed(path: wifi, ssid: "Home"))
        XCTAssertFalse(baseline.changed(path: wifi, ssid: "Home"))
    }

    func testOfflineAndRestorationNotifyOnceEach() {
        var baseline = NetworkChangeNoticeBaseline()
        XCTAssertFalse(baseline.changed(path: wifi, ssid: "Office"))
        XCTAssertTrue(baseline.changed(path: offline, ssid: nil))
        XCTAssertFalse(baseline.changed(path: offline, ssid: nil))
        XCTAssertTrue(baseline.changed(path: wifi, ssid: nil))
        XCTAssertFalse(baseline.changed(path: wifi, ssid: "Home"))
    }
    func testGatewayOnlyChangesNotifyOnceForBothFamilies() {
        var baseline = NetworkChangeNoticeBaseline()
        var path = wifi
        path.gateways = ["IPv4=192.168.1.1", "IPv6=fe80::1"]
        XCTAssertFalse(baseline.changed(path: path, ssid: "Office"))
        path.gateways = ["IPv4=192.168.1.254", "IPv6=fe80::1"]
        XCTAssertTrue(baseline.changed(path: path, ssid: "Office"))
        XCTAssertFalse(baseline.changed(path: path, ssid: "Office"))
        path.gateways = ["IPv4=192.168.1.254", "IPv6=fe80::2"]
        XCTAssertTrue(baseline.changed(path: path, ssid: "Office"))
        XCTAssertFalse(baseline.changed(path: path, ssid: "Office"))
        path.gateways = []
        XCTAssertTrue(baseline.changed(path: path, ssid: "Office"))
    }

    func testPrimaryAdapterSwitchWithSameGatewayAndUnusedAdapterChanges() {
        var states: [String: [String: Any]] = [
            "State:/Network/Global/IPv4": ["PrimaryInterface": "en7", "Router": "192.168.1.1"],
            "State:/Network/Global/IPv6": ["PrimaryInterface": "en7", "Router": "fe80::1"],
        ]
        func sample() -> NetworkChangeNoticeBaseline.Path {
            let facts = NetworkGatewayNoticeMonitor.currentFacts { states[$0] }
            return .init(available: true, usesWiFi: false,
                         interfaces: facts.interfaces, gateways: facts.gateways)
        }
        var baseline = NetworkChangeNoticeBaseline()
        XCTAssertFalse(baseline.changed(path: sample(), ssid: nil))
        // An unused adapter appearing must not change the primary network.
        states["State:/Network/Service/unused/IPv4"] = ["InterfaceName": "en8", "Router": "192.168.1.1"]
        XCTAssertFalse(baseline.changed(path: sample(), ssid: nil))
        states["State:/Network/Global/IPv4"]?["PrimaryInterface"] = "en8"
        XCTAssertTrue(baseline.changed(path: sample(), ssid: nil))
        XCTAssertFalse(baseline.changed(path: sample(), ssid: nil))
        // IPv6 can move independently, with its router unchanged too.
        states["State:/Network/Global/IPv6"]?["PrimaryInterface"] = "en8"
        XCTAssertTrue(baseline.changed(path: sample(), ssid: nil))
        XCTAssertFalse(baseline.changed(path: sample(), ssid: nil))
    }

}
