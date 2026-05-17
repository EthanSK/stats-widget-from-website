//
//  MacosWidgetsStatsFromWebsiteApp.swift
//  MacosWidgetsStatsFromWebsite
//
//  App entry and scene wiring.
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
    @State private var showsFirstLaunchFlow: Bool

    init() {
        if CommandLine.arguments.contains("--mcp-stdio") {
            MCPServer.shared.runStdioServer()
            Darwin.exit(0)
        }

        // v0.20.0 — headless widget-refresh mode.
        //
        // Background: WidgetKit on macOS will NOT wake a parked widget
        // extension just because a non-host CLI process calls
        // `WidgetCenter.reloadAllTimelines()`, even with matching App Group
        // entitlements (verified empirically on v0.19.1, see PLAN.md).
        // The only process identity that reliably wakes the extension is
        // the host app itself.
        //
        // The LaunchAgent's `scrape-all` CLI tick now spawns this binary
        // (the GUI bundle's executable) with `--background-widget-refresh`
        // after a successful scrape. We detect that flag here BEFORE any
        // SwiftUI scene or AppDelegate is touched, set the activation
        // policy to `.prohibited` so no Dock icon / window can appear,
        // call `WidgetCenter.reloadAllTimelines()`, and exit after a
        // short delay so the WidgetKit IPC has time to flush.
        //
        // This path deliberately bypasses `AppDelegate.terminatePriorInstancesIfNeeded()`
        // — if the user has the real GUI running we still want their
        // window to keep working. The CLI side handles "GUI is already
        // running" by skipping the headless relaunch entirely (see
        // CLI/main.swift).
        if BackgroundWidgetRefreshRunner.isInvokedForBackgroundRefresh() {
            BackgroundWidgetRefreshRunner.runAndExit()
            // runAndExit() never returns.
        }

        ActivityLogger.log("app", "launch")

        // Single-instance enforcement: terminate any prior copy of this app
        // (different PID, same bundle identifier) before we touch the App
        // Group container or migrate legacy data. This handles the
        // Xcode/`./scripts/build.sh` iteration loop where the freshly built
        // bundle lives at a different on-disk path from the previously
        // launched one — AppKit's normal reopen flow doesn't fire across
        // bundle paths, so we'd otherwise end up with two instances fighting
        // over the App Group container and MCP socket.
        AppDelegate.terminatePriorInstancesIfNeeded()

        // One-time copy of user data from the legacy unprefixed App Group
        // container into the team-prefixed container adopted in 0.12.7.
        // Must run before AppGroupStore() reads/writes the new container.
        AppGroupStore.migrateLegacyAppGroupContainerIfNeeded()

        // Backfill the default failure-hook scaffold on pre-0.18 trackers.
        // Idempotent — only adds hooks to trackers whose hooks bag is
        // currently empty, so user-disabled hooks (enabled=false) and
        // user-edited hooks are not overwritten.
        do {
            _ = try AppGroupStore.backfillDefaultHookScaffoldIfNeeded()
        } catch {
            ActivityLogger.log("app", "hook scaffold backfill failed", metadata: ["error": error.localizedDescription])
        }

        let store = AppGroupStore()
        _store = StateObject(wrappedValue: store)
        _backgroundScheduler = StateObject(wrappedValue: BackgroundScheduler(store: store))
        _showsFirstLaunchFlow = State(initialValue: !AppGroupStore.hasExistingConfigurationFile())
    }

    private func reloadWidgets() {
        WidgetCenter.shared.reloadTimelines(ofKind: "MacosWidgetsStatsFromWebsite")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(backgroundScheduler)
                .onAppear {
                    ActivityLogger.log("app", "main window appeared")
                    backgroundScheduler.sync()
                    // Drain anything the widget queued while the app was
                    // not running — the file watcher inside the scheduler
                    // only fires for changes that happen *after* it's
                    // installed, so the cold-launch backlog needs an
                    // explicit drain. Idempotent; safe to call repeatedly.
                    backgroundScheduler.drainPendingScrapeRequests()
                    DockBadgeUpdater.update()
                    reloadWidgets()
                }
                .onReceive(store.$trackers) { _ in
                    backgroundScheduler.sync()
                    reloadWidgets()
                }
                .onReceive(store.$widgetConfigurations) { _ in
                    reloadWidgets()
                }
                .onReceive(NotificationCenter.default.publisher(for: .mcpConfigurationChanged)) { _ in
                    store.reloadFromDisk()
                    backgroundScheduler.sync()
                    DockBadgeUpdater.update()
                    reloadWidgets()
                }
                .onReceive(NotificationCenter.default.publisher(for: AppNavigationEvents.drainPendingScrapeRequestsNotification)) { _ in
                    // Triggered by macos-widgets-stats-from-website://refresh
                    // deep links from the widget extension when the main app
                    // wasn't running. The watcher inside the scheduler also
                    // handles this case while the app IS running.
                    backgroundScheduler.drainPendingScrapeRequests()
                }
                .sheet(isPresented: $showsFirstLaunchFlow) {
                    FirstLaunchWizardView(isPresented: $showsFirstLaunchFlow)
                        .environmentObject(store)
                }
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    UpdateController.shared.checkForUpdates()
                }
            }

            CommandGroup(replacing: .appSettings) {
                Button("Preferences...") {
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(after: .help) {
                Button("Show First-Launch Flow") {
                    showsFirstLaunchFlow = true
                }
            }
        }
    }
}
