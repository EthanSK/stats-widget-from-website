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

        // v0.21.0 — menu-bar agent architecture.
        //
        // Previously (v0.19/0.20) we relied on a per-user LaunchAgent
        // firing the bundled CLI every 5 min to keep `readings.json`
        // fresh. That hit two WidgetKit problems:
        //   1. macOS only honours `WidgetCenter.reloadTimelines(ofKind:)`
        //      from the host app's process identity, so the CLI's call
        //      was a no-op; we had to relaunch the GUI binary headlessly
        //      every tick to wake the widget — fragile + chronod-noisy.
        //   2. WidgetKit budgets non-foreground apps to ~40–70 timeline
        //      reloads/day. A 5-min cadence = 288/day; we routinely
        //      blew the budget and chronod started silently throttling
        //      us on macOS 26.
        //
        // The new model: the app itself runs as an `LSUIElement=true`
        // menu-bar agent. It is the one persistent process. The
        // BackgroundScheduler's in-process timers handle scraping
        // (default 30 min cadence per tracker), and the host calls
        // `WidgetCenter.reloadTimelines(ofKind:)` from its own (correct)
        // identity. No CLI re-launch, no LaunchAgent, no chronod-state
        // mismatch.
        //
        // Migration: tear down any legacy LaunchAgent from prior
        // installs so we don't end up with both schedulers fighting.
        let migrated = LegacyLaunchAgentMigrator.migrateIfNeeded()

        // Install menu-bar status item. Wires up "Open Preferences",
        // "Scrape Trackers Now", "Launch at Login", "Quit", etc.
        if let store = appStoreForWiring, let scheduler = appSchedulerForWiring {
            MainPreferencesWindowController.shared.configure(
                store: store,
                backgroundScheduler: scheduler
            )
            MenuBarController.shared.install(
                store: store,
                backgroundScheduler: scheduler
            )
        }

        // Default activation policy is `.accessory` — no Dock icon,
        // no menu bar. Only the menu-bar status item is visible.
        // (LSUIElement=true in Info.plist already gives us this on
        // launch; we re-assert here to be explicit.)
        NSApp.setActivationPolicy(.accessory)

        if migrated {
            presentMigrationAlertOnNextRunLoop()
        }

        // First-launch flow: if there's no existing configuration on
        // disk, auto-open the preferences window so the user can
        // create their first tracker. (Without this, a fresh-install
        // user would just see a chart icon in their menu bar with no
        // obvious way to start.)
        if AppDelegate.shouldShowFirstLaunchFlow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                MainPreferencesWindowController.shared.showWindow()
            }
        }
    }

    /// Set by `MacosWidgetsStatsFromWebsiteApp.init()` after the
    /// `AppGroupStore` and `BackgroundScheduler` have been created so
    /// `applicationDidFinishLaunching` can hand them to the menu-bar /
    /// window controllers. Static rather than instance state so
    /// `App.init()` can write to it before `AppDelegate` is invoked.
    static var pendingStore: AppGroupStore?
    static var pendingScheduler: BackgroundScheduler?
    static var shouldShowFirstLaunchFlow: Bool = false

    private var appStoreForWiring: AppGroupStore? { AppDelegate.pendingStore }
    private var appSchedulerForWiring: BackgroundScheduler? { AppDelegate.pendingScheduler }

    private func presentMigrationAlertOnNextRunLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Stats Widget now runs in the menu bar"
            alert.informativeText = """
                The app now lives in your menu bar (look for the chart icon at the top of your screen). Click it to open Preferences, trigger a manual scrape, or quit.

                The previous background-refresh job (a LaunchAgent) has been disabled — the menu-bar app handles refreshing on its own now.
                """
            alert.addButton(withTitle: "Got it")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
        MCPServer.shared.stopSocketServer()
    }

    /// Menu-bar agent behaviour: when the user re-launches the app
    /// (double-clicking the .app in Finder, hitting Open from
    /// LaunchPad, etc.), we surface the Preferences window. The menu-
    /// bar status item is already present; the re-launch is a clear
    /// "I want to see the UI" signal so we honour it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainPreferencesWindowController.shared.showWindow()
        }
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
            MainPreferencesWindowController.shared.showWindow(section: .trackers)
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
            // v0.21.0 — menu-bar agent never needs to foreground for a
            // refresh deep link. The scheduler watches the pending-
            // request directory and dispatches scrapes from background.
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

        // Open the preferences window so AppNavigationEvents can route
        // to the trackers section. Without a visible window the
        // notification would land but never be acted on.
        MainPreferencesWindowController.shared.showWindow(section: .trackers)
        AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
    }

    // v0.21.0 — `bringAppToFrontOnLaunch` removed. The menu-bar agent
    // is intentionally launch-silent (no Dock icon flash, no auto-
    // opened window). The user explicitly opens Preferences from the
    // menu-bar dropdown when they want to interact with the app.
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
