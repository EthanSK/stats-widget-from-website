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

    init(store: AppGroupStore) {
        self.store = store
    }

    func sync() {
        let trackers = store.trackers
        let trackerIDs = Set(trackers.map(\.id))

        for removedID in activeTrackerIDs.subtracting(trackerIDs) {
            schedulers[removedID]?.invalidate()
            schedulers[removedID] = nil
        }

        for tracker in trackers {
            schedule(tracker)
        }

        activeTrackerIDs = trackerIDs
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
}
