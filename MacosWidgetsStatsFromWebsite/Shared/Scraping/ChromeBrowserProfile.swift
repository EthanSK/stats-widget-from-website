//
//  ChromeBrowserProfile.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  OpenClaw-style Chromium/Chrome profile launcher for Google-login-safe CDP scraping.
//

import AppKit
import Darwin
import Foundation

struct ChromeBrowserLaunchConfiguration: Equatable {
    let profileName: String
    let cdpPort: Int
    let cdpURL: URL
    let userDataDirectory: URL
}

struct ChromeBrowserTarget: Equatable {
    let id: String
    let webSocketDebuggerURL: URL
}

struct ChromeBrowserPageTarget: Equatable {
    let id: String
    let url: URL?
    let title: String
    let webSocketDebuggerURL: URL
}

enum ChromeBrowserProfileError: LocalizedError {
    case browserNotFound
    case launchFailed(String)
    case cdpNotReachable(Int)
    case targetCreationFailed(String)
    case invalidCDPResponse

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            return "Could not find the bundled Chromium browser inside the app bundle. Reinstall macOS Widgets Stats from Website — the build is incomplete."
        case .launchFailed(let message):
            return "Could not launch the browser profile: \(message)"
        case .cdpNotReachable(let port):
            return "Chrome DevTools Protocol did not become reachable on port \(port)."
        case .targetCreationFailed(let message):
            return "Could not create a browser tab: \(message)"
        case .invalidCDPResponse:
            return "Chrome DevTools Protocol returned an unreadable response."
        }
    }
}

final class ChromeBrowserProfile {
    static let shared = ChromeBrowserProfile()
    static let defaultProfileName = Tracker.defaultBrowserProfile

