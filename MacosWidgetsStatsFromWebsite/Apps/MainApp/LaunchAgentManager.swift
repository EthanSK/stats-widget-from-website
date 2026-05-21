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
    static let appBundlePath = "/Applications/MacosWidgetsStatsFromWebsite.app"
    static let executablePath = "/Applications/MacosWidgetsStatsFromWebsite.app/Contents/MacOS/MacosWidgetsStatsFromWebsite"
    static let logPath = "/tmp/stats-widget-launchd.log"

    /// Idempotent startup hook. It writes the LaunchAgent plist and
    /// bootstraps it into the user's Aqua session when the canonical
    /// /Applications install is present.
    static func ensureInstalledAndBootstrapped() {
        guard isRunningFromCanonicalInstall() else {
            ActivityLogger.log("launchd", "LaunchAgent install skipped; app is not running from canonical install path", metadata: [
                "expectedBundle": appBundlePath,
                "bundle": Bundle.main.bundlePath
            ])
            return
        }

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            ActivityLogger.log("launchd", "LaunchAgent install skipped; canonical app executable not present", metadata: [
                "expectedExecutable": executablePath,
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

        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executablePath],
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
            "executable": executablePath
        ])
        return true
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
        let current = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let expected = URL(fileURLWithPath: appBundlePath).resolvingSymlinksInPath().path
        return current == expected
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
