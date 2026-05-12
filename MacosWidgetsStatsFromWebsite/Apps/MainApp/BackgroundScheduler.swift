//
//  BackgroundScheduler.swift
//  MacosWidgetsStatsFromWebsite
//
//  NSBackgroundActivityScheduler wrapper for app-owned scraping.
//

import Foundation
import WidgetKit

final class BackgroundScheduler: ObservableObject {
    /// Posted on the main queue whenever a tracker's reading is written
    /// (scheduled scrape, on-demand row refresh, or recorded failure). UI
    /// surfaces — like the tracker list rows — observe this so they can
    /// re-pull `AppGroupStore.reading(for:)` immediately and surface the new
    /// value without needing the widget-reload roundtrip.
    static let trackerReadingDidChangeNotification = Notification.Name(
        "com.ethansk.macos-widgets-stats-from-website.trackerReadingDidChange"
    )

    /// Tracker IDs currently being scraped on-demand (Scrape Now). Exposed so
    /// list rows / toolbar buttons can show a busy indicator. Published so
    /// SwiftUI observers refresh when the set changes.
    @Published private(set) var inFlightTrackerIDs: Set<UUID> = []

    private let store: AppGroupStore
    private var schedulers: [UUID: NSBackgroundActivityScheduler] = [:]
    private var activeTrackerIDs: Set<UUID> = []
    private var notifiedBrokenTrackerIDs: Set<UUID> = []

    // MARK: - Widget refresh handoff
    //
    // The widget extension (separate sandboxed process) writes pending
    // scrape requests as JSON files under <AppGroup>/pending-scrape-requests/.
    // We watch that directory with a DispatchSourceFileSystemObject so the
    // user gets near-instant feedback after tapping the refresh button in
    // the widget UI. See PendingScrapeRequestStore for the file format.
    private var pendingRequestWatcher: DispatchSourceFileSystemObject?
    private var pendingRequestWatcherFD: Int32 = -1
    private let pendingRequestWatcherQueue = DispatchQueue(
        label: "com.ethansk.macos-widgets-stats-from-website.pending-scrape-watcher"
    )

    init(store: AppGroupStore) {
        self.store = store
        startPendingRequestWatcher()
        // Drain anything written while the app was off (the watcher only
        // fires for changes that happen *after* it's installed).
        drainPendingScrapeRequests()
    }

    deinit {
        stopPendingRequestWatcher()
    }

    func sync() {
        let trackers = store.trackers
        let trackerIDs = Set(trackers.map(\.id))

        for removedID in activeTrackerIDs.subtracting(trackerIDs) {
            schedulers[removedID]?.invalidate()
            schedulers[removedID] = nil
        }

        // Capture freshly-added IDs BEFORE we overwrite activeTrackerIDs.
        // NSBackgroundActivityScheduler does NOT fire on registration —
        // it waits for its first interval window (default 30 min for text
        // trackers). Without an explicit kickoff, the widget the user just
        // pinned shows a placeholder for the whole first interval. We
        // trigger a one-shot scrape immediately so AppGroupStore gets a
        // reading + the widget lights up within seconds.
        let newlyAddedIDs = trackerIDs.subtracting(activeTrackerIDs)

        for tracker in trackers {
            schedule(tracker)
        }

        activeTrackerIDs = trackerIDs

        for newID in newlyAddedIDs {
            triggerScrapeNow(trackerID: newID)
        }
    }

