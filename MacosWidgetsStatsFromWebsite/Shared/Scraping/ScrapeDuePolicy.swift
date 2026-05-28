//
//  ScrapeDuePolicy.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Decides whether a tracker is due for a fresh scrape based on its
//  configured `refreshIntervalSec` and the timestamp of the most recent
//  attempt (success or failure). Shared between the in-app
//  BackgroundScheduler and the CLI's `scrape-all --due-only` mode used by
//  the LaunchAgent (v0.19.0+).
//
//  Rate-limiting on the ATTEMPT timestamp (not just the success timestamp)
//  is important because a broken tracker keeps `lastUpdatedAt` frozen at
//  its last-good value forever — without `lastAttemptedAt` gating, the
//  LaunchAgent would retry a 404 every tick.
//

import Foundation

enum ScrapeDuePolicy {
    /// Hard floor on retry cadence — even if the user configured a very
    /// short interval, we never poll the same tracker more frequently than
    /// every 60 seconds. Mirrors the floor used by `BackgroundScheduler`.
    static let minimumIntervalSec: TimeInterval = 60

    /// Returns true when a fresh scrape attempt should be initiated for
    /// the tracker. The caller is responsible for providing the current
    /// reading; if no reading has ever been recorded the tracker is
    /// considered immediately due (no rate-limit yet to honour).
    static func isDue(
        tracker: Tracker,
        reading: TrackerReading?,
        now: Date = Date()
    ) -> Bool {
        guard let reading else {
            return true
        }

        let interval = max(minimumIntervalSec, TimeInterval(tracker.effectiveRefreshIntervalSec))

        // Prefer lastAttemptedAt — that's the gate we need so failures don't
        // hammer every tick. Fall back to lastUpdatedAt for readings written
        // by pre-lastAttemptedAt builds, and to "never" if both are missing.
        let lastAttempt = reading.lastAttemptedAt ?? reading.lastUpdatedAt
        guard let lastAttempt else {
            return true
        }

        return now.timeIntervalSince(lastAttempt) >= interval
    }
}
