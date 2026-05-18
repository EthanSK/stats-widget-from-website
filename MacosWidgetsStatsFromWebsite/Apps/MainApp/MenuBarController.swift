//
//  MenuBarController.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.0 — menu-bar agent host (NSStatusItem).
//
//  Background: prior to v0.21.0 the app shipped as a regular GUI app and
//  relied on a per-user LaunchAgent + CLI tick to keep `readings.json`
//  fresh while the window was closed. That architecture hit two
//  fundamental WidgetKit limits:
//    1. macOS only honours `WidgetCenter.reloadTimelines(ofKind:)` from
//       the host app's process identity. CLI calls were ignored; the
//       only working fix was relaunching the GUI binary headlessly per
//       tick — fragile and noisy on macOS 26 chronod.
//    2. WidgetKit budgets non-foreground apps to ~40–70 timeline reloads
//       per day. A 5-minute cadence = 288/day; we routinely blew the
//       budget and chronod silently throttled us.
//
//  The v0.21.0 pivot mirrors what Stats / Eul / Lungo / iStat Menus
//  already do: ship as an `LSUIElement=true` menu-bar agent. The host
//  is the one and only persistent process, owns the scrape timer, and
//  calls `WidgetCenter.reloadTimelines(ofKind:)` from its own (correct)
//  identity. Cadence drops to 30 minutes = 48 reloads/day, well under
//  Apple's budget.
//
//  MenuBarController owns:
//    - The NSStatusItem in the menu bar (icon + dropdown menu).
//    - A weak reference to the AppGroupStore for badge + on-click state.
//    - The "Open Preferences", "Trigger Scrape Now", "Quit" menu items.
//
//  Preferences window lifecycle:
//    - At startup the window is HIDDEN. The user opens it explicitly
//      from the menu bar OR from a deep link / re-launch.
//    - When the user clicks "Open Preferences" or activates the dock
//      icon (only fires for a foreground app — n/a here), we ask the
//      AppDelegate to materialise the window via the shared
//      `MainPreferencesWindowController`.
//

import AppKit
import Combine
import SwiftUI

final class MenuBarController: ObservableObject {
    static let shared = MenuBarController()

    private var statusItem: NSStatusItem?
    private weak var store: AppGroupStore?
    private weak var backgroundScheduler: BackgroundScheduler?
    private var brokenCountCancellable: AnyCancellable?

    private init() {}

    /// Installs the menu-bar status item. Idempotent — second call is a
    /// no-op. Must be called on the main actor (AppKit constraint).
    func install(store: AppGroupStore, backgroundScheduler: BackgroundScheduler) {
        guard statusItem == nil else { return }
        self.store = store
        self.backgroundScheduler = backgroundScheduler

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            // SF Symbol — a small bar chart. Templated so it adapts to
            // light/dark menu bar automatically.
            button.image = NSImage(
                systemSymbolName: "chart.bar.fill",
                accessibilityDescription: "Stats Widget"
            )
            button.image?.isTemplate = true
            button.toolTip = "Stats Widget from Website"
        }
        item.menu = buildMenu()
        statusItem = item

        ActivityLogger.log("menubar", "installed")

        // Wire badge updates: surface broken-tracker count in the menu-bar
        // tooltip + the menu title. We piggy-back on the existing
        // notification BackgroundScheduler posts whenever a reading lands.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReadingChanged),
            name: BackgroundScheduler.trackerReadingDidChangeNotification,
            object: nil
        )
        refreshTooltip()
    }

    /// Builds (or rebuilds) the dropdown menu. Called once at install
    /// time; subsequent invocations rebuild on demand if the menu items'
    /// dynamic state needs to change (currently only the title text of
    /// the trigger-scrape-now item).
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let preferencesItem = NSMenuItem(
            title: "Open Preferences…",
            action: #selector(openPreferencesAction),
            keyEquivalent: ","
        )
        preferencesItem.target = self
        menu.addItem(preferencesItem)

        let scrapeItem = NSMenuItem(
            title: "Scrape Trackers Now",
            action: #selector(scrapeNowAction),
            keyEquivalent: "r"
        )
        scrapeItem.target = self
        menu.addItem(scrapeItem)

        menu.addItem(NSMenuItem.separator())

        let launchAtLoginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLoginAction),
            keyEquivalent: ""
        )
        launchAtLoginItem.target = self
        launchAtLoginItem.state = LoginItemManager.isEnabled() ? .on : .off
        launchAtLoginItem.identifier = NSUserInterfaceItemIdentifier("launchAtLogin")
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(
            title: "About Stats Widget",
            action: #selector(openAboutAction),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let updatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdatesAction),
            keyEquivalent: ""
        )
        updatesItem.target = self
        menu.addItem(updatesItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Stats Widget",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        menu.delegate = MenuDelegateProxy.shared
        return menu
    }

    // MARK: - Public hooks (called from NSMenu delegate proxy)

    func menuWillOpen() {
        // Sync the "Launch at Login" toggle in case the user changed it
        // from outside the app (e.g. System Settings > Login Items).
        if let menu = statusItem?.menu,
           let item = menu.items.first(where: { $0.identifier?.rawValue == "launchAtLogin" }) {
            item.state = LoginItemManager.isEnabled() ? .on : .off
        }
    }

    // MARK: - Actions

    @objc private func openPreferencesAction() {
        MainPreferencesWindowController.shared.showWindow()
    }

    @objc private func scrapeNowAction() {
        ActivityLogger.log("menubar", "scrape now triggered")
        backgroundScheduler?.scrapeAllDueTrackers(force: true)
    }

    @objc private func toggleLaunchAtLoginAction() {
        let newValue = !LoginItemManager.isEnabled()
        do {
            try LoginItemManager.setEnabled(newValue)
            ActivityLogger.log("menubar", "launch-at-login toggled", metadata: [
                "enabled": "\(newValue)"
            ])
        } catch {
            ActivityLogger.log("menubar", "launch-at-login toggle failed", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    @objc private func openAboutAction() {
        MainPreferencesWindowController.shared.showWindow(section: .about)
    }

    @objc private func checkForUpdatesAction() {
        UpdateController.shared.checkForUpdates()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    // MARK: - Tooltip / badge state

    @objc private func handleReadingChanged() {
        refreshTooltip()
    }

    private func refreshTooltip() {
        guard let button = statusItem?.button else { return }
        let readings = AppGroupStore.loadReadings().readings
        let trackers = AppGroupStore.loadSharedConfiguration().trackers
        let activeIDs = Set(trackers.map { $0.id.uuidString })
        let broken = readings.filter { id, reading in
            activeIDs.contains(id) && reading.status == .broken
        }.count
        if broken > 0 {
            button.toolTip = "Stats Widget — \(broken) tracker\(broken == 1 ? "" : "s") need attention"
        } else {
            button.toolTip = "Stats Widget from Website"
        }
    }
}

/// NSMenuDelegate proxy that forwards `menuWillOpen` to the
/// MenuBarController shared instance. NSMenu doesn't let us assign
/// `MenuBarController` directly as a delegate because the controller is
/// `@MainActor`-isolated and AppKit can't satisfy the isolation contract
/// implicitly — the proxy hops into the main actor explicitly.
private final class MenuDelegateProxy: NSObject, NSMenuDelegate {
    static let shared = MenuDelegateProxy()
    func menuWillOpen(_ menu: NSMenu) {
        MenuBarController.shared.menuWillOpen()
    }
}
