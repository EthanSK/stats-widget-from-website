//
//  DueScrapePlanner.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Pure due-candidate selection shared by the app scheduler and CLI.
//

import Foundation

enum DueScrapePlanner {
    struct Plan {
        var candidates: [Tracker]
        var configuredCount: Int
        var skippedIncompleteCount: Int
    }

    static func plan(
        configuration: AppConfiguration,
        readings: [String: TrackerReading],
        now: Date = Date(),
        force: Bool
    ) -> Plan {
        let scrapeReadyTrackers = configuration.trackers.filter(\.isScrapeReady)
        let candidates: [Tracker]
        if force {
            candidates = scrapeReadyTrackers
        } else {
            candidates = scrapeReadyTrackers.filter { tracker in
                let reading = readings[tracker.id.uuidString]
                return ScrapeDuePolicy.isDue(tracker: tracker, reading: reading, now: now)
            }
        }

        return Plan(
            candidates: candidates,
            configuredCount: configuration.trackers.count,
            skippedIncompleteCount: configuration.trackers.count - scrapeReadyTrackers.count
        )
    }
}
