import Darwin
import Foundation
import notify

/// Ethan's "on exhaustion" / "release memory, wait, then resume" mode.
/// Ordinary RAM usage, swap usage, warning and critical pressure never start it.
/// The optional root relay owns the emergency/recovery policy; this process only
/// observes its latched Darwin notification and gates browser work. No root
/// commands, credentials or app data cross that boundary.
final class EmergencyMemoryRelief {
    static let notificationName = "com.ethansk.stats-widget.memory-exhaustion"
    static let shared = EmergencyMemoryRelief(notificationName: notificationName, onRecovery: {
        ActivityLogger.log("memory-relief", "recovered: refreshing allowed")
    }) {
        ActivityLogger.log("memory-relief", "exhaustion: refreshing paused")
        ChromeBrowserProfile.shared.releaseBackgroundBrowsersForMemoryEmergency()
    }

    private let lock = NSLock()
    private var paused = false
    private var generation: UInt64 = 0
    private var notificationToken: Int32 = 0
    private var registered = false
    private let onPause: () -> Void
    private let onRecovery: () -> Void
    private let queue = DispatchQueue(label: "StatsWidget.memory-relief")

    init(notificationName: String, onRecovery: @escaping () -> Void = {}, onPause: @escaping () -> Void) {
        self.onPause = onPause
        self.onRecovery = onRecovery
        // Register before reading the latch so an event during startup cannot
        // fall into the gap between the initial read and subscription.
        let status = notify_register_dispatch(notificationName, &notificationToken,
                                              queue) { [weak self] _ in
            self?.readRelayState()
        }
        registered = status == NOTIFY_STATUS_OK
        if registered { queue.sync { readRelayState() } }
    }

    deinit {
        if registered { notify_cancel(notificationToken) }
    }

    /// A generation invalidates work queued before an emergency, even if its
    /// callback arrives after recovery. This keeps saved readings/failure counts
    /// intact and prevents old delayed scrape jobs from reopening Chromium.
    func permit() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return paused ? nil : generation
    }

    func isValid(_ permit: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !paused && permit == generation
    }

    /// Serialize the final exec with emergency admission. The browser's serial
    /// queue records the new child before the queued emergency cleanup runs.
    func withLaunchPermit<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !paused else { throw CancellationError() }
        return try body()
    }

    private func readRelayState() {
        var state: UInt64 = 0
        guard notify_get_state(notificationToken, &state) == NOTIFY_STATUS_OK else { return }
        lock.lock()
        let wasPaused = paused
        paused = state != 0
        if paused && !wasPaused { generation &+= 1 }
        let changed = paused != wasPaused
        let shouldRelease = paused && changed
        lock.unlock()
        guard changed else { return }
        if shouldRelease { onPause() } else { onRecovery() }
    }
}
