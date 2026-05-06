//
//  ChromeBrowserProfile.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  OpenClaw-style Chromium/Chrome profile launcher for Google-login-safe CDP scraping.
//

import AppKit
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
    case downloadFailed(String)
    case cdpNotReachable(Int)
    case targetCreationFailed(String)
    case invalidCDPResponse

    var errorDescription: String? {
        switch self {
        case .browserNotFound:
            return "No Chromium-based browser was found. Bundle Chrome for Testing, install Google Chrome/Chromium, or set MACOS_WIDGETS_STATS_CHROME_PATH."
        case .launchFailed(let message):
            return "Could not launch the browser profile: \(message)"
        case .downloadFailed(let message):
            return "Could not download Chrome for Testing: \(message)"
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
    private let chromeForTestingManifestURL = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json")!
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
                markUserVisible(configuration: configuration)
                activateBrowserIfPossible()
            }
            completion(.success(configuration))
            return
        }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                try self.fileManager.createDirectory(at: configuration.userDataDirectory, withIntermediateDirectories: true)
                let browser = try self.resolveBrowser()
                try self.launch(browser: browser, configuration: configuration, foreground: foreground)
                self.waitUntilCDPReachable(configuration: configuration, deadline: Date().addingTimeInterval(12), completion: completion)
            } catch {
                DispatchQueue.main.async {
                    completion(.failure(error))
                }
            }
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
            "--no-proxy-server"
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

        switch browser.kind {
        case .appBundle(let appURL):
            guard foreground else {
                try launchHeadlessProcess(
                    executableURL: try Self.executableURL(forAppBundle: appURL),
                    arguments: arguments,
                    configuration: configuration
                )
                break
            }

            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.arguments = arguments
            openConfiguration.activates = foreground
            openConfiguration.createsNewApplicationInstance = true
            markUserVisible(configuration: configuration)

            NSWorkspace.shared.openApplication(at: appURL, configuration: openConfiguration) { [weak self] application, error in
                if let error {
                    ActivityLogger.log("browser", "Chrome app launch callback reported failure", metadata: ["error": error.localizedDescription])
                    return
                }

                guard let application else {
                    return
                }

                self?.queue.async { [weak self] in
                    guard let self else { return }
                    self.foregroundLaunchedApplications[configuration.cdpPort] = application
                }
            }
        case .executable(let executableURL):
            if foreground {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                markUserVisible(configuration: configuration)
                foregroundLaunchedProcesses[configuration.cdpPort] = process
            } else {
                try launchHeadlessProcess(executableURL: executableURL, arguments: arguments, configuration: configuration)
            }
        }

        ActivityLogger.log("browser", foreground ? "opened visible Chrome profile" : "launched headless app-owned Chrome", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)"
        ])
    }

    private func launchHeadlessProcess(
        executableURL: URL,
        arguments: [String],
        configuration: ChromeBrowserLaunchConfiguration
    ) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        backgroundLaunchedProcesses[configuration.cdpPort] = process
    }

    private static func executableURL(forAppBundle appURL: URL) throws -> URL {
        let bundle = Bundle(url: appURL)
        let executableName = bundle?.object(forInfoDictionaryKey: "CFBundleExecutable") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
        let executableURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ChromeBrowserProfileError.launchFailed("The browser app bundle did not contain a launchable executable.")
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
        guard let url = URL(string: "/json/version", relativeTo: configuration.cdpURL)?.absoluteURL,
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        return (json["Browser"] as? String)?.isEmpty == false || (json["webSocketDebuggerUrl"] as? String)?.isEmpty == false
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

    private func resolveBrowser() throws -> ResolvedBrowser {
        if let override = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_CHROME_PATH"]?.nilIfEmpty {
            if let browser = ResolvedBrowser(path: override) {
                return browser
            }
            throw ChromeBrowserProfileError.launchFailed("MACOS_WIDGETS_STATS_CHROME_PATH does not point at an app bundle or executable browser.")
        }

        for url in bundledBrowserCandidates() + managedBrowserCandidates() + systemBrowserCandidates() {
            if let browser = ResolvedBrowser(url: url) {
                return browser
            }
        }

        if autoDownloadChromeForTestingEnabled {
            return try downloadChromeForTesting()
        }

        throw ChromeBrowserProfileError.browserNotFound
    }

    private func bundledBrowserCandidates() -> [URL] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [
            resources.appendingPathComponent("Browsers/Chromium.app", isDirectory: true),
            resources.appendingPathComponent("Browsers/Google Chrome for Testing.app", isDirectory: true),
            resources.appendingPathComponent("Chromium.app", isDirectory: true)
        ]
    }

    private func managedBrowserCandidates() -> [URL] {
        [managedChromeForTestingAppURL]
    }

    private func systemBrowserCandidates() -> [URL] {
        [
            URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Google Chrome for Testing.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Chromium.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Brave Browser.app", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Microsoft Edge.app", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/local/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/chromium", isDirectory: false),
            URL(fileURLWithPath: "/usr/bin/google-chrome", isDirectory: false)
        ]
    }

    private var autoDownloadChromeForTestingEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_DISABLE_CHROME_DOWNLOAD"]?.lowercased()
        return value != "1" && value != "true" && value != "yes"
    }

    private var chromeForTestingPlatform: String {
        #if arch(arm64)
        return "mac-arm64"
        #else
        return "mac-x64"
        #endif
    }

    private var managedChromeForTestingRootURL: URL {
        AppGroupPaths.canonicalApplicationSupportURL()
            .appendingPathComponent("Browser", isDirectory: true)
            .appendingPathComponent("ChromeForTesting", isDirectory: true)
            .appendingPathComponent(chromeForTestingPlatform, isDirectory: true)
    }

    private var managedChromeForTestingAppURL: URL {
        managedChromeForTestingRootURL.appendingPathComponent("Google Chrome for Testing.app", isDirectory: true)
    }

    private func downloadChromeForTesting() throws -> ResolvedBrowser {
        if let existing = ResolvedBrowser(url: managedChromeForTestingAppURL) {
            return existing
        }

        try fileManager.createDirectory(at: managedChromeForTestingRootURL, withIntermediateDirectories: true)
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MacosWidgetsStatsChromeForTesting-")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let downloadURL = try chromeForTestingDownloadURL()
        let archiveURL = temporaryRoot.appendingPathComponent("chrome-for-testing.zip", isDirectory: false)
        try downloadFile(from: downloadURL, to: archiveURL)

        let extractURL = temporaryRoot.appendingPathComponent("extract", isDirectory: true)
        try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)
        try extractZip(at: archiveURL, to: extractURL)

        guard let extractedAppURL = findExtractedChromeForTestingApp(in: extractURL) else {
            throw ChromeBrowserProfileError.downloadFailed("Chrome for Testing archive did not contain Google Chrome for Testing.app.")
        }

        let stagingURL = managedChromeForTestingRootURL
            .appendingPathComponent("Google Chrome for Testing.app.staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: extractedAppURL, to: stagingURL)

        if fileManager.fileExists(atPath: managedChromeForTestingAppURL.path) {
            try fileManager.removeItem(at: managedChromeForTestingAppURL)
        }
        try fileManager.moveItem(at: stagingURL, to: managedChromeForTestingAppURL)

        guard let browser = ResolvedBrowser(url: managedChromeForTestingAppURL) else {
            throw ChromeBrowserProfileError.downloadFailed("Downloaded Chrome for Testing is not launchable.")
        }
        return browser
    }

    private func chromeForTestingDownloadURL() throws -> URL {
        let data = try downloadData(from: chromeForTestingManifestURL, timeout: 60)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let channels = json["channels"] as? [String: Any],
              let stable = channels["Stable"] as? [String: Any],
              let downloads = stable["downloads"] as? [String: Any],
              let chromeDownloads = downloads["chrome"] as? [[String: Any]] else {
            throw ChromeBrowserProfileError.downloadFailed("Chrome for Testing manifest was unreadable.")
        }

        guard let match = chromeDownloads.first(where: { $0["platform"] as? String == chromeForTestingPlatform }),
              let urlString = match["url"] as? String,
              let url = URL(string: urlString) else {
            throw ChromeBrowserProfileError.downloadFailed("Chrome for Testing manifest has no \(chromeForTestingPlatform) build.")
        }
        return url
    }

    private func downloadData(from url: URL, timeout: TimeInterval) throws -> Data {
        let session = URLSession(configuration: chromeDownloadSessionConfiguration(timeout: timeout))
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Data, Error>?
        session.dataTask(with: url) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse,
                      !(200..<300).contains(httpResponse.statusCode) {
                result = .failure(ChromeBrowserProfileError.downloadFailed("HTTP \(httpResponse.statusCode) from \(url.host ?? url.absoluteString)."))
            } else if let data {
                result = .success(data)
            } else {
                result = .failure(ChromeBrowserProfileError.downloadFailed("No data returned from \(url.absoluteString)."))
            }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout) == .success, let result else {
            throw ChromeBrowserProfileError.downloadFailed("Timed out downloading \(url.absoluteString).")
        }
        return try result.get()
    }

    private func downloadFile(from url: URL, to destinationURL: URL) throws {
        let timeout: TimeInterval = 1_800
        let session = URLSession(configuration: chromeDownloadSessionConfiguration(timeout: timeout))
        defer { session.invalidateAndCancel() }

        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<URL, Error>?
        session.downloadTask(with: url) { temporaryURL, response, error in
            if let error {
                result = .failure(error)
            } else if let httpResponse = response as? HTTPURLResponse,
                      !(200..<300).contains(httpResponse.statusCode) {
                result = .failure(ChromeBrowserProfileError.downloadFailed("HTTP \(httpResponse.statusCode) from \(url.host ?? url.absoluteString)."))
            } else if let temporaryURL {
                result = .success(temporaryURL)
            } else {
                result = .failure(ChromeBrowserProfileError.downloadFailed("No file returned from \(url.absoluteString)."))
            }
            semaphore.signal()
        }.resume()

        guard semaphore.wait(timeout: .now() + timeout) == .success, let result else {
            throw ChromeBrowserProfileError.downloadFailed("Timed out downloading \(url.absoluteString).")
        }

        let temporaryURL = try result.get()
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }

    private func chromeDownloadSessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        return configuration
    }

    private func extractZip(at archiveURL: URL, to destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto", isDirectory: false)
        process.arguments = ["-x", "-k", archiveURL.path, destinationURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ChromeBrowserProfileError.downloadFailed("Failed to extract Chrome for Testing archive.")
        }
    }

    private func findExtractedChromeForTestingApp(in rootURL: URL) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            if url.lastPathComponent == "Google Chrome for Testing.app",
               let browser = ResolvedBrowser(url: url),
               case .appBundle = browser.kind {
                return url
            }
        }
        return nil
    }

    private func activateBrowserIfPossible() {
        guard let browser = try? resolveBrowser(),
              case .appBundle(let appURL) = browser.kind,
              let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier else {
            return
        }

        DispatchQueue.main.async {
            for application in NSWorkspace.shared.runningApplications where application.bundleIdentifier == bundleIdentifier {
                application.activate(options: [.activateIgnoringOtherApps])
            }
        }
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
            kind = .appBundle(url)
            return
        }

        guard !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: path) else {
            return nil
        }

        kind = .executable(url)
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