    private let baseCDPPort = 18880
    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "ChromeBrowserProfile")
    private var backgroundLaunchedApplications: [Int: NSRunningApplication] = [:]
    private var backgroundLaunchedProcesses: [Int: Process] = [:]
    private var foregroundLaunchedApplications: [Int: NSRunningApplication] = [:]
    private var foregroundLaunchedProcesses: [Int: Process] = [:]
    private var backgroundUseCounts: [Int: Int] = [:]
    private var userVisiblePorts: Set<Int> = []

    private init() {}

    func configuration(profileName: String = ChromeBrowserProfile.defaultProfileName) -> ChromeBrowserLaunchConfiguration {
        let sanitizedProfileName = safeProfileName(profileName)
        let cdpPort = cdpPort(for: sanitizedProfileName)
        let root = AppGroupPaths.canonicalApplicationSupportURL()
            .appendingPathComponent("Browser", isDirectory: true)
            .appendingPathComponent(sanitizedProfileName, isDirectory: true)
        return ChromeBrowserLaunchConfiguration(
            profileName: profileName,
            cdpPort: cdpPort,
            cdpURL: URL(string: "http://127.0.0.1:\(cdpPort)")!,
            userDataDirectory: root.appendingPathComponent("user-data", isDirectory: true)
        )
    }

    func openVisibleBrowser(
        url: URL?,
        profileName: String = ChromeBrowserProfile.defaultProfileName,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        openVisibleBrowserTarget(url: url, profileName: profileName) { result in
            completion?(result.map { _ in () })
        }
    }

    func openVisibleBrowserTarget(
        url: URL?,
        profileName: String = ChromeBrowserProfile.defaultProfileName,
        completion: ((Result<ChromeBrowserTarget?, Error>) -> Void)? = nil
    ) {
        ensureLaunched(profileName: profileName, foreground: true) { [weak self] result in
            switch result {
            case .success(let configuration):
                guard let url else {
                    completion?(.success(nil))
                    return
                }

                self?.openTab(url: url, configuration: configuration) { tabResult in
                    completion?(tabResult.map { Optional($0) })
                }
            case .failure(let error):
                completion?(.failure(error))
            }
        }
    }

    func ensureLaunched(
        profileName: String = ChromeBrowserProfile.defaultProfileName,
        foreground: Bool = false,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        let configuration = configuration(profileName: profileName)
        if isCDPReachable(configuration: configuration) {
            if foreground {
                // Foreground (Identify-in-Chrome) callers need a VISIBLE Chrome window.
                // The background scraper spawns headless Chrome on the same CDP port; if
                // that headless instance is alive when the user clicks Identify, we MUST
                // tear it down and spawn a headed instance — otherwise CDP is reachable
                // but no window ever appears (the failure mode that caused v0.12.10's
                // "identify is active but no Chrome opens" bug).
                if isExistingInstanceHeadless(configuration: configuration) {
                    ActivityLogger.log("browser", "tearing down headless Chrome to spawn headed instance for foreground identify", metadata: [
                        "profile": configuration.profileName,
                        "port": "\(configuration.cdpPort)"
                    ])
                    terminateHeadlessInstance(configuration: configuration) { [weak self] in
                        self?.spawnNewBrowser(configuration: configuration, foreground: true, completion: completion)
                    }
                    return
                }

                markUserVisible(configuration: configuration)
                activateDedicatedBrowser(configuration: configuration)
                ActivityLogger.log("browser", "reusing existing headed Chrome instance", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)"
                ])
            }
            completion(.success(configuration))
            return
        }

        spawnNewBrowser(configuration: configuration, foreground: foreground, completion: completion)
    }

    private func spawnNewBrowser(
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileManager.createDirectory(at: configuration.userDataDirectory, withIntermediateDirectories: true)
                let browser = try self.resolveBrowser()
                try self.launch(browser: browser, configuration: configuration, foreground: foreground)
                self.waitUntilCDPReachable(configuration: configuration, deadline: Date().addingTimeInterval(12), completion: completion)
            } catch {
                ActivityLogger.log("browser", "launch failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "foreground": foreground ? "true" : "false",
                    "error": error.localizedDescription
                ])
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
        }
    }

    /// Returns true if the dedicated Chrome instance currently serving this CDP port
    /// was launched as a background headless instance (via `--headless=new`). Detected
    /// either from our in-process tracking (the headless was spawned in this app session)
    /// or from the Chrome DevTools `/json/version` User-Agent exposed by the
    /// dedicated CDP port. `ps` is only a best-effort fallback for unsandboxed builds.
    private func isExistingInstanceHeadless(configuration: ChromeBrowserLaunchConfiguration) -> Bool {
        let port = configuration.cdpPort

        let trackedHeadless: Bool = queue.sync {
            // If we have a tracked foreground process/application for this port, the live
            // instance is headed — even if a stale headless tracker is also present.
            if foregroundLaunchedProcesses[port] != nil || foregroundLaunchedApplications[port] != nil {
                return false
            }
            return backgroundLaunchedProcesses[port] != nil || backgroundLaunchedApplications[port] != nil
        }

        if trackedHeadless {
            return true
        }

        // No in-process tracking (e.g. the dedicated Chrome was started by a previous app
        // session). Probe the dedicated CDP endpoint first: Release builds are sandboxed
        // and cannot exec `/bin/ps`, but they can still talk to the Chrome instance they
        // launched on localhost.
        if let cdpHeadless = findDedicatedHeadlessChromeViaCDP(configuration: configuration) {
            return cdpHeadless
        }

        // Best-effort fallback for unsandboxed/dev contexts where CDP did not return
        // readable version metadata.
        return findDedicatedHeadlessChromeViaPS(configuration: configuration)
    }

    private func findDedicatedHeadlessChromeViaCDP(configuration: ChromeBrowserLaunchConfiguration) -> Bool? {
        guard let versionInfo = Self.cdpVersionInfo(configuration: configuration) else {
            ActivityLogger.log("browser", "headless-detection CDP probe failed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)"
            ])
            return nil
        }

        let browser = versionInfo["Browser"] as? String ?? ""
        let userAgent = versionInfo["User-Agent"] as? String ?? ""
        let isHeadless = browser.localizedCaseInsensitiveContains("HeadlessChrome")
            || userAgent.localizedCaseInsensitiveContains("HeadlessChrome")

        ActivityLogger.log("browser", "headless-detection CDP probe", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "browser": browser,
            "userAgentContainsHeadless": userAgent.localizedCaseInsensitiveContains("HeadlessChrome") ? "true" : "false",
            "result": isHeadless ? "headless" : "headed"
        ])

        return isHeadless
    }

    private func findDedicatedHeadlessChromeViaPS(configuration: ChromeBrowserLaunchConfiguration) -> Bool {
        let userDataNeedle = "--user-data-dir=\(configuration.userDataDirectory.path)"
        guard let output = Self.runPSAndReadOutput() else {
            ActivityLogger.log("browser", "headless-detection PS probe failed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)"
            ])
            return false
        }

        var totalLines = 0
        var matchingUserDataDir = 0
        var parentMatches = 0
        var headlessParents = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            totalLines += 1
            let command = String(line)
            guard command.contains(userDataNeedle) else { continue }
            matchingUserDataDir += 1
            // Skip helper renderer/utility/gpu PIDs — they share argv with the parent.
            if command.contains("--type=") { continue }
            parentMatches += 1
            if command.contains("--headless") {
                headlessParents += 1
            }
        }

        let isHeadless = headlessParents > 0

        ActivityLogger.log("browser", "headless-detection PS probe", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "scannedLines": "\(totalLines)",
            "matchingUserDataDir": "\(matchingUserDataDir)",
            "parentMatches": "\(parentMatches)",
            "headlessParents": "\(headlessParents)",
            "result": isHeadless ? "headless" : "headed"
        ])

        return isHeadless
    }

    /// Runs `ps -axwwo pid=,command=` and returns the full stdout as a UTF-8 string.
    ///
    /// IMPORTANT: We must drain the stdout pipe concurrently with the child process
    /// running, NOT after `waitUntilExit()`. The pipe buffer is ~64 KB and `ps -axww`
    /// on a busy system easily exceeds 200 KB; if we let `ps` block on a full pipe
    /// while we wait for it to exit, the whole thing deadlocks. The previous
    /// `process.run() -> waitUntilExit() -> readToEnd()` ordering hit this on Ethan's
    /// machine (≥800 processes, ~220 KB ps output) and made `findDedicatedHeadlessChromeViaPS`
    /// return false, leading the foreground identify path to incorrectly reuse a
    /// running headless Chrome instance instead of tearing it down and spawning a
    /// headed one.
    private static func runPSAndReadOutput() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps", isDirectory: false)
        process.arguments = ["-axwwo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        let lock = NSLock()
        var collected = Data()
        let readHandle = pipe.fileHandleForReading
        readHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            collected.append(chunk)
            lock.unlock()
        }

        do {
            try process.run()
        } catch {
            readHandle.readabilityHandler = nil
            return nil
        }
        process.waitUntilExit()

        // Detach the readabilityHandler and drain anything still buffered. The handler
        // may already have stopped firing (EOF) or we may need to read the trailing
        // bytes synchronously.
        readHandle.readabilityHandler = nil
        let trailing = (try? readHandle.readToEnd()) ?? Data()

        lock.lock()
        collected.append(trailing)
        let snapshot = collected
        lock.unlock()

        return String(data: snapshot, encoding: .utf8)
    }

    private func terminateHeadlessInstance(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping () -> Void
    ) {
        let port = configuration.cdpPort

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.global(qos: .userInitiated).async { completion() }
                return
            }

            // Terminate any in-process tracked headless first.
            let trackedProcess = self.backgroundLaunchedProcesses.removeValue(forKey: port)
            let trackedApplication = self.backgroundLaunchedApplications.removeValue(forKey: port)
            self.backgroundUseCounts[port] = nil

            if let trackedProcess, trackedProcess.isRunning {
                trackedProcess.terminate()
            }
            if let trackedApplication, !trackedApplication.isTerminated {
                DispatchQueue.main.async {
                    trackedApplication.terminate()
                }
            }

            // For untracked-but-running headless (started in a previous app session),
            // ask Chrome to close over CDP first. This works in the Release sandbox,
            // where execing `/bin/ps` is denied.
            self.requestBrowserCloseViaCDP(configuration: configuration) { [weak self] in
                guard let self else {
                    DispatchQueue.global(qos: .userInitiated).async { completion() }
                    return
                }

                self.queue.async {
                    // Non-sandbox fallback: if CDP close did not make the port go away,
                    // resolve via ps and SIGTERM the parent.
                    if self.isCDPReachable(configuration: configuration),
                       let pid = self.findDedicatedBrowserPID(configuration: configuration) {
                        kill(pid, SIGTERM)
                    }

                    // Wait briefly for the CDP port to actually go down so the subsequent
                    // launch sees a non-reachable port. waitUntilCDPGone polls every 100ms
                    // up to 3s.
                    self.waitUntilCDPGone(configuration: configuration, deadline: Date().addingTimeInterval(3)) {
                        completion()
                    }
                }
            }
        }
    }

    private func requestBrowserCloseViaCDP(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping () -> Void
    ) {
        guard let webSocketURL = Self.cdpBrowserWebSocketURL(configuration: configuration) else {
            completion()
            return
        }

        let client = ChromeCDPClient(webSocketURL: webSocketURL)
        let lock = NSLock()
        var didFinish = false

        @discardableResult
        func markFinished() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinish else { return false }
            didFinish = true
            return true
        }

        client.connect()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            guard markFinished() else { return }
            ActivityLogger.log("browser", "Chrome CDP close request timed out", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)"
            ])
            client.close()
            completion()
        }

        client.send(method: "Browser.close") { result in
            guard markFinished() else { return }
            switch result {
            case .success:
                ActivityLogger.log("browser", "requested Chrome close over CDP", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)"
                ])
            case .failure(let error):
                ActivityLogger.log("browser", "Chrome CDP close request failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "error": error.localizedDescription
                ])
            }
            client.close()
            completion()
        }
    }

    private func waitUntilCDPGone(
        configuration: ChromeBrowserLaunchConfiguration,
        deadline: Date,
        completion: @escaping () -> Void
    ) {
        if !isCDPReachable(configuration: configuration) || Date() >= deadline {
            completion()
            return
        }

        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitUntilCDPGone(configuration: configuration, deadline: deadline, completion: completion)
        }
    }

    @discardableResult
    func beginBackgroundUse(profileName: String = ChromeBrowserProfile.defaultProfileName) -> ChromeBrowserLaunchConfiguration {
        let configuration = configuration(profileName: profileName)
        queue.sync {
            backgroundUseCounts[configuration.cdpPort, default: 0] += 1
        }
        return configuration
    }

    func endBackgroundUse(configuration: ChromeBrowserLaunchConfiguration) {
        queue.async { [weak self] in
            guard let self else { return }

            let port = configuration.cdpPort
            let remaining = max(0, (self.backgroundUseCounts[port] ?? 1) - 1)
            if remaining == 0 {
                self.backgroundUseCounts[port] = nil
            } else {
                self.backgroundUseCounts[port] = remaining
            }

            guard remaining == 0, !self.userVisiblePorts.contains(port) else {
                return
            }

            let application = self.backgroundLaunchedApplications.removeValue(forKey: port)
            let process = self.backgroundLaunchedProcesses.removeValue(forKey: port)

            if let process, process.isRunning {
                process.terminate()
            }

            if let application, !application.isTerminated {
                DispatchQueue.main.async {
                    application.terminate()
                }
            }

            if application == nil && process == nil {
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    guard let self else { return }
                    // Defensive: `userVisiblePorts.contains(port)` was already checked above,
                    // but that set only tracks visibility marked in THIS app session. A
                    // user-visible Chrome started by a previous app session bound to the same
                    // CDP port wouldn't appear in `userVisiblePorts` and would otherwise get
                    // closed here. Confirm the existing instance is headless before issuing
                    // the CDP-close. `isExistingInstanceHeadless` returns false when the
                    // instance is headed OR when probing fails — in either case, skip.
                    if self.isExistingInstanceHeadless(configuration: configuration) {
                        self.requestBrowserCloseViaCDP(configuration: configuration) {
                            ActivityLogger.log("browser", "closed app-owned background Chrome after scrape via CDP", metadata: [
                                "profile": configuration.profileName,
                                "port": "\(port)"
                            ])
                        }
                    } else {
                        ActivityLogger.log("browser", "skipped CDP close — instance not confirmed headless", metadata: [
                            "profile": configuration.profileName,
                            "port": "\(port)"
                        ])
                    }
                }
                return
            }

            if application != nil || process != nil {
                ActivityLogger.log("browser", "closed app-owned background Chrome after scrape", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(port)"
                ])
            }
        }
    }

    func terminateAppOwnedBrowsersOnAppExit() {
        let tracked: (applications: [NSRunningApplication], processes: [Process]) = queue.sync {
            let applications = Array(backgroundLaunchedApplications.values) + Array(foregroundLaunchedApplications.values)
            let processes = Array(backgroundLaunchedProcesses.values) + Array(foregroundLaunchedProcesses.values)
            backgroundLaunchedApplications.removeAll()
            foregroundLaunchedApplications.removeAll()
            backgroundLaunchedProcesses.removeAll()
            foregroundLaunchedProcesses.removeAll()
            backgroundUseCounts.removeAll()
            userVisiblePorts.removeAll()
            return (applications, processes)
        }

        for process in tracked.processes where process.isRunning {
            process.terminate()
        }

        for application in tracked.applications where !application.isTerminated {
            application.terminate()
        }

        if !tracked.applications.isEmpty || !tracked.processes.isEmpty {
            ActivityLogger.log("browser", "closed app-owned Chrome profiles on app termination", metadata: [
                "applications": "\(tracked.applications.count)",
                "processes": "\(tracked.processes.count)"
            ])
        }
    }

    func openTab(
        url: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        createTargetRequest(url: url, configuration: configuration, method: "PUT") { [weak self] result in
            switch result {
            case .success:
                completion(result)
            case .failure:
                self?.createTargetRequest(url: url, configuration: configuration, method: "GET", completion: completion)
            }
        }
    }

    func closeTarget(id: String, configuration: ChromeBrowserLaunchConfiguration) {
        guard !id.isEmpty,
              let url = URL(string: "/json/close/\(id)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            return
        }

        URLSession.shared.dataTask(with: url).resume()
    }

    func bestExistingPageTarget(
        preferredTargetID: String?,
        matching url: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        listPageTargets(configuration: configuration) { result in
            switch result {
            case .success(let targets):
                if let preferredTargetID,
                   let preferred = targets.first(where: { $0.id == preferredTargetID }),
                   Self.reuseScore(for: preferred, requestedURL: url) != nil {
                    completion(.success(preferred.asTarget))
                    return
                }

                let rankedTargets: [(score: Int, listIndex: Int, target: ChromeBrowserPageTarget)] = targets.enumerated().compactMap { index, target in
                    guard let score = Self.reuseScore(for: target, requestedURL: url) else { return nil }
                    return (score, index, target)
                }.sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    // Preserve Chrome's /json/list ordering as the final tie-breaker.
                    // In practice this keeps us on the already-visible/user-touched tab
                    // instead of failing and creating a fresh logged-out tab.
                    return lhs.listIndex < rhs.listIndex
                }

                if let bestTarget = rankedTargets.first?.target {
                    completion(.success(bestTarget.asTarget))
                    return
                }

                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("No usable existing CDP browser tab was available to identify.")))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func buildChromeLaunchArguments(configuration: ChromeBrowserLaunchConfiguration, headless: Bool) -> [String] {
        var arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(configuration.cdpPort)",
            "--user-data-dir=\(configuration.userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            "--disable-features=Translate,MediaRouter",
            "--disable-session-crashed-bubble",
            "--hide-crash-restore-bubble",
            "--no-proxy-server",
            // Crash fix (v0.12.14, mode "D"): when this app is sandboxed (Release build
            // distributed via App Group) and we exec Chrome as a child, Chrome inherits
            // our sandbox/responsible-process. Chrome's password manager + cookie
            // encryption (OSCrypt) calls SecKeychain* on a blocking thread-pool worker
            // to fetch its profile encryption key from the macOS Keychain. Inside our
            // sandbox the keychain access for `com.google.Chrome` items returns an
            // unexpected error and Chrome's IMMEDIATE_CRASH/CHECK macro fires
            // (EXC_BREAKPOINT / SIGTRAP on ThreadPoolSingleThreadForegroundBlocking0).
            // Chromium ships two flags specifically for this case:
            //   --password-store=basic  → use an in-profile basic password store
            //                             instead of macOS Keychain.
            //   --use-mock-keychain     → skip OSCrypt's keychain handshake on macOS
            //                             and use a derived fallback key instead.
            // We pass both for both headless AND headed launches: headless dodged the
            // crash by not initializing the password manager the same way, but the
            // headed foreground spawn (introduced in 2103ad5 to fix the v0.12.10
            // "identify is active but no window" bug) hit it on every launch under
            // Release. Belt-and-suspenders is fine here — we never want Chrome to
            // touch the system keychain from our app's user-data-dir anyway, since
            // the data is silo'd to this widget app.
            "--password-store=basic",
            "--use-mock-keychain"
        ]

        if headless {
            arguments.append(contentsOf: [
                "--headless=new",
                "--disable-gpu"
            ])
        }

        return arguments
    }

    private func launch(browser: ResolvedBrowser, configuration: ChromeBrowserLaunchConfiguration, foreground: Bool) throws {
        let arguments = buildChromeLaunchArguments(configuration: configuration, headless: !foreground) + ["about:blank"]

        // We always exec the Chrome binary directly (bypassing LaunchServices) so a
        // pre-existing personal Chrome session cannot intercept the launch and absorb
        // our flags. LaunchServices' `NSWorkspace.shared.openApplication` (and the
        // equivalent `/usr/bin/open -n -a <app>` CLI) is unreliable here: on some
        // macOS+Chrome combinations the open event still routes into the user's
        // already-running personal Chrome (which uses the default user-data-dir),
        // instead of spawning our dedicated `--user-data-dir=<app-group>/Browser/...`
        // instance. Direct exec guarantees a separate child process owning our
        // user-data-dir.
        //
        // Sandbox/keychain note: the SIGTRAP crash in v0.12.13 was *not* caused by
        // direct exec — it was Chrome's password manager hitting the macOS keychain
        // from within our inherited sandbox. v0.12.14 fixed that by passing
        // --password-store=basic + --use-mock-keychain (see
        // buildChromeLaunchArguments). Switching to LaunchServices would remove the
        // dedicated-profile guarantee and re-open the personal-Chrome-hijack hole;
        // direct exec + keychain-bypass flags is the right combination.
        let executableURL: URL
        switch browser.kind {
        case .appBundle(let appURL):
            executableURL = try Self.executableURL(forAppBundle: appURL)
        case .executable(let directExecutable):
            executableURL = directExecutable
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Log unexpected process termination so silent crashes are visible. CDP
        // unreachability + this log line together pinpoint the failure mode.
        let cdpPortString = "\(configuration.cdpPort)"
        let profileNameForLog = configuration.profileName
        let foregroundForLog = foreground
        process.terminationHandler = { proc in
            ActivityLogger.log("browser", "Chrome process terminated", metadata: [
                "profile": profileNameForLog,
                "port": cdpPortString,
                "foreground": foregroundForLog ? "true" : "false",
                "exit": "\(proc.terminationStatus)",
                "reason": "\(proc.terminationReason.rawValue)"
            ])
        }

        try process.run()

        ActivityLogger.log("browser", foreground ? "spawned dedicated Chrome instance" : "launched headless app-owned Chrome", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "executable": executableURL.path,
            "userDataDir": configuration.userDataDirectory.path,
            "pid": "\(process.processIdentifier)"
        ])

        if foreground {
            markUserVisible(configuration: configuration)
            foregroundLaunchedProcesses[configuration.cdpPort] = process

            // Resolve the NSRunningApplication so we can later activate ONLY this
            // dedicated instance, never the user's personal Chrome.
            let pid = process.processIdentifier
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if let application = NSRunningApplication(processIdentifier: pid) {
                    self.foregroundLaunchedApplications[configuration.cdpPort] = application
                    DispatchQueue.main.async {
                        application.activate(options: [.activateIgnoringOtherApps])
                    }
                }
            }
        } else {
            backgroundLaunchedProcesses[configuration.cdpPort] = process
        }
    }

    private static func executableURL(forAppBundle appURL: URL) throws -> URL {
        let bundle = Bundle(url: appURL)
        let executableName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: executableURL.path) {
            throw ChromeBrowserProfileError.launchFailed(
                "Browser bundle at \(appURL.path) has no executable file at Contents/MacOS/\(executableName). "
                    + "The .app appears corrupt or stripped of its inner binary."
            )
        }

        if !fileManager.isExecutableFile(atPath: executableURL.path) {
            // Try restoring the executable bit before giving up. This handles the
            // case where a sandboxed move/copy stripped the +x bit (one of the
            // failure modes that produced the 0.12.15 "no launchable executable"
            // error). We do NOT touch the file in any other way — code signing
            // depends on the on-disk bytes being unchanged.
            _ = try? fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: executableURL.path)
        }

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw ChromeBrowserProfileError.launchFailed(
                "Browser executable at \(executableURL.path) is not executable. "
                    + "If you set MACOS_WIDGETS_STATS_CHROME_PATH, fix or unset it. Otherwise reinstall "
                    + "macOS Widgets Stats from Website so the bundled Chromium is restored."
            )
        }

        return executableURL
    }

    private func markUserVisible(configuration: ChromeBrowserLaunchConfiguration) {
        queue.async { [weak self] in
            self?.userVisiblePorts.insert(configuration.cdpPort)
        }
    }

    private func waitUntilCDPReachable(
        configuration: ChromeBrowserLaunchConfiguration,
        deadline: Date,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        if isCDPReachable(configuration: configuration) {
            DispatchQueue.main.async {
                completion(.success(configuration))
            }
            return
        }

        guard Date() < deadline else {
            DispatchQueue.main.async {
                completion(.failure(ChromeBrowserProfileError.cdpNotReachable(configuration.cdpPort)))
            }
            return
        }

        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitUntilCDPReachable(configuration: configuration, deadline: deadline, completion: completion)
        }
    }

    private func isCDPReachable(configuration: ChromeBrowserLaunchConfiguration) -> Bool {
        guard let json = Self.cdpVersionInfo(configuration: configuration) else { return false }

        return (json["Browser"] as? String)?.isEmpty == false || (json["webSocketDebuggerUrl"] as? String)?.isEmpty == false
    }

    private static func cdpVersionInfo(configuration: ChromeBrowserLaunchConfiguration) -> [String: Any]? {
        guard let url = URL(string: "/json/version", relativeTo: configuration.cdpURL)?.absoluteURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    private static func cdpBrowserWebSocketURL(configuration: ChromeBrowserLaunchConfiguration) -> URL? {
        guard let webSocketString = cdpVersionInfo(configuration: configuration)?["webSocketDebuggerUrl"] as? String else {
            return nil
        }

        return URL(string: webSocketString)
    }

    private func createTargetRequest(
        url targetURL: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        method: String,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        guard let encoded = targetURL.absoluteString.addingPercentEncoding(withAllowedCharacters: Self.cdpQueryAllowedCharacters),
              let requestURL = URL(string: "/json/new?\(encoded)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            completion(.failure(ChromeBrowserProfileError.targetCreationFailed("The URL could not be encoded.")))
            return
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("CDP /json/new returned HTTP \(httpResponse.statusCode).")))
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let webSocketString = json["webSocketDebuggerUrl"] as? String,
                  let webSocketURL = URL(string: webSocketString) else {
                completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
                return
            }

            completion(.success(ChromeBrowserTarget(id: id, webSocketDebuggerURL: webSocketURL)))
        }.resume()
    }

    private func listPageTargets(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<[ChromeBrowserPageTarget], Error>) -> Void
    ) {
        guard let url = URL(string: "/json/list", relativeTo: configuration.cdpURL)?.absoluteURL else {
            completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
            return
        }

        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("CDP /json/list returned HTTP \(httpResponse.statusCode).")))
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
                return
            }

            let targets = json.compactMap { item -> ChromeBrowserPageTarget? in
                guard (item["type"] as? String) == "page",
                      let id = item["id"] as? String,
                      let webSocketString = item["webSocketDebuggerUrl"] as? String,
                      let webSocketURL = URL(string: webSocketString) else {
                    return nil
                }

                let url = (item["url"] as? String).flatMap(URL.init(string:))
                let title = item["title"] as? String ?? ""
                return ChromeBrowserPageTarget(id: id, url: url, title: title, webSocketDebuggerURL: webSocketURL)
            }

            completion(.success(targets))
        }.resume()
    }

    static func safeInitialURL(for url: URL) -> URL {
        guard isLikelyLogoutURL(url),
              let scheme = url.scheme,
              let host = url.host else {
            return url
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/"
        return components.url ?? url
    }

    static func isLikelyLogoutURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let query = url.query?.lowercased() ?? ""
        return path.contains("logout")
            || path.contains("log-out")
            || path.contains("signout")
            || path.contains("sign-out")
            || query.contains("logout")
            || query.contains("signout")
    }

    private static func isUsableExistingPageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return false
        }
        return !isLikelyLogoutURL(url)
    }

    private static func reuseScore(for target: ChromeBrowserPageTarget, requestedURL: URL) -> Int? {
        guard let targetURL = target.url,
              isUsableExistingPageURL(targetURL) else {
            return nil
        }

        // Any usable existing CDP page is better than creating a new tab: it
        // preserves the browser profile, Google login/cookies, and the page the
        // user was actually working in. The rest of this score only chooses the
        // most likely intended tab when several usable CDP pages exist.
        var score = 10

        if equivalentPageURL(targetURL, requestedURL) {
            score += 1_000
        }

        if let requestedHost = requestedURL.host?.lowercased(),
           targetURL.host?.lowercased() == requestedHost {
            score += 500

            let requestedPath = normalizedPath(requestedURL)
            let targetPath = normalizedPath(targetURL)
            if targetPath == requestedPath {
                score += 100
            } else if !requestedPath.isEmpty,
                      (targetPath.hasPrefix(requestedPath) || requestedPath.hasPrefix(targetPath)) {
                score += 25
            }
        }

        if !target.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 1
        }

        return score
    }

    private static func equivalentPageURL(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased(),
              normalizedPath(lhs) == normalizedPath(rhs) else {
            return false
        }

        let lhsQuery = lhs.query ?? ""
        let rhsQuery = rhs.query ?? ""
        return lhsQuery == rhsQuery
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.lowercased()
    }

    // MARK: - Public availability + install API
    //
    // 0.14.0+: Chromium is bundled inside the .app at build time (see
    // scripts/embed-chromium.sh and Resources/Browsers/), so resolveBrowser()
    // always succeeds in normal installs. The availability API is kept
    // defensively so the UI can still surface a clear error if the bundled
    // Chromium is missing (corrupt install, broken signature, partial DMG).
    // installChromium() is now a no-op — there is no managed download path.
    //
    // The 0.13.x lazy-download flow (download → extract to <Container>/Data/
    // Library/Application Support → exec) was fundamentally broken in App
    // Sandbox: macOS auto-re-attaches `com.apple.quarantine` when a sandboxed
    // app touches the extracted binary, and the sandbox itself denies execve
    // from container-relative paths regardless of POSIX perms / xattr state.
    // The 0.13.4 removexattr-syscall fix did not (and could not) solve this.
    // Bundling Chromium inside the .app is the only sandbox-compatible path.

    /// Posted (on the main queue) whenever Chromium-availability state may
    /// have changed. Kept for backward compatibility with SwiftUI views that
    /// subscribe to it; emitted by `installChromium()` even though it's now
    /// a no-op, so any UI gating still refreshes when the (defensive) sheet
    /// is dismissed.
    static let chromiumAvailabilityDidChangeNotification = Notification.Name(
        "com.ethansk.macos-widgets-stats-from-website.chromiumAvailabilityDidChange"
    )

    /// True iff `resolveBrowser()` would succeed without network access.
    ///
    /// Resolution order matches `resolveBrowser()`:
    ///   1. `MACOS_WIDGETS_STATS_CHROME_PATH` env override (dev)
    ///   2. Bundled Chromium inside the .app (the canonical install)
    ///
    /// If `MACOS_WIDGETS_STATS_CHROME_PATH` is set but does not point at a
    /// valid browser, this returns `false` to mirror `resolveBrowser()`'s
    /// fail-shut behavior.
    func chromiumIsAvailable() -> Bool {
        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CHROME_PATH"]?.nilIfEmpty {
            return ResolvedBrowser(path: override) != nil
        }

        for url in bundledBrowserCandidates() where ResolvedBrowser(url: url) != nil {
            return true
        }

        return false
    }

    /// Legacy install entry point — now a no-op in 0.14.0+. Chromium is
    /// bundled inside the .app at build time, so there is nothing to
    /// install. We keep this method (and the `ChromiumInstallSheet` UI
    /// that calls it) defensively in case a future install is somehow
    /// shipped without the bundled Chromium (corrupt .app, partial DMG,
    /// failed embed build phase) — the sheet then surfaces the
    /// "Chromium missing" state and tells the user to reinstall.
    func installChromium(
        progress: @escaping (Double) -> Void,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.main.async {
            progress(1.0)

            if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CHROME_PATH"]?.nilIfEmpty {
                if let browser = ResolvedBrowser(path: override) {
                    switch browser.kind {
                    case .appBundle(let url), .executable(let url):
                        completion(.success(url))
                    }
                } else {
                    completion(.failure(ChromeBrowserProfileError.launchFailed("MACOS_WIDGETS_STATS_CHROME_PATH does not point at an app bundle or executable browser.")))
                }
            } else if let browser = self.bundledBrowserCandidates()
                .compactMap({ ResolvedBrowser(url: $0) })
                .first {
                switch browser.kind {
                case .appBundle(let url), .executable(let url):
                    completion(.success(url))
                }
            } else {
                completion(.failure(ChromeBrowserProfileError.browserNotFound))
            }
            self.postAvailabilityDidChange()
        }
    }

    private func postAvailabilityDidChange() {
        NotificationCenter.default.post(
            name: Self.chromiumAvailabilityDidChangeNotification,
            object: self
        )
    }

    private func resolveBrowser() throws -> ResolvedBrowser {
        // Developer / power-user escape hatch. Lets us point at a custom
        // Chromium binary for local testing or for a hand-installed Chromium.app
        // outside the bundle.
        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CHROME_PATH"]?.nilIfEmpty {
            if let browser = ResolvedBrowser(path: override) {
                ActivityLogger.log("browser", "resolved browser via MACOS_WIDGETS_STATS_CHROME_PATH override", metadata: [
                    "path": override
                ])
                return browser
            }
            throw ChromeBrowserProfileError.launchFailed("MACOS_WIDGETS_STATS_CHROME_PATH does not point at an app bundle or executable browser.")
        }

        // Bundled Chromium dropped into Resources/Browsers/ at build time
        // (see scripts/embed-chromium.sh). This is the canonical path in
        // 0.14.0+ and the only one expected to succeed in normal installs.
        //
        // We deliberately do NOT fall back to a system-installed Chromium /
        // Brave / Edge any more. Those fallbacks existed in 0.13.x as a hedge
        // against the (broken) lazy-download path failing under sandbox, but
        // with Chromium bundled inside our .app there is no scenario where
        // the fallback would help: if the bundled bundle is missing the .app
        // itself is corrupt and the user needs to reinstall, not fall back
        // to whatever browser happens to be in /Applications.
        for url in bundledBrowserCandidates() {
            if let browser = ResolvedBrowser(url: url) {
                ActivityLogger.log("browser", "resolved bundled Chromium", metadata: [
                    "path": url.path
                ])
                return browser
            }
        }

        ActivityLogger.log("browser", "bundled Chromium not found inside app bundle", metadata: [
            "candidates": bundledBrowserCandidates().map { $0.path }.joined(separator: ",")
        ])
        throw ChromeBrowserProfileError.browserNotFound
    }

    private func bundledBrowserCandidates() -> [URL] {
        // Probe order:
        //   - Resources/Browsers/<arch>/Chromium.app  (multi-arch build layout)
        //   - Resources/Browsers/Chromium.app         (single-arch build layout)
        //
        // scripts/embed-chromium.sh writes the single-arch layout for normal
        // Debug builds and the per-arch layout for universal Release archives.
        // Both are probed here so a developer who runs xcodegen + a universal
        // archive locally still resolves correctly.
        #if arch(arm64)
        let archSubdir = "mac-arm64"
        #else
        let archSubdir = "mac-x64"
        #endif

        let relativeCandidates = [
            "Browsers/\(archSubdir)/Chromium.app",
            "Browsers/Chromium.app"
        ]

        var roots: [URL] = []

        if let bundleResources = Bundle.main.resourceURL {
            roots.append(bundleResources)
        }

        // Sibling-installed main app Resources — lets the CLI build inherit
        // whatever the main app has bundled.
        let mainAppName = "MacosWidgetsStatsFromWebsite.app"
        let mainAppLocations: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(mainAppName, isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
                .appendingPathComponent(mainAppName, isDirectory: true)
        ]
        for appURL in mainAppLocations {
            let resourcesURL = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
            if fileManager.fileExists(atPath: resourcesURL.path) {
                roots.append(resourcesURL)
            }
        }

        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_BROWSERS_DIR"]?.nilIfEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        var urls: [URL] = []
        for root in roots {
            for relative in relativeCandidates {
                urls.append(root.appendingPathComponent(relative, isDirectory: true))
            }
        }
        return urls
    }

    /// Bring ONLY the dedicated Chrome instance for `configuration` to the front —
    /// never touch the user's personal Chrome session.
    ///
    /// Resolution order:
    ///   1. The tracked `NSRunningApplication` from a foreground launch in this app session.
    ///   2. A scan of running processes whose argv contains the dedicated `--user-data-dir`.
    ///   3. No-op (we never blanket-activate by bundle id, since that would yank the user's
    ///      personal Chrome windows forward — see regression introduced in commit f78e310).
    private func activateDedicatedBrowser(configuration: ChromeBrowserLaunchConfiguration) {
        let port = configuration.cdpPort
        let trackedApplication: NSRunningApplication? = queue.sync {
            foregroundLaunchedApplications[port] ?? backgroundLaunchedApplications[port]
        }

        if let application = trackedApplication, !application.isTerminated {
            DispatchQueue.main.async {
                application.activate(options: [.activateIgnoringOtherApps])
            }
            return
        }

        // No tracked app (e.g. dedicated Chrome was started in a previous app session and
        // is still alive serving the CDP port). Find the PID whose argv references our
        // dedicated user-data-dir so we can activate that specific instance.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self,
                  let pid = self.findDedicatedBrowserPID(configuration: configuration),
                  let application = NSRunningApplication(processIdentifier: pid) else {
                return
            }

            self.queue.async { [weak self] in
                self?.foregroundLaunchedApplications[port] = application
            }

            DispatchQueue.main.async {
                application.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    /// Scan `ps` for a process whose argv contains `--user-data-dir=<configuration.userDataDirectory.path>`.
    /// This matches the dedicated Chrome instance even when the user's personal Chrome is running
    /// concurrently, because personal Chrome uses Chrome's default user-data-dir
    /// (`~/Library/Application Support/Google/Chrome`), never our app-group path.
    private func findDedicatedBrowserPID(configuration: ChromeBrowserLaunchConfiguration) -> pid_t? {
        let needle = "--user-data-dir=\(configuration.userDataDirectory.path)"
        guard let output = Self.runPSAndReadOutput() else {
            return nil
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = String(line).trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let pidString = String(trimmed[..<space])
            let command = String(trimmed[space...])
            guard command.contains(needle) else { continue }
            // The "main" Chrome process has the dedicated user-data-dir argv;
            // helper renderers/utility processes use --user-data-dir but typically also pass
            // --type=renderer / --type=utility / --type=gpu-process. Skip helpers so we
            // activate the parent (the one with the visible window).
            if command.contains("--type=") {
                continue
            }
            if let pid = pid_t(pidString.trimmingCharacters(in: .whitespaces)) {
                return pid
            }
        }
        return nil
    }

    private func cdpPort(for safeProfileName: String) -> Int {
        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CDP_PORT"]?.nilIfEmpty,
           let port = Int(override),
           (1...65535).contains(port) {
            return port
        }

        var hash: UInt32 = 2_166_136_261
        for scalar in safeProfileName.unicodeScalars {
            hash ^= UInt32(scalar.value)
            hash = hash &* 16_777_619
        }

        return baseCDPPort + Int(hash % 1_000)
    }

    private func safeProfileName(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let safe = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return safe.isEmpty ? "openclaw" : safe
    }

    private static let cdpQueryAllowedCharacters: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return allowed
    }()
}

