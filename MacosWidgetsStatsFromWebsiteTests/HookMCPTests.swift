//
//  HookMCPTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Smoke tests over the AppGroupStore-backed CRUD path that the
//  add_tracker_hook / update_tracker_hook / delete_tracker_hook MCP
//  tools call. We bypass the JSON-RPC parser and invoke the underlying
//  mutateSharedConfiguration directly so the test surface stays small.
//

import XCTest

final class HookMCPTests: XCTestCase {
    private var testContainerURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        testContainerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hook-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testContainerURL, withIntermediateDirectories: true)
        setenv("MACOS_WIDGETS_STATS_TEST_CONTAINER", testContainerURL.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("MACOS_WIDGETS_STATS_TEST_CONTAINER")
        if let url = testContainerURL {
            try? FileManager.default.removeItem(at: url)
        }
        try super.tearDownWithError()
    }

    func testAddingHookAppendsToCorrectList() throws {
        let tracker = Tracker(name: "t", url: "https://example.com", selector: ".x", hooks: TrackerHooks())

        // Seed the store.
        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }

        let newHook = TrackerHook(
            name: "Slack ping",
            trigger: .onSuccess,
            actionKind: .runShellCommand,
            actionPayload: "curl webhook"
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers[0].hooks.onSuccess.append(newHook)
        }

        let stored = AppGroupStore.loadSharedConfiguration().trackers[0]
        XCTAssertEqual(stored.hooks.onSuccess.count, 1)
        XCTAssertEqual(stored.hooks.onSuccess[0].name, "Slack ping")
        XCTAssertEqual(stored.hooks.onFailure.count, 0)
    }

    func testRecordHookTelemetryStampsLastRun() throws {
        let hook = TrackerHook(name: "h", trigger: .onFailure, actionKind: .runShellCommand, actionPayload: "echo")
        var tracker = Tracker(name: "t", url: "https://example.com", selector: ".x", hooks: TrackerHooks(onFailure: [hook]))
        tracker.hooks.onFailure = [hook]

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }

        let lastRun = HookLastRun(
            startedAt: Date(timeIntervalSince1970: 1_715_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_715_000_004),
            status: .ok,
            exitCode: 0,
            detail: nil
        )
        try AppGroupStore.recordHookTelemetry(trackerID: tracker.id, hookID: hook.id, lastRun: lastRun)

        let stored = AppGroupStore.loadSharedConfiguration().trackers[0]
        XCTAssertEqual(stored.hooks.onFailure[0].lastRun?.status, .ok)
        XCTAssertEqual(stored.hooks.onFailure[0].lastRun?.exitCode, 0)
    }

    func testBackfillScaffoldIsIdempotentAndOnlyTouchesEmptyTrackers() throws {
        // One tracker with an empty hooks bag (pre-0.18), another with a user-hook (don't touch).
        var legacy = Tracker(name: "legacy", url: "https://example.com", selector: ".x", hooks: TrackerHooks())
        legacy.hooks = TrackerHooks()
        let usersHook = TrackerHook(name: "user-hook", trigger: .onSuccess, actionKind: .runShellCommand, actionPayload: "x")
        var userOwned = Tracker(name: "user", url: "https://example.com", selector: ".y", hooks: TrackerHooks())
        userOwned.hooks = TrackerHooks(onSuccess: [usersHook])

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers = [legacy, userOwned]
        }

        let firstPass = try AppGroupStore.backfillDefaultHookScaffoldIfNeeded()
        XCTAssertEqual(firstPass, 1, "Only the legacy tracker should have been backfilled.")

        let secondPass = try AppGroupStore.backfillDefaultHookScaffoldIfNeeded()
        XCTAssertEqual(secondPass, 0, "Backfill must be idempotent.")

        let stored = AppGroupStore.loadSharedConfiguration().trackers
        XCTAssertEqual(stored[0].hooks.onFailure.first?.builtInIdentifier, BuiltInHookIdentifier.autoRepair)
        XCTAssertEqual(stored[1].hooks.onSuccess.first?.name, "user-hook")
        XCTAssertEqual(stored[1].hooks.onFailure.count, 0)
    }

    func testSavingEmptyConfigurationBlocksAndBacksUpNonEmptyConfiguration() throws {
        let tracker = Tracker(name: "t", url: "https://example.com", selector: ".x", hooks: TrackerHooks())

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers = [tracker]
        }

        XCTAssertThrowsError(try AppGroupStore.save(configuration: .empty)) { error in
            XCTAssertEqual(error as? AppGroupStoreError, .emptyConfigurationOverwriteBlocked)
        }

        let backups = try FileManager.default.contentsOfDirectory(
            at: testContainerURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("trackers.json.nonempty-before-empty-") }

        XCTAssertEqual(backups.count, 1)
        let restored = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: backups[0]))
        XCTAssertEqual(restored.trackers.map(\.id), [tracker.id])
        XCTAssertEqual(AppGroupStore.loadSharedConfiguration().trackers.map(\.id), [tracker.id])
    }

    func testExplicitEmptyConfigurationOverwriteAllowsUserDelete() throws {
        let tracker = Tracker(name: "t", url: "https://example.com", selector: ".x", hooks: TrackerHooks())

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers = [tracker]
        }

        try AppGroupStore.save(configuration: .empty, allowEmptyOverwrite: true)

        let stored = AppGroupStore.loadSharedConfiguration()
        XCTAssertEqual(stored.trackers.count, 0)
        XCTAssertEqual(stored.widgetConfigurations.count, 0)
    }
}
