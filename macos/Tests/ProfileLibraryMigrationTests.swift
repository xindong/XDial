import CryptoKit
import Foundation
import XCTest

final class ProfileLibraryMigrationTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: home) }
        return home
    }

    private func writeLegacy(_ profile: Profile, at source: ConfigurationStorage.LegacyLocation,
                             home: URL, date: Date = Date()) throws -> [URL: Data] {
        let preferences = home.appendingPathComponent(source.preferencesPath)
        let vault = home.appendingPathComponent(source.dataPath + "/vault.json")
        let files = [preferences: try PropertyListSerialization.data(
            fromPropertyList: ["xdial.profile": JSONEncoder().encode(profile), "xdial.autoConnect": true],
            format: .binary, options: 0), vault: try JSONEncoder().encode(["vpn-vpn": "saved-password"])]
        for (url, data) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return files
    }

    private func converted(_ profile: Profile, id: String) -> Profile {
        var value = profile
        value.profileID = id
        return value
    }

    func testFirstLaunchCreatesOneDefaultAndNeverWritesBackToLegacy() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines.append(Line(id: "vpn", name: "Company", type: "vpn"))
        old.scenarios[0].defaultLineID = "vpn"
        let original = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home)
        var conversions = 0
        let library = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { profile, id in
                conversions += 1
                return self.converted(profile, id: id)
            }
        }
        XCTAssertEqual(conversions, 1)
        XCTAssertEqual(library.profiles.count, 1)
        XCTAssertEqual(library.profiles[0].name, "默认配置")
        XCTAssertEqual(library.activeProfileID, ProfileLibrary.configurationID)
        XCTAssertEqual(library.editingProfileID, library.profiles[0].id)
        XCTAssertEqual(library.profiles[0].profile.lines.last?.vpnPassword, "saved-password")
        XCTAssertEqual(library.scenarios, old.scenarios)
        var changed = library
        changed.profiles[0].profile.lines[1].name = "Edited in new version"
        try store.save(changed)
        let relaunched = ProfileLibraryStore(directory: store.directory, keyProvider: { _ in key })
        XCTAssertEqual(try relaunched.loadOrCreate { XCTFail("must not import twice"); return nil }, changed)
        for (url, data) in original { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testNewestSavedConfigurationWinsWithoutAChannelPriority() throws {
        let home = try temporaryHome()
        var old = ProfileRecord.empty(named: "Old").profile
        old.lines[0].name = "older formal"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[0], home: home, date: Date(timeIntervalSince1970: 100))
        old.lines[0].name = "newer debug"
        _ = try writeLegacy(old, at: ConfigurationStorage.desktopLocations[1], home: home, date: Date(timeIntervalSince1970: 200))
        let library = try XCTUnwrap(ProfileLibraryMigration.initialLibrary(home: home, convertProfile: converted))
        XCTAssertEqual(library.profiles[0].profile.lines[0].name, "newer debug")
    }

    func testExistingNextLibraryRetainsEveryProfileAndOriginalEncryptedFile() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let source = ConfigurationStorage.desktopLocations[2]
        let oldStore = ProfileLibraryStore(directory: home.appendingPathComponent(source.dataPath), keyProvider: { _ in key })
        var original = ProfileLibrary()
        try original.insert(.empty(named: "Second"))
        original.activeScenarioID = original.scenarios.last!.id
        try oldStore.save(original)
        let oldFile = oldStore.directory.appendingPathComponent("profiles.enc")
        let bytes = try Data(contentsOf: oldFile)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let loaded = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home, readLibrary: { location in
                XCTAssertEqual(location, source)
                return try oldStore.load()
            }, convertProfile: { _, _ in XCTFail("already a Profile library"); return Profile() })
        }
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(try Data(contentsOf: oldFile), bytes)
        XCTAssertEqual(try store.load(), original)
    }

    func testFailedConversionDoesNotCreateEmptyLibraryOrTouchSource() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let files = try writeLegacy(ProfileRecord.empty(named: "Old").profile,
                                    at: ConfigurationStorage.desktopLocations[0], home: home)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        XCTAssertThrowsError(try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in
                throw ProfileLibraryError.invalid("cannot convert")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.enc").path))
        for (url, data) in files { XCTAssertEqual(try Data(contentsOf: url), data) }
    }

    func testCorruptSharedLibraryNeverFallsBackToOldConfiguration() throws {
        let home = try temporaryHome()
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in SymmetricKey(size: .bits256) })
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let file = store.directory.appendingPathComponent("profiles.enc")
        let original = Data("corrupt shared library".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.loadOrCreate { XCTFail("must not migrate an unreadable existing library"); return ProfileLibrary() })
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testAnotherVersionFinishingMigrationFirstIsRetained() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let first = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let second = ProfileLibraryStore(directory: first.directory, keyProvider: { _ in key })
        var winner = ProfileLibrary()
        winner.profiles[0].name = "Already migrated"
        let result = try first.loadOrCreate {
            try second.save(winner)
            return ProfileLibrary()
        }
        XCTAssertEqual(result, winner)
    }

    func testNoLegacyDataCreatesDefaultOnce() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        let result = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in XCTFail(); return Profile() }
        }
        XCTAssertEqual(result.profiles.count, 1)
        XCTAssertEqual(result.profiles[0].name, "默认配置")
        XCTAssertEqual(try store.loadOrCreate { XCTFail(); return nil }, result)
    }

    private func seededProfile(id: String) -> Profile {
        var profile = Profile()
        profile.profileID = id
        profile.lines = [Line(id: "direct", name: "直连", type: "direct"), Line(id: id + "-vpn", name: "Company", type: "vpn")]
        profile.lines[1].vpnServer = "vpn.example.test:8443"
        profile.ruleSets = [RuleSet(id: id + "-intranet", name: "Intranet", type: "manual", domains: ["corp.example"])]
        var office = Scenario(id: id + "-office", name: "Office", defaultLineID: "direct")
        office.matchSSIDs = ["CORP"]
        var remote = Scenario(id: id + "-remote", name: "Remote", defaultLineID: "direct")
        remote.bindings = [RuleBinding(ruleSetID: id + "-intranet", lineID: id + "-vpn")]
        remote.matchSSIDs = ["CORP-GUEST"]
        profile.scenarios = [office, remote]
        profile.activeScenarioID = remote.id
        return profile
    }

    private func existingLibrary(claiming ssids: [String]) throws -> ProfileLibrary {
        var library = ProfileLibrary()
        library.scenarios[0].matchSSIDs = ssids
        return try library.validated()
    }

    func testMobileSeedKeepsEditsAndMapsRegionsIntoImportedNamespace() throws {
        let directory = try temporaryHome()
        let data = Data(#"{"format":"xdial-mobile-seed","schema_version":1,"revision":2,"region_scenarios":{"nz":"office","*":"away"},"profile":{"scenarios":[{"id":"office"},{"id":"away"}]}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("Seed.json"))
        let source = try XCTUnwrap(SeedProfile.load(directory: directory))
        let applied = SeedProfileLedger.Entry(profileID: "seed", digest: "mobile-v1-999")
        XCTAssertTrue(applied.isNewer(than: source))
        XCTAssertFalse(SeedProfileLedger.Entry(profileID: "seed", digest: source.digest).isNewer(than: source))
        var incoming = Profile.bootstrap()
        incoming.lines[1].vpnServer = "vpn.example.com"
        incoming.scenarios = [Scenario(id: "scoped-a", name: "Office", defaultLineID: "vpn"),
                              Scenario(id: "scoped-b", name: "Away", defaultLineID: "direct")]
        incoming.activeScenarioID = "scoped-b"
        XCTAssertEqual(source.regionTargets(in: incoming), ["NZ": "scoped-a", "*": "scoped-b"])
        var library = ProfileLibrary()
        let selection = library.activeScenarioID
        library.profiles[0].profile.lines.append(Line(id: "saved", name: "Saved VPN", type: "vpn",
            vpnServer: "vpn.example.com", vpnUsername: "employee", vpnPassword: "Ｐass word"))
        let updated = try ProfileLibraryMigration.addingMobileSeed(incoming, named: "Seed", id: "seed", to: library)
        XCTAssertEqual(updated.activeScenarioID, selection)
        XCTAssertEqual(updated.scenarios.first?.defaultLineID, "saved")
        XCTAssertEqual(updated.snapshot().lines.first { $0.id == "saved" }?.vpnPassword, "Ｐass word")
        // Joined beside the existing Profile, the preset's Scenarios carry its name, as file imports do.
        XCTAssertEqual(updated.scenarios.prefix(2).map(\.name), ["Seed · Office", "Seed · Away"])
        var edited = updated
        edited.scenarios[0].defaultLineID = "direct"
        let next = try ProfileLibraryMigration.addingMobileSeed(incoming, named: "Seed", id: "seed", to: edited)
        XCTAssertEqual(next.scenarios[0].defaultLineID, "direct")
    }

    func testSeedLoadsOneNamedDocumentAndRejectsAmbiguousDirectories() throws {
        let home = try temporaryHome()
        let directory = home.appendingPathComponent("SeedProfile")
        XCTAssertNil(try SeedProfile.load(directory: directory))
        XCTAssertNil(try SeedProfile.load(directory: nil))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("seed document".utf8).write(to: directory.appendingPathComponent("公司.json"))
        XCTAssertEqual(try SeedProfile.load(directory: directory), SeedProfile(name: "公司", text: "seed document"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("Other.json"))
        XCTAssertThrowsError(try SeedProfile.load(directory: directory))
    }

    func testSeedCreatesEmptyLibraryOnceWithUnprefixedScenarios() throws {
        let home = try temporaryHome()
        let key = SymmetricKey(size: .bits256)
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in key })
        var imports = 0
        let library = try store.loadOrCreate {
            try ProfileLibraryMigration.initialLibrary(home: home) { _, _ in XCTFail(); return Profile() }
                ?? ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "seed document")) { text, id in
                    imports += 1
                    XCTAssertEqual(text, "seed document")
                    return self.seededProfile(id: id)
                }
        }
        XCTAssertEqual(imports, 1)
        XCTAssertEqual(library.profiles.map(\.name), ["公司"])
        XCTAssertEqual(library.profiles[0].profile.profileID, library.profiles[0].id)
        XCTAssertEqual(library.scenarios.map(\.name), ["Office", "Remote"])
        XCTAssertEqual(library.scenarios[0].matchSSIDs, ["CORP"])
        XCTAssertEqual(library.scenarios.first { $0.id == library.activeScenarioID }?.name, "Remote")
        XCTAssertEqual(library.profiles[0].profile.lines.first { $0.type == "vpn" }?.vpnPassword, "")
        XCTAssertEqual(try store.loadOrCreate { XCTFail("must not seed twice"); return nil }, library)
    }

    func testSeedNeverCreatesLibraryWhenExistingConfigurationIsFound() throws {
        let home = try temporaryHome()
        _ = try writeLegacy(ProfileRecord.empty(named: "Old").profile, at: ConfigurationStorage.desktopLocations[0], home: home)
        let library = try ProfileLibraryMigration.initialLibrary(home: home, convertProfile: converted)
            ?? ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "")) { _, _ in XCTFail(); return Profile() }
        XCTAssertEqual(library?.profiles.map(\.name), ["默认配置"])
    }

    func testMissingSeedKeepsBuiltInDefault() throws {
        XCTAssertNil(try ProfileLibraryMigration.seedLibrary(nil) { _, _ in XCTFail(); return Profile() })
    }

    func testInvalidSeedDoesNotCreateLibrary() throws {
        let home = try temporaryHome()
        let store = ProfileLibraryStore(directory: ConfigurationStorage.directory(home: home), keyProvider: { _ in SymmetricKey(size: .bits256) })
        XCTAssertThrowsError(try store.loadOrCreate {
            try ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "")) { _, _ in
                throw ProfileLibraryError.invalid("bad seed")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("profiles.enc").path))
    }

    func testSeedJoinsExistingLibraryWithoutChangingSelection() throws {
        let original = try existingLibrary(claiming: ["HOME"])
        let merged = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed", into: original)
        XCTAssertEqual(merged.profiles.map(\.name), ["默认配置", "公司"])
        XCTAssertEqual(merged.profiles.dropLast().map(\.self), original.profiles)
        XCTAssertEqual(merged.activeScenarioID, original.activeScenarioID)
        XCTAssertEqual(merged.editingProfileID, original.editingProfileID)
        XCTAssertEqual(merged.scenarios.first, original.scenarios.first)
        XCTAssertEqual(merged.scenarios.dropFirst().map(\.name), ["公司 · Office", "公司 · Remote"])
        XCTAssertEqual(merged.scenarios.dropFirst().map(\.matchSSIDs), [["CORP"], ["CORP-GUEST"]])
    }

    func testSeedLeavesClaimedWiFiTriggerWithExistingScenario() throws {
        let original = try existingLibrary(claiming: ["CORP"])
        let merged = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed", into: original)
        XCTAssertEqual(merged.scenarios.map(\.matchSSIDs), [["CORP"], [], ["CORP-GUEST"]])
    }

    private func refreshedSeed(id: String) -> Profile {
        var profile = seededProfile(id: id)
        profile.ruleSets[0].domains = ["corp.example", "corp2.example"]
        profile.ruleSets.append(RuleSet(id: id + "-ops", name: "Ops", type: "manual", domains: ["ops.example"]))
        profile.scenarios[0].matchSSIDs = ["CORP", "CORP-5G"]
        profile.scenarios[1].bindings.append(RuleBinding(ruleSetID: id + "-ops", lineID: id + "-vpn"))
        var travel = Scenario(id: id + "-travel", name: "Travel", defaultLineID: id + "-vpn")
        travel.matchSSIDs = ["HOTEL"]
        profile.scenarios.append(travel)
        return profile
    }

    func testSeedRefreshOverwritesOwnedContentButKeepsUserState() throws {
        var library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: ["HOTEL"]))
        let index = try XCTUnwrap(library.profiles.firstIndex { $0.id == "seed" })
        let vpn = try XCTUnwrap(library.profiles[index].profile.lines.firstIndex { $0.type == "vpn" })
        library.profiles[index].profile.lines[vpn].vpnUsername = "alice"
        library.profiles[index].profile.lines[vpn].vpnPassword = "saved-password"
        let office = try XCTUnwrap(library.scenarios.firstIndex { $0.id == "seed-office" })
        library.scenarios[office].name = "My Office"
        let active = library.activeScenarioID

        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        let record = try XCTUnwrap(refreshed.profiles.first { $0.id == "seed" })
        XCTAssertEqual(record.profile.ruleSets.first { $0.id == "seed-intranet" }?.domains, ["corp.example", "corp2.example"])
        XCTAssertEqual(record.profile.lines.first { $0.type == "vpn" }?.vpnUsername, "alice")
        XCTAssertEqual(record.profile.lines.first { $0.type == "vpn" }?.vpnPassword, "saved-password")
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-office" }?.name, "My Office")
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-office" }?.matchSSIDs, ["CORP", "CORP-5G"])
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-remote" }?.bindings.map(\.ruleSetID), ["seed-intranet", "seed-ops"])
        let travel = try XCTUnwrap(refreshed.scenarios.first { $0.id == "seed-travel" })
        XCTAssertEqual(travel.name, "公司 · Travel")
        XCTAssertEqual(travel.matchSSIDs, [], "HOTEL stays with the user's Scenario")
        XCTAssertEqual(refreshed.activeScenarioID, active)
        XCTAssertEqual(refreshed.editingProfileID, library.editingProfileID)
        XCTAssertEqual(refreshed.profiles.first, library.profiles.first)
    }

    /// The seed ships Lines without credentials; employees must be able to fill them in.
    func testSeedLineCredentialsBelongToTheUserButSubscriptionCredentialsDoNot() throws {
        let library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let seed = try XCTUnwrap(library.profiles.first { $0.id == "seed" })
        XCTAssertNotNil(seed.baseline, "seed Lines stay source-owned")
        XCTAssertTrue(seed.lineCredentialsBelongToUser)

        var subscription = seed
        subscription.source = ProfileSource(url: "https://example.com/sub")
        XCTAssertFalse(subscription.lineCredentialsBelongToUser, "a refresh replaces subscription credentials")

        var line = Line(id: "vpn", name: "VPN", type: "vpn")
        var saved = line
        for field in Line.credentialFields { saved[keyPath: field] = "user" }
        line = line.keepingCredentials(of: saved)
        for field in Line.credentialFields {
            XCTAssertEqual(line[keyPath: field], "user", "\(field) is editable and therefore kept")
        }
    }

    /// Seed and subscription share the refresh merge; employees never subscribed to anything.
    func testSeedRefreshErrorsNameThePresetNotASubscription() throws {
        let library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let warning = try JSONDecoder().decode(SubRule.self, from: Data(#"{"type":"USER-AGENT","value":"Example*","group":"Proxy"}"#.utf8))
        var incoming = refreshedSeed(id: "seed")
        incoming.importWarnings = [warning]
        XCTAssertThrowsError(try ProfileLibraryMigration.refreshingSeed(incoming, profileID: "seed", named: "公司", in: library)) {
            XCTAssertEqual($0.localizedDescription, "预置配置新增了无法执行的规则，已保留原配置")
        }

        var subscribed = library
        let index = try XCTUnwrap(subscribed.profiles.firstIndex { $0.id == "seed" })
        subscribed.profiles[index].source = ProfileSource(url: "https://example.com/sub")
        XCTAssertThrowsError(try subscribed.refreshing(profileID: "seed", incoming: incoming)) {
            XCTAssertEqual($0.localizedDescription, "订阅新增了无法执行的规则，已保留原配置")
        }
    }

    func testSeedRefreshCanDropARuleItsScenarioUsed() throws {
        let library = try ProfileLibraryMigration.merging(refreshedSeed(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let refreshed = try ProfileLibraryMigration.refreshingSeed(seededProfile(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        XCTAssertNil(refreshed.profiles.first { $0.id == "seed" }?.profile.ruleSets.first { $0.id == "seed-ops" })
        XCTAssertEqual(refreshed.scenarios.first { $0.id == "seed-remote" }?.bindings.map(\.ruleSetID), ["seed-intranet"])
    }

    func testFirstLaunchSeedRefreshKeepsUnprefixedNames() throws {
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "公司", text: "v1")) { _, id in
            self.seededProfile(id: id)
        })
        let id = created.profiles[0].id
        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: id), profileID: id, named: "公司", in: created)
        XCTAssertEqual(refreshed.scenarios.map(\.name), ["Office", "Remote", "Travel"])
        XCTAssertEqual(refreshed.scenarios.last?.matchSSIDs, ["HOTEL"])
    }

    func testSeedLedgerRoundTripsAndStartsEmpty() throws {
        let url = SeedProfileLedger.url(directory: try temporaryHome())
        XCTAssertEqual(try SeedProfileLedger.load(from: url), SeedProfileLedger())
        var ledger = SeedProfileLedger()
        ledger.entries["公司"] = .init(profileID: "seed", digest: SeedProfile(name: "公司", text: "v1").digest)
        try ledger.save(to: url)
        XCTAssertEqual(try SeedProfileLedger.load(from: url), ledger)
        XCTAssertNotEqual(SeedProfile(name: "公司", text: "v1").digest, SeedProfile(name: "公司", text: "v2").digest)
    }

    func testSeedRefreshAdoptsARecordWithoutBaseline() throws {
        var library = try ProfileLibraryMigration.merging(seededProfile(id: "seed"), named: "公司", id: "seed",
                                                          into: existingLibrary(claiming: []))
        let index = try XCTUnwrap(library.profiles.firstIndex { $0.id == "seed" })
        library.profiles[index].baseline = nil
        let refreshed = try ProfileLibraryMigration.refreshingSeed(refreshedSeed(id: "seed"), profileID: "seed",
                                                                   named: "公司", in: library)
        XCTAssertEqual(refreshed.scenarios.map(\.id).filter { $0.hasPrefix("seed-") }, ["seed-office", "seed-remote", "seed-travel"])
        XCTAssertEqual(refreshed.scenarios.count, library.scenarios.count + 1)
    }

    // Mac builds up to 45 shipped the two-Scenario desktop seed; the phone seed
    // has four with different routing. Same IDs, so an upgrade must add the
    // missing Scenarios and adopt the new routing only where the user did not
    // change it.
    private func desktopSeed() throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: Data(#"""
        {"lines":[{"id":"direct","name":"直连","type":"direct","enabled":true},
                  {"id":"vpn","name":"公司 VPN","type":"vpn","enabled":true,"vpn_server":"vpn.example.com:8443"}],
         "rule_sets":[{"id":"intranet","name":"公司内网","type":"manual","enabled":true,"domains":["example.com"]}],
         "scenarios":[{"id":"office","name":"公司","default_line_id":"direct","match_ssids":["OFFICE"]},
                      {"id":"domestic","name":"国内","default_line_id":"direct","bindings":[{"rule_set_id":"intranet","line_id":"vpn"}]}],
         "active_scenario_id":"office"}
        """#.utf8))
    }

    private func phoneSeed() throws -> Profile {
        try JSONDecoder().decode(Profile.self, from: Data(#"""
        {"lines":[{"id":"direct","name":"直连","type":"direct","enabled":true},
                  {"id":"vpn","name":"公司 VPN","type":"vpn","enabled":true,"vpn_server":"vpn.example.com:8443"}],
         "rule_sets":[{"id":"intranet","name":"公司内网","type":"manual","enabled":true,"domains":["example.com"]},
                      {"id":"lan","name":"本地局域网","type":"manual","enabled":true,"cidrs":["192.168.0.0/16"]},
                      {"id":"cn","name":"国内网站","type":"manual","enabled":true,"domains":["cn"]}],
         "scenarios":[{"id":"office","name":"在公司","default_line_id":"direct","match_ssids":["OFFICE"]},
                      {"id":"domestic","name":"在国内","default_line_id":"vpn","bindings":[{"rule_set_id":"intranet","line_id":"vpn"},{"rule_set_id":"lan","line_id":"direct"},{"rule_set_id":"cn","line_id":"direct"}]},
                      {"id":"overseas","name":"在国外","default_line_id":"direct","bindings":[{"rule_set_id":"lan","line_id":"direct"},{"rule_set_id":"intranet","line_id":"vpn"},{"rule_set_id":"cn","line_id":"vpn"}]},
                      {"id":"hongkong","name":"在香港","default_line_id":"direct","bindings":[{"rule_set_id":"intranet","line_id":"vpn"},{"rule_set_id":"cn","line_id":"vpn"}]}],
         "active_scenario_id":"domestic"}
        """#.utf8))
    }

    private func desktopSeedLibrary() throws -> ProfileLibrary {
        let old = try desktopSeed()
        var library = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v1"), id: "seed") { _, _ in old })
        // The employee filled in their account and chose a Scenario by hand.
        let index = try XCTUnwrap(library.profiles[0].profile.lines.firstIndex { $0.id == "vpn" })
        library.profiles[0].profile.lines[index].vpnUsername = "employee"
        library.profiles[0].profile.lines[index].vpnPassword = "secret"
        library.activeScenarioID = "domestic"
        return try library.validated()
    }

    func testPhoneSeedUpgradesUntouchedDesktopSeedScenarios() throws {
        let library = try desktopSeedLibrary()
        XCTAssertEqual(library.scenarios.map(\.name), ["公司", "国内"])
        let upgraded = try ProfileLibraryMigration.addingMobileSeed(phoneSeed(), named: "心动", id: "seed", to: library, aligningLegacySeed: true)
        XCTAssertEqual(upgraded.scenarios.map(\.id), ["office", "domestic", "overseas", "hongkong"])
        XCTAssertEqual(upgraded.scenarios.map(\.name), ["在公司", "在国内", "在国外", "在香港"])
        let domestic = try XCTUnwrap(upgraded.scenarios.first { $0.id == "domestic" })
        XCTAssertEqual(domestic.defaultLineID, "vpn")
        XCTAssertEqual(domestic.bindings.map(\.ruleSetID), ["intranet", "lan", "cn"])
        XCTAssertEqual(upgraded.scenarios.first { $0.id == "office" }?.matchSSIDs, ["OFFICE"])
        XCTAssertEqual(upgraded.activeScenarioID, "domestic")
        let vpn = try XCTUnwrap(upgraded.snapshot().lines.first { $0.id == "vpn" })
        XCTAssertEqual(vpn.vpnUsername, "employee")
        XCTAssertEqual(vpn.vpnPassword, "secret")
        XCTAssertEqual(Set(upgraded.snapshot().ruleSets.map(\.id)), ["intranet", "lan", "cn"])
        // Idempotent: the same seed again changes nothing.
        XCTAssertEqual(try ProfileLibraryMigration.addingMobileSeed(phoneSeed(), named: "心动", id: "seed", to: upgraded, aligningLegacySeed: true), upgraded)
    }

    func testPhoneSeedKeepsWhatTheUserChangedInDesktopSeedScenarios() throws {
        var library = try desktopSeedLibrary()
        let index = try XCTUnwrap(library.scenarios.firstIndex { $0.id == "domestic" })
        library.scenarios[index].name = "我的国内"
        library.scenarios[index].bindings = []
        library.scenarios.append(Scenario(id: "mine", name: "自己的", defaultLineID: "direct"))
        library = try library.validated()
        let upgraded = try ProfileLibraryMigration.addingMobileSeed(phoneSeed(), named: "心动", id: "seed", to: library, aligningLegacySeed: true)
        let domestic = try XCTUnwrap(upgraded.scenarios.first { $0.id == "domestic" })
        XCTAssertEqual(domestic.name, "我的国内")
        XCTAssertEqual(domestic.bindings, [])
        // The default exit was untouched, so it follows the new seed.
        XCTAssertEqual(domestic.defaultLineID, "vpn")
        XCTAssertTrue(upgraded.scenarios.contains { $0.id == "mine" && $0.name == "自己的" })
        XCTAssertEqual(Set(upgraded.scenarios.map(\.id)), ["office", "domestic", "overseas", "hongkong", "mine"])
        // Only the user's own changes are reported as the reason the Mac differs from the phone.
        XCTAssertEqual(ProfileLibraryMigration.keptCustomizations(upgraded.scenarios, seed: try phoneSeed(), prefix: "心动 · "),
                       ["Scenario domestic (name, rules)"])
    }

    func testLaterRevisionsOnlyAddWhatIsMissingLikeIPhone() throws {
        let seed = try phoneSeed()
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v2"), id: "seed") { _, _ in seed })
        var changed = seed
        changed.scenarios[1].defaultLineID = "direct"
        changed.scenarios.append(Scenario(id: "extra", name: "新场景", defaultLineID: "direct"))
        let next = try ProfileLibraryMigration.addingMobileSeed(changed, named: "心动", id: "seed", to: created)
        XCTAssertEqual(next.scenarios.first { $0.id == "domestic" }?.defaultLineID, "vpn")
        XCTAssertTrue(next.scenarios.contains { $0.id == "extra" })
    }

    func testPhoneSeedOnFreshInstallCreatesAllFourScenarios() throws {
        let seed = try phoneSeed()
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v2"), id: "seed") { _, _ in seed })
        XCTAssertEqual(created.scenarios.map(\.name), ["在公司", "在国内", "在国外", "在香港"])
        XCTAssertEqual(try ProfileLibraryMigration.addingMobileSeed(seed, named: "心动", id: "seed", to: created).scenarios,
                       created.scenarios)
    }
    func testScenariosAddedBesideOtherProfilesKeepThePresetPrefix() throws {
        // The old desktop preset joined beside the user's own Profile, so its Scenarios are prefixed.
        let joined = try ProfileLibraryMigration.merging(desktopSeed(), named: "心动", id: "seed",
                                                         into: ProfileLibraryMigration.starterLibrary())
        XCTAssertEqual(joined.scenarios.filter { joined.scenarioSources[$0.id] == "seed" }.map(\.name), ["心动 · 公司", "心动 · 国内"])
        var renamed = joined
        let index = try XCTUnwrap(renamed.scenarios.firstIndex { $0.id == "domestic" })
        renamed.scenarios[index].name = "我的国内"
        renamed = try renamed.validated()
        let upgraded = try ProfileLibraryMigration.addingMobileSeed(phoneSeed(), named: "心动", id: "seed", to: renamed,
                                                                    aligningLegacySeed: true)
        XCTAssertEqual(upgraded.scenarios.filter { upgraded.scenarioSources[$0.id] == "seed" }.map(\.name),
                       ["心动 · 在公司", "我的国内", "心动 · 在国外", "心动 · 在香港"])
    }

    func testScenariosAddedToTheOnlyProfileStayUnprefixed() throws {
        let seed = try phoneSeed()
        var created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v2"), id: "seed") { _, _ in seed })
        // A Profile added later does not rename what the preset already shows.
        try created.insert(ProfileRecord(id: "mine", name: "自己的", profile: Profile()))
        var changed = seed
        changed.scenarios.append(Scenario(id: "extra", name: "新场景", defaultLineID: "direct"))
        let next = try ProfileLibraryMigration.addingMobileSeed(changed, named: "心动", id: "seed", to: created)
        XCTAssertEqual(next.scenarios.first { $0.id == "extra" }?.name, "新场景")
    }

    func testAlignmentMovesWiFiBetweenUnchangedScenarios() {
        var previous = Profile()
        previous.scenarios = [Scenario(id: "a", name: "A", defaultLineID: "direct"),
                              Scenario(id: "b", name: "B", matchSSIDs: ["OFFICE"], defaultLineID: "direct")]
        var seed = previous
        seed.scenarios[0].matchSSIDs = ["OFFICE"]
        seed.scenarios[1].matchSSIDs = []
        let moved = ProfileLibraryMigration.refreshedSeedScenarios(previous.scenarios, previous: previous, seed: seed,
                                                                   owned: { _ in true }, prefix: "")
        XCTAssertEqual(moved.map(\.matchSSIDs), [["OFFICE"], []])
        // A trigger the user put on a Scenario outside the seed stays there.
        let mine = Scenario(id: "mine", name: "Mine", matchSSIDs: ["OFFICE"], defaultLineID: "direct")
        var claimed = previous.scenarios
        claimed[1].matchSSIDs = []
        let kept = ProfileLibraryMigration.refreshedSeedScenarios(claimed + [mine], previous: previous, seed: seed,
                                                                  owned: { $0 != "mine" }, prefix: "")
        XCTAssertEqual(kept.map(\.matchSSIDs), [[], [], ["OFFICE"]])
    }

    func testReworkedRuleFollowsThePresetOnlyWhileUntouched() throws {
        var previous = try phoneSeed()
        previous.ruleSets[0].domains = ["example.com", "Shop.example"]
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v2"), id: "seed") { _, _ in previous })
        let current = try phoneSeed() // the next revision drops shop.example from the intranet rule
        let history = ["intranet": [ShippedRuleContent(domains: ["shop.example", "EXAMPLE.com"], cidrs: [])]]
        let updated = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: created,
                                                                   ruleSetHistory: history)
        XCTAssertEqual(updated.snapshot().ruleSets.first { $0.id == "intranet" }?.domains, ["example.com"])
        XCTAssertEqual(try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: updated,
                                                                    ruleSetHistory: history).snapshot(),
                       updated.snapshot(), "applying the same revision again changes nothing")

        var edited = created
        let index = try XCTUnwrap(edited.profiles[0].profile.ruleSets.firstIndex { $0.id == "intranet" })
        edited.profiles[0].profile.ruleSets[index].domains.append("mine.example")
        edited = try edited.validated()
        let kept = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: edited,
                                                                ruleSetHistory: history)
        XCTAssertEqual(kept.snapshot().ruleSets.first { $0.id == "intranet" }?.domains,
                       ["example.com", "Shop.example", "mine.example"])
    }

    func testRuleHistoryFollowsTheImportedAndScopedIDs() throws {
        let directory = try temporaryHome()
        let data = Data(#"{"format":"xdial-mobile-seed","schema_version":1,"revision":3,"rule_set_history":{"intranet":[{"domains":["example.com","shop.example"]}]},"profile":{"rule_sets":[{"id":"intranet","type":"manual"},{"id":"cn","type":"url"}],"scenarios":[{"id":"office"}]}}"#.utf8)
        try data.write(to: directory.appendingPathComponent("心动.json"))
        let source = try XCTUnwrap(SeedProfile.load(directory: directory))
        var imported = Profile()
        imported.ruleSets = [RuleSet(id: "scoped-intranet", name: "公司内网", type: "manual"),
                             RuleSet(id: "scoped-cn", name: "国内网站", type: "url")]
        XCTAssertEqual(source.ruleSetHistory(in: imported),
                       ["scoped-intranet": [ShippedRuleContent(domains: ["shop.example", "example.com"], cidrs: [])]])
        for bad in [#""rule_set_history":{"cn":[{"domains":["a"]}]}"#, #""rule_set_history":{"intranet":[{"invert":true}]}"#] {
            let text = String(decoding: data, as: UTF8.self).replacingOccurrences(
                of: #""rule_set_history":{"intranet":[{"domains":["example.com","shop.example"]}]}"#, with: bad)
            XCTAssertNotEqual(text, String(decoding: data, as: UTF8.self))
            try Data(text.utf8).write(to: directory.appendingPathComponent("心动.json"))
            XCTAssertThrowsError(try SeedProfile.load(directory: directory))
        }

        // Beside the user's own Profile the seed's rule IDs are scoped; the history follows them.
        var previous = try phoneSeed()
        previous.ruleSets[0].domains = ["example.com", "shop.example"]
        var userLibrary = try ProfileLibraryMigration.starterLibrary()
        let userRule = RuleSet(id: "intranet", name: "My rule", type: "manual", domains: ["mine.example"])
        userLibrary.profiles[0].profile.ruleSets.append(userRule)
        userLibrary = try userLibrary.validated()
        var joined = try ProfileLibraryMigration.merging(previous, named: "心动", id: "seed",
                                                         into: userLibrary)
        joined = try joined.validated()
        let mapping = try XCTUnwrap(joined.profiles.first { $0.id == "seed" }).resourceIDs
        let scopedIntranet = try XCTUnwrap(mapping?["intranet"])
        XCTAssertNotEqual(scopedIntranet, "intranet", "the collision must scope the preset rule")
        XCTAssertEqual(joined.snapshot().ruleSets.first { $0.id == scopedIntranet }?.domains,
                       ["example.com", "shop.example"])
        let updated = try ProfileLibraryMigration.addingMobileSeed(
            try phoneSeed(), named: "心动", id: "seed", to: joined,
            ruleSetHistory: ["intranet": [ShippedRuleContent(domains: ["example.com", "shop.example"], cidrs: [])]])
        XCTAssertEqual(updated.snapshot().ruleSets.first { $0.id == scopedIntranet }?.domains, ["example.com"])
        XCTAssertEqual(updated.snapshot().ruleSets.first { $0.id == "intranet" }, userRule)
    }

    /// The next revision puts a new direct rule first in "在国外" and records the routing it shipped before.
    private func reroutedPhoneSeed() throws -> (Profile, [String: [ShippedScenarioRouting]]) {
        var seed = try phoneSeed()
        let overseas = try XCTUnwrap(seed.scenarios.firstIndex { $0.id == "overseas" })
        let shipped = try XCTUnwrap(ShippedScenarioRouting(seed.scenarios[overseas]))
        seed.ruleSets.append(RuleSet(id: "product", name: "产品", type: "manual", domains: ["product.example"]))
        seed.scenarios[overseas].bindings.insert(RuleBinding(ruleSetID: "product", lineID: "direct"), at: 0)
        return (seed, ["overseas": [shipped]])
    }

    func testReroutedScenarioFollowsThePresetOnlyWhileUntouched() throws {
        let created = try XCTUnwrap(ProfileLibraryMigration.seedLibrary(SeedProfile(name: "心动", text: "v2"), id: "seed") { _, _ in
            try self.phoneSeed()
        })
        var renamed = created
        let index = try XCTUnwrap(renamed.scenarios.firstIndex { $0.id == "overseas" })
        renamed.scenarios[index].name = "出差"
        renamed.scenarios[index].iconOverride = "travel"
        renamed = try renamed.validated()
        let (current, history) = try reroutedPhoneSeed()
        let updated = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: renamed,
                                                                   scenarioHistory: history)
        let overseas = try XCTUnwrap(updated.scenarios.first { $0.id == "overseas" })
        XCTAssertEqual(overseas.bindings.map(\.ruleSetID), ["product", "lan", "intranet", "cn"])
        XCTAssertEqual(overseas.name, "出差")
        XCTAssertEqual(overseas.iconOverride, "travel")
        XCTAssertEqual(updated.scenarios.first { $0.id == "domestic" }?.bindings.map(\.ruleSetID), ["intranet", "lan", "cn"])
        XCTAssertEqual(try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: updated,
                                                                    scenarioHistory: history).snapshot(),
                       updated.snapshot(), "applying the same revision again changes nothing")
        // Without the history an existing Scenario keeps its routing, as before.
        let unchanged = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: renamed)
        XCTAssertEqual(unchanged.scenarios.first { $0.id == "overseas" }?.bindings.map(\.ruleSetID), ["lan", "intranet", "cn"])

        var edited = created
        edited.scenarios[index].defaultLineID = "vpn"
        edited = try edited.validated()
        let kept = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: edited,
                                                                scenarioHistory: history)
        let mine = try XCTUnwrap(kept.scenarios.first { $0.id == "overseas" })
        XCTAssertEqual(mine.defaultLineID, "vpn")
        XCTAssertEqual(mine.bindings.map(\.ruleSetID), ["lan", "intranet", "cn"])
    }

    func testScenarioHistoryFollowsTheImportedAndScopedIDs() throws {
        let directory = try temporaryHome()
        let history = #""scenario_history":{"overseas":[{"default_line_id":"direct","bindings":[{"rule_set_id":"intranet","line_id":"vpn"}]}]}"#
        let text = #"{"format":"xdial-mobile-seed","schema_version":1,"revision":3,"#.appending(history)
            + #","profile":{"lines":[{"id":"direct","type":"direct"},{"id":"vpn","type":"vpn"}],"rule_sets":[{"id":"intranet","type":"manual"}],"scenarios":[{"id":"office"},{"id":"overseas"}]}}"#
        try Data(text.utf8).write(to: directory.appendingPathComponent("心动.json"))
        let source = try XCTUnwrap(SeedProfile.load(directory: directory))
        var imported = Profile()
        imported.lines = [Line(id: "line-a", name: "直连", type: "direct"), Line(id: "line-b", name: "VPN", type: "vpn")]
        imported.ruleSets = [RuleSet(id: "rule-a", name: "公司内网", type: "manual")]
        imported.scenarios = [Scenario(id: "scene-a", name: "在公司"), Scenario(id: "scene-b", name: "在国外")]
        XCTAssertEqual(source.scenarioHistory(in: imported), ["scene-b": [ShippedScenarioRouting(
            defaultLineID: "line-a", bindings: [.init(ruleSetID: "rule-a", lineID: "line-b")])]])
        for bad in [#""scenario_history":{"gone":[{"default_line_id":"direct"}]}"#,
                    #""scenario_history":{"overseas":[{"default_line_id":"gone"}]}"#,
                    #""scenario_history":{"overseas":[{"default_line_id":"direct","name":"x"}]}"#,
                    #""scenario_history":{"overseas":[{"default_line_id":"direct","bindings":[{"rule_set_id":"gone","line_id":"vpn"}]}]}"#,
                    #""scenario_history":{"overseas":"x"}"#] {
            try Data(text.replacingOccurrences(of: history, with: bad).utf8).write(to: directory.appendingPathComponent("心动.json"))
            XCTAssertThrowsError(try SeedProfile.load(directory: directory), bad)
        }

        // Beside the user's own Profile the seed's IDs are scoped; the history follows them.
        var userLibrary = try ProfileLibraryMigration.starterLibrary()
        userLibrary.profiles[0].profile.ruleSets.append(RuleSet(id: "intranet", name: "My rule", type: "manual"))
        userLibrary.scenarios.append(Scenario(id: "overseas", name: "Mine", defaultLineID: "direct"))
        userLibrary.activeScenarioID = "overseas"
        userLibrary = try userLibrary.validated()
        let joined = try ProfileLibraryMigration.merging(try phoneSeed(), named: "心动", id: "seed", into: userLibrary).validated()
        let mapping = try XCTUnwrap(joined.profiles.first { $0.id == "seed" }?.resourceIDs)
        let scopedOverseas = try XCTUnwrap(mapping["overseas"])
        XCTAssertNotEqual(scopedOverseas, "overseas", "the collision must scope the preset Scenario")
        let (current, routing) = try reroutedPhoneSeed()
        let updated = try ProfileLibraryMigration.addingMobileSeed(current, named: "心动", id: "seed", to: joined,
                                                                   scenarioHistory: routing)
        let scoped = try XCTUnwrap(updated.scenarios.first { $0.id == scopedOverseas })
        XCTAssertEqual(scoped.bindings.map(\.ruleSetID),
                       ["product"] + ["lan", "intranet", "cn"].map { mapping[$0] ?? $0 })
        XCTAssertEqual(updated.scenarios.first { $0.id == "overseas" }?.bindings, [])
    }
}
