//
//  LaunchAgentManager.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.4 — installs a per-user launchd KeepAlive job for the menu-bar
//  agent so crash exits are respawned without relying on SMAppService.
//

import Foundation

enum LaunchAgentManager {
    static let agentLabel = "com.ethansk.macos-widgets-stats-from-website"
    // v0.21.22 renamed the user-facing .app wrapper to
    // "Stats Widget from Website.app" (voice 4002 / MBP-CC bridge
    // msg-65036391). The legacy install location
    // ("/Applications/MacosWidgetsStatsFromWebsite.app") is kept here so
    // `migrateLegacyProgramArgumentsIfNeeded()` can detect a previously
    // installed LaunchAgent that points at the OLD path and rewrite it
    // to the new wrapper name without forcing users to re-install
    // manually. The internal executable name (`MacosWidgetsStatsFromWebsite`)
    // is unchanged — only the .app wrapper directory's filename changed.
    static let appBundlePath = "/Applications/Stats Widget from Website.app"
    static let executablePath = "/Applications/Stats Widget from Website.app/Contents/MacOS/MacosWidgetsStatsFromWebsite"
    static let legacyAppBundlePath = "/Applications/MacosWidgetsStatsFromWebsite.app"
    static let legacyExecutablePath = "/Applications/MacosWidgetsStatsFromWebsite.app/Contents/MacOS/MacosWidgetsStatsFromWebsite"
    static let logPath = "/tmp/stats-widget-launchd.log"

    /// Idempotent startup hook. It writes the LaunchAgent plist and
    /// bootstraps it into the user's Aqua session when the canonical
    /// /Applications install is present.
    static func ensureInstalledAndBootstrapped() {
        // v0.21.22: handle the .app wrapper rename. If a user is running
        // a freshly renamed v0.21.22+ install but the on-disk LaunchAgent
        // plist still references the OLD wrapper path
        // ("/Applications/MacosWidgetsStatsFromWebsite.app/..."), launchd
        // will keep trying to launch the OLD binary on every login until
        // we rewrite the ProgramArguments. Run the migration first so any
        // downstream "already loaded?" check sees the corrected plist.
        // Idempotent — safe on repeated launches and on fresh installs.
        // voice 4002 / MBP-CC bridge msg-65036391.
        migrateLegacyProgramArgumentsIfNeeded()

        guard isRunningFromCanonicalInstall() else {
            ActivityLogger.log("launchd", "LaunchAgent install skipped; app is not running from canonical install path", metadata: [
                "expectedBundle": appBundlePath,
                "bundle": Bundle.main.bundlePath
            ])
            return
        }

        // Resolve which executable path matches the running install (new
        // wrapper vs legacy wrapper — see isRunningFromCanonicalInstall()
        // comment). Sparkle in-place updates keep the legacy directory
        // name, so we MUST use the resolved path here, not the new-only
        // constant. v0.21.22.
        let resolvedExecutable = resolvedExecutablePathForRunningInstall()
        guard FileManager.default.isExecutableFile(atPath: resolvedExecutable) else {
            ActivityLogger.log("launchd", "LaunchAgent install skipped; canonical app executable not present", metadata: [
                "expectedExecutable": resolvedExecutable,
                "bundle": Bundle.main.bundlePath
            ])
            return
        }

        do {
            let plistChanged = try writePlistIfNeeded()
            let launchdManaged = isCurrentProcessLaunchdManaged()
            let loaded = isLoaded()

            if loaded {
                if plistChanged && !launchdManaged {
                    let bootout = runLaunchctl(["bootout", domainTarget()])
                    ActivityLogger.log("launchd", "LaunchAgent reloaded after plist update", metadata: [
                        "bootoutStatus": "\(bootout.status)"
                    ])
                    try bootstrap()
                } else {
                    ActivityLogger.log("launchd", "LaunchAgent already loaded", metadata: [
                        "launchdManaged": "\(launchdManaged)",
                        "plistChanged": "\(plistChanged)",
                        "path": plistURL().path
                    ])
                }
                return
            }

            try bootstrap()
        } catch {
            ActivityLogger.log("launchd", "LaunchAgent install failed", metadata: [
                "error": error.localizedDescription,
                "path": plistURL().path
            ])
            NSLog("[launchd] LaunchAgent install failed: %@", error.localizedDescription)
        }
    }

