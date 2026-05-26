//
//  LaunchAgentManager.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.35 — REPURPOSED to one-shot migrator only.
//
//  History: v0.21.4–v0.21.34 used this enum to install a per-user
//  LaunchAgent (`~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.plist`)
//  that directly exec'd the host binary at login. The LaunchAgent's
//  `ProgramArguments` model gave the running process an `osservice`
//  identity under launchd, NOT a LaunchServices foreground-app identity.
//  Symptom: after the app was running, double-clicking the .app bundle
//  in Finder returned `-600 / "Application isn't running"` because
//  LaunchServices refused to start a second instance for a bundle ID it
//  already saw as running, and the osservice could not receive the
//  reopen event (no LaunchServices identity).
//
//  v0.21.35 switches to `SMAppService.mainApp` (see LoginItemManager.swift)
//  which registers the .app for login launches via LaunchServices —
//  preserving the foreground-app identity so Finder double-clicks
//  coexist with the running process. This file is now JUST the
//  migration path that tears down the legacy LaunchAgent plist on
//  upgrade.
//
//  See LEARNINGS.md entry "v0.21.35 LaunchAgent → SMAppService" for the
//  full root-cause analysis.
//

import Foundation

enum LaunchAgentManager {
    /// Label of the legacy host LaunchAgent (created by v0.21.4–v0.21.34).
    /// MUST match the `Label` key the old `writePlistIfNeeded()` wrote, or
    /// `launchctl bootout` will silently do nothing.
    static let legacyAgentLabel = "com.ethansk.macos-widgets-stats-from-website"

    /// One-shot migration from the v0.21.x LaunchAgent model to the
    /// v0.21.35 SMAppService model. Idempotent — safe to call on every
    /// launch; performs no work after the first run.
    ///
    /// Steps:
    ///   1. If `~/Library/LaunchAgents/<label>.plist` doesn't exist,
    ///      nothing to migrate (fresh install or already-migrated). Return.
    ///   2. Bootout the running job from the user's GUI domain. This
    ///      stops launchd from respawning the binary on next exit and
    ///      removes the `osservice` identity that was blocking Finder
    ///      double-click launches.
    ///   3. Delete the plist file from disk so a future
    ///      `launchctl bootstrap` can't reload it accidentally (e.g. via
    ///      the stale stats-widget-host-watchdog script).
    ///   4. Log the result via `ActivityLogger` so the migration is
    ///      visible in the activity log if Ethan wants to verify.
    ///
    /// Note on the host-watchdog: `~/.claude/scripts/stats-widget-host-watchdog.sh`
    /// guards against the "plist missing" case (line 262 — logs
    /// `watchdog.no-op host_plist_missing app_likely_uninstalled` and
    /// exits without trying to bootstrap). So after migration the
    /// watchdog will quietly no-op every 5 minutes until it's removed.
    /// We don't attempt to unload the watchdog itself from inside the
    /// app — that's Ethan-territory (separate LaunchAgent owned by the
    /// dot-claude infra).
    static func removeLegacyHostLaunchAgent() {
        let fm = FileManager.default
        let plistPath = legacyPlistURL().path

        // Step 1 — fast path: nothing on disk means nothing to undo.
        guard fm.fileExists(atPath: plistPath) else {
            ActivityLogger.log("launchd-migrator", "legacy host LaunchAgent plist not present; nothing to migrate", metadata: [
                "expectedPath": plistPath
            ])
            return
        }

        ActivityLogger.log("launchd-migrator", "legacy host LaunchAgent plist detected; tearing down", metadata: [
            "path": plistPath
        ])

        // Step 2 — `launchctl bootout` to stop the running job. The
        // bootout target must use the FULL domain target form
        // (`gui/<uid>/<label>`) for a per-user LaunchAgent. A non-zero
        // status here is normal if the job wasn't actually loaded
        // (e.g. user already manually bootout'd it earlier today); we
        // log and continue to step 3 either way.
        let bootoutResult = runLaunchctl(["bootout", domainTarget()])
        ActivityLogger.log("launchd-migrator", "launchctl bootout completed", metadata: [
            "status": "\(bootoutResult.status)",
            "domainTarget": domainTarget()
        ])

        // Step 3 — delete the plist file from disk. Once it's gone, the
        // legacy LaunchAgent path can't ever respawn the binary again
        // (launchd only reloads files in `~/Library/LaunchAgents/` at
        // login; no on-disk file = nothing to reload). We're deliberate
        // about REMOVAL rather than RENAME (vs LegacyLaunchAgentMigrator's
        // .DISABLED suffix dance for the older scraper plist): the
        // failure mode for the HOST plist is "Finder double-click broken",
        // which is more user-visible than scraper-double-fire, and we
        // don't want any backdoor to re-enable it.
        do {
            try fm.removeItem(atPath: plistPath)
            ActivityLogger.log("launchd-migrator", "legacy host LaunchAgent plist deleted", metadata: [
                "path": plistPath
            ])
        } catch {
            // Soft failure — log it but don't throw. Most likely cause is
            // a permissions issue (file owned by a different UID after a
            // restore-from-Time-Machine), which Ethan can sort out
            // manually. The bootout in step 2 already stopped the
            // running job, so the immediate Finder-double-click bug is
            // fixed even if file deletion failed.
            ActivityLogger.log("launchd-migrator", "legacy host LaunchAgent plist delete failed (non-fatal)", metadata: [
                "path": plistPath,
                "error": error.localizedDescription
            ])
        }
    }

    // MARK: - Internals

    /// Location of the legacy host LaunchAgent plist as written by
    /// v0.21.4–v0.21.34's `writePlistIfNeeded()`. Hardcoded path —
    /// `legacyAgentLabel` + standard `~/Library/LaunchAgents/`.
    private static func legacyPlistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(legacyAgentLabel).plist", isDirectory: false)
    }

    /// `gui/<uid>/<label>` — full launchctl domain target string for the
    /// user's Aqua session. `bootout` needs this form, not just the
    /// label.
    private static func domainTarget() -> String {
        "gui/\(getuid())/\(legacyAgentLabel)"
    }

    private struct LaunchctlResult {
        let status: Int32
        let output: String
    }

    /// Run `/bin/launchctl <args...>` and capture stdout+stderr. Returns
    /// the exit status + combined output. Failures to spawn launchctl
    /// itself (extraordinarily rare on macOS) map to status -1 with the
    /// localized error string as output.
    private static func runLaunchctl(_ arguments: [String]) -> LaunchctlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
            process.waitUntilExit()
            var data = stdout.fileHandleForReading.readDataToEndOfFile()
            data.append(stderr.fileHandleForReading.readDataToEndOfFile())
            let output = String(data: data, encoding: .utf8) ?? ""
            return LaunchctlResult(status: process.terminationStatus, output: output)
        } catch {
            return LaunchctlResult(status: -1, output: error.localizedDescription)
        }
    }
}
