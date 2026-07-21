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

        // v0.21.53 — COLLAPSE POST-REBOOT TCC DIALOG CASCADE.
        //
        // MUST be the absolute first Group Container access in the
        // process — runs BEFORE `ActivityLogger.log` (which writes to
        // Logs/activity.log inside the Group Container), BEFORE
        // `AppGroupStore.*` (which reads + writes trackers.json), and
        // BEFORE any other call site that touches
        // `~/Library/Group Containers/<id>/`.
        //
        // Why this ordering matters:
        //   macOS Sonoma+ binds the `kTCCServiceSystemPolicyAppData`
        //   grant to the current boot UUID, NOT permanently. Every
        //   reboot the user sees the "would like to access data from
        //   other apps" dialog again. Pre-v0.21.53 the `App.init()`
        //   above used to fire 3-4 distinct file ops in rapid
        //   succession (ActivityLogger.log + migrate + backfill +
        //   AppGroupStore init), each issuing its own TCC prompt
        //   before the user could click "Allow" on the previous one
        //   — net result: TWO stacked dialogs per reboot (voice 4274,
        //   2026-05-27).
        //
        //   TCCPrewarmer issues ONE deliberate write to a dedicated
        //   sentinel file, blocks the calling thread until the user
        //   resolves the dialog, and then returns. From that point on
        //   in this boot session, all subsequent file ops reuse the
        //   now-resolved boot-session grant — no more dialogs.
        //
        //   Net effect: ONE dialog per reboot instead of TWO.
        //
        //   The architecturally correct fix (re-add `application-groups`
        //   entitlement + embed a Developer ID Direct Distribution
        //   provisioning profile) is deferred — would eliminate the
        //   dialog ENTIRELY, but requires the CI signing pipeline to
        //   gain profile-embedding support and risks reintroducing
        //   the v0.21.31 AMFI -413 SIGKILL if the profile is ever
        //   missing/expired. See TCCPrewarmer.swift for the full
        //   write-up.
        //
        // CAUTION: do not reorder this below any line that touches
        // the Group Container. Doing so silently re-introduces the
        // double-dialog bug.
        TCCPrewarmer.prewarmGroupContainerAccess()

        ActivityLogger.log("app", "launch")

        AppDelegate.terminatePriorInstancesIfNeeded()
        AppGroupStore.migrateLegacyAppGroupContainerIfNeeded()
        // Capture first-launch state BEFORE the hook-scaffold backfill below.
        // `mutateSharedConfiguration` intentionally persists even an empty
        // configuration, so asking `hasExistingConfigurationFile()` afterward
        // makes a genuinely fresh install look configured and silently skips
        // onboarding. Legacy migration runs first so an existing legacy user
        // is still recognised correctly.
        let shouldShowFirstLaunchFlow = !AppGroupStore.hasExistingConfigurationFile()
        if shouldShowFirstLaunchFlow {
            // A clean configuration should always land on the calm Home page
            // after onboarding is dismissed. UserDefaults can outlive an app
            // reinstall (and isolated UI tests deliberately share them), so a
            // remembered advanced/setup tab is not reliable first-run state.
            UserDefaults.standard.set(
                PreferencesSection.home.rawValue,
                forKey: "preferences.selectedSection"
            )
        }
        ChromeBrowserProfile.shared.terminateAppOwnedBrowsersFromPreviousSessions(reason: "startup")

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
        AppDelegate.shouldShowFirstLaunchFlow = shouldShowFirstLaunchFlow

        // Trigger an initial sync of the in-process schedulers so the
        // menu-bar agent starts scraping immediately on launch.
        scheduler.sync()
        scheduler.drainPendingScrapeRequests()
        DockBadgeUpdater.update()
        if !AppGroupPaths.isUsingTestContainerOverride {
            WidgetCenterDiagnostics.reloadTimelines(reason: "app init")
        }
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
