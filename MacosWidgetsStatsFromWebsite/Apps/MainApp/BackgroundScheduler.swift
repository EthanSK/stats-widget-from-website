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

    // MARK: - Coalesced widget reload (v0.21.0)
    //
    // WidgetKit budgets non-foreground apps to ~40-70 timeline reloads
    // per day. If every tracker calls `reloadTimelines(ofKind:)` after
    // its own scrape, a 4-tracker setup at 30 min cadence = 192 reloads/
    // day — well over budget. We coalesce all reload requests in a
    // 5-second window so consecutive scrapes only emit one wake-up.
    //
    // The coalescing window is deliberately short so user-visible
    // delays after "Scrape Now" stay <10 s.
    private let widgetReloadCoalesceWindow: TimeInterval = 5.0
    private var widgetReloadWorkItem: DispatchWorkItem?

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

    /// v0.21.0 — single entry point for the menu-bar "Scrape Trackers
    /// Now" command. When `force` is true we ignore `ScrapeDuePolicy`
    /// and scrape every configured tracker; when false we only scrape
    /// trackers that are actually due.
    func scrapeAllDueTrackers(force: Bool) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings
        let now = Date()
        let candidates: [Tracker]
        if force {
            candidates = configuration.trackers
        } else {
            candidates = configuration.trackers.filter { tracker in
                let reading = readings[tracker.id.uuidString]
                return ScrapeDuePolicy.isDue(tracker: tracker, reading: reading, now: now)
            }
        }
        ActivityLogger.log("scheduler", "scrapeAllDueTrackers", metadata: [
            "force": "\(force)",
            "candidates": "\(candidates.count)",
            "configured": "\(configuration.trackers.count)"
        ])
        for tracker in candidates {
            triggerScrapeNow(trackerID: tracker.id)
        }
    }

    /// Coalesces widget-timeline reload requests inside a short window
    /// so a burst of scrapes only emits a single `reloadTimelines`
    /// call. WidgetKit's daily budget for non-foreground apps means
    /// we want to minimise wake-ups; one per coalesced burst is enough
    /// because the next scrape cycle is 30 min away regardless.
    private func requestCoalescedWidgetReload() {
        widgetReloadWorkItem?.cancel()
        let work = DispatchWorkItem {
            WidgetCenter.shared.reloadTimelines(ofKind: "MacosWidgetsStatsFromWebsite")
            ActivityLogger.log("scheduler", "coalesced widget reload fired")
        }
        widgetReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + widgetReloadCoalesceWindow, execute: work)
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
        let interval = TimeInterval(max(60, tracker.refreshIntervalSec))
        scheduler.interval = interval
        scheduler.tolerance = TimeInterval(max(30, tracker.refreshIntervalSec / 5))
        scheduler.repeats = true
        schedulers[tracker.id] = scheduler

        // Log every (re)schedule so we can verify hot-reload mechanism is
        // working without having to instrument from outside the app.
        // Filter with: `log show --predicate 'subsystem == "..."' --info`
        // or grep activity.log.
        ActivityLogger.log("scheduler", "rescheduled", metadata: [
            "trackerID": tracker.id.uuidString,
            "trackerName": tracker.name,
            "intervalSec": "\(Int(interval))"
        ])

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
            let scrapeError: Error?
            switch result {
            case .success(let reading):
                try AppGroupStore.record(reading: reading, for: tracker)
                recordedReading = reading
                scrapeError = nil
            case .failure(let error):
                recordedReading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
                scrapeError = error
            }
            handlePostRecord(reading: recordedReading, tracker: tracker)
            DockBadgeUpdater.update()
            requestCoalescedWidgetReload()
            postReadingDidChange(trackerID: tracker.id)
            fireScrapeLifecycleHooks(
                tracker: tracker,
                reading: recordedReading,
                scrapeError: scrapeError
            )
        } catch {
            // The Preferences UI surfaces configuration persistence errors;
            // scrape write failures are transient and retried by the scheduler.
        }
    }

    /// Bridges scrape outcomes into the per-tracker hook system (v0.18.0+).
    /// Lives here (rather than inside `record`) so hook firing can run
    /// against the *latest persisted* copy of the tracker — which may
    /// include hook telemetry updates from a prior firing.
    ///
    /// Errors thrown by hooks are intentionally swallowed so a broken
    /// user-authored hook NEVER blocks the scheduler. See HookExecutor's
    /// fire(...) contract.
    private func fireScrapeLifecycleHooks(
        tracker: Tracker,
        reading: TrackerReading,
        scrapeError: Error?
    ) {
        let trigger: HookTrigger = (scrapeError == nil && reading.status == .ok) ? .onSuccess : .onFailure
        // Re-read the tracker so we pick up any hook config updates that
        // landed between scrape-start and now (e.g. MCP add_tracker_hook).
        let latestTracker = AppGroupStore.loadSharedConfiguration().trackers.first { $0.id == tracker.id } ?? tracker
        let context = HookScrapeContext(
            trigger: trigger,
            firedAt: Date(),
            scrapedValue: reading.currentValue,
            scrapedNumeric: reading.currentNumeric,
            errorKind: scrapeError.map { "\(type(of: $0))" },
            errorMessage: scrapeError?.localizedDescription ?? reading.lastError,
            consecutiveFailureCount: reading.consecutiveFailureCount
        )
        HookExecutor.fire(
            trigger: trigger,
            tracker: latestTracker,
            scrapeContext: context
        ) { hookID, telemetry in
            // Persist lastRun back into the tracker config.
            do {
                try AppGroupStore.recordHookTelemetry(
                    trackerID: latestTracker.id,
                    hookID: hookID,
                    lastRun: telemetry
                )
            } catch {
                ActivityLogger.log("hook", "telemetry persist failed", metadata: [
                    "trackerID": latestTracker.id.uuidString,
                    "hookID": hookID.uuidString,
                    "error": error.localizedDescription
                ])
            }
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
