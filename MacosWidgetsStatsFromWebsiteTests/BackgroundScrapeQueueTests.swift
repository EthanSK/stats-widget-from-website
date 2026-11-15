// Verifies account checks cannot overlap in round-robin mode, including mode
// changes while checks are in flight. Completions model real browser teardown.

import XCTest

final class BackgroundScrapeQueueTests: XCTestCase {
    func testRoundRobinWaitsForCompletionAndKeepsFIFOOrder() {
        let queue = BackgroundScrapeQueue()
        var started: [String] = []
        var finishes: [() -> Void] = []
        for account in ["first", "second", "first"] {
            queue.enqueue(profileName: account, serialized: true) { finish in
                started.append(account)
                finishes.append(finish)
            }
        }
        XCTAssertEqual(started, ["first"])
        finishes[0]()
        XCTAssertEqual(started, ["first", "second"])
        finishes[0]() // A duplicate teardown callback must not release a sibling.
        XCTAssertEqual(started, ["first", "second"])
        finishes[1]()
        XCTAssertEqual(started, ["first", "second", "first"])
        finishes[2]()
    }

    func testEnablingWaitsForAllExistingParallelChecks() {
        let queue = BackgroundScrapeQueue()
        var finishes: [() -> Void] = []
        for serialized in [false, false, true, false] {
            queue.enqueue(profileName: "account", serialized: serialized) { finishes.append($0) }
        }
        XCTAssertEqual(finishes.count, 2)
        finishes[0]()
        XCTAssertEqual(finishes.count, 2)
        finishes[1]()
        XCTAssertEqual(finishes.count, 3)
        finishes[2]()
        XCTAssertEqual(finishes.count, 4)
        finishes[3]()
    }

    func testSynchronousFailureDoesNotStallTheQueue() {
        let queue = BackgroundScrapeQueue()
        var completions = 0
        for _ in 0..<10 {
            queue.enqueue(profileName: "account", serialized: true) { finish in
                completions += 1
                finish()
            }
        }
        XCTAssertEqual(completions, 10)
    }

    func testExistingPreferencesEnableRoundRobinWithoutLosingSettings() throws {
        let old = Data(#"{"notificationChannels":{"macosNative":false},"snapshotConcurrencyCap":3}"#.utf8)
        let preferences = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertTrue(preferences.singleBackgroundBrowserMode)
        XCTAssertFalse(preferences.notificationChannels.macosNative)
        XCTAssertEqual(preferences.snapshotConcurrencyCap, 3)
    }

    func testExplicitOptOutSurvivesSavingAndReloading() throws {
        let preferences = AppPreferences(singleBackgroundBrowserMode: false)
        let saved = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(AppPreferences.self, from: saved), preferences)
    }

    func testBrowserTurnLocksAcrossIndependentDescriptorsAndReleasesOnCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("MACOS_WIDGETS_STATS_TEST_CONTAINER", directory.path, 1)
        defer {
            unsetenv("MACOS_WIDGETS_STATS_TEST_CONTAINER")
            try? FileManager.default.removeItem(at: directory)
        }
        var lease: ChromeBrowserProfile.BackgroundBrowserLease? = try .init()
        let descriptor = open(directory.appendingPathComponent(".background-browser.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), -1)
        XCTAssertEqual(errno, EWOULDBLOCK)
        lease = nil
        XCTAssertNil(lease)
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        flock(descriptor, LOCK_UN)
    }

    func testCancelledWorkCannotPrepareAnotherAccountBrowser() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("MACOS_WIDGETS_STATS_TEST_CONTAINER", directory.path, 1)
        defer {
            unsetenv("MACOS_WIDGETS_STATS_TEST_CONTAINER")
            try? FileManager.default.removeItem(at: directory)
        }
        let completed = expectation(description: "cancelled before touching browser accounts")
        ChromeBrowserProfile.shared.prepareSingleBackgroundBrowser(profileName: "cancelled-test", canStart: { false }) { result in
            switch result {
            case .success: XCTFail("cancelled work must not get a browser turn")
            case .failure(let error): XCTAssertTrue(error is CancellationError)
            }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
    }

    func testHandoffWaitsForTheProcessAfterItsReadySignal() throws {
        // Model Chromium closing its CDP connection while profile cleanup is
        // still running. A socket/ready signal alone must not release the turn.
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf ready; exec /bin/sleep 0.2"]
        process.standardOutput = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        XCTAssertEqual(output.fileHandleForReading.readData(ofLength: 5), Data("ready".utf8))
        ChromeBrowserProfile.shared.waitForProcessExit(pids: [process.processIdentifier], timeout: 1.5)
        XCTAssertFalse(process.isRunning, "A closed connection does not mean the browser has exited")
    }
}
