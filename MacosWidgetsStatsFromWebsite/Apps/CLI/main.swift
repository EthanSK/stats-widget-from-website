//
//  main.swift
//  MacosWidgetsStatsFromWebsiteCLI
//
//  Power-user adjunct and MCP stdio entrypoint.
//

import AppKit
import Foundation
// WidgetKit is needed so the LaunchAgent code path can call
// WidgetCenter.shared.reloadAllTimelines() after scrape-all writes fresh
// readings to the App Group. v0.19.1 added this as a belt-and-braces
// partner to the timeline reload policy, BUT empirically it does NOT
// wake a parked widget extension when the host GUI app is fully quit —
// WidgetKit only honours the call from the host app's process identity.
//
// v0.20.0 fixes the actual repaint by spawning the bundled GUI binary
// with `--background-widget-refresh` from this CLI after a successful
// scrape; the GUI binary calls `reloadAllTimelines()` from the right
// identity and exits ~2 s later (see BackgroundWidgetRefreshRunner).
// The direct call below is kept as a no-op-cheap fallback so the
// LaunchAgent path stays self-contained if the GUI binary lookup ever
// fails.
import WidgetKit

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--mcp-stdio") || arguments.first == "mcp-stdio" {
    MCPServer.shared.runStdioServer()
    exit(0)
}

switch arguments.first {
case "mcp-token":
    if let token = MCPServer.shared.currentToken() {
        print(token)
    } else {
        fputs("No MCP token is available. Launch the app to start the socket server.\n", stderr)
        exit(1)
    }

case "scrape-all":
    // LaunchAgent-driven background scrape entrypoint (v0.19.0+). Reads
    // the shared App Group configuration, decides which trackers are
    // currently due based on `ScrapeDuePolicy`, runs Chrome/CDP scrapes
    // against them in parallel, and exits when all complete. This is the
    // path that fixes the "widget freezes when GUI app is closed" bug —
    // the LaunchAgent fires us every 5 minutes regardless of whether the
    // SwiftUI app is alive.
    let dueOnly = arguments.contains("--due-only")
    ScrapeAllCommand.run(dueOnly: dueOnly)

default:
    // Read CFBundleShortVersionString from the embedded Info.plist (xcodebuild
    // links the CLI Info.plist into the binary via INFOPLIST_FILE). Single
    // source of truth lives in project.yml MARKETING_VERSION; see AGENTS.md.
    let marketingVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    print("macos-widgets-stats-from-website CLI v\(marketingVersion)")
    print("Usage:")
    print("  macos-widgets-stats-from-website mcp-stdio")
    print("  macos-widgets-stats-from-website mcp-token")
    print("  macos-widgets-stats-from-website scrape-all [--due-only]")
}

// MARK: - scrape-all command

private enum ScrapeAllCommand {
    /// Hard timeout — caps the entire CLI invocation so a single hung
    /// scrape can't pin the LaunchAgent's slot indefinitely. Each
    /// individual scrape inside ChromeCDPScraper already has its own
    /// per-tracker timeout (`armTimeout()`), but the harness needs a
    /// belt-and-braces upper bound too.
    static let overallTimeoutSec: TimeInterval = 120

    static func run(dueOnly: Bool) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings
        let now = Date()

        let candidates: [Tracker]
        if dueOnly {
            candidates = configuration.trackers.filter { tracker in
                let reading = readings[tracker.id.uuidString]
                return ScrapeDuePolicy.isDue(tracker: tracker, reading: reading, now: now)
            }
        } else {
            candidates = configuration.trackers
        }

        guard !candidates.isEmpty else {
            print("scrape-all: nothing due (\(configuration.trackers.count) trackers configured)")
            ActivityLogger.log("cli", "scrape-all skipped: no due trackers", metadata: [
                "configured": "\(configuration.trackers.count)",
                "due_only": "\(dueOnly)"
            ])
            exit(0)
        }

        ActivityLogger.log("cli", "scrape-all starting", metadata: [
            "candidates": "\(candidates.count)",
            "configured": "\(configuration.trackers.count)",
            "due_only": "\(dueOnly)"
        ])

        // Track per-tracker outcomes for a clean stdout summary at end.
        var pending = candidates.count
        var successes = 0
        var failures = 0
        let mutex = DispatchQueue(label: "scrape-all.mutex")

