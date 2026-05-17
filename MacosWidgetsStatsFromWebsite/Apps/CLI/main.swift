//
//  main.swift
//  MacosWidgetsStatsFromWebsiteCLI
//
//  Power-user adjunct and MCP stdio entrypoint.
//

import Foundation
// WidgetKit is needed so the LaunchAgent code path can call
// WidgetCenter.shared.reloadAllTimelines() after scrape-all writes fresh
// readings to the App Group. Without this call macOS does not reliably
// invoke the widget extension's TimelineProvider when the host GUI app is
// not running, even though the timeline policy is `.after(Date+5min)` —
// the system parks the extension under "no host activity" and the desktop
// widget visibly stays stale. v0.19.1 introduced this signal as the
// belt-and-braces partner to the existing reload policy. See PLAN.md
// §9.2 (no macOS widget reload budget) for why poking is safe.
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
                    // Force every placed WidgetKit widget to reload its
                    // timeline. v0.19.1 fix: the widget extension's
                    // TimelineReloadPolicy `.after(Date+5min)` (StatsWidget
                    // line ~197) is correct, but macOS does not reliably
                    // honour it when the host GUI app is fully quit — the
                    // extension gets parked and the desktop widget visibly
                    // freezes on stale data even though the App Group has
                    // fresh readings. Calling reloadAllTimelines from the
                    // CLI (which shares the App Group + team prefix as the
                    // widget extension) wakes the extension's
                    // getTimeline() within seconds. macOS WidgetKit has no
                    // reload budget (PLAN.md §9.2), so calling on every
                    // tick is safe.
                    //
                    // We fire this BEFORE the browser teardown + exit so
                    // any deferred WidgetKit IPC has a chance to flush
                    // while the runloop is still spinning.
                    WidgetCenter.shared.reloadAllTimelines()
                    ActivityLogger.log("cli", "scrape-all reloaded widget timelines")
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
