//
//  MainPreferencesWindowController.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.32 — owns the preferences window for the hybrid-UX app
//  (Dock icon + menu-bar status item + long-running host).
//
//  History: pre-v0.21 the app used a SwiftUI `WindowGroup` scene that
//  AppKit auto-presented at launch (clashed with the LSUIElement=true
//  menu-bar pattern). v0.21.0–0.21.31 ran as a pure menu-bar agent
//  with the window opened only on demand. v0.21.32 reverts to a
//  Dock-visible app (LSUIElement=false) while keeping the on-demand
//  window-controller path because it gives us deep-link section
//  routing + window reuse + explicit activation control that a
//  WindowGroup scene wouldn't.
//
//  The actual auto-open-on-launch happens in
//  `AppDelegate.applicationDidFinishLaunching` calling `showWindow()`.
//
//  Activation policy:
//    From v0.21.32 the app stays at `.regular` for its whole lifetime
//    — `applicationDidFinishLaunching` sets it once, and `showWindow`
//    re-asserts it as a no-op. The previous "revert to .accessory on
//    windowWillClose" behaviour was removed because we now want the
//    Dock icon to stay visible after the user closes the window (so
//    they can click it again to reopen, like any normal app).
//

import AppKit
import SwiftUI

final class MainPreferencesWindowController: NSObject, NSWindowDelegate {
    static let shared = MainPreferencesWindowController()

    private static let minimumWindowSize = NSSize(width: 780, height: 520)
    private static let defaultWindowSize = NSSize(width: 900, height: 620)
    private static let minimumVisibleSpan: CGFloat = 96
    private static let screenMargin: CGFloat = 40

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
            configureWindowSizing(existing)
            repairFrameIfNeeded(for: existing, context: "refocus")
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
            contentRect: NSRect(origin: .zero, size: Self.defaultWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        newWindow.contentViewController = hosting
        newWindow.title = "Stats Widget from Website"
        configureWindowSizing(newWindow)
        newWindow.delegate = self
        newWindow.center()
        repairFrameIfNeeded(for: newWindow, context: "open")
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
        // v0.21.32 — DO NOT revert to .accessory here. The hybrid-UX
        // model wants the Dock icon to stay visible so the user can
        // click it again to reopen the prefs window
        // (`applicationShouldHandleReopen` handles that). Previously
        // (v0.21.0–0.21.31) we dropped to .accessory on close, which
        // hid the Dock icon and made the app feel "gone" even though
        // the host process was still running for widget refreshes.
        ActivityLogger.log("prefs-window", "closed; staying at .regular for hybrid UX")
        // Don't nil out `window` — we want subsequent showWindow() calls
        // to re-use the same NSWindow instance (cheaper) AND avoid the
        // SwiftUI view's `@State` being thrown away mid-session. The
        // window is hidden but kept alive.
    }

    private func configureWindowSizing(_ window: NSWindow) {
        window.minSize = Self.minimumWindowSize
        window.contentMinSize = Self.minimumWindowSize
    }

    private func repairFrameIfNeeded(for window: NSWindow, context: String) {
        let frame = window.frame
        let visibleSpan = Self.visibleSpan(for: frame)
        let hasInvalidGeometry = !Self.isFinite(frame)
        let hasInvalidSize = frame.width < Self.minimumWindowSize.width || frame.height < Self.minimumWindowSize.height
        let isEffectivelyHidden = visibleSpan.width < Self.minimumVisibleSpan || visibleSpan.height < Self.minimumVisibleSpan

        guard hasInvalidGeometry || hasInvalidSize || isEffectivelyHidden else {
            return
        }

        guard let targetScreen = Self.bestScreen(for: frame) ?? window.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.setFrame(NSRect(origin: .zero, size: Self.defaultWindowSize), display: true)
            ActivityLogger.log("prefs-window", "repaired window frame without screen", metadata: [
                "context": context,
                "previous": Self.describe(frame),
                "next": Self.describe(window.frame)
            ])
            return
        }

        let nextFrame = Self.defaultFrame(on: targetScreen)
        window.setFrame(nextFrame, display: true)
        ActivityLogger.log("prefs-window", "repaired window frame", metadata: [
            "context": context,
            "previous": Self.describe(frame),
            "next": Self.describe(nextFrame),
            "screen": targetScreen.localizedName
        ])
    }

    private static func bestScreen(for frame: NSRect) -> NSScreen? {
        let finiteFrame = isFinite(frame) ? frame : .zero
        let center = NSPoint(x: finiteFrame.midX, y: finiteFrame.midY)

        if let containing = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) {
            return containing
        }

        let intersecting = NSScreen.screens
            .map { screen -> (screen: NSScreen, area: CGFloat) in
                let intersection = screen.visibleFrame.intersection(finiteFrame)
                return (screen, max(0, intersection.width) * max(0, intersection.height))
            }
            .max { lhs, rhs in lhs.area < rhs.area }

        if let intersecting, intersecting.area > 0 {
            return intersecting.screen
        }

        return NSScreen.main ?? NSScreen.screens.first
    }

    private static func defaultFrame(on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let maxWidth = max(minimumWindowSize.width, visible.width - screenMargin * 2)
        let maxHeight = max(minimumWindowSize.height, visible.height - screenMargin * 2)
        let width = min(defaultWindowSize.width, maxWidth)
        let height = min(defaultWindowSize.height, maxHeight)
        let x = visible.midX - width / 2
        let y = visible.midY - height / 2
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func visibleSpan(for frame: NSRect) -> NSSize {
        guard isFinite(frame) else {
            return .zero
        }

        return NSScreen.screens.reduce(.zero) { best, screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return NSSize(
                width: max(best.width, max(0, intersection.width)),
                height: max(best.height, max(0, intersection.height))
            )
        }
    }

    private static func isFinite(_ frame: NSRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.size.width.isFinite
            && frame.size.height.isFinite
    }

    private static func describe(_ frame: NSRect) -> String {
        "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))"
    }
}

extension Notification.Name {
    static let menuBarPreferencesSectionRequested = Notification.Name(
        "com.ethansk.macos-widgets-stats-from-website.menuBarPreferencesSectionRequested"
    )
}