        // Schedule the hard timeout. If we hit it, force-terminate any
        // app-owned browsers and bail with a non-zero exit so launchd's
        // log captures the partial-completion state.
        let timeoutDeadline = Date().addingTimeInterval(overallTimeoutSec)
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .main)
        timeoutTimer.schedule(deadline: .now() + overallTimeoutSec)
        timeoutTimer.setEventHandler {
            fputs("scrape-all: timed out after \(Int(overallTimeoutSec))s with \(pending) tracker(s) still in flight\n", stderr)
            ActivityLogger.log("cli", "scrape-all timed out", metadata: [
                "pending": "\(pending)",
                "successes": "\(successes)",
                "failures": "\(failures)"
            ])
            // Even on timeout some trackers may have written fresh data
            // before the deadline — wake the widget so those land on
            // screen rather than being held back until next tick.
            if successes > 0 {
                WidgetCenter.shared.reloadAllTimelines()
                ActivityLogger.log("cli", "scrape-all reloaded widget timelines (partial)")
                HeadlessWidgetRelauncher.kickIfNeeded()
            }
            ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
            exit(2)
        }
        timeoutTimer.resume()

        for tracker in candidates {
            ChromeCDPScraper.scrape(tracker: tracker) { result in
                let (didSucceed, errorMessage): (Bool, String?) = {
                    switch result {
                    case .success(let reading):
                        do {
                            try AppGroupStore.record(reading: reading, for: tracker)
                            return (true, nil)
                        } catch {
                            return (false, "record failed: \(error.localizedDescription)")
                        }
                    case .failure(let error):
                        do {
                            _ = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
                        } catch {
                            // Failure-of-the-failure-write is logged but not
                            // surfaced — the original scrape error is the
                            // signal the user cares about.
                            ActivityLogger.log("cli", "recordFailure threw", metadata: [
                                "tracker": tracker.id.uuidString,
                                "error": error.localizedDescription
                            ])
                        }
                        return (false, error.localizedDescription)
                    }
                }()

                mutex.sync {
                    if didSucceed {
                        successes += 1
                    } else {
                        failures += 1
                    }
                    pending -= 1
                }

                let line: String
                if let errorMessage {
                    line = "  - \(tracker.name): FAIL — \(errorMessage)"
                } else {
                    line = "  - \(tracker.name): ok"
                }
                fputs(line + "\n", stdout)

                if pending == 0 {
                    timeoutTimer.cancel()
                    print("scrape-all: \(successes) ok, \(failures) failed (\(Int(Date().timeIntervalSince(timeoutDeadline.addingTimeInterval(-overallTimeoutSec))))s)")
                    ActivityLogger.log("cli", "scrape-all completed", metadata: [
                        "successes": "\(successes)",
                        "failures": "\(failures)"
                    ])
                    // v0.19.1 belt-and-braces signal — does not wake the
                    // extension on its own but is cheap and safe to call.
                    WidgetCenter.shared.reloadAllTimelines()
                    ActivityLogger.log("cli", "scrape-all reloaded widget timelines")
                    // v0.20.0 — the actual repaint-trigger. Spawn the GUI
                    // binary in invisible background-refresh mode so
                    // WidgetCenter.reloadAllTimelines() runs from the
                    // host's process identity, which is the only thing
                    // macOS will accept as a wake signal for the parked
                    // widget extension. Fire-and-forget — we don't block
                    // the CLI's exit on the GUI binary's lifecycle.
                    HeadlessWidgetRelauncher.kickIfNeeded()
                    // Best-effort browser teardown — match what
                    // applicationWillTerminate does in the GUI app.
                    ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
                    exit(failures > 0 ? 1 : 0)
                }
            }
        }

        // Run the main run loop so async callbacks fire. ChromeCDPScraper
        // dispatches to DispatchQueue.main internally, so the CLI MUST
        // drive the main run loop forward until either every scrape
        // completes (its callback calls exit()) or the overall timeout
        // fires.
        dispatchMain()
    }
}

// MARK: - Headless GUI relaunch for widget refresh (v0.20.0)