    func triggerScrapeNow(trackerID: UUID) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }

        markInFlight(tracker.id)
        scrape(tracker) { [weak self] in
            self?.markFinished(tracker.id)
        }
    }

    func isScrapeInFlight(trackerID: UUID) -> Bool {
        inFlightTrackerIDs.contains(trackerID)
    }

    private func markInFlight(_ trackerID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inFlightTrackerIDs.insert(trackerID)
        }
    }

    private func markFinished(_ trackerID: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inFlightTrackerIDs.remove(trackerID)
        }
    }

    private func schedule(_ tracker: Tracker) {
        let identifier = "com.ethansk.macos-widgets-stats-from-website.scrape.\(tracker.id.uuidString)"
        let scheduler = schedulers[tracker.id] ?? NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.invalidate()
        scheduler.interval = TimeInterval(max(60, tracker.refreshIntervalSec))
        scheduler.tolerance = TimeInterval(max(30, tracker.refreshIntervalSec / 5))
        scheduler.repeats = true
        schedulers[tracker.id] = scheduler

        scheduler.schedule { [weak self] completion in
            guard let self,
                  let currentTracker = store.trackers.first(where: { $0.id == tracker.id }) else {
                completion(.finished)
                return
            }

            scrape(currentTracker) {
                completion(.finished)
            }
        }
    }

    private func scrape(_ tracker: Tracker, completion: (() -> Void)? = nil) {
        ChromeCDPScraper.scrape(tracker: tracker) { [weak self] result in
            self?.record(result: result, for: tracker)
            completion?()
        }
    }

    private func record(result: Result<TrackerReading, Error>, for tracker: Tracker) {
        do {
            let recordedReading: TrackerReading
            switch result {
            case .success(let reading):
                try AppGroupStore.record(reading: reading, for: tracker)
                recordedReading = reading
            case .failure(let error):
                recordedReading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
            }
            handlePostRecord(reading: recordedReading, tracker: tracker)
            DockBadgeUpdater.update()
            WidgetCenter.shared.reloadTimelines(ofKind: "MacosWidgetsStatsFromWebsite")
            postReadingDidChange(trackerID: tracker.id)
        } catch {
            // The Preferences UI surfaces configuration persistence errors;
            // scrape write failures are transient and retried by the scheduler.
        }
    }

    private func postReadingDidChange(trackerID: UUID) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Self.trackerReadingDidChangeNotification,
                object: nil,
                userInfo: ["trackerID": trackerID]
            )
        }
    }

    private func handlePostRecord(reading: TrackerReading, tracker: Tracker) {
        if reading.status == .ok {
            notifiedBrokenTrackerIDs.remove(tracker.id)
            return
        }

        let failureCount = reading.consecutiveFailureCount ?? 0
        guard failureCount >= 3, !notifiedBrokenTrackerIDs.contains(tracker.id) else {
            return
        }

        notifiedBrokenTrackerIDs.insert(tracker.id)
        TrackerAttentionNotifier.shared.notifyBrokenTracker(tracker, failureCount: failureCount)
    }

    // MARK: - Pending-request watcher

    /// Public entry point so app-lifecycle code (`scenePhase` changes, URL
    /// scheme deep links from `macos-widgets-stats-from-website://refresh`)
    /// can force a drain without waiting on the FS watcher. Idempotent.
    func drainPendingScrapeRequests() {
        let pending = PendingScrapeRequestStore.loadPending()
        guard !pending.isEmpty else {
            return
        }

        // Dedupe: if the user tap-spammed the widget, multiple files exist
        // for the same trackerID. One scrape is sufficient — collapse and
        // clear all matching files.
        //
        // Also detect the cross-process WidgetCenter reload sentinel
        // (PendingScrapeRequest.reloadTimelinesSentinel). The CLI stdio MCP
        // server writes one of those whenever an external agent calls
        // `reload_widget_timelines` — since WidgetKit's WidgetCenter must
        // be invoked from the main app process, the sentinel is how the
        // out-of-process MCP delegates the call.
        var seenTrackerIDs: Set<UUID> = []
        var reloadRequested = false
        for (fileURL, request) in pending {
            defer { PendingScrapeRequestStore.clearPending(fileURL: fileURL) }

            if request.trackerID == PendingScrapeRequest.reloadTimelinesSentinel {
                reloadRequested = true
                continue
            }

            guard let trackerID = UUID(uuidString: request.trackerID),
                  !seenTrackerIDs.contains(trackerID) else {
                continue
            }
            seenTrackerIDs.insert(trackerID)

            ActivityLogger.log("pending-scrape", "draining", metadata: [
                "trackerID": trackerID.uuidString
            ])
            DispatchQueue.main.async { [weak self] in
                self?.triggerScrapeNow(trackerID: trackerID)
            }
        }

        if reloadRequested {
            ActivityLogger.log("pending-scrape", "draining widget reload sentinel")
            // AppGroupStore on disk has changed (the external MCP caller
            // wrote to it before requesting reload). Reload our in-memory
            // copy so the next tick sees the new config, then push the
            // timeline refresh.
            DispatchQueue.main.async { [weak self] in
                self?.store.reloadFromDisk()
                self?.sync()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// Installs a DispatchSourceFileSystemObject on the pending-request
    /// directory so widget-side writes are picked up within milliseconds.
    /// We watch the *directory* (not individual files) because requests
    /// are short-lived and the file set churns frequently. Restarted
    /// transparently if the FD ever closes.
    private func startPendingRequestWatcher() {
        guard let directory = PendingScrapeRequestStore.ensureDirectoryExists() else {
            return
        }

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            ActivityLogger.log("pending-scrape", "watcher open failed", metadata: [
                "path": directory.path,
                "errno": "\(errno)"
            ])
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: pendingRequestWatcherQueue
        )
        source.setEventHandler { [weak self] in
            // .write fires on directory mutations (new files, removals).
            // We don't differentiate event types — any change is a signal
            // to re-enumerate the directory.
            self?.drainPendingScrapeRequests()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()

        pendingRequestWatcher = source
        pendingRequestWatcherFD = fd
        ActivityLogger.log("pending-scrape", "watcher started", metadata: [
            "path": directory.path
        ])
    }

    private func stopPendingRequestWatcher() {
        pendingRequestWatcher?.cancel()
        pendingRequestWatcher = nil
        pendingRequestWatcherFD = -1
    }
}
