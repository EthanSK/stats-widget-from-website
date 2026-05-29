//
//  main.swift
//  MacosWidgetsStatsFromWebsiteCLI
//
//  Power-user adjunct and MCP stdio entrypoint.
//
//  v0.21.0 — the scrape loop has moved INSIDE the menu-bar host app
//  (`BackgroundScheduler` running 24/7 inside the always-running app
//  process). The CLI no longer needs to:
//    - run on a LaunchAgent tick (removed in v0.21.0)
//    - spawn the GUI binary in `--background-widget-refresh` mode
//      (removed in v0.21.0; widget reload now fires from the menu-bar
//      host directly)
//    - call `WidgetCenter.reloadAllTimelines()` itself (it was always
//      a no-op from CLI bundle identity anyway)
//
//  What's kept:
//    - `--mcp-stdio` / `mcp-stdio` — the stdio MCP server entrypoint
//      used by external agent integrations.
//    - `mcp-token` — print the current MCP socket token.
//    - `scrape-all [--due-only]` — manual one-shot scrape from a
//      shell. Useful for diagnostics; no longer wired into automation.
//

import Foundation
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
    let dueOnly = arguments.contains("--due-only")
    ScrapeAllCommand.run(dueOnly: dueOnly)

default:
    let marketingVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
    print("macos-widgets-stats-from-website CLI v\(marketingVersion)")
    print("Usage:")
    print("  macos-widgets-stats-from-website mcp-stdio")
    print("  macos-widgets-stats-from-website mcp-token")
    print("  macos-widgets-stats-from-website scrape-all [--due-only]")
    print("")
    print("Note: v0.21.0+ the scrape loop runs inside the always-on")
    print("menu-bar app. The CLI scrape-all command remains for one-")
    print("shot diagnostic use; it is no longer fired automatically.")
}

// MARK: - scrape-all command

private enum ScrapeAllCommand {
    /// Hard timeout — caps the entire CLI invocation so a single hung
    /// scrape can't pin the diagnostic shell-invocation indefinitely.
    static let overallTimeoutSec: TimeInterval = 120

    static func run(dueOnly: Bool) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings
        let plan = DueScrapePlanner.plan(
            configuration: configuration,
            readings: readings,
            force: !dueOnly
        )
        let candidates = plan.candidates

        guard !candidates.isEmpty else {
            print("scrape-all: nothing due (\(plan.configuredCount) trackers configured)")
            ActivityLogger.log("cli", "scrape-all skipped: no due trackers", metadata: [
                "configured": "\(plan.configuredCount)",
                "due_only": "\(dueOnly)",
                "skippedIncomplete": "\(plan.skippedIncompleteCount)"
            ])
            exit(0)
        }

        ActivityLogger.log("cli", "scrape-all starting", metadata: [
            "candidates": "\(candidates.count)",
            "configured": "\(plan.configuredCount)",
            "due_only": "\(dueOnly)",
            "skippedIncomplete": "\(plan.skippedIncompleteCount)"
        ])

        var pending = candidates.count
        var successes = 0
        var failures = 0
        let mutex = DispatchQueue(label: "scrape-all.mutex")

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
                    // v0.21.0 — calling reloadAllTimelines here is a
                    // documented no-op from CLI bundle identity, BUT
                    // the menu-bar host has a PendingScrapeRequestStore
                    // file watcher. Write a reload sentinel so the host
                    // wakes up the widget on our behalf.
                    do {
                        try PendingScrapeRequestStore.requestScrape(
                            trackerID: PendingScrapeRequest.reloadTimelinesSentinel
                        )
                    } catch {
                        ActivityLogger.log("cli", "reload sentinel write failed", metadata: [
                            "error": error.localizedDescription
                        ])
                    }
                    ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
                    exit(failures > 0 ? 1 : 0)
                }
            }
        }

        dispatchMain()
    }
}
