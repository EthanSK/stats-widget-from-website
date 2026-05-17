//
//  AppDelegate.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.1 stub — see PLAN.md §4 for the full design.
//

import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Bundle identifier of the main app. Hardcoded here so the
    /// single-instance enforcement runs even before `Bundle.main` is fully
    /// resolved (it is, but keeping this as a constant makes the intent
    /// explicit and avoids a force-unwrap on `Bundle.main.bundleIdentifier`
    /// during very-early startup).
    static let mainBundleIdentifier = "com.ethansk.macos-widgets-stats-from-website"

    /// Terminate any other running copies of this app that share our bundle
    /// identifier but have a different PID from ourselves.
    ///
    /// Why: when iterating in Xcode (or via `./scripts/build.sh`), each build
    /// produces a fresh `.app` bundle at a *different* on-disk path. Launching
    /// the freshly built bundle does NOT cause AppKit's normal reopen flow
    /// (`applicationShouldHandleReopen`) to fire on the prior instance —
    /// macOS treats them as two separate apps that just happen to share a
    /// bundle ID, and you end up with two copies of the app fighting over the
    /// shared App Group container, MCP socket, dock icon, menu bar, etc.
    ///
    /// This helper enumerates `NSRunningApplication` instances matching the
    /// main bundle ID, filters out our own PID, and asks each one to
    /// terminate gracefully (falling back to `forceTerminate()` if a stuck
    /// instance is still alive after a short grace period).
    ///
    /// This is intentionally called from `App.init()` (before the
    /// `AppGroupStore` is constructed) so the new instance has uncontended
    /// access to the App Group container by the time it reads from disk.
    /// `applicationShouldHandleReopen` is still kept for the
    /// same-bundle-relaunch case where a single-window focus is the right
    /// behaviour.
    static func terminatePriorInstancesIfNeeded() {
        let myPID = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: mainBundleIdentifier)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }

        guard !others.isEmpty else { return }

        for other in others {
            NSLog(
                "[startup] terminating prior MacosWidgetsStatsFromWebsite instance PID=%d (bundleURL=%@)",
                other.processIdentifier,
                other.bundleURL?.path ?? "<unknown>"
            )
            // Graceful first; macOS sends an AppleEvent quit which lets the
            // old instance run `applicationWillTerminate` (which closes the
            // MCP socket and tears down browsers cleanly).
            _ = other.terminate()
        }

        // Wait briefly for them to die so the App Group container and
        // MCP socket are unencumbered before we proceed. Cap at ~2s so a
        // wedged prior instance never blocks the new launch indefinitely;
        // anything still alive after the grace period gets force-killed.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let stillAlive = others.contains { !$0.isTerminated }
            if !stillAlive { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for other in others where !other.isTerminated {
            NSLog(
                "[startup] force-terminating stuck prior instance PID=%d",
                other.processIdentifier
            )
            _ = other.forceTerminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        TrackerAttentionNotifier.shared.configure()
        UpdateController.shared.start()
        MCPServer.shared.startSocketServer()
        // v0.19.0+ — install / refresh the per-user LaunchAgent that runs
        // the bundled CLI on a fixed interval. Without this, scrapes only
        // happen while the SwiftUI app is alive, and `readings.json`
        // freezes the moment the user closes the window (the bug Ethan
        // reported 2026-05-17: "last updated says 1356 thats ages ago").
        // Idempotent — re-runs every launch to keep the plist's
        // ProgramArguments path in sync with the current bundle.
        LaunchAgentInstaller.installIfPossible()
        bringAppToFrontOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
        MCPServer.shared.stopSocketServer()
    }

    /// Single-window app behaviour: when the user (re)launches the app while
    /// another instance is already running, focus the existing window instead
    /// of opening a second one. macOS calls `applicationShouldHandleReopen`
    /// when the dock icon is clicked or the app is reopened with no visible
    /// windows; returning `true` lets AppKit run its default reopen logic
    /// (which makes the main window key and ordered front).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "macos-widgets-stats-from-website" {
                openDeepLink(url)
            } else if url.pathExtension.lowercased() == SelectorPack.fileExtension {
                do {
                    _ = try SelectorPackImportCoordinator.importSelectorPack(at: url)
                } catch {
                    MCPInvocationLoggerProxy.logImportFailure(error)
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let trackerIDString = response.notification.request.content.userInfo["trackerID"] as? String,
           let trackerID = UUID(uuidString: trackerIDString) {
            NSApp.activate(ignoringOtherApps: true)
            AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
        }

        completionHandler()
    }

    private func openDeepLink(_ url: URL) {
        // `macos-widgets-stats-from-website://refresh` is the widget
        // fallback path: the widget extension's RefreshTrackerIntent
        // writes a pending-request file AND (if the main app was off)
        // nudges via this URL so LaunchServices brings the app forward.
        // The actual scrape is dispatched by BackgroundScheduler when it
        // drains the pending-request directory on foreground / launch, so
        // we don't need to do anything extra here other than make sure
        // the app is foregrounded.
        if url.host == "refresh" {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: AppNavigationEvents.drainPendingScrapeRequestsNotification,
                object: nil
            )
            return
        }

        guard url.host == "tracker",
              let trackerIDString = url.pathComponents.dropFirst().first,
              let trackerID = UUID(uuidString: trackerIDString) else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
    }

    private func bringAppToFrontOnLaunch() {
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)

            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private enum MCPInvocationLoggerProxy {
    static func logImportFailure(_ error: Error) {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macOS Widgets Stats from Website", isDirectory: true)
        let url = directory.appendingPathComponent("selector-pack-import.log", isDirectory: false)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(error.localizedDescription)\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {}
    }
}
