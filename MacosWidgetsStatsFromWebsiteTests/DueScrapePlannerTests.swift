//
//  DueScrapePlannerTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Guards for shared due-candidate selection used by the app watchdog.
//

import XCTest

final class DueScrapePlannerTests: XCTestCase {
    func testMissingReadingIsImmediatelyDue() {
        let tracker = readyTracker(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
        let plan = DueScrapePlanner.plan(
            configuration: configuration(trackers: [tracker]),
            readings: [:],
            now: baseDate,
            force: false
        )

        XCTAssertEqual(plan.candidates.map(\.id), [tracker.id])
        XCTAssertEqual(plan.configuredCount, 1)
        XCTAssertEqual(plan.skippedIncompleteCount, 0)
    }

    func testProtectedDomainUsesFifteenMinuteEffectiveCadence() {
        let tracker = readyTracker(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            url: "https://claude.ai/settings/usage",
            refreshIntervalSec: 180
        )
        let readings = [
            tracker.id.uuidString: reading(at: baseDate)
        ]

        let early = DueScrapePlanner.plan(
            configuration: configuration(trackers: [tracker]),
            readings: readings,
            now: baseDate.addingTimeInterval(899),
            force: false
        )
        let due = DueScrapePlanner.plan(
            configuration: configuration(trackers: [tracker]),
            readings: readings,
            now: baseDate.addingTimeInterval(900),
            force: false
        )

        XCTAssertTrue(early.candidates.isEmpty)
        XCTAssertEqual(due.candidates.map(\.id), [tracker.id])
    }

    func testLastAttemptedAtGatesRetriesEvenWhenLastSuccessIsOld() {
        let tracker = readyTracker(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            refreshIntervalSec: 600
        )
        let readings = [
            tracker.id.uuidString: TrackerReading(
                lastUpdatedAt: baseDate.addingTimeInterval(-3600),
                lastAttemptedAt: baseDate.addingTimeInterval(-30),
                status: .broken,
                consecutiveFailureCount: 1
            )
        ]

        let plan = DueScrapePlanner.plan(
            configuration: configuration(trackers: [tracker]),
            readings: readings,
            now: baseDate,
            force: false
        )

        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testForceIncludesReadyTrackersButStillSkipsIncompleteTrackers() {
        let ready = readyTracker(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!)
        let incomplete = Tracker(
            id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            name: "Incomplete",
            url: "https://example.com",
            selector: " \n\t "
        )
        let readings = [
            ready.id.uuidString: reading(at: baseDate)
        ]

        let plan = DueScrapePlanner.plan(
            configuration: configuration(trackers: [ready, incomplete]),
            readings: readings,
            now: baseDate.addingTimeInterval(1),
            force: true
        )

        XCTAssertEqual(plan.candidates.map(\.id), [ready.id])
        XCTAssertEqual(plan.configuredCount, 2)
        XCTAssertEqual(plan.skippedIncompleteCount, 1)
    }

    private var baseDate: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func configuration(trackers: [Tracker]) -> AppConfiguration {
        AppConfiguration(
            schemaVersion: currentSchemaVersion,
            trackers: trackers,
            widgetConfigurations: [],
            preferences: AppPreferences()
        )
    }

    private func readyTracker(
        id: UUID,
        url: String = "https://example.com",
        refreshIntervalSec: Int = 600
    ) -> Tracker {
        Tracker(
            id: id,
            name: "Ready",
            url: url,
            selector: "h1",
            refreshIntervalSec: refreshIntervalSec
        )
    }

    private func reading(at date: Date) -> TrackerReading {
        TrackerReading(
            currentValue: "10%",
            currentNumeric: 10,
            lastUpdatedAt: date,
            lastAttemptedAt: date,
            status: .ok
        )
    }
}
