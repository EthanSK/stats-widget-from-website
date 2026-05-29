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
    private var hasCompletedInitialSync = false
    private var notifiedBrokenTrackerIDs: Set<UUID> = []
    private let dueScrapeWatchdogInitialDelaySec = 15
    private let dueScrapeWatchdogIntervalSec = 60
    private let dueScrapeWatchdogLeewaySec = 10
    private let dueScrapeWatchdogQueue = DispatchQueue(
        label: "com.ethansk.macos-widgets-stats-from-website.due-scrape-watchdog"
    )
    private var dueScrapeWatchdogTimer: DispatchSourceTimer?

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
        startDueScrapeWatchdog()
    }

    deinit {
        stopDueScrapeWatchdog()
        stopPendingRequestWatcher()
    }

    func sync() {
        let trackers = store.trackers
        let scrapeReadyTrackers = trackers.filter(\.isScrapeReady)
        let scrapeReadyTrackerIDs = Set(scrapeReadyTrackers.map(\.id))

        for removedID in Set(schedulers.keys).subtracting(scrapeReadyTrackerIDs) {
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
        //
        // On the first sync of a normal app launch, though, every persisted
        // tracker would otherwise look "new" because `activeTrackerIDs` starts
        // empty. That creates a cold-start scrape burst immediately after an
        // update/restart, racing Chromium launch and surfacing transient
        // stale/error rows even when the next scrape succeeds. Only apply the
        // immediate kickoff after the initial scheduler population has run.
        let newlyAddedIDs = scrapeReadyTrackerIDs.subtracting(activeTrackerIDs)
        let shouldTriggerNewTrackers = hasCompletedInitialSync

        for tracker in scrapeReadyTrackers {
            schedule(tracker)
        }

        for tracker in trackers where !tracker.isScrapeReady {
            ActivityLogger.log("scheduler", "skipped incomplete tracker", metadata: [
                "reason": "selector-empty",
                "trackerID": tracker.id.uuidString,
                "trackerName": tracker.name
            ])
        }

        activeTrackerIDs = scrapeReadyTrackerIDs
        if !hasCompletedInitialSync {
            hasCompletedInitialSync = true
            if !newlyAddedIDs.isEmpty {
                ActivityLogger.log("scheduler", "initial sync registered existing trackers without immediate scrape", metadata: [
                    "trackers": "\(newlyAddedIDs.count)"
                ])
            }
        }

        if shouldTriggerNewTrackers {
            for newID in newlyAddedIDs {
                triggerScrapeNow(trackerID: newID)
            }
        }
    }

    /// v0.21.0 — single entry point for the menu-bar "Scrape Trackers
    /// Now" command. When `force` is true we ignore `ScrapeDuePolicy`
    /// and scrape every configured tracker; when false we only scrape
    /// trackers that are actually due.
    func scrapeAllDueTrackers(force: Bool) {
        scrapeAllDueTrackers(force: force, source: "manual")
    }

    private func scrapeAllDueTrackers(force: Bool, source: String) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings
        let plan = DueScrapePlanner.plan(
            configuration: configuration,
            readings: readings,
            force: force
        )
        if source != "watchdog" || !plan.candidates.isEmpty {
            ActivityLogger.log("scheduler", "scrapeAllDueTrackers", metadata: [
                "source": source,
                "force": "\(force)",
                "candidates": "\(plan.candidates.count)",
                "configured": "\(plan.configuredCount)",
                "skippedIncomplete": "\(plan.skippedIncompleteCount)"
            ])
        }
        for tracker in plan.candidates {
            triggerScrapeNow(trackerID: tracker.id)
        }
    }

    private func startDueScrapeWatchdog() {
        guard dueScrapeWatchdogTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: dueScrapeWatchdogQueue)
        timer.schedule(
            deadline: .now() + .seconds(dueScrapeWatchdogInitialDelaySec),
            repeating: .seconds(dueScrapeWatchdogIntervalSec),
            leeway: .seconds(dueScrapeWatchdogLeewaySec)
        )
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                self?.scrapeAllDueTrackers(force: false, source: "watchdog")
            }
        }
        dueScrapeWatchdogTimer = timer
        timer.resume()

        ActivityLogger.log("scheduler", "due scrape watchdog started", metadata: [
            "initialDelaySec": "\(dueScrapeWatchdogInitialDelaySec)",
            "intervalSec": "\(dueScrapeWatchdogIntervalSec)",
            "leewaySec": "\(dueScrapeWatchdogLeewaySec)"
        ])
    }

    private func stopDueScrapeWatchdog() {
        dueScrapeWatchdogTimer?.cancel()
        dueScrapeWatchdogTimer = nil
    }

    /// Coalesces widget-timeline reload requests inside a short window
    /// so a burst of scrapes only emits a single `reloadTimelines`
    /// call. WidgetKit's daily budget for non-foreground apps means
    /// we want to minimise wake-ups; one per coalesced burst is enough
    /// because the next scrape cycle is 30 min away regardless.
    private func requestCoalescedWidgetReload() {
        widgetReloadWorkItem?.cancel()
        let work = DispatchWorkItem {
            WidgetCenterDiagnostics.reloadTimelines(reason: "coalesced scrape")
            ActivityLogger.log("scheduler", "coalesced widget reload fired")
        }
        widgetReloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + widgetReloadCoalesceWindow, execute: work)
    }

    func triggerScrapeNow(trackerID: UUID) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }
        guard tracker.isScrapeReady else {
            ActivityLogger.log("scheduler", "skipped immediate scrape for incomplete tracker", metadata: [
                "reason": "selector-empty",
                "trackerID": tracker.id.uuidString,
                "trackerName": tracker.name
            ])
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
        guard tracker.isScrapeReady else {
            schedulers[tracker.id]?.invalidate()
            schedulers[tracker.id] = nil
            ActivityLogger.log("scheduler", "skipped scheduling incomplete tracker", metadata: [
                "reason": "selector-empty",
                "trackerID": tracker.id.uuidString,
                "trackerName": tracker.name
            ])
            return
        }

        let identifier = "com.ethansk.macos-widgets-stats-from-website.scrape.\(tracker.id.uuidString)"
        let scheduler = schedulers[tracker.id] ?? NSBackgroundActivityScheduler(identifier: identifier)
        scheduler.invalidate()
        // v0.21.29 (Ethan voice 4019): use the tracker's EFFECTIVE refresh
        // interval, which floors protected-domain trackers at 15 min
        // (900s) to dodge challenge/rate heuristics. Other trackers use
        // their stored `refreshIntervalSec` unchanged.
        // The legacy 60s minimum below still applies as a sanity floor in
        // case someone hand-edits trackers.json to an impossible value.
        let effectiveIntervalSec = tracker.effectiveRefreshIntervalSec
        let interval = TimeInterval(max(60, effectiveIntervalSec))
        scheduler.interval = interval
        scheduler.tolerance = TimeInterval(max(30, effectiveIntervalSec / 5))
        scheduler.repeats = true
        schedulers[tracker.id] = scheduler

        // Log every (re)schedule so we can verify hot-reload mechanism is
        // working without having to instrument from outside the app.
        // Filter with: `log show --predicate 'subsystem == "..."' --info`
        // or grep activity.log.
        // v0.21.29/v0.21.68: include `domainCadenceFloor` so we can tell
        // whether the protected-domain 15-min override actually kicked in
        // for this tracker, vs the user just setting a 15-min cadence.
        let cadenceFloored = Tracker.isCloudflareSensitiveDomain(url: tracker.url)
            && tracker.refreshIntervalSec < 900
        ActivityLogger.log("scheduler", "rescheduled", metadata: [
            "trackerID": tracker.id.uuidString,
            "trackerName": tracker.name,
            "intervalSec": "\(Int(interval))",
            "configuredIntervalSec": "\(tracker.refreshIntervalSec)",
            "domainCadenceFloor": cadenceFloored ? "protected-15min" : "none"
        ])

        scheduler.schedule { [weak self] completion in
            guard let self,
                  let currentTracker = store.trackers.first(where: { $0.id == tracker.id }) else {
                completion(.finished)
                return
            }
            guard currentTracker.isScrapeReady else {
                ActivityLogger.log("scheduler", "skipped scheduled scrape for incomplete tracker", metadata: [
                    "reason": "selector-empty",
                    "trackerID": currentTracker.id.uuidString,
                    "trackerName": currentTracker.name
                ])
                completion(.finished)
                return
            }

            scrape(currentTracker) {
                completion(.finished)
            }
        }
    }

    private func scrape(_ tracker: Tracker, completion: (() -> Void)? = nil) {
        guard tracker.isScrapeReady else {
            ActivityLogger.log("scheduler", "skipped scrape for incomplete tracker", metadata: [
                "reason": "selector-empty",
                "trackerID": tracker.id.uuidString,
                "trackerName": tracker.name
            ])
            completion?()
            return
        }

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

        // v0.21.29 (Ethan voice 4020): suppress failure hooks (incl. the
        // built-in Auto-repair Claude spawner) until the tracker has
        // failed 3 times in a row. ChatGPT pages routinely have a single
        // Cloudflare-challenge blip every few hours that recovers on the
        // next scrape; firing the auto-repair agent + macOS notification
        // on every transient failure was noisy + woke Ethan up. The
        // 3-consecutive-failure floor matches the existing
        // `notifyBrokenTracker` gate in `handlePostRecord` so the user
        // sees both the system notification AND the agent spawn at the
        // same threshold (consistency = fewer surprises).
        //
        // Success hooks are NOT gated — onSuccess fires on every healthy
        // scrape as before (user-authored success hooks shouldn't have
        // surprise quiet-periods).
        let failureCount = reading.consecutiveFailureCount ?? 0
        if trigger == .onFailure, failureCount < 3 {
            ActivityLogger.log("hook", "failure-hooks suppressed (consecutiveFailureCount<3)", metadata: [
                "trackerID": latestTracker.id.uuidString,
                "trackerName": latestTracker.name,
                "consecutiveFailureCount": "\(failureCount)"
            ])
            return
        }

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
                WidgetCenterDiagnostics.reloadAllTimelines(reason: "pending-scrape sentinel")
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
