//
//  BackgroundWidgetRefreshRunner.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.20.0 — invisible, host-process-identity widget timeline refresh.
//
//  The LaunchAgent's `scrape-all` CLI writes fresh data to the App Group
//  every 5 minutes, but macOS WidgetKit will not wake a parked widget
//  extension just because the CLI calls `reloadAllTimelines()`. The
//  canonical fix is to briefly relaunch the host GUI binary in
//  background-only mode so `reloadAllTimelines()` is invoked from the
//  host's process identity — that DOES wake the extension.
//
//  Invocation contract:
//    /Applications/MacosWidgetsStatsFromWebsite.app/Contents/MacOS/MacosWidgetsStatsFromWebsite \
//      --background-widget-refresh
//
//  Or via env var (covers the case where Swift's CommandLine parser is
//  stripped by some launch path):
//    STATS_WIDGET_BG_REFRESH=1
//
//  Observed behaviour when wired correctly:
//    - No Dock icon bounce (activation policy is `.prohibited` BEFORE any
//      window can present).
//    - No window appears.
//    - Process appears in `ps` for ~1.5 s then exits cleanly.
//    - Within a few seconds the WidgetExtension's TimelineProvider fires
//      and the widget repaints with the fresh App Group reading.
//

import AppKit
import Darwin
import Foundation
import WidgetKit

enum BackgroundWidgetRefreshRunner {
    static let flag = "--background-widget-refresh"
    static let envVarName = "STATS_WIDGET_BG_REFRESH"

    /// How long to keep the process alive after asking WidgetKit to
    /// reload. WidgetKit dispatches the reload over XPC, so the host
    /// needs to be alive long enough for the request to actually land
    /// with `chronod` and the extension to be scheduled. Empirically
    /// 1.5 s is plenty; bumped to 2.0 s for a small safety margin
    /// against system load spikes.
    static let runloopHoldSeconds: TimeInterval = 2.0

    /// True iff the current invocation should run the headless refresh
    /// path (and skip every other startup side effect).
    static func isInvokedForBackgroundRefresh() -> Bool {
        if CommandLine.arguments.contains(flag) {
            return true
        }
        if let envValue = ProcessInfo.processInfo.environment[envVarName],
           envValue == "1" || envValue.lowercased() == "true" {
            return true
        }
        return false
    }

    /// Headless refresh path. Sets the activation policy to `.prohibited`
    /// to suppress all UI, asks WidgetKit to reload every placed widget,
    /// holds the run loop briefly so the IPC actually flushes, and exits.
    /// Never returns.
    static func runAndExit() -> Never {
        // Touching `NSApplication.shared` materialises NSApp if it does
        // not already exist. We're called from `App.init()`, which is
        // SwiftUI's `@main`-driven entry point — by this point AppKit
        // has bootstrapped enough that NSApp is available, but reading
        // `.shared` explicitly is the defensive belt-and-braces form.
        //
        // `.prohibited` MUST be set BEFORE any window can present so
        // no Dock icon flash / window flash reaches the user. We're
        // upstream of SwiftUI's Scene construction at this point.
        NSApplication.shared.setActivationPolicy(.prohibited)

        // ActivityLogger writes to the same log file the GUI uses, so
        // the entry shows up next to the normal "app launch" entries
        // and is greppable from `~/Library/Logs/macOS Widgets Stats from Website/`.
        ActivityLogger.log("app", "background widget refresh starting", metadata: [
            "pid": "\(getpid())"
        ])

        WidgetCenter.shared.reloadAllTimelines()

        ActivityLogger.log("app", "background widget refresh reloaded timelines")

        // Spin the main run loop briefly so any deferred WidgetKit IPC
        // has time to flush before the process exits. RunLoop.run(until:)
        // is the supported way to do this from a non-async context — a
        // bare `Thread.sleep` would block any AppKit work that needs the
        // main run loop.
        let deadline = Date().addingTimeInterval(runloopHoldSeconds)
        RunLoop.main.run(until: deadline)

        ActivityLogger.log("app", "background widget refresh exiting")
        Darwin.exit(0)
    }
}
