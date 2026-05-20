//
//  RefreshTrackerIntent.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  AppIntent invoked by `Button(intent:)` inside the widget. Triggers an
//  on-demand scrape of the tapped tracker by writing a pending-scrape
//  request into the shared App Group; the main app's BackgroundScheduler
//  watches that directory and drains pending requests.
//
//  Lives in Shared/Intents so both the widget extension and the main
//  app target can reference the same type (the widget calls
//  `Button(intent:)`; the main app's URL handler also resolves trackerID
//  strings against the same store). Both targets include
//  Shared/** in their sources list (see project.yml).
//

import AppIntents
import Foundation
import WidgetKit

struct RefreshTrackerIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh Tracker"
    static var description = IntentDescription("Refreshes the scraped value for a tracker.")

    /// Keep the widget in-place when the user taps refresh — don't open
    /// the main app window over their desktop. The handoff to the main
    /// process happens through the shared App Group file; we only fall
    /// back to launching the app if no other path is available, and
    /// even then it's left to the URL-scheme deep link below.
    static var openAppWhenRun: Bool = false

    /// UUID(s) of the tracker(s) the user tapped, encoded as a String
    /// because AppIntents' `@Parameter` doesn't support `UUID` or
    /// `[String]` directly across the widget/app boundary without extra
    /// plumbing. For single-tracker templates this is one UUID string;
    /// for multi-tracker templates (Dashboard3Up, StatsListWatchlist,
    /// MegaDashboardGrid, DualStatCompare) it's a comma-separated list
    /// so one button refreshes every visible tracker. The main app
    /// drains each ID as a separate scrape, deduped by trackerID.
    @Parameter(title: "Tracker IDs")
    var trackerID: String

    init() {
        self.trackerID = ""
    }

    init(trackerID: String) {
        self.trackerID = trackerID
    }

    init(trackerIDs: [UUID]) {
        self.trackerID = trackerIDs.map(\.uuidString).joined(separator: ",")
    }

    func perform() async throws -> some IntentResult {
        let trimmed = trackerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .result()
        }

        let ids = trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // 1. Write a request file per tracker. If the main app is
        //    running, its DispatchSourceFileSystemObject watcher fires
        //    on the directory change and triggers a scrape immediately.
        for id in ids {
            do {
                try PendingScrapeRequestStore.requestScrape(trackerID: id)
            } catch {
                // Swallow — the URL fallback below is the next line of
                // defence. We don't want to surface a noisy error in the
                // widget UI for a tap-to-refresh.
                ActivityLogger.log("refresh-intent", "request write failed", metadata: [
                    "trackerID": id,
                    "error": "\(error)"
                ])
            }
        }

        // 2. Nudge WidgetKit so any optimistic UI (e.g. a "queued" hint
        //    we add later) refreshes immediately. The actual value swap
        //    happens after the scrape completes; that path already calls
        //    WidgetCenter.shared.reloadTimelines from BackgroundScheduler.
        logWidgetReload(reason: "refresh intent")
        WidgetCenter.shared.reloadTimelines(ofKind: "MacosWidgetsStatsFromWebsite")

        ActivityLogger.log("refresh-intent", "perform", metadata: [
            "trackerIDs": ids.joined(separator: ",")
        ])
        return .result()
    }

    private func logWidgetReload(reason: String) {
        let bundle = Bundle.main
        ActivityLogger.log("widget-reload", "WidgetCenter.reloadTimelines", metadata: [
            "reason": reason,
            "kind": "MacosWidgetsStatsFromWebsite",
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "bundleID": bundle.bundleIdentifier ?? "unknown",
            "bundlePath": bundle.bundleURL.path,
            "version": (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "build": (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        ])
    }
}
