//
//  LaunchAgentInstaller.swift
//  MacosWidgetsStatsFromWebsite
//
//  Installs / refreshes a per-user LaunchAgent that runs the bundled CLI
//  binary (`Contents/MacOS/macos-widgets-stats-from-website scrape-all
//  --due-only`) on a fixed interval. Introduced in v0.19.0 to fix the
//  long-standing "widget last-updated freezes when the user closes the
//  main window" bug (voice 2026-05-17).
//
//  Why a LaunchAgent (not BGAppRefreshTask, not a menu-bar daemon)?
//  - `NSBackgroundActivityScheduler` only fires while the SwiftUI host app
//    is alive. The moment the user quits the window the scheduler dies and
//    `readings.json` freezes — exactly what the user observed.
//  - `BGAppRefreshTask` has the same lifecycle problem on macOS: it
//    requires the host app to be eligible for resume, which it isn't after
//    a hard quit. It also gates wake cadence to ~15+ min minimums.
//  - A LaunchAgent runs at the user-session level, survives the GUI app
//    quitting entirely, and re-uses the existing in-bundle CLI binary
//    (which already shares the `ChromeCDPScraper` / `AppGroupStore` /
//    `Tracker` code via the Shared target). The CLI runs unsandboxed and
//    has the App Group + keychain entitlements it needs to write
//    `readings.json` and spawn the bundled Chromium.
//
//  Idempotent: install() unconditionally re-writes the plist + reloads the
//  job, so an upgrade picks up new arguments / new bundle paths
//  automatically. uninstall() is provided for completeness (Preferences
//  could expose it later) but the default app lifecycle just calls
//  install() on every launch.
//

import Foundation

enum LaunchAgentInstaller {
    static let agentLabel = "com.ethansk.macos-widgets-stats-from-website.scraper"

    /// LaunchAgent tick cadence. We want the LaunchAgent to fire often
    /// enough that the smallest configured `refreshIntervalSec` is honoured
    /// closely, but not so often that an always-failing tracker burns the
    /// machine on retries (`ScrapeDuePolicy` rate-limits per-tracker by
    /// `lastAttemptedAt`).
    ///
    /// 5 minutes matches the widget timeline reload cadence
    /// (`StatsWidget.swift` Timeline `.after(Date+5min)`) so the widget
    /// re-renders shortly after the CLI writes fresh data.
    static let tickIntervalSec: Int = 300

    /// Installs (or refreshes) the LaunchAgent plist for the current user
    /// and bootstraps it into launchd. Safe to call on every app launch —
    /// the plist is re-written every time so bundle-path changes (e.g.
    /// moving the .app, swapping between dev build and installed copy) are
    /// picked up automatically.
    @discardableResult
    static func installIfPossible() -> Bool {
        guard let cliPath = resolveCLIPath() else {
            ActivityLogger.log("launchagent", "install skipped: CLI binary not found in bundle")
            return false
        }

        do {
            let plistURL = try plistDestinationURL()
            try writePlist(to: plistURL, cliPath: cliPath)
            reloadJob(plistURL: plistURL)
            ActivityLogger.log("launchagent", "installed", metadata: [
                "label": agentLabel,
                "plist": plistURL.path,
                "cli": cliPath
            ])
            return true
        } catch {
            ActivityLogger.log("launchagent", "install failed", metadata: [
                "error": error.localizedDescription
            ])
            return false
        }
    }

    /// Uninstalls the LaunchAgent — boots it out of launchd and removes the
    /// plist. Not currently wired into any user-facing surface; provided so
    /// future Preferences UI can offer "stop background refresh".
    @discardableResult
    static func uninstall() -> Bool {
        do {
            let plistURL = try plistDestinationURL()
            bootOut(plistURL: plistURL)
            try? FileManager.default.removeItem(at: plistURL)
            ActivityLogger.log("launchagent", "uninstalled")
            return true
        } catch {
            ActivityLogger.log("launchagent", "uninstall failed", metadata: [
                "error": error.localizedDescription
            ])
            return false
        }
    }

    // MARK: - Internals

    private static func resolveCLIPath() -> String? {
        // Bundle.main.executableURL points at the main-app binary. The CLI
        // ships alongside it in the same Contents/MacOS directory, named
        // by PRODUCT_NAME (`macos-widgets-stats-from-website`).
        guard let macOSURL = Bundle.main.executableURL?.deletingLastPathComponent() else {
            return nil
        }

        let cliURL = macOSURL.appendingPathComponent("macos-widgets-stats-from-website")
        let path = cliURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }
        return path
    }

    private static func plistDestinationURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let launchAgentsDir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: launchAgentsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return launchAgentsDir.appendingPathComponent("\(agentLabel).plist", isDirectory: false)
    }

    private static func writePlist(to plistURL: URL, cliPath: String) throws {
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [cliPath, "scrape-all", "--due-only"],
            "StartInterval": tickIntervalSec,
            // RunAtLoad fires once when the agent is loaded so the user
            // sees a fresh value immediately after install (without waiting
            // a full StartInterval window).
            "RunAtLoad": true,
            // Don't restart on completion — this is a one-shot tick. The
            // job exits naturally after the CLI returns.
            "KeepAlive": false,
            // Pipe stdout / stderr into ~/Library/Logs so failures are
            // greppable from the unified-log debug workflow. Truncates
            // every time, so the file size stays bounded.
            "StandardOutPath": logPath(suffix: "stdout"),
            "StandardErrorPath": logPath(suffix: "stderr"),
            // Inherit the user's PATH so the CLI can find /usr/bin/open etc.
            "EnvironmentVariables": [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
            ]
            // NOTE: deliberately NOT setting ThrottleInterval. StartInterval
            // already paces spawns; adding ThrottleInterval=300 caused
            // launchctl kickstart to hit a 5-minute cooldown after the first
            // few manual triggers during install verification. KeepAlive=false
            // means launchd won't respawn on its own anyway.
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
    }

    private static func logPath(suffix: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsDir = home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("macOS Widgets Stats from Website", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)
        return logsDir.appendingPathComponent("scraper-launchagent.\(suffix).log").path
    }

    private static func gui_uid_domain() -> String {
        "gui/\(getuid())"
    }

    private static func reloadJob(plistURL: URL) {
        // `bootstrap` registers the plist; if it's already registered we
        // bootout first to ensure the new plist content takes effect.
        bootOut(plistURL: plistURL)
        runLaunchctl(["bootstrap", gui_uid_domain(), plistURL.path])
        // `kickstart -k` (re)starts the job immediately. Without it the
        // user has to wait a full StartInterval for the first tick.
        runLaunchctl(["kickstart", "-k", "\(gui_uid_domain())/\(agentLabel)"])
    }

    private static func bootOut(plistURL: URL) {
        runLaunchctl(["bootout", gui_uid_domain(), plistURL.path])
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            ActivityLogger.log("launchagent", "launchctl spawn failed", metadata: [
                "args": arguments.joined(separator: " "),
                "error": error.localizedDescription
            ])
            return -1
        }

        // launchctl bootout returns non-zero when the job isn't loaded —
        // that's expected on the first install. Only log unexpected
        // outcomes from bootstrap / kickstart at error level.
        if process.terminationStatus != 0, !arguments.contains("bootout") {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let stderrText = String(data: data, encoding: .utf8) ?? ""
            ActivityLogger.log("launchagent", "launchctl non-zero exit", metadata: [
                "args": arguments.joined(separator: " "),
                "status": "\(process.terminationStatus)",
                "stderr": stderrText
            ])
        }
        return process.terminationStatus
    }
}
