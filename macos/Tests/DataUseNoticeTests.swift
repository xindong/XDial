import XCTest

final class DataUseNoticeTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "data-use-notice-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testOnlyTheStoreBuildWaitsForConfirmation() {
        let store = defaults()
        XCTAssertTrue(DataUseNoticeAcceptance.isAccepted(defaults: store, required: false))
        XCTAssertFalse(DataUseNoticeAcceptance.isAccepted(defaults: store, required: true))
    }

    func testConfirmationIsRememberedForTheCurrentVersion() {
        let store = defaults()
        DataUseNoticeAcceptance.accept(defaults: store)
        XCTAssertTrue(DataUseNoticeAcceptance.isAccepted(defaults: store, required: true))
        // 说明内容升级后需要重新确认。
        store.set(DataUseNoticeAcceptance.version - 1, forKey: DataUseNoticeAcceptance.defaultsKey)
        XCTAssertFalse(DataUseNoticeAcceptance.isAccepted(defaults: store, required: true))
    }

    func testNoticeNamesEveryAutomaticServiceOnTheMac() {
        for isChinese in [true, false] {
            let text = MacDataUseNotice.sections(isChinese: isChinese, companyPreset: false)
                .flatMap(\.points).joined(separator: "\n")
            for needle in ["1.1.1.1", "223.5.5.5", "r.inews.qq.com", "checkip.amazonaws.com", "www.gstatic.com", "MAC"] {
                XCTAssertTrue(text.contains(needle), "\(needle) missing (zh: \(isChinese))")
            }
            // 公开版不带地区预置，不查出口地区。
            XCTAssertFalse(text.contains("gspe1-ssl.ls.apple.com"))
            let preset = MacDataUseNotice.sections(isChinese: isChinese, companyPreset: true)
                .flatMap(\.points).joined(separator: "\n")
            XCTAssertTrue(preset.contains("gspe1-ssl.ls.apple.com"))
        }
    }

    @MainActor
    func testLineTestsStayOfflineUntilTheNoticeIsConfirmed() {
        let store = LineLatencyStore()
        var allowed = false
        store.standaloneRequest = { _, _ in throw CocoaError(.userCancelled) }
        store.permitsNetworkTests = { allowed }
        let line = Line(id: "direct", name: "直连", type: "direct", verified: true)
        XCTAssertNil(store.test([line], profileID: "p"))
        allowed = true
        XCTAssertNotNil(store.test([line], profileID: "p"))
    }

    func testCollectionClaimCoversOnlyTheClientAndCompanyLinesNeedAnOwnAccount() {
        for isChinese in [true, false] {
            let text = MacDataUseNotice.sections(isChinese: isChinese, companyPreset: true)
                .flatMap(\.points).joined(separator: "\n")
            XCTAssertFalse(text.contains("不运行收集") || text.contains("runs no server"))
            XCTAssertTrue(text.contains(isChinese ? "自己的公司账号" : "your own company account"))
            XCTAssertTrue(text.contains(isChinese ? "以公司的规定为准" : "governed by your company's policies"))
        }
    }

    func testNoticeCoversMyServer() {
        for isChinese in [true, false] {
            let text = MacDataUseNotice.sections(isChinese: isChinese, companyPreset: false)
                .flatMap(\.points).joined(separator: "\n")
            for needle in ["speed.cloudflare.com", "deb.sagernet.org", "10 MB"] {
                XCTAssertTrue(text.contains(needle), needle)
            }
        }
    }
}
