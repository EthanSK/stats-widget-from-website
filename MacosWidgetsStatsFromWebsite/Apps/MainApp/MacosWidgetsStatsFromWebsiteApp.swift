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

        ActivityLogger.log("app", "launch")

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