private extension ChromeBrowserPageTarget {
    var asTarget: ChromeBrowserTarget {
        ChromeBrowserTarget(id: id, webSocketDebuggerURL: webSocketDebuggerURL)
    }
}

private struct ResolvedBrowser {
    enum Kind {
        case appBundle(URL)
        case executable(URL)
    }

    let kind: Kind

    init?(path: String) {
        self.init(url: URL(fileURLWithPath: path))
    }

    init?(url: URL) {
        let path = url.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue, url.pathExtension.lowercased() == "app" {
            // Validate that the .app actually has a launchable inner executable
            // BEFORE accepting it. Otherwise a corrupt bundled Chromium.app
            // would pass availability checks and fail later during launch.
            guard ResolvedBrowser.hasLaunchableExecutable(forAppBundle: url) else {
                return nil
            }
            kind = .appBundle(url)
            return
        }

        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        kind = .executable(url)
    }

    /// True iff the `.app` at `appURL` has a readable Info.plist (or a sensible
    /// CFBundleExecutable fallback) AND the inner Contents/MacOS/<exec> file
    /// exists. Does not require the +x bit (we re-set that lazily on launch via
    /// `executableURL(forAppBundle:)`), but does require an actual binary so a
    /// .app bundle that contains only a Resources/ subdir cannot pass.
    private static func hasLaunchableExecutable(forAppBundle appURL: URL) -> Bool {
        let bundle = Bundle(url: appURL)
        let executableName = (bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
        return FileManager.default.fileExists(atPath: executableURL.path)
    }
}

private extension FileHandle {
    static var nullDevice: FileHandle {
        FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.standardError
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
