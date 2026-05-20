//
//  ContentView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Root view for the Preferences window. v0.21.0+ this is hosted
//  inside `MainPreferencesWindowController`'s NSWindow rather than a
//  SwiftUI WindowGroup, so the side-effect wiring that used to live
//  in the WindowGroup closure (`scheduler.sync`, drain pending
//  requests, widget reload on tracker change, etc.) is anchored here
//  via `.onAppear` / `.onReceive`.
//

import SwiftUI
import WidgetKit

struct ContentView: View {
    @EnvironmentObject private var store: AppGroupStore
    @EnvironmentObject private var backgroundScheduler: BackgroundScheduler
    @State private var showsFirstLaunchFlow: Bool = !AppGroupStore.hasExistingConfigurationFile()

    var body: some View {
        PreferencesWindow()
            .onAppear {
                ActivityLogger.log("app", "preferences window appeared")
                backgroundScheduler.sync()
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
                backgroundScheduler.drainPendingScrapeRequests()
            }
            .sheet(isPresented: $showsFirstLaunchFlow) {
                FirstLaunchWizardView(isPresented: $showsFirstLaunchFlow)
                    .environmentObject(store)
            }
    }

    private func reloadWidgets() {
        WidgetCenterDiagnostics.reloadTimelines(reason: "preferences/config change")
    }
}
