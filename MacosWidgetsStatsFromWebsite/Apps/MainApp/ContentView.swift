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
    @State private var showsFirstLaunchFlow: Bool = AppDelegate.shouldShowFirstLaunchFlow

    var body: some View {
        PreferencesWindow(onStartGuidedSetup: {
            showsFirstLaunchFlow = true
        })
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
            .onChange(of: showsFirstLaunchFlow) { isShowing in
                guard !isShowing else { return }

                // Whether the user finishes setup or chooses "Not now",
                // return them to the calm journey overview instead of
                // exposing whichever setup/advanced tab happened to be
                // remembered in UserDefaults.
                UserDefaults.standard.set(
                    PreferencesSection.home.rawValue,
                    forKey: "preferences.selectedSection"
                )
                NotificationCenter.default.post(
                    name: .menuBarPreferencesSectionRequested,
                    object: nil,
                    userInfo: ["section": PreferencesSection.home.rawValue]
                )
            }
    }

    private func reloadWidgets() {
        WidgetCenterDiagnostics.reloadTimelines(reason: "preferences/config change")
    }
}
