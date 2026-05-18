//
//  MainPreferencesWindowController.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.0 — owns the on-demand preferences window for the menu-bar
//  agent. Pre-0.21 the app used a SwiftUI `WindowGroup` scene that
//  AppKit auto-presented at launch, which is incompatible with the
//  `LSUIElement=true` menu-bar pattern (no foreground / Dock icon, so
//  the auto-present silently fails — or, depending on AppKit version,
//  briefly flashes a window the user never asked for).
//
//  Instead we host the SwiftUI ContentView inside an NSHostingController
//  + NSWindow that we instantiate ONLY when the user explicitly asks
//  for it (menu bar > Open Preferences, or a deep link / second-launch).
//
//  Activation policy:
//    When the window is shown we temporarily switch
//    `NSApp.setActivationPolicy(.regular)` so the user gets a proper
//    Dock icon + menu bar while interacting. When the window is closed
//    we drop back to `.accessory` so the Dock icon disappears. This
//    matches what Stats / Lungo / iStat Menus do.
//

import AppKit
import SwiftUI

final class MainPreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = MainPreferencesWindowController()

    private var window: NSWindow?
    private var store: AppGroupStore?
    private var backgroundScheduler: BackgroundScheduler?

    private override init() {
        super.init()
    }

    func configure(store: AppGroupStore, backgroundScheduler: BackgroundScheduler) {
        self.store = store
        self.backgroundScheduler = backgroundScheduler
    }

    /// Materialise (or refocus) the preferences window. Switches the
    /// app's activation policy to `.regular` for the duration so the
    /// user sees a normal Dock icon + window chrome. Safe to call from
    /// any thread, but hops to main if necessary.
    func showWindow(section: PreferencesSection = .trackers) {
        if Thread.isMainThread {
            showWindowMainActor(section: section)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.showWindowMainActor(section: section)
            }
        }
    }

    private func showWindowMainActor(section: PreferencesSection) {
        guard let store, let backgroundScheduler else {
            ActivityLogger.log("prefs-window", "showWindow called before configure()")
            return
        }

        // Temporarily promote the app to a regular foreground app so
        // the window has a Dock icon + can become key/main without
        // weirdness.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let existing = window {
            NotificationCenter.default.post(
                name: .menuBarPreferencesSectionRequested,
                object: nil,
                userInfo: ["section": section.rawValue]
            )
            existing.makeKeyAndOrderFront(nil)
            ActivityLogger.log("prefs-window", "re-focused existing window", metadata: [
                "section": section.rawValue
            ])
            return
        }

        let rootView = ContentView()
            .environmentObject(store)
            .environmentObject(backgroundScheduler)
        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.contentViewController = hosting
        newWindow.title = "Stats Widget from Website"
        newWindow.minSize = NSSize(width: 780, height: 520)
        newWindow.delegate = self
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        // We DON'T set NSWindowStyleMaskFullSizeContentView — keep the
        // standard titlebar so the user can drag/move the window
        // normally.
        window = newWindow

        // Post the section request slightly after the window appears so
        // ContentView's onReceive has a chance to wire its subscription.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .menuBarPreferencesSectionRequested,
                object: nil,
                userInfo: ["section": section.rawValue]
            )
        }

        newWindow.makeKeyAndOrderFront(nil)
        ActivityLogger.log("prefs-window", "opened", metadata: [
            "section": section.rawValue
        ])
    }

    func windowWillClose(_ notification: Notification) {
        ActivityLogger.log("prefs-window", "closed; reverting to accessory")
        // Drop the Dock icon when the user closes the window — we go
        // back to being a pure menu-bar agent.
        NSApp.setActivationPolicy(.accessory)
        // Don't nil out `window` — we want subsequent showWindow() calls
        // to re-use the same NSWindow instance (cheaper) AND avoid the
        // SwiftUI view's `@State` being thrown away mid-session. The
        // window is hidden but kept alive.
    }
}

extension Notification.Name {
    static let menuBarPreferencesSectionRequested = Notification.Name(
        "com.ethansk.macos-widgets-stats-from-website.menuBarPreferencesSectionRequested"
    )
}