/// Spawns the bundled GUI binary in invisible background-refresh mode so
/// WidgetCenter.reloadAllTimelines() runs from the host app's process
/// identity. The widget extension only wakes when the call originates
/// from the host — calling it from this CLI (different bundle id) is a
/// no-op even with matching App Group entitlements (verified empirically
/// on v0.19.1).
///
/// Hardcoded bundle id of the main app — kept in sync with
/// AppDelegate.mainBundleIdentifier. Hardcoding avoids a runtime
/// dependency on Bundle metadata that the CLI doesn't otherwise need.
private let mainAppBundleIdentifier = "com.ethansk.macos-widgets-stats-from-website"

/// Background-refresh flag — kept in sync with
/// BackgroundWidgetRefreshRunner.flag in Apps/MainApp. The MainApp
/// directory is NOT in the CLI target's source set (see project.yml
/// MacosWidgetsStatsFromWebsiteCLI.sources), so we hardcode the
/// literal here. If you change one, change both.
private let backgroundWidgetRefreshFlag = "--background-widget-refresh"

private enum HeadlessWidgetRelauncher {
    /// Decides whether to spawn the GUI binary in background-refresh
    /// mode. Skips when the GUI app is already running (the running
    /// instance's normal store/onChange wiring already calls
    /// reloadWidgets() — see MacosWidgetsStatsFromWebsiteApp.body —
    /// AND it already has the correct process identity, so we don't
    /// need a second copy fighting it for the App Group container).
    /// Fire-and-forget — never blocks the caller.
    static func kickIfNeeded() {
        if isMainAppAlreadyRunning() {
            ActivityLogger.log("cli", "headless widget relaunch skipped: GUI already running")
            return
        }

        guard let guiBinaryPath = resolveGUIBinaryPath() else {
            ActivityLogger.log("cli", "headless widget relaunch skipped: GUI binary not found in bundle")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: guiBinaryPath)
        process.arguments = [backgroundWidgetRefreshFlag]
        // Detach stdio so the child does not inherit the LaunchAgent's
        // log file handles; the child writes its own ActivityLogger
        // entries via the GUI app's normal log file.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            ActivityLogger.log("cli", "headless widget relaunch spawned", metadata: [
                "pid": "\(process.processIdentifier)",
                "binary": guiBinaryPath
            ])
            // Fire-and-forget: do NOT call waitUntilExit() — the CLI is
            // about to call exit() and we don't want to block on the
            // GUI binary's ~2 s runloop hold. The child is a normal
            // detached subprocess from launchd's POV; it will not be
            // reparented or zombied because the CLI exits before
            // becoming a parent that needs to reap it (launchd
            // adopts the orphan if the CLI dies first).
        } catch {
            ActivityLogger.log("cli", "headless widget relaunch spawn failed", metadata: [
                "binary": guiBinaryPath,
                "error": error.localizedDescription
            ])
        }
    }

    /// "Already running" = at least one `NSRunningApplication` with the
    /// main bundle id, EXCLUDING any prior background-refresh process
    /// that might still be in its 2 s hold (we only care about
    /// foreground GUI instances). The headless instance sets activation
    /// policy `.prohibited` BEFORE any registration so it never shows
    /// up as a running app with `.regular` policy; we filter on that to
    /// avoid the two-headless-ticks-in-a-row deadlock.
    static func isMainAppAlreadyRunning() -> Bool {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: mainAppBundleIdentifier)
            .filter { !$0.isTerminated }
        // `.prohibited`-policy processes do not register with the normal
        // running-application list (NSRunningApplication is for `.regular`
        // and `.accessory` policies), so they won't appear here. Defensive
        // filter regardless.
        let foreground = running.filter { $0.activationPolicy != .prohibited }
        return !foreground.isEmpty
    }

    /// Resolves the path to the GUI binary that lives alongside this
    /// CLI inside the .app bundle's Contents/MacOS directory. CLI binary
    /// is `macos-widgets-stats-from-website`; GUI binary is
    /// `MacosWidgetsStatsFromWebsite` (the productName of the main app
    /// target in project.yml — kept in sync with that file).
    private static func resolveGUIBinaryPath() -> String? {
        let cliBinaryURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let macosDir = cliBinaryURL.deletingLastPathComponent()
        let guiBinaryURL = macosDir.appendingPathComponent("MacosWidgetsStatsFromWebsite")
        let path = guiBinaryURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }
}
