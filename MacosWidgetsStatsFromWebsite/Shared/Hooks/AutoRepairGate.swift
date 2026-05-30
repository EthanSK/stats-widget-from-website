//
//  AutoRepairGate.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Pure, testable decision logic for whether the built-in "Auto-repair via
//  Claude" hook (which RE-IDENTIFIES the scraped element via a Claude Code
//  session) should be allowed to fire for a given failed scrape.
//
//  WHY this exists as a standalone, dependency-free helper:
//    The real gate runs inside BackgroundScheduler.fireScrapeLifecycleHooks(),
//    which is a private instance method that touches AppGroupStore, the
//    HookExecutor, the widget reload coalescer, etc. — none of which can be
//    exercised cleanly in a unit test. Extracting the *pure* decision (given a
//    persisted TrackerReading, should the auto-repair agent run?) lets us pin
//    the anti-false-positive behaviour with a fast, deterministic test, and
//    lets the scheduler stay a thin caller.
//

import Foundation

enum AutoRepairGate {
    /// Minimum number of consecutive failures before the auto-repair agent is
    /// even considered. Matches the `notifyBrokenTracker` gate in
    /// BackgroundScheduler.handlePostRecord and the defensive gate in
    /// auto-repair-tracker.sh, so the macOS notification and the agent spawn
    /// happen at the SAME threshold (consistency = fewer surprises).
    static let minConsecutiveFailures = 3

    /// Decides whether the built-in auto-repair re-identify agent should fire.
    ///
    /// Ethan voice 4417 (2026-05-30): the agent was firing "all the time" for
    /// the WRONG reasons. "It doesn't need to re-identify, it's just lagging
    /// for some other reason — the element itself doesn't really change. It
    /// should only re-identify with the agent if the element couldn't be found
    /// specifically." This function encodes that as the DEFAULT: the agent
    /// fires ONLY when ALL of the following hold:
    ///
    ///   1. KIND — the failure is a GENUINE `.selectorNotFound`. Every other
    ///      kind (browserChallenge / loginRequired / pageTimeout / staleSuccess
    ///      / other) means the element didn't actually disappear, so
    ///      re-identifying it is pointless churn → no fire.
    ///
    ///   2. ANTI-MISCLASSIFICATION — a "selector did not match" string from a
    ///      page that was still loading / blank / mid-challenge is NOT a real
    ///      selectorNotFound. By the time a reading reaches this gate, the
    ///      scraper (ChromeCDPScraper.finishSelectorFailure, v0.21.37) has
    ///      already DOWNGRADED such non-rendered pages to the transient
    ///      browserChallenge kind, so they classify as `.browserChallenge`
    ///      here and fail check (1). That scraper-side downgrade + this kind
    ///      check form the two-layer false-positive defence.
    ///
    ///   3. SUSTAINED — at least `minConsecutiveFailures` (3) consecutive
    ///      failures, so a one-off lag/blip never triggers it. Note that
    ///      transient failures (browserChallenge) RESET the consecutive counter
    ///      to 0 in AppGroupStore.recordFailure, so an intermittent challenge
    ///      page can't silently accumulate toward this threshold.
    ///
    /// Returns false for an `.ok` reading (no failure ⇒ nothing to repair).
    static func shouldFireAutoRepair(reading: TrackerReading) -> Bool {
        // (3) sustained
        let failureCount = reading.consecutiveFailureCount ?? 0
        guard failureCount >= minConsecutiveFailures else {
            return false
        }

        // (1) + (2) genuine, non-misclassified selectorNotFound
        guard let kind = TrackerFailureKind.classify(reading: reading) else {
            return false  // .ok reading
        }
        if case .selectorNotFound = kind {
            return true
        }
        return false
    }
}
