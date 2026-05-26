//
//  MacosWidgetsStatsFromWebsiteApp.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.32 — hybrid UX: behaves like a normal Mac app (Dock icon,
//  auto-opens prefs window on launch, click-Dock-to-reopen) AND keeps
//  the menu-bar status item as a secondary access point.
//
//  Architecture: the App's `body` still returns a `Settings` scene
//  (intentionally — `WindowGroup` would auto-spawn a blank SwiftUI
//  window we don't own, and we already manage the real preferences
//  window via `MainPreferencesWindowController` / NSHostingController
//  for fine-grained control over activation policy, window reuse, and
//  section deep-linking). The actual "open prefs on launch" trigger
//  lives in `AppDelegate.applicationDidFinishLaunching` (see notes
//  there). Reopen-from-Dock is wired via `applicationShouldHandleReopen`.
//
//  Why this isn't just a pure-LSUIElement agent any more: see Info.plist
//  comment block on the `LSUIElement` key — TL;DR the chronod widget
//  budget is governed by process longevity + reload cadence, NOT
//  LSUIElement, so we can have a Dock icon + menu bar icon + long-running
//  host all at once.
//

import Darwin
import Foundation
import AppKit
import SwiftUI
import WidgetKit

@main
struct MacosWidgetsStatsFromWebsiteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: AppGroupStore
    @StateObject private var backgroundScheduler: BackgroundScheduler

    init() {
        if CommandLine.arguments.contains("--mcp-stdio") {
            MCPServer.shared.runStdioServer()
            Darwin.exit(0)
        }

        // v0.21.0 — `--background-widget-refresh` and the headless GUI
        // relaunch path have been removed. Stale LaunchAgent installs
        // may still invoke it; silently exit instead of crashing.
        if CommandLine.arguments.contains("--background-widget-refresh") {
            NSLog("[v0.21.0] --background-widget-refresh is a no-op now; menu-bar host handles widget reloads. Exiting.")
            Darwin.exit(0)
        }

        ActivityLogger.log("app", "launch")

        AppDelegate.terminatePriorInstancesIfNeeded()
        AppGroupStore.migrateLegacyAppGroupContainerIfNeeded()

        do {
            _ = try AppGroupStore.backfillDefaultHookScaffoldIfNeeded()
        } catch {
            ActivityLogger.log("app", "hook scaffold backfill failed", metadata: ["error": error.localizedDescription])
        }

        let store = AppGroupStore()
        let scheduler = BackgroundScheduler(store: store)
        _store = StateObject(wrappedValue: store)
        _backgroundScheduler = StateObject(wrappedValue: scheduler)

        AppDelegate.pendingStore = store
        AppDelegate.pendingScheduler = scheduler
        AppDelegate.shouldShowFirstLaunchFlow = !AppGroupStore.hasExistingConfigurationFile()

        // Trigger an initial sync of the in-process schedulers so the
        // menu-bar agent starts scraping immediately on launch.
        scheduler.sync()
        scheduler.drainPendingScrapeRequests()
        DockBadgeUpdater.update()
        WidgetCenterDiagnostics.reloadTimelines(reason: "app init")
    }

    var body: some Scene {
        // v0.21.32 — we deliberately use `Settings` here, NOT
        // `WindowGroup`, even though we now want a Dock-icon Mac app
        // that auto-opens its prefs window. Reason:
        //   - `WindowGroup` would auto-create a SwiftUI-owned window at
        //     launch with no way to position/size/title it the way the
        //     existing AppKit window expects.
        //   - We already host the prefs UI via
        //     `MainPreferencesWindowController` (NSHostingController +
        //     NSWindow). That's what every existing call site
        //     (menu bar > Open Preferences, deep-link routing, dock
        //     reopen, first-launch wizard) uses; replacing it with a
        //     WindowGroup would mean rewiring all of them and losing
        //     section-deep-linking / activation-policy control.
        // The auto-open-on-launch behaviour lives in
        // `AppDelegate.applicationDidFinishLaunching` — see the
        // `showWindow()` call there.
        Settings {
            EmptyView()
        }
        // v0.21.39 — inject a "Check for Updates…" menu item right after
        // the system-provided "About…" entry in the App menu (the one
        // named after the app — "Stats Widget from Website"). Voice
        // 4196: Ethan asked where the Check for Updates button is —
        // the menu-bar status item already had one, and About now has
        // one (PreferencesWindow.swift > AboutPrefsView), but the
        // canonical macOS UX is also the App menu. CommandGroup with
        // `after: .appInfo` slots us in immediately below "About Stats
        // Widget from Website".
        //
        // We call UpdateController.shared.checkForUpdates(_:) — same
        // path the menu-bar item + About button use — so behaviour is
        // identical across all three entry points.
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateController.shared.checkForUpdates(nil)
                }
            }
        }
    }
}
