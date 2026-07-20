//
//  BrowserAccountTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Migration, isolation, and persistence coverage for browser accounts.
//

import XCTest

final class BrowserAccountTests: XCTestCase {
    private var testContainerURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("browser-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testContainerURL, withIntermediateDirectories: true)
        setenv("MACOS_WIDGETS_STATS_TEST_CONTAINER", testContainerURL.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MACOS_WIDGETS_STATS_TEST_CONTAINER")
        if let testContainerURL {
            try? FileManager.default.removeItem(at: testContainerURL)
        }
        try super.tearDownWithError()
    }

    func testLegacyConfigurationMigratesToDefaultBrowserAccount() throws {
        let tracker = Tracker(name: "Legacy", url: "https://example.com", selector: "h1")
        let configuration = AppConfiguration(
            schemaVersion: 5,
            trackers: [tracker],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any]
        )
        object["schemaVersion"] = 5
        object.removeValue(forKey: "browserAccounts")

        let decoded = try JSONDecoder().decode(
            AppConfiguration.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.browserAccounts, [.defaultAccount])
        XCTAssertEqual(decoded.trackers.first?.browserProfile, Tracker.defaultBrowserProfile)
    }

    func testLegacyNonDefaultTrackerProfileIsRecoveredWithoutReassignment() throws {
        let profileID = "existing-work-account"
        let tracker = Tracker(
            name: "Work",
            url: "https://example.com",
            browserProfile: profileID,
            selector: "h1"
        )
        let configuration = AppConfiguration(
            schemaVersion: 5,
            trackers: [tracker],
            browserAccounts: [],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )

        XCTAssertEqual(configuration.trackers.first?.browserProfile, profileID)
        XCTAssertEqual(configuration.browserAccounts.map(\.id), [Tracker.defaultBrowserProfile, profileID])
    }

    func testGeneratedAccountsHaveUniqueStorageIdentifiersAndPorts() throws {
        var accounts: [BrowserAccount] = [.defaultAccount]
        for index in 1...20 {
            accounts.append(try BrowserAccountCatalog.makeAccount(named: "Account \(index)", existing: accounts))
        }

        XCTAssertEqual(Set(accounts.map(\.id)).count, accounts.count)
        XCTAssertEqual(Set(accounts.map { BrowserAccountCatalog.derivedCDPPort(for: $0.id) }).count, accounts.count)
        XCTAssertEqual(
            ChromeBrowserProfile.shared.configuration(profileName: Tracker.defaultBrowserProfile).cdpPort,
            BrowserAccountCatalog.derivedCDPPort(for: Tracker.defaultBrowserProfile)
        )
    }

    func testDifferentAccountsUseDifferentPortsAndDataDirectoriesForTheSameURL() throws {
        let second = try BrowserAccountCatalog.makeAccount(
            named: "Second Login",
            existing: [.defaultAccount]
        )
        let defaultConfiguration = ChromeBrowserProfile.shared.configuration(
            profileName: BrowserAccount.defaultAccount.id
        )
        let secondConfiguration = ChromeBrowserProfile.shared.configuration(profileName: second.id)
        let sharedURL = "https://example.com/dashboard"
        let trackers = [
            Tracker(name: "Default stat", url: sharedURL, browserProfile: BrowserAccount.defaultAccount.id, selector: "#value"),
            Tracker(name: "Second stat", url: sharedURL, browserProfile: second.id, selector: "#value")
        ]

        XCTAssertEqual(Set(trackers.map(\.url)), [sharedURL])
        XCTAssertNotEqual(defaultConfiguration.cdpPort, secondConfiguration.cdpPort)
        XCTAssertNotEqual(defaultConfiguration.userDataDirectory, secondConfiguration.userDataDirectory)
        XCTAssertTrue(defaultConfiguration.userDataDirectory.path.contains(BrowserAccount.defaultAccount.id))
        XCTAssertTrue(secondConfiguration.userDataDirectory.path.contains(second.id))
    }

