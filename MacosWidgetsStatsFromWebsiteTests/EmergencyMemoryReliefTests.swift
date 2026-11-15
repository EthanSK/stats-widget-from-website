import Darwin
import Foundation
import XCTest
import notify

final class EmergencyMemoryReliefTests: XCTestCase {
    func testEmergencyInvalidatesQueuedWorkAndRecoveryAllowsFreshWork() throws {
        let name = "com.ethansk.stats-widget.test.memory.\(UUID().uuidString)"
        var publisher: Int32 = 0
        XCTAssertEqual(notify_register_check(name, &publisher), UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(publisher) }
        XCTAssertEqual(notify_set_state(publisher, 0), UInt32(NOTIFY_STATUS_OK))
        let paused = expectation(description: "browser cleanup requested")
        let monitor = EmergencyMemoryRelief(notificationName: name) { paused.fulfill() }
        let oldPermit = try XCTUnwrap(monitor.permit())

        notify_set_state(publisher, 1)
        notify_post(name)
        wait(for: [paused], timeout: 3)
        XCTAssertNil(monitor.permit())
        XCTAssertFalse(monitor.isValid(oldPermit))
        XCTAssertThrowsError(try monitor.withLaunchPermit { XCTFail("must not launch") })

        notify_set_state(publisher, 0)
        notify_post(name)
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            monitor.permit() != nil
        }, object: nil)
        wait(for: [recovered], timeout: 3)
        XCTAssertFalse(monitor.isValid(oldPermit), "old completions stay cancelled after recovery")
        let freshPermit = try XCTUnwrap(monitor.permit())
        XCTAssertTrue(monitor.isValid(freshPermit))
        XCTAssertEqual(try monitor.withLaunchPermit { 42 }, 42)
    }

    func testHostStartingDuringEmergencyReadsLatchBeforeFirstScrape() {
        let name = "com.ethansk.stats-widget.test.memory.\(UUID().uuidString)"
        var publisher: Int32 = 0
        XCTAssertEqual(notify_register_check(name, &publisher), UInt32(NOTIFY_STATUS_OK))
        defer { notify_cancel(publisher) }
        notify_set_state(publisher, 1)
        var cleanups = 0
        let monitor = EmergencyMemoryRelief(notificationName: name) { cleanups += 1 }
        XCTAssertNil(monitor.permit())
        XCTAssertEqual(cleanups, 1)
    }
}
