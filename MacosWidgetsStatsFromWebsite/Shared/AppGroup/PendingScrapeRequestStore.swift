//
//  PendingScrapeRequestStore.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Cross-process pending scrape request store.
//
//  The widget extension lives in a separate sandboxed process and cannot
//  directly invoke `BackgroundScheduler.triggerScrapeNow` on the main app.
//  Instead, the widget's `RefreshTrackerIntent` writes a small JSON file
//  into the shared App Group container; the main app watches that
//  directory and drains pending requests via the scheduler. This file is
//  the read/write layer shared between both processes.
//

import Foundation

/// Single pending refresh request written by the widget extension and read
/// by the main app. One file per request so the watcher can drain N
/// concurrent presses without worrying about read-modify-write conflicts.
struct PendingScrapeRequest: Codable, Equatable {
    /// Tracker the user tapped to refresh, encoded as UUID string for
    /// JSON portability.
    ///
    /// Special sentinel value `PendingScrapeRequest.reloadTimelinesSentinel`
    /// (a single dunder string, not a UUID) signals "the configuration was
    /// changed from a separate process (e.g. the CLI stdio MCP server) and
    /// the running main app should call WidgetCenter.shared.reloadAllTimelines
    /// to pick up the change." Used by the MCP `reload_widget_timelines`
    /// tool — it's the only cross-process surface that can ask the running
    /// main app (which holds the WidgetCenter handle) to refresh.
    let trackerID: String
    /// ISO8601 timestamp the widget wrote the request. Used for ordering
    /// + stale-request cleanup if the main app was off for an extended
    /// period.
    let requestedAt: Date

    /// Sentinel trackerID that BackgroundScheduler interprets as
    /// "reloadAllTimelines now" rather than "scrape this tracker." Never
    /// a valid UUID, so legitimate tracker IDs can never collide.
    static let reloadTimelinesSentinel = "__reload_widget_timelines__"
}

enum PendingScrapeRequestStore {
    /// Subdirectory name inside the App Group container holding one JSON
    /// file per pending request. Created on demand.
    private static let directoryName = "pending-scrape-requests"
    /// Requests older than this are ignored on drain — prevents an
    /// avalanche of stale presses (e.g. user spam-tapped while the app
    /// was off for a day) from kicking off a massive scrape burst.
    private static let maxRequestAge: TimeInterval = 60 * 60 * 24

    enum StoreError: Error {
        case appGroupUnavailable
    }

    /// Resolved App Group directory holding pending request files. Returns
    /// nil if the App Group container is unavailable (which shouldn't
    /// happen in production since both the widget extension and main app
    /// declare the same group entitlement, but the widget runs sandboxed
    /// so we treat it defensively).
    static func directoryURL() -> URL? {
        guard let containerURL = AppGroupPaths.sharedContainerURL() else {
            return nil
        }

        return containerURL.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Ensures the pending-request directory exists. Safe to call from
    /// either process at any time — uses `withIntermediateDirectories:
    /// true`.
    @discardableResult
    static func ensureDirectoryExists() -> URL? {
        guard let url = directoryURL() else {
            return nil
        }

        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            // Directory may already exist or container may be transiently
            // unavailable; callers can re-check existence below.
        }
        return url
    }

    /// Writes a pending scrape request file for the given tracker. Used
    /// from the widget extension's `RefreshTrackerIntent.perform()`.
    ///
    /// Performs an atomic temp-file + rename so the watcher in the main
    /// app never sees a half-written file. Throws if the App Group
    /// container is unavailable.
    static func requestScrape(trackerID: String) throws {
        guard let directory = ensureDirectoryExists() else {
            throw StoreError.appGroupUnavailable
        }

        let request = PendingScrapeRequest(trackerID: trackerID, requestedAt: Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)

        // One file per request so concurrent writes (e.g. user mashes the
        // refresh button on two different widgets at once) don't clobber
        // each other. UUID-named to avoid filesystem collisions.
        let fileURL = directory.appendingPathComponent("\(UUID().uuidString).json", isDirectory: false)
        try data.write(to: fileURL, options: .atomic)

        ActivityLogger.log("pending-scrape", "request written", metadata: [
            "trackerID": trackerID,
            "path": fileURL.lastPathComponent
        ])
    }

    /// Loads all pending requests currently on disk. Stale requests
    /// (older than `maxRequestAge`) are removed and not returned.
    static func loadPending() -> [(fileURL: URL, request: PendingScrapeRequest)] {
        guard let directory = directoryURL(),
              FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }

        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let now = Date()
        var results: [(URL, PendingScrapeRequest)] = []
        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: fileURL),
                  let request = try? decoder.decode(PendingScrapeRequest.self, from: data) else {
                // Corrupt / partially-written file — remove so it doesn't
                // jam the watcher loop indefinitely.
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            if now.timeIntervalSince(request.requestedAt) > maxRequestAge {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }

            results.append((fileURL, request))
        }

        // Stable ordering by request time so older presses get serviced
        // first.
        results.sort { $0.1.requestedAt < $1.1.requestedAt }
        return results
    }

    /// Removes a single pending request file after the main app's
    /// scheduler has dispatched its scrape. Best-effort — failures are
    /// non-fatal because stale files will be cleaned up by the age check
    /// or overwritten by a new request anyway.
    static func clearPending(fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