    func testLegacyCDPPortOverrideOnlyAppliesToDefaultAccount() throws {
        let environmentKey = "MACOS_WIDGETS_STATS_CDP_PORT"
        let previousValue = getenv(environmentKey).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(environmentKey, previousValue, 1)
            } else {
                unsetenv(environmentKey)
            }
        }

        setenv(environmentKey, "23456", 1)
        let second = try BrowserAccountCatalog.makeAccount(
            named: "Second Login",
            existing: [.defaultAccount]
        )

        XCTAssertEqual(
            ChromeBrowserProfile.shared.configuration(
                profileName: BrowserAccount.defaultAccount.id
            ).cdpPort,
            23_456
        )
        XCTAssertEqual(
            ChromeBrowserProfile.shared.configuration(profileName: second.id).cdpPort,
            BrowserAccountCatalog.derivedCDPPort(for: second.id)
        )
        XCTAssertNotEqual(
            ChromeBrowserProfile.shared.configuration(profileName: second.id).cdpPort,
            23_456
        )
    }

    func testCurrentSchemaRoundTripPreservesAccountsAndTrackerAssignments() throws {
        let account = try BrowserAccountCatalog.makeAccount(named: "Work", existing: [.defaultAccount])
        let tracker = Tracker(
            name: "Work stat",
            url: "https://example.com/dashboard",
            browserProfile: account.id,
            selector: "#value"
        )
        let original = AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: [tracker],
            browserAccounts: [.defaultAccount, account],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppConfiguration.self, from: encoder.encode(original))

        XCTAssertEqual(decoded.schemaVersion, currentSchemaVersion)
        XCTAssertEqual(decoded.browserAccounts, original.browserAccounts)
        XCTAssertEqual(decoded.trackers.first?.browserProfile, account.id)
    }

    func testAccountCatalogPersistsWithoutAnyTrackers() throws {
        let account = try BrowserAccountCatalog.makeAccount(named: "Second Login", existing: [.defaultAccount])
        let configuration = AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: [],
            browserAccounts: [.defaultAccount, account],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )

        try AppGroupStore.save(configuration: configuration)
        let loaded = AppGroupStore.loadSharedConfiguration()

        XCTAssertEqual(loaded.browserAccounts.map(\.id), [Tracker.defaultBrowserProfile, account.id])
        XCTAssertTrue(loaded.trackers.isEmpty)
    }

    func testCustomizedDefaultAccountPersistsWithoutAnyTrackers() throws {
        let customizedDefault = BrowserAccount(
            id: Tracker.defaultBrowserProfile,
            name: "Personal",
            colorHex: "#F59E0B"
        )
        let configuration = AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: [],
            browserAccounts: [customizedDefault],
            widgetConfigurations: [],
            preferences: AppPreferences()
        )

        try AppGroupStore.save(configuration: configuration)
        let loaded = AppGroupStore.loadSharedConfiguration()

        XCTAssertEqual(loaded.browserAccounts, [customizedDefault])
    }

    func testDuplicateAccountNamesAreRejectedCaseInsensitively() throws {
        let existing = BrowserAccount(
            id: "browser-account-existing",
            name: "Work",
            colorHex: "#14B8A6"
        )

        XCTAssertThrowsError(
            try BrowserAccountCatalog.makeAccount(named: "  work  ", existing: [.defaultAccount, existing])
        ) { error in
            XCTAssertEqual(error as? BrowserAccountCatalogError, .duplicateName("work"))
        }
    }

    func testColourValuesAreCanonicalAndInvalidValuesAreRejected() throws {
        XCTAssertEqual(BrowserAccountCatalog.normalizedColorHex("4c8dff"), "#4C8DFF")
        XCTAssertEqual(BrowserAccountCatalog.normalizedColorHex(" #14b8a6 "), "#14B8A6")
        XCTAssertNil(BrowserAccountCatalog.normalizedColorHex("-12345"))
        XCTAssertNil(BrowserAccountCatalog.normalizedColorHex("#12345G"))

        let store = AppGroupStore()
        XCTAssertThrowsError(try store.addBrowserAccount(named: "Invalid", colorHex: "#12345G")) { error in
            XCTAssertEqual(error as? BrowserAccountCatalogError, .invalidColor("#12345G"))
        }
        XCTAssertEqual(store.browserAccounts, [.defaultAccount])
    }

    func testDeletingAccountIsBlockedWhileTrackerUsesIt() throws {
        let store = AppGroupStore()
        let account = try store.addBrowserAccount(named: "Account Two")
        store.addTracker(Tracker(
            name: "Second account tracker",
            url: "https://example.com",
            browserProfile: account.id,
            selector: "h1"
        ))

        XCTAssertThrowsError(try store.deleteBrowserAccount(id: account.id)) { error in
            XCTAssertEqual(
                error as? BrowserAccountCatalogError,
                .accountInUse(name: account.name, trackerCount: 1)
            )
        }
        XCTAssertTrue(store.browserAccounts.contains(where: { $0.id == account.id }))
    }

    func testDefaultAccountCannotBeDeleted() throws {
        let store = AppGroupStore()

        XCTAssertThrowsError(try store.deleteBrowserAccount(id: Tracker.defaultBrowserProfile)) { error in
            XCTAssertEqual(error as? BrowserAccountCatalogError, .cannotDeleteDefault)
        }
        XCTAssertEqual(store.browserAccounts, [.defaultAccount])
    }

    func testAccountCanBeDeletedAfterItsTrackerMovesElsewhere() throws {
        let store = AppGroupStore()
        let account = try store.addBrowserAccount(named: "Temporary")
        var tracker = Tracker(
            name: "Movable tracker",
            url: "https://example.com",
            browserProfile: account.id,
            selector: "h1"
        )
        store.addTracker(tracker)

        tracker.browserProfile = Tracker.defaultBrowserProfile
        store.updateTracker(tracker)
        try store.deleteBrowserAccount(id: account.id)

        XCTAssertFalse(store.browserAccounts.contains(where: { $0.id == account.id }))
        XCTAssertEqual(store.trackers.first(where: { $0.id == tracker.id })?.browserProfile, Tracker.defaultBrowserProfile)
        XCTAssertFalse(AppGroupStore.loadSharedConfiguration().browserAccounts.contains(where: { $0.id == account.id }))
    }

    func testRenamingAccountKeepsTrackerStorageReferenceStable() throws {
        let store = AppGroupStore()
        let account = try store.addBrowserAccount(named: "Before")
        let tracker = Tracker(
            name: "Tracker",
            url: "https://example.com",
            browserProfile: account.id,
            selector: "h1"
        )
        store.addTracker(tracker)

        try store.updateBrowserAccount(id: account.id, name: "After", colorHex: "#14B8A6")

        XCTAssertEqual(store.browserAccounts.first(where: { $0.id == account.id })?.name, "After")
        XCTAssertEqual(store.trackers.first(where: { $0.id == tracker.id })?.browserProfile, account.id)
    }
}