    /// Startup self-test used by AppDelegate logging. This asks launchd
    /// whether the loaded job's PID is this process.
    static func isCurrentProcessLaunchdManaged() -> Bool {
        let result = runLaunchctl(["print", domainTarget()])
        guard result.status == 0 else { return false }
        return result.output.contains("pid = \(getpid())")
    }

    private static func writePlistIfNeeded() throws -> Bool {
        let destination = plistURL()
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        // v0.21.22: use the resolved (new-vs-legacy) executable path so an
        // in-place Sparkle update from v0.21.21 keeps writing a plist that
        // points at the still-named wrapper directory the user has on
        // disk. Fresh installs / users who manually re-installed with the
        // new wrapper name get the new path. The migration step that runs
        // earlier handles the case where an older plist already exists at
        // the old path — see migrateLegacyProgramArgumentsIfNeeded().
        let resolvedExecutable = resolvedExecutablePathForRunningInstall()

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [resolvedExecutable],
            "RunAtLoad": true,
            "KeepAlive": [
                "SuccessfulExit": false
            ],
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
            "LimitLoadToSessionType": "Aqua"
        ]

        let plistObject = NSDictionary(dictionary: plist)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plistObject,
            format: .xml,
            options: 0
        )

        if let existing = try? Data(contentsOf: destination),
           let existingObject = try? PropertyListSerialization.propertyList(
            from: existing,
            options: [],
            format: nil
           ) as? NSDictionary,
           existingObject.isEqual(plistObject) {
            return false
        }

        try data.write(to: destination, options: .atomic)
        ActivityLogger.log("launchd", "LaunchAgent plist written", metadata: [
            "path": destination.path,
            "executable": resolvedExecutable
        ])
        return true
    }

    /// One-shot migration for users coming from a pre-v0.21.22 install
    /// whose LaunchAgent plist still references a wrapper path that no
    /// longer matches the running install. If the on-disk plist's
    /// ProgramArguments[0] does NOT equal the path that
    /// `resolvedExecutablePathForRunningInstall()` would write, AND that
    /// resolved path is actually executable, rewrite the plist and
    /// `launchctl bootout`+`bootstrap` so launchd loads the corrected
    /// ProgramArguments before `writePlistIfNeeded()` runs.
    ///
    /// Strict idempotency property (Codex xhigh review fix, voice 4002):
    /// every branch below ends in "no migration work to do" UNLESS the
    /// plist genuinely needs to be rewritten to match the running
    /// install's wrapper. Compare against the resolved-for-running path
    /// (NOT the new canonical path) so a user who is launched from the
    /// legacy wrapper does not thrash between legacy and new on every
    /// launch — `writePlistIfNeeded()` will then immediately see the
    /// matching plist and return false, so there is no second rewrite.
    ///
    /// Cases:
    ///   - No existing plist (fresh install) → no-op; writePlistIfNeeded() handles it.
    ///   - Plist already matches resolved path → no-op.
    ///   - Plist references the OTHER wrapper path but the resolved target
    ///     is not executable on disk → defer with a log line; writePlistIfNeeded()
    ///     will then also bail out at its isExecutableFile() guard above.
    ///   - Plist references the OTHER wrapper path AND resolved target is
    ///     executable → rewrite plist + bootout+bootstrap.
    ///
    /// v0.21.22, voice 4002 / MBP-CC bridge msg-65036391.
    private static func migrateLegacyProgramArgumentsIfNeeded() {
        let plistPath = plistURL().path
        guard let existingData = try? Data(contentsOf: URL(fileURLWithPath: plistPath)),
              let parsed = try? PropertyListSerialization.propertyList(
                from: existingData,
                options: [],
                format: nil
              ) as? [String: Any] else {
            // No existing plist (fresh install) or unreadable — nothing
            // to migrate. ensureInstalledAndBootstrapped() will write a
            // fresh plist via the standard code path below.
            return
        }

        guard let programArgs = parsed["ProgramArguments"] as? [String],
              let firstArg = programArgs.first else {
            ActivityLogger.log("launchd", "LaunchAgent migration skipped — plist has no ProgramArguments")
            return
        }

        let resolvedExecutable = resolvedExecutablePathForRunningInstall()
        if firstArg == resolvedExecutable {
            // Plist already matches the running install's wrapper. No
            // rewrite needed — this is the steady-state path on every
            // launch after the first migration AND the path for users
            // who never had legacy state to migrate.
            return
        }

        guard FileManager.default.isExecutableFile(atPath: resolvedExecutable) else {
            ActivityLogger.log("launchd", "LaunchAgent migration deferred — resolved target not executable", metadata: [
                "currentFirstArg": firstArg,
                "resolvedExecutable": resolvedExecutable
            ])
            return
        }

        var rewritten = parsed
        rewritten["ProgramArguments"] = [resolvedExecutable]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: rewritten,
                format: .xml,
                options: 0
            )
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        } catch {
            ActivityLogger.log("launchd", "LaunchAgent migration plist rewrite failed", metadata: [
                "error": error.localizedDescription
            ])
            return
        }

        // Reload launchd so the new ProgramArguments takes effect. The
        // bootout result is logged but not fatal — launchd may report a
        // non-zero status if the job wasn't loaded, which is fine.
        let bootout = runLaunchctl(["bootout", domainTarget()])
        let bootstrap = runLaunchctl(["bootstrap", guiDomain(), plistPath])
        ActivityLogger.log("launchd", "LaunchAgent ProgramArguments migrated to running wrapper", metadata: [
            "from": firstArg,
            "to": resolvedExecutable,
            "bootoutStatus": "\(bootout.status)",
            "bootstrapStatus": "\(bootstrap.status)"
        ])
    }

    private static func bootstrap() throws {
        let result = runLaunchctl(["bootstrap", guiDomain(), plistURL().path])
        if result.status != 0 {
            throw LaunchAgentError.bootstrapFailed(status: result.status, output: result.output)
        }
        ActivityLogger.log("launchd", "LaunchAgent bootstrapped", metadata: [
            "domain": guiDomain(),
            "path": plistURL().path
        ])
    }

    private static func isLoaded() -> Bool {
        runLaunchctl(["print", domainTarget()]).status == 0
    }

    private static func isRunningFromCanonicalInstall() -> Bool {
        // v0.21.22: accept BOTH the new ("/Applications/Stats Widget from
        // Website.app") and legacy ("/Applications/MacosWidgetsStatsFromWebsite.app")
        // wrapper paths as canonical. Sparkle in-place updates a v0.21.21 -> v0.21.22
        // user will preserve the OLD wrapper directory name (Sparkle replaces the
        // bundle CONTENTS but does not rename the outer directory), so the legacy
        // path is still a valid running location for the foreseeable migration
        // window. resolvedExecutablePathForRunningInstall() then picks the right
        // ProgramArguments for the LaunchAgent plist. voice 4002 / MBP-CC bridge
        // msg-65036391.
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let newPath = URL(fileURLWithPath: appBundlePath).resolvingSymlinksInPath().path
        let legacyPath = URL(fileURLWithPath: legacyAppBundlePath).resolvingSymlinksInPath().path
        return current == newPath || current == legacyPath
    }

    /// Resolve the ProgramArguments path that the LaunchAgent plist should
    /// reference, based on the current running install. This mirrors the
    /// dual-path tolerance in `isRunningFromCanonicalInstall()` so an
    /// in-place Sparkle update keeps a working LaunchAgent without
    /// requiring the user to re-install. v0.21.22.
    private static func resolvedExecutablePathForRunningInstall() -> String {
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let legacyPath = URL(fileURLWithPath: legacyAppBundlePath).resolvingSymlinksInPath().path
        if current == legacyPath {
            return legacyExecutablePath
        }
        // Default to the new canonical path. If the user is running from
        // somewhere else entirely, `ensureInstalledAndBootstrapped()`
        // already refused via the canonical-install guard so we don't
        // reach this code path.
        return executablePath
    }

    private static func plistURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist", isDirectory: false)
    }

    private static func guiDomain() -> String {
        "gui/\(getuid())"
    }

    private static func domainTarget() -> String {
        "\(guiDomain())/\(agentLabel)"
    }

    private struct LaunchctlResult {
        let status: Int32
        let output: String
    }

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

    private enum LaunchAgentError: LocalizedError {
        case bootstrapFailed(status: Int32, output: String)

        var errorDescription: String? {
            switch self {
            case let .bootstrapFailed(status, output):
                let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedOutput.isEmpty {
                    return "launchctl bootstrap failed with status \(status)"
                }
                return "launchctl bootstrap failed with status \(status): \(trimmedOutput)"
            }
        }
    }
}
