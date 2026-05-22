//
//  AppNavigationEvents.swift
//  MacosWidgetsStatsFromWebsite
//
//  Lightweight routing for notification-driven tracker editing.
//

import Foundation

enum AppNavigationEvents {
    static let openTrackerSettingsNotification = Notification.Name("AppNavigationEvents.openTrackerSettings")
    /// Posted when the main app receives a deep link / URL nudge from the
    /// widget extension asking it to drain pending scrape requests. The
    /// app scene observes this and forwards to
    /// `BackgroundScheduler.drainPendingScrapeRequests()`. This is the
    /// fallback path for "user pressed refresh while the main app was
    /// not running" — the watcher inside BackgroundScheduler picks up
    /// new files immediately while the app IS running.
    static let drainPendingScrapeRequestsNotification = Notification.Name("AppNavigationEvents.drainPendingScrapeRequests")
    private static var pendingTrackerID: UUID?
    /// One-shot flag captured alongside `pendingTrackerID`. When set, the
    /// editor that opens for the queued tracker auto-fires its Identify
    /// Element flow on appearance — this is the wire-up for the
    /// "tap login-required row → re-identify" action on the trackers
    /// list page (v0.21.6). It clears after consumption so a later edit
    /// click doesn't surprise the user by reopening Chromium.
    private static var pendingShouldStartIdentify: Bool = false

    static func openTrackerSettings(trackerID: UUID, startIdentify: Bool = false) {
        pendingTrackerID = trackerID
        pendingShouldStartIdentify = startIdentify
        NotificationCenter.default.post(
            name: openTrackerSettingsNotification,
            object: nil,
            userInfo: [
                "trackerID": trackerID,
                "startIdentify": startIdentify
            ]
        )
    }

    static func consumePendingTrackerID() -> UUID? {
        let trackerID = pendingTrackerID
        pendingTrackerID = nil
        return trackerID
    }

    static func consumePendingShouldStartIdentify() -> Bool {
        let flag = pendingShouldStartIdentify
        pendingShouldStartIdentify = false
        return flag
    }
}
