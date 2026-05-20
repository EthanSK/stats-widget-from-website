//
//  MacosWidgetsStatsFromWebsiteApp.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.0 — menu-bar agent host (no auto-open window).
//
//  Architecture: the App's `body` returns a `Settings` scene, which
//  SwiftUI hosts even when `LSUIElement=true` and does NOT auto-open
//  a window at launch. All UI surfaces are presented on demand by the
//  AppDelegate / MenuBarController / MainPreferencesWindowController
//  trio.
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
        // `Settings` is the conventional SwiftUI scene for menu-bar
        // agents — it does NOT auto-present a window at launch, but
        // gives the app a valid scene root so SwiftUI's lifecycle
        // proceeds normally.
        Settings {
            EmptyView()
        }
    }
}
