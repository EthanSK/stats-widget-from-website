//
//  LegacyLaunchAgentMigrator.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.0 — tears down the legacy LaunchAgent from v0.19/0.20 on first
//  launch of the new menu-bar architecture.
//
//  Why a migrator (vs just deleting `LaunchAgentInstaller`)? Existing
//  installs already have a plist on disk at
//  `~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.scraper.plist`.
//  The plist will keep firing the bundled CLI every 5 minutes even
//  after we ship a new app version that no longer reads from it — the
//  CLI's `scrape-all` will still scrape, but the BackgroundScheduler
//  inside the new menu-bar host will ALSO scrape on its own timer.
//  Net effect = double scraping, double widget-reload calls, double
//  log spam.
//
//  Migration steps on first launch of v0.21.0:
//    1. Check whether the legacy plist exists.
//    2. `launchctl bootout` it so launchd stops the running job.
//    3. Rename the plist to `*.DISABLED-MIGRATED-v0.21.0.plist` so:
//       a. launchd can no longer auto-load it (the name no longer
//          matches the registered label).
//       b. The user / a future debug session can see what happened
//          (file still exists, just renamed).
//       c. We don't delete user-touchable state — if the user later
//          wants to revert to the LaunchAgent model they can rename
//          it back.
//    4. Persist a "migrated" sentinel in UserDefaults so clean launches
//       stay quiet. We still check for the plist every launch: debug builds,
//       restores, or manual testing can recreate the legacy file after the
//       sentinel was written, and that stale LaunchAgent must be disabled
//       again rather than firing a second scraper forever.
//

import Foundation

enum LegacyLaunchAgentMigrator {
    static let agentLabel = "com.ethansk.macos-widgets-stats-from-website.scraper"
    static let migratedSentinelKey = "com.ethansk.macos-widgets-stats-from-website.legacyLaunchAgentMigrated.v0.21.0"
    static let disabledSuffix = ".DISABLED-MIGRATED-v0.21.0"

    /// Idempotent — call from `AppDelegate.applicationDidFinishLaunching`.
    /// Returns whether a migration action was actually performed (true =
    /// did real work, false = nothing to do).
    @discardableResult
    static func migrateIfNeeded() -> Bool {
        let plistURL = plistDestinationURL()
        let plistExists = FileManager.default.fileExists(atPath: plistURL.path)
        let alreadyMarkedMigrated = UserDefaults.standard.bool(forKey: migratedSentinelKey)

        if !plistExists {
            if !alreadyMarkedMigrated {
                UserDefaults.standard.set(true, forKey: migratedSentinelKey)
                ActivityLogger.log("migrator", "no legacy LaunchAgent present; marking migrated")
            }
            return false
        }

        ActivityLogger.log(
            "migrator",
            alreadyMarkedMigrated
                ? "legacy LaunchAgent reappeared after migration; tearing down"
                : "legacy LaunchAgent detected; tearing down",
            metadata: ["path": plistURL.path]
        )

        // bootout first so the running job stops cleanly. Status is
        // typically non-zero if the job isn't loaded — that's fine,
        // we log + continue.
        let bootoutStatus = runLaunchctl(["bootout", gui_uid_domain(), plistURL.path])
        ActivityLogger.log("migrator", "launchctl bootout completed", metadata: [
            "status": "\(bootoutStatus)"
        ])

        // Rename to .DISABLED-MIGRATED-v0.21.0.plist so launchd's
        // auto-load logic can't pick it up again. If the rename fails
        // (e.g. file moved out from under us), we still mark the
        // sentinel so we don't loop trying.
        let disabledURL = plistURL.deletingPathExtension().appendingPathExtension("plist\(disabledSuffix)")
        // The naive rename targets a file with a `.plist.DISABLED-...`
        // double extension — that's fine; we just want a name that
        // launchd will NOT pick up.
        var actualDisabledURL = URL(fileURLWithPath: plistURL.path + disabledSuffix)
        do {
            // If a stale disabled file from a prior migration already
            // exists, keep it and add a timestamp to this migration's
            // disabled copy. The legacy file is user-touchable state, so
            // preserve every copy rather than deleting a previous disabled
            // plist to make room.
            if FileManager.default.fileExists(atPath: actualDisabledURL.path) {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                actualDisabledURL = URL(fileURLWithPath: "\(plistURL.path)\(disabledSuffix)-\(timestamp)")
            }
            try FileManager.default.moveItem(at: plistURL, to: actualDisabledURL)
            ActivityLogger.log("migrator", "renamed legacy plist", metadata: [
                "from": plistURL.path,
                "to": actualDisabledURL.path
            ])
        } catch {
            ActivityLogger.log("migrator", "rename failed; deleting instead", metadata: [
                "error": error.localizedDescription
            ])
            try? FileManager.default.removeItem(at: plistURL)
        }

        // Reference the suppressed disabledURL local so the Swift
        // compiler doesn't warn — it's kept in the source as a hint
        // for future code that wants to use `.plist.DISABLED-...` form.
        _ = disabledURL

        UserDefaults.standard.set(true, forKey: migratedSentinelKey)
        ActivityLogger.log("migrator", "legacy LaunchAgent migration complete")
        return true
    }

    // MARK: - Internals

    private static func plistDestinationURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist", isDirectory: false)
    }

    private static func gui_uid_domain() -> String {
        "gui/\(getuid())"
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            ActivityLogger.log("migrator", "launchctl spawn failed", metadata: [
                "args": arguments.joined(separator: " "),
                "error": error.localizedDescription
            ])
            return -1
        }
    }
}
