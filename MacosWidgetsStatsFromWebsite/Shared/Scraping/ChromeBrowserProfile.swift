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

private struct PendingTargetCreation {
    let url: URL
    let completion: (Result<ChromeBrowserTarget, Error>) -> Void
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
            // v0.21.22: user-facing product name renamed (voice 4002 /
            // MBP-CC bridge msg-65036391). All localized error descriptions
            // refer to the new wrapper name "Stats Widget from Website".
            return "Could not find the bundled Chromium browser inside the app bundle. Reinstall Stats Widget from Website — the build is incomplete."
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
    // v0.21.74 — MAIN-THREAD BLOCK FIX (Ethan's #1 symptom: "Chromium takes
    // forever / won't open"). `ensureLaunched(...)`'s entry-point reachability
    // probe (`isCDPReachable` → `cdpVersionInfo` → `synchronousProbe`) blocks
    // its caller for up to ~11s (semaphore.wait(timeoutForResource + 1)) when
    // the CDP socket is alive-but-wedged. The scraper kickoff was posted onto
    // `DispatchQueue.main` (ChromeCDPScraper.scrape → whenIdentifyClear →
    // main.async → start → ensureLaunched), so that ~11s wait ran ON THE MAIN
    // THREAD every wedged scrape, freezing the UI / app and making Chromium
    // appear to "not open".
    //
    // We CANNOT hop the probe onto `self.queue` (the serial coordination
    // queue) because helpers it calls — notably `isExistingInstanceHeadless`
    // — themselves do `queue.sync { ... }`, which would DEADLOCK a serial
    // queue via re-entrancy. So we use a SEPARATE concurrent utility queue
    // purely for the off-main reachability probe + launch-path dispatch.
    // `spawnNewBrowser`, `terminateHeadlessInstance`, etc. all internally
    // re-hop onto `self.queue`, so calling them from this probe queue is
    // safe. The scraper's completion handler re-marshals back to main on its
    // own (ChromeCDPScraper.swift handleBrowserLaunch wraps in main.async),
    // so callers never observe a thread change.
    private let probeQueue = DispatchQueue(
        label: "ChromeBrowserProfile.probe",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var backgroundLaunchedApplications: [Int: NSRunningApplication] = [:]
    private var backgroundLaunchedProcesses: [Int: Process] = [:]
    private var foregroundLaunchedApplications: [Int: NSRunningApplication] = [:]
    private var foregroundLaunchedProcesses: [Int: Process] = [:]
    private var backgroundUseCounts: [Int: Int] = [:]
    private var userVisiblePorts: Set<Int> = []
    private var pendingLaunchCompletions: [String: [(Result<ChromeBrowserLaunchConfiguration, Error>) -> Void]] = [:]
    /// v0.21.48 — per-pending-launch initial URL (set by foreground-identify
    /// callers so the spawned Chromium boots with the target page as its
    /// first/active tab). Keyed by the same `launchKey` as
    /// `pendingLaunchCompletions`. Absent key → no initial URL → falls
    /// back to `about:blank` in `launch(...)`. Cleared in
    /// `finishPendingLaunch`.
    private var pendingLaunchInitialURLs: [String: URL] = [:]
    private var pendingTargetCreations: [Int: [PendingTargetCreation]] = [:]
    private var targetCreationPortsInFlight: Set<Int> = []

    /// v0.21.14 — per-profile scrape-start watermark for the 15s min-gap
    /// stagger introduced to fix the multi-tracker CDP parallel-scrape
    /// flake (Ethan voice 3988, MBP-side activity.log was showing
    /// `CDP websocket disconnected` + `scrape failed` storms whenever
    /// two trackers on the same profile fired their NSBackgroundActivityScheduler
    /// windows within a second of each other).
    ///
    /// Layered ON TOP OF v0.21.12's `pinnedActiveScrapeTargets` orphan-sweep
    /// pin — that fix prevents parallel scrapes from race-killing each
    /// other's tabs WHEN they DO overlap. This stagger prevents the
    /// overlap from happening in the first place, which is the cheaper
    /// path (no tab churn, no CDP socket bring-up while another scrape
    /// is mid-flight, no concurrent target creation on the same CDP port).
    ///
    /// Keyed by `cdpPort` (one profile = one port, matches the keying
    /// of `backgroundUseCounts` / `pendingTargetCreations` etc.).
    /// The value stored is the PROJECTED scrape-start time (now + computed
    /// delay), NOT `Date()` at call time — required for race-correctness
    /// when N scrapes arrive simultaneously: each successive caller sees
    /// the cumulative projected gap so they all stagger correctly rather
    /// than all delaying by the same amount and landing in lockstep.
    private var lastScrapeStartedAt: [Int: Date] = [:]

    /// Minimum gap between any two scrape STARTS on the same profile.
    /// 15s chosen empirically — the CDP target-creation + WebSocket
    /// handshake + initial Page.navigate round-trip typically completes
    /// in <5s on a healthy profile, with a tail out to ~10s on cold
    /// starts. 15s gives ~5s of headroom over the worst-case warmup
    /// to ensure the prior scrape is genuinely past the websocket-
    /// open phase (where the flake manifests) before the next one starts.
    static let minScrapeStartGap: TimeInterval = 15.0

    /// v0.21.46 — persistent (long-running) Chromium mode.
    ///
    /// Previously every scrape went: spawn fresh Chromium → CDP handshake →
    /// open tab → scrape → close tab → terminate Chromium. The terminate
    /// step (in `endBackgroundUse` when `remaining == 0`) means the NEXT
    /// scrape hits the SIGTRAP-prone browser-init code path AGAIN — every
    /// 12 minutes on a 4-tracker config = ~5/hour exposure to the Tahoe
    /// init crash region at imageOffset 0x6816xxx.
    ///
    /// In persistent mode we KEEP the Chromium process alive between
    /// scrapes. Each scrape still opens a fresh tab and closes it
    /// afterwards (so per-page state isn't reused), but the parent
    /// browser process survives. Init-crash exposure drops to ~once per
    /// app session (i.e. once per Mac boot / once per app relaunch)
    /// instead of once per scrape.
    ///
    /// Memory cost: idle Chromium browser process ~80-120 MB. Acceptable
    /// for a menu-bar app on machines with ≥8 GB RAM.
    ///
    /// Recovery: if Chromium dies for any other reason (real crash, user
    /// kills it, OOM), `ensureLaunched` re-checks `isCDPReachable` at the
    /// start of every scrape and `spawnNewBrowser`s a fresh one if the
    /// old process is gone. The persistent flag only suppresses the
    /// END-OF-SCRAPE terminate; it doesn't gate the start-of-scrape
    /// relaunch on a missing process.
    ///
    /// Note: app-exit (`terminateAppOwnedBrowsersOnAppExit`) still tears
    /// down Chromium cleanly — we don't leak processes when the host
    /// quits. The persistent mode only applies between scrapes within
    /// the same app session.
    ///
    /// To roll back: flip to `false`. Reverts to the v0.21.45 lifecycle.
    static let persistentBrowserMode: Bool = true

    // MARK: - v0.21.48 feature flags
    //
    // History:
    //   • v0.21.48 (2026-05-27, voice 4277): flag introduced + set to `false`
    //     to hide the secondary-element UX from the tracker editor. The code
    //     path (model decode/encode, Identify-in-Chrome `.secondary` routing,
    //     `secondaryElementsSection` view, `SecondaryElementPicker` in the
    //     widget config UI, and `SingleBigNumber.secondaryTextJoined`
    //     rendering) was deliberately kept intact so re-enabling later would
    //     be a one-flag flip rather than a feature re-implementation.
    //   • v0.21.76 (2026-06-01, voice request via MBP-CC bridge): RE-ENABLED.
    //     Ethan wants the secondary element back so he can show a small
    //     contextual line under the hero number on the small widget — e.g.
    //     a "Resets 9:27 PM" caption beneath a usage % bar, or a unit
    //     suffix that would otherwise crowd the big number. The "removed
    //     for now" experiment is over.
    //
    // The flag is read by TrackerEditorView when deciding whether to render
    // the secondary-elements section + the "+ Add secondary element" button.
    // Set to `false` if we ever need to hide the UI again — every consumer
    // already respects this gate.
    static let enableSecondaryElements: Bool = true

    // MARK: - v0.21.48 Identify-in-Chrome serialization
    //
    // ## Why we need this
    //
    // Voice 4277 (2026-05-27): "I click identify them in Chrome. It opens
    // Chromium and it opens the four tabs, one per tracker, I guess. But
    // the one I'm trying to identify is not the last one is not the one
    // the tab that's activated."
    //
    // Root cause we observed in `activity.log` (10:56:11–10:57:33Z BST):
    // when user clicks Identify, background scrapers continue firing
    // their NSBackgroundActivityScheduler windows. Each scrape calls
    // `ensureLaunched(foreground: false)`. If a foreground spawn is
    // already in-flight, the scrapes hit the
    // `joined in-flight Chrome launch` path on line ~265 and pile their
    // completion callbacks on the SAME pending-launch slot. When the
    // headed Chromium finally boots, ALL of those scrapes fire
    // simultaneously and each calls `openTab(...)` → N extra tracker tabs
    // open in the visible window the user just asked for. The right tab
    // (the one Identify created via /json/new) gets lost in the noise.
    //
    // ## The lock
    //
    // `identifyInProgressPorts` is the set of CDP ports for which an
    // Identify flow is currently driving the user-visible Chromium. When
    // a port is in this set:
    //   • `ChromeCDPScraper.scrape(...)` defers its kickoff via
    //     `whenIdentifyClear(...)` (see `ChromeCDPScraper.swift`). Scrapes
    //     queue locally until the lock clears, then run normally.
    //   • `endBackgroundUse(...)`'s persistent-mode teardown still applies,
    //     but no NEW scrape can begin to add fresh tabs.
    //
    // Set via `beginIdentifyInProgress(port:)` at the start of
    // `ChromeIdentifyElementCoordinator.start(...)` and cleared via
    // `endIdentifyInProgress(port:)` in the coordinator's terminal paths
    // (`finishWithPreview`, `finishWithError`, `finishCancelled`,
    // `cancel`). The clear is idempotent.
    //
    // The lock is GLOBAL across the app (not per-tracker) because all
    // trackers in a profile share the same CDP port; locking the port
    // is what gates scrapers.
    private var identifyInProgressPorts: Set<Int> = []

    /// v0.21.48 — callbacks waiting for the identify lock to clear.
    /// Each entry is a closure scheduled by `ChromeCDPScraper` via
    /// `whenIdentifyClear`. When `endIdentifyInProgress` fires, all
    /// callbacks for that port are dispatched to the main queue.
    private var identifyLockWaiters: [Int: [() -> Void]] = [:]

    private struct AppOwnedBrowserProcess {
        let pid: pid_t
        let command: String
        let isBrowserParent: Bool
    }

    /// v0.21.48 — set the identify-in-progress flag for the given port.
    /// Idempotent (safe to call multiple times). Called at the start of
    /// the Identify-in-Chrome flow.
    func beginIdentifyInProgress(port: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasInProgress = self.identifyInProgressPorts.contains(port)
            self.identifyInProgressPorts.insert(port)
            // Log the lock state transitions so the activity log can prove
            // that scrapers actually paused during the Identify window.
            if !wasInProgress {
                ActivityLogger.log("identify", "identify lock engaged", metadata: [
                    "port": "\(port)",
                    "activeScrapeCount": "\(ChromeCDPScraper.currentActiveScrapeCount)"
                ])
            }
        }
    }

    /// v0.21.48 — clear the identify-in-progress flag for the given port
    /// and drain any pending scrape-kickoff waiters. Idempotent.
    func endIdentifyInProgress(port: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            let wasInProgress = self.identifyInProgressPorts.remove(port) != nil
            // Snapshot + clear waiters under the same queue tick so a new
            // waiter that arrives after this point doesn't get drained twice.
            let waitersToRun = self.identifyLockWaiters.removeValue(forKey: port) ?? []
            if wasInProgress {
                ActivityLogger.log("identify", "identify lock released", metadata: [
                    "port": "\(port)",
                    "drainedWaiters": "\(waitersToRun.count)"
                ])
            }
            // Dispatch waiters on the main queue so they can safely call
            // back into ChromeCDPScraper (which expects main-thread state).
            if !waitersToRun.isEmpty {
                DispatchQueue.main.async {
                    for waiter in waitersToRun {
                        waiter()
                    }
                }
            }
        }
    }

    /// v0.21.48 — fire `body` immediately on the main queue if no identify
    /// is in progress for `port`, otherwise enqueue `body` so it runs when
    /// the lock clears. Used by `ChromeCDPScraper.scrape(...)` to defer
    /// scrape kickoffs until any in-flight identify finishes.
    func whenIdentifyClear(port: Int, _ body: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: body)
                return
            }
            if self.identifyInProgressPorts.contains(port) {
                self.identifyLockWaiters[port, default: []].append(body)
                ActivityLogger.log("identify", "scrape deferred behind identify lock", metadata: [
                    "port": "\(port)",
                    "waiterCount": "\(self.identifyLockWaiters[port]?.count ?? 0)"
                ])
            } else {
                DispatchQueue.main.async(execute: body)
            }
        }
    }

    /// v0.21.48 — read-only snapshot of whether the identify lock is held
    /// for `port`. Used in diagnostic logs.
    func isIdentifyInProgress(port: Int) -> Bool {
        queue.sync { identifyInProgressPorts.contains(port) }
    }

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
        initialURL: URL? = nil,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        let configuration = configuration(profileName: profileName)
        // v0.21.74 — MAIN-THREAD BLOCK FIX. The reachability probe below
        // (`isCDPReachable`) blocks for up to ~11s when the CDP socket is
        // wedged. This method was historically entered on the MAIN thread
        // (scraper kickoff path), freezing the UI. Hop the ENTIRE decision
        // body onto `probeQueue` (a concurrent utility queue, NOT `self.queue`
        // — see the probeQueue declaration for why re-entrancy on the serial
        // queue would deadlock). Every downstream call (`spawnNewBrowser`,
        // `terminateHeadlessInstance`) re-hops onto `self.queue` internally,
        // and the `completion` closure is re-marshaled to main by the caller
        // (ChromeCDPScraper.handleBrowserLaunch), so behaviour is identical —
        // only the thread the probe runs on changes.
        probeQueue.async { [weak self] in
            guard let self else {
                // Profile singleton deallocated mid-flight (should never happen
                // for a `static let shared`, but keep the contract: always call
                // completion). Spawn fallback can't run without `self`, so fail
                // closed with the same error shape spawnNewBrowser would use.
                DispatchQueue.main.async {
                    completion(.failure(ChromeBrowserProfileError.targetCreationFailed("ChromeBrowserProfile deallocated")))
                }
                return
            }
            self.ensureLaunchedOnProbeQueue(
                configuration: configuration,
                foreground: foreground,
                initialURL: initialURL,
                completion: completion
            )
        }
    }

    // v0.21.74 — extracted from `ensureLaunched` so the (potentially ~11s
    // blocking) reachability probe + launch-decision logic runs OFF the main
    // thread, on `probeQueue`. See `ensureLaunched` and the `probeQueue`
    // declaration for the full rationale. Behaviour is byte-for-byte identical
    // to the previous inline body; only the executing thread changed.
    private func ensureLaunchedOnProbeQueue(
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        initialURL: URL?,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        if isCDPReachable(configuration: configuration) {
            if foreground {
                // v0.21.48 — REWRITTEN for voice 4277. Previous behavior (v0.21.47
                // and earlier) was:
                //   - if existing instance is HEADLESS → tear down + spawn headed.
                //   - if existing instance is already HEADED → REUSE it as-is.
                //
                // The "reuse if headed" branch is what produced Ethan's "4 tabs,
                // one per tracker" + "wrong tab activated" + "no overlay" bug.
                // When persistent-Chromium mode keeps Chromium alive across
                // scrapes, the SAME Chromium accumulates 4–6 tabs (one per
                // scraper that recently ran). If the user clicked Identify
                // earlier in the session, Chromium is also already headed —
                // so the old code path simply reused it, leaving:
                //   • all stale scraper tabs visible to the user
                //   • the previously-foregrounded tab still in front (NOT
                //     the one we're trying to identify)
                //   • no clean known state for the picker overlay to inject
                //     into
                //
                // The v0.21.48 fix is to ALWAYS tear down + spawn fresh for a
                // foreground identify request, regardless of headless vs.
                // headed. Combined with the `initialURL` parameter (which
                // makes Chromium boot DIRECTLY with the target URL as the
                // first/active tab, skipping `about:blank`), this gives a
                // single-tab Chromium window in a known clean state every
                // time. Background scrapers are paused via the
                // `identifyInProgressPorts` lock so they cannot race-create
                // extra tabs in the foreground Chromium between teardown
                // and spawn.
                //
                // Trade-off: each Identify click now incurs the full
                // Chromium browser-init cycle (~1–2s on a healthy machine).
                // Acceptable because Identify is a user-initiated action
                // they do rarely (selector re-capture, new tracker setup),
                // NOT a hot path. The persistent-mode optimisation is
                // about background scrapes, which still get to share a
                // long-lived Chromium between themselves.

                // Always tear down the entire instance (process + all tabs)
                // before spawning the headed Identify Chromium. We use
                // `terminateHeadlessInstance` for both headless AND headed
                // existing instances — its name is historical (v0.21.47).
                // It SIGTERMs the parent process + waits for CDP to go
                // unreachable, which is the right teardown for any state.
                let backgroundUseCount = queue.sync { backgroundUseCounts[configuration.cdpPort] ?? 0 }
                let wasHeadless = isExistingInstanceHeadless(configuration: configuration)
                ActivityLogger.log("browser", "foreground teardown decision", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "decision": "teardownAlways",
                    "caller": "foreground-identify",
                    "wasHeadless": wasHeadless ? "true" : "false",
                    "backgroundUseCount": "\(backgroundUseCount)",
                    "activeScrapeCount": "\(ChromeCDPScraper.currentActiveScrapeCount)",
                    "initialURL": initialURL?.absoluteString ?? "(about:blank)"
                ])
                ActivityLogger.log("browser", "tearing down Chrome to spawn clean headed instance for foreground identify", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "wasHeadless": wasHeadless ? "true" : "false"
                ])
                terminateHeadlessInstance(configuration: configuration) { [weak self] in
                    self?.spawnNewBrowser(
                        configuration: configuration,
                        foreground: true,
                        initialURL: initialURL,
                        completion: completion
                    )
                }
                return
            }
            completion(.success(configuration))
            return
        }

        spawnNewBrowser(
            configuration: configuration,
            foreground: foreground,
            initialURL: initialURL,
            completion: completion
        )
    }

    private func spawnNewBrowser(
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        initialURL: URL? = nil,
        completion: @escaping (Result<ChromeBrowserLaunchConfiguration, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            if self.isCDPReachable(configuration: configuration) {
                DispatchQueue.main.async {
                    completion(.success(configuration))
                }
                return
            }

            let launchKey = self.pendingLaunchKey(configuration: configuration, foreground: foreground)
            if self.pendingLaunchCompletions[launchKey] != nil {
                self.pendingLaunchCompletions[launchKey]?.append(completion)
                ActivityLogger.log("browser", "joined in-flight Chrome launch", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "foreground": foreground ? "true" : "false"
                ])
                return
            }

            self.pendingLaunchCompletions[launchKey] = [completion]
            // v0.21.48 — `initialURL` is the launch-time URL Chromium should
            // open as its FIRST/active tab. Set by `ensureLaunched` from the
            // foreground-identify path so the visible window boots with the
            // right page already active (no `about:blank` placeholder, no
            // post-launch `openTab` round-trip). nil → fall back to the
            // historical `["about:blank"]` launch arg.
            self.pendingLaunchInitialURLs[launchKey] = initialURL
            self.startPendingLaunchWhenReady(
                configuration: configuration,
                foreground: foreground,
                deadline: Date().addingTimeInterval(8),
                loggedWait: false
            )
        }
    }

    private func pendingLaunchKey(configuration: ChromeBrowserLaunchConfiguration, foreground: Bool) -> String {
        "\(configuration.cdpPort):\(foreground ? "foreground" : "background")"
    }

    private func startPendingLaunchWhenReady(
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        deadline: Date,
        loggedWait: Bool
    ) {
        if isCDPReachable(configuration: configuration) {
            finishPendingLaunch(configuration: configuration, foreground: foreground, result: .success(configuration))
            return
        }

        if let pid = findDedicatedBrowserPID(configuration: configuration), Date() < deadline {
            if !loggedWait {
                ActivityLogger.log("browser", "waiting for previous Chrome process before launch", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "pid": "\(pid)",
                    "foreground": foreground ? "true" : "false"
                ])
            }
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.startPendingLaunchWhenReady(
                    configuration: configuration,
                    foreground: foreground,
                    deadline: deadline,
                    loggedWait: true
                )
            }
            return
        }

        if let pid = findDedicatedBrowserPID(configuration: configuration) {
            // v0.21.5 — the previous behavior was to LOG-AND-LAUNCH-ANYWAY here,
            // which raced a fresh Chromium against the stale one on the same
            // `--user-data-dir` + `--remote-debugging-port`. The new instance
            // frequently failed to bind CDP and every coalesced waiter in
            // `pendingLaunchCompletions` failed together (observed: PID 90672
            // wedged for ~20h, 196 consecutive scrape failures with "CDP did
            // not become reachable on port 18987"). Now we SIGTERM the stale
            // PID, wait for CDP to clear (or 3s deadline), then retry the
            // launch path from the top — which will either reach CDP if the
            // stale process is gone, or detect a no-PID state and fall
            // through to a clean launch.
            terminateStaleBrowser(
                pid: pid,
                configuration: configuration,
                foreground: foreground
            )
            return
        }

        do {
            try fileManager.createDirectory(at: configuration.userDataDirectory, withIntermediateDirectories: true)
            let browser = try resolveBrowser()
            // v0.21.48 — pull the per-pending-launch initial URL set by the
            // foreground-identify caller (if any). Read inside the same
            // serial-queue tick that consumes `pendingLaunchCompletions` so
            // there's no race with `spawnNewBrowser` writing the URL.
            let launchKey = pendingLaunchKey(configuration: configuration, foreground: foreground)
            let initialURL = pendingLaunchInitialURLs[launchKey] ?? nil
            try launch(
                browser: browser,
                configuration: configuration,
                foreground: foreground,
                initialURL: initialURL
            )
            // Cold release Chromium can take much longer than a warm launch
            // to publish /json/version after an app update, first notarized
            // run, or profile recovery. Keep launch bounded, but do not turn
            // a healthy slow boot into a false stale tracker row.
            waitUntilCDPReachable(configuration: configuration, deadline: Date().addingTimeInterval(45)) { [weak self] result in
                self?.finishPendingLaunch(configuration: configuration, foreground: foreground, result: result)
            }
        } catch {
            ActivityLogger.log("browser", "launch failed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "foreground": foreground ? "true" : "false",
                "error": error.localizedDescription
            ])
            finishPendingLaunch(configuration: configuration, foreground: foreground, result: .failure(error))
        }
    }

    /// SIGTERM (escalating to SIGKILL after 1s) a stale Chromium PID that's
    /// blocking the serialized launch path, then poll until the PID is gone
    /// AND CDP is no longer reachable on `configuration.cdpPort` OR a 3s
    /// deadline elapses. On clear, re-enter `startPendingLaunchWhenReady`
    /// with a fresh deadline so it can spawn a new Chromium against the
    /// `--user-data-dir` + `--remote-debugging-port`.
    ///
    /// Why TERM first: TERM lets Chromium tear down its profile lock and any
    /// child renderer/utility processes cleanly. KILL after 1s is the
    /// escape hatch for a hung parent process that ignores TERM.
    private func terminateStaleBrowser(
        pid: pid_t,
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool
    ) {
        ActivityLogger.log("browser", "terminating stale Chrome before relaunch", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "pid": "\(pid)",
            "foreground": foreground ? "true" : "false",
            "signal": "SIGTERM"
        ])

        if kill(pid, SIGTERM) != 0 && errno != ESRCH {
            ActivityLogger.log("browser", "SIGTERM to stale Chrome failed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "pid": "\(pid)",
                "errno": "\(errno)"
            ])
        }

        let killDeadline = Date().addingTimeInterval(1.0)
        let clearDeadline = Date().addingTimeInterval(3.0)
        waitForStaleBrowserClear(
            pid: pid,
            configuration: configuration,
            foreground: foreground,
            killDeadline: killDeadline,
            clearDeadline: clearDeadline,
            sentKill: false
        )
    }

    private func waitForStaleBrowserClear(
        pid: pid_t,
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        killDeadline: Date,
        clearDeadline: Date,
        sentKill: Bool
    ) {
        let pidStillAlive = (kill(pid, 0) == 0)
        let cdpStillUp = isCDPReachable(configuration: configuration)

        if !pidStillAlive && !cdpStillUp {
            ActivityLogger.log("browser", "stale Chrome cleared; relaunching", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "pid": "\(pid)"
            ])
            startPendingLaunchWhenReady(
                configuration: configuration,
                foreground: foreground,
                deadline: Date().addingTimeInterval(8),
                loggedWait: true
            )
            return
        }

        if Date() >= clearDeadline {
            ActivityLogger.log("browser", "stale Chrome did not clear within deadline; relaunching anyway", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "pid": "\(pid)",
                "pid_alive": pidStillAlive ? "true" : "false",
                "cdp_reachable": cdpStillUp ? "true" : "false"
            ])
            // Last-resort fallthrough: drive the launch path with a fresh
            // deadline. If CDP is still up (somehow), the launch path will
            // detect that and succeed without spawning a new instance.
            startPendingLaunchWhenReady(
                configuration: configuration,
                foreground: foreground,
                deadline: Date().addingTimeInterval(8),
                loggedWait: true
            )
            return
        }

        if pidStillAlive && !sentKill && Date() >= killDeadline {
            ActivityLogger.log("browser", "escalating to SIGKILL on stale Chrome", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "pid": "\(pid)"
            ])
            if kill(pid, SIGKILL) != 0 && errno != ESRCH {
                ActivityLogger.log("browser", "SIGKILL to stale Chrome failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "pid": "\(pid)",
                    "errno": "\(errno)"
                ])
            }
            queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.waitForStaleBrowserClear(
                    pid: pid,
                    configuration: configuration,
                    foreground: foreground,
                    killDeadline: killDeadline,
                    clearDeadline: clearDeadline,
                    sentKill: true
                )
            }
            return
        }

        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForStaleBrowserClear(
                pid: pid,
                configuration: configuration,
                foreground: foreground,
                killDeadline: killDeadline,
                clearDeadline: clearDeadline,
                sentKill: sentKill
            )
        }
    }

    private func finishPendingLaunch(
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        result: Result<ChromeBrowserLaunchConfiguration, Error>
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let launchKey = self.pendingLaunchKey(configuration: configuration, foreground: foreground)
            let completions = self.pendingLaunchCompletions.removeValue(forKey: launchKey) ?? []
            // v0.21.48 — clear the corresponding initial-URL entry so a
            // later background spawn for the same port doesn't accidentally
            // inherit an old foreground-identify URL. Keep the cleanup in
            // the same queue tick as the completions removal so the two
            // can never drift out of sync.
            self.pendingLaunchInitialURLs.removeValue(forKey: launchKey)
            DispatchQueue.main.async {
                completions.forEach { $0(result) }
            }
        }
    }

    /// Sentinel file dropped into the user-data-dir whenever this app spawns a Chrome
    /// instance via `launch(browser:configuration:foreground:)`. Its presence proves the
    /// instance currently bound to this CDP port is ours and therefore safe to close —
    /// even when the live User-Agent has been masked (e.g. `--user-agent=<custom>` strips
    /// "HeadlessChrome" from the default UA, which used to fool the CDP probe into
    /// classifying the instance as "headed" and refusing to close it).
    ///
    /// See `markUserDataDirAsAppSpawned(configuration:foreground:)` for write logic and
    /// `isUserDataDirAppSpawned(configuration:)` for the read.
    private static let appSpawnedSentinelFilename = ".macos-widgets-stats-from-website-spawned"

    private func appSpawnedSentinelURL(configuration: ChromeBrowserLaunchConfiguration) -> URL {
        configuration.userDataDirectory
            .appendingPathComponent(Self.appSpawnedSentinelFilename, isDirectory: false)
    }

    /// Writes the sentinel file into `userDataDirectory` containing PID + ISO timestamp +
    /// foreground/background tag. Safe to call repeatedly; later writes overwrite earlier
    /// ones with the most recent spawn metadata.
    ///
    /// Called from `launch()` directly after `process.run()` succeeds. Failure to write
    /// is logged but non-fatal — the headed/headless heuristic will fall back to the
    /// pre-existing UA/PS probes, which are still correct in the no-UA-masking case.
    private func markUserDataDirAsAppSpawned(
        configuration: ChromeBrowserLaunchConfiguration,
        pid: Int32,
        foreground: Bool
    ) {
        let url = appSpawnedSentinelURL(configuration: configuration)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let contents = """
        pid=\(pid)
        ts=\(formatter.string(from: Date()))
        mode=\(foreground ? "foreground" : "headless")
        bundleID=\(Bundle.main.bundleIdentifier ?? "unknown")
        """
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ActivityLogger.log("browser", "failed to write app-spawned sentinel", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "path": url.path,
                "error": error.localizedDescription
            ])
        }
    }

    /// Reads-only check: is the sentinel file present in the user-data-dir for this
    /// configuration? Presence means a previous (or current) app session spawned the
    /// Chrome bound to this CDP port, so it's owned by us and safe to close.
    ///
    /// Note: we deliberately do NOT validate the PID inside the sentinel — a 2-day-old
    /// orphaned headless still has the sentinel from when it was spawned, and that's
    /// exactly the case we want to recognize and clean up. The fact that the sentinel
    /// exists at all is sufficient proof of ownership.
    private func isUserDataDirAppSpawned(configuration: ChromeBrowserLaunchConfiguration) -> Bool {
        let url = appSpawnedSentinelURL(configuration: configuration)
        return fileManager.fileExists(atPath: url.path)
    }

    /// Returns true if the dedicated Chrome instance currently serving this CDP port
    /// was launched by this app (and therefore is safe to close via CDP). Detected in
    /// order of certainty:
    ///   1. In-process tracking — we spawned it in this app session.
    ///   2. Sentinel file in the user-data-dir — we spawned it in a previous session.
    ///   3. CDP `/json/version` User-Agent containing "HeadlessChrome" — legacy heuristic.
    ///   4. `ps` argv scan for `--headless` on the parent process — unsandboxed-fallback.
    ///
    /// The sentinel check (#2) is the durable fix for the UA-masking bug: when we spawn
    /// Chrome with `--user-agent=<custom>` the default UA's "HeadlessChrome" tag is
    /// stripped, so #3 returns false even though the instance is ours. #2 returns true
    /// regardless of UA because the sentinel is written at spawn time. See
    /// `markUserDataDirAsAppSpawned`.
    ///
    /// XCTest target is not yet configured for this project; the test cases that should
    /// be added once it exists:
    ///   - probe result `userAgentContainsHeadless=false` + sentinel PRESENT
    ///     → expect `isExistingInstanceHeadless == true` (treatAsOursAndClose).
    ///   - probe result `userAgentContainsHeadless=false` + sentinel ABSENT
    ///     → expect `isExistingInstanceHeadless == false` (preserves the existing
    ///       "don't kill external Chrome" safety — only our spawns get closed).
    ///   - probe result `userAgentContainsHeadless=true` (legacy default-UA case)
    ///     → expect `isExistingInstanceHeadless == true` regardless of sentinel.
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
        // session). Sentinel-file check is the primary durable signal — it's UA-independent
        // and survives across app restarts. If the sentinel is present, the instance is
        // ours; treat it as closable regardless of what UA-masking flags we may have used.
        if isUserDataDirAppSpawned(configuration: configuration) {
            ActivityLogger.log("browser", "headless-detection via sentinel — treating as app-owned", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "sentinelPath": appSpawnedSentinelURL(configuration: configuration).path,
                "result": "app-owned"
            ])
            return true
        }

        // Sentinel absent (e.g. a user-launched Chrome happens to be on the same CDP port,
        // OR the user-data-dir was wiped). Fall back to the CDP-UA heuristic — still valid
        // for default-UA builds where we haven't overridden `--user-agent`.
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

    /// v0.21.48 — public entry point to terminate the headed Chromium
    /// that Identify-in-Chrome spawned. Used by
    /// `ChromeIdentifyElementCoordinator.releaseIdentifyLock` to ensure
    /// the user-visible window doesn't linger after the picker is done.
    /// Delegates to the same internal kill path used for the headless
    /// teardown (the function is called `terminateHeadlessInstance` for
    /// historical reasons but is the right teardown for any state — it
    /// SIGTERMs the parent process + waits for CDP to go unreachable).
    func terminateHeadedIdentifyInstance(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping () -> Void
    ) {
        // Reuse the shared teardown path, but keep the foreground Process
        // tracked until that path can use it as a bounded fallback. Dropping
        // it here made Browser.close timeouts wait on CDP discovery with no
        // PID to terminate.
        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.global(qos: .userInitiated).async { completion() }
                return
            }
            self.userVisiblePorts.remove(configuration.cdpPort)
            self.terminateHeadlessInstance(configuration: configuration, completion: completion)
        }
    }

    private func terminateHeadlessInstance(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping () -> Void
    ) {
        let port = configuration.cdpPort
        // v0.21.8 items #7/#10: log teardown start so we can spot the (rare
        // but historically painful) case of a teardown colliding with an
        // in-flight scrape — `activeScrapers.count` is the cross-reference.
        let startedAt = Date()
        let activeScrapeCount = ChromeCDPScraper.currentActiveScrapeCount

        queue.async { [weak self] in
            guard let self else {
                DispatchQueue.global(qos: .userInitiated).async { completion() }
                return
            }

            let preTrackedProcessCount = self.backgroundLaunchedProcesses.count + self.foregroundLaunchedProcesses.count
            let preTrackedApplicationCount = self.backgroundLaunchedApplications.count + self.foregroundLaunchedApplications.count

            ActivityLogger.log("browser", "terminateHeadlessInstance started", metadata: [
                "profile": configuration.profileName,
                "port": "\(port)",
                "activeScrapeCount": "\(activeScrapeCount)",
                "trackedProcesses": "\(preTrackedProcessCount)",
                "trackedApplications": "\(preTrackedApplicationCount)"
            ])

            let cdpReachableAtStart = self.isCDPReachable(configuration: configuration)

            // Remove in-process tracking before shutdown so another caller
            // cannot decide this instance is reusable while it is closing.
            let trackedProcess = self.backgroundLaunchedProcesses.removeValue(forKey: port)
                ?? self.foregroundLaunchedProcesses.removeValue(forKey: port)
            let trackedApplication = self.backgroundLaunchedApplications.removeValue(forKey: port)
                ?? self.foregroundLaunchedApplications.removeValue(forKey: port)
            self.backgroundUseCounts[port] = nil
            self.userVisiblePorts.remove(port)
            let trackedProcessPID = (trackedProcess?.isRunning == true) ? trackedProcess?.processIdentifier : nil

            // For untracked-but-running headless (started in a previous app session),
            // ask Chrome to close over CDP first. This also matters for tracked
            // app-owned Chromium: a graceful Browser.close keeps the profile's
            // exit_type clean, while SIGTERM marks it crashed and makes the next
            // launch restore stale Identify tabs.
            self.requestBrowserCloseViaCDP(configuration: configuration) { [weak self] in
                guard let self else {
                    DispatchQueue.global(qos: .userInitiated).async { completion() }
                    return
                }

                self.queue.async {
                    let cdpGoneStartedAt = Date()
                    // Wait briefly for the CDP port to actually go down so the subsequent
                    // launch sees a non-reachable port. waitUntilCDPGone polls every 100ms
                    // up to 3s.
                    self.waitUntilCDPGone(configuration: configuration, deadline: Date().addingTimeInterval(3)) {
                        self.queue.async {
                            let gracefulWaitMs = Int(Date().timeIntervalSince(cdpGoneStartedAt) * 1000)
                            var fallbackKillPID: pid_t? = nil
                            var usedTrackedFallback = false

                            let trackedStillRunning = trackedProcess?.isRunning == true
                                || trackedApplication?.isTerminated == false
                            if self.isCDPReachable(configuration: configuration) || trackedStillRunning || !cdpReachableAtStart {
                                if let trackedProcess, trackedProcess.isRunning {
                                    usedTrackedFallback = true
                                    trackedProcess.terminate()
                                }
                                if let trackedApplication, !trackedApplication.isTerminated {
                                    usedTrackedFallback = true
                                    DispatchQueue.main.async {
                                        trackedApplication.terminate()
                                    }
                                }
                                if self.isCDPReachable(configuration: configuration),
                                   let pid = self.findDedicatedBrowserPID(configuration: configuration) {
                                    fallbackKillPID = pid
                                    kill(pid, SIGTERM)
                                }
                            }

                            let finalWaitStartedAt = Date()
                            self.waitUntilCDPGone(configuration: configuration, deadline: Date().addingTimeInterval(3)) {
                                let fallbackWaitMs = Int(Date().timeIntervalSince(finalWaitStartedAt) * 1000)
                                let finalCDPReachable = self.isCDPReachable(configuration: configuration)
                                let totalElapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                                ActivityLogger.log("browser", "terminateHeadlessInstance ended", metadata: [
                                    "profile": configuration.profileName,
                                    "port": "\(port)",
                                    "totalElapsedMs": "\(totalElapsedMs)",
                                    "waitMsUntilCDPGone": "\(gracefulWaitMs + fallbackWaitMs)",
                                    "gracefulCloseAttempted": cdpReachableAtStart ? "true" : "false",
                                    "usedTrackedFallback": usedTrackedFallback ? "true" : "false",
                                    "finalCDPReachable": finalCDPReachable ? "true" : "false",
                                    "trackedProcessPID": trackedProcessPID.map(String.init) ?? "",
                                    "fallbackKillPID": fallbackKillPID.map(String.init) ?? "",
                                    "activeScrapeCountAtEnd": "\(ChromeCDPScraper.currentActiveScrapeCount)"
                                ])
                                completion()
                            }
                        }
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

    /// v0.21.14 — atomically reserves a scrape-start slot for the given
    /// profile and returns the delay (seconds) the caller must wait
    /// before actually beginning the scrape. Returns 0 when no stagger
    /// is needed.
    ///
    /// Race-correctness: the watermark is advanced INSIDE the same
    /// queue.sync that reads the previous value, BEFORE returning to
    /// the caller. This guarantees that if N callers race in, they
    /// each see the cumulative projected start time of all prior
    /// reservations and stagger correctly. Without this, two callers
    /// arriving simultaneously could both read the same "last start"
    /// and compute the same delay, then both fire after that delay
    /// and stomp on each other (the exact failure mode this fix
    /// targets — voice 3988).
    ///
    /// The structured "staggering scrape" log line lets MBP-CC grep
    /// activity.log for stagger events during the 10-cycle verification:
    ///   grep "staggering scrape: profile=" activity.log
    func reserveScrapeStart(profileName: String = ChromeBrowserProfile.defaultProfileName) -> TimeInterval {
        let configuration = configuration(profileName: profileName)
        let port = configuration.cdpPort
        let now = Date()

        let (delay, projectedStart, sinceLast): (TimeInterval, Date, TimeInterval?) = queue.sync {
            let last = lastScrapeStartedAt[port]
            let sinceLast = last.map { now.timeIntervalSince($0) }

            // Compute delay: if last scrape was T seconds ago (or no prior),
            // wait max(0, minGap - T). If `last` is in the FUTURE (because
            // a prior reservation pushed the watermark beyond now), wait
            // until that future time PLUS the full minGap.
            let projectedStart: Date
            let delay: TimeInterval
            if let last {
                // If last is in the future, the previous reserver scheduled
                // a start at `last`; this new reservation must come at
                // least minGap AFTER that point.
                let earliestNextStart = last.addingTimeInterval(Self.minScrapeStartGap)
                if earliestNextStart > now {
                    projectedStart = earliestNextStart
                    delay = earliestNextStart.timeIntervalSince(now)
                } else {
                    projectedStart = now
                    delay = 0
                }
            } else {
                projectedStart = now
                delay = 0
            }

            lastScrapeStartedAt[port] = projectedStart
            return (delay, projectedStart, sinceLast)
        }

        if delay > 0 {
            // Structured log line — keep field names stable so MBP-CC
            // (and any other consumer) can grep for `staggering scrape: profile=`.
            ActivityLogger.log("scheduler", "staggering scrape", metadata: [
                "profile": profileName,
                "port": "\(port)",
                "gapSec": String(format: "%.1f", delay),
                "sinceLastSec": sinceLast.map { String(format: "%.1f", $0) } ?? "(none)",
                "projectedStartIso": ISO8601DateFormatter().string(from: projectedStart),
                "minGapSec": String(format: "%.0f", Self.minScrapeStartGap)
            ])
        }

        return delay
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

            // v0.21.46 — persistent Chromium mode short-circuit.
            //
            // When persistentBrowserMode is on we DELIBERATELY skip the
            // end-of-scrape terminate. The Chromium process stays alive,
            // ready for the next scrape to open a fresh tab on the same
            // CDP port without a new browser-init cycle (which is the
            // Tahoe-26 SIGTRAP hot zone at imageOffset 0x6816xxx).
            //
            // We keep the bookkeeping entries (backgroundLaunchedProcesses,
            // backgroundLaunchedApplications) in place so:
            //   1. terminateAppOwnedBrowsersOnAppExit can still find +
            //      cleanly terminate the long-running browser when the
            //      host app quits (no orphan Chromium processes).
            //   2. isExistingInstanceHeadless can confirm app-ownership
            //      via in-process tracking on the next scrape.
            //
            // If Chromium dies between scrapes (real crash / OOM / user
            // kill), the next call to ensureLaunched detects via
            // isCDPReachable + findDedicatedBrowserPID and spawns fresh.
            // No special handling needed here.
            //
            // We log the skip so activity.log makes it clear that we
            // KEPT the process intentionally — otherwise this looks like
            // a missing terminate in audits / debug sessions.
            if ChromeBrowserProfile.persistentBrowserMode {
                ActivityLogger.log("browser", "persistent-mode: keeping Chrome alive between scrapes", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(port)"
                ])
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
                    // closed here. Confirm the existing instance is app-owned before issuing
                    // the CDP-close. `isExistingInstanceHeadless` checks (in order): in-process
                    // tracking, the spawn-sentinel file in `--user-data-dir` (UA-independent,
                    // survives across app restarts — the durable fix for the UA-masking bug),
                    // then the legacy CDP-UA + ps heuristics. It returns false only when the
                    // instance is plausibly external/user-owned OR when probing fails — in
                    // either case, skip the close.
                    if self.isExistingInstanceHeadless(configuration: configuration) {
                        self.requestBrowserCloseViaCDP(configuration: configuration) {
                            ActivityLogger.log("browser", "closed app-owned background Chrome after scrape via CDP", metadata: [
                                "profile": configuration.profileName,
                                "port": "\(port)"
                            ])
                        }
                    } else {
                        ActivityLogger.log("browser", "skipped CDP close — instance not confirmed app-owned", metadata: [
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

        terminateAppOwnedBrowsersFromPreviousSessions(reason: "app-exit")
    }

    /// Kill app-owned Chromium processes that survived outside this app
    /// session's in-memory tracking.
    ///
    /// This intentionally runs at startup before the background scheduler
    /// starts. Sparkle and local install flows can replace the `.app` while
    /// persistent Chromium from the prior build is still alive under
    /// launchd. That orphan can later crash and show "Chromium quit
    /// unexpectedly", or keep serving an old CDP instance/profile lock.
    ///
    /// Safety boundary: only processes whose argv contains this app's
    /// dedicated browser profile root OR the app-bundled Chromium path are
    /// targeted. Personal Chrome/Chromium uses a different user-data-dir and
    /// does not live under our app bundle, so it is out of scope.
    func terminateAppOwnedBrowsersFromPreviousSessions(reason: String) {
        let matches = findAppOwnedBrowserProcesses()
        guard !matches.isEmpty else {
            ActivityLogger.log("browser", "no orphaned app-owned Chromium processes found", metadata: [
                "reason": reason
            ])
            return
        }

        ActivityLogger.log("browser", "terminating orphaned app-owned Chromium processes", metadata: [
            "reason": reason,
            "count": "\(matches.count)",
            "parents": "\(matches.filter(\.isBrowserParent).count)",
            "pids": matches.map { String($0.pid) }.joined(separator: ",")
        ])

        let orderedMatches = matches.sorted { lhs, rhs in
            if lhs.isBrowserParent != rhs.isBrowserParent {
                return lhs.isBrowserParent
            }
            return lhs.pid < rhs.pid
        }

        for match in orderedMatches {
            if kill(match.pid, SIGTERM) != 0 && errno != ESRCH {
                ActivityLogger.log("browser", "SIGTERM to orphaned Chromium failed", metadata: [
                    "reason": reason,
                    "pid": "\(match.pid)",
                    "errno": "\(errno)"
                ])
            }
        }

        waitForProcessExit(pids: orderedMatches.map(\.pid), timeout: 1.5)

        let survivors = orderedMatches.filter { kill($0.pid, 0) == 0 }
        for survivor in survivors {
            if kill(survivor.pid, SIGKILL) != 0 && errno != ESRCH {
                ActivityLogger.log("browser", "SIGKILL to orphaned Chromium failed", metadata: [
                    "reason": reason,
                    "pid": "\(survivor.pid)",
                    "errno": "\(errno)"
                ])
            }
        }

        if !survivors.isEmpty {
            waitForProcessExit(pids: survivors.map(\.pid), timeout: 1.0)
        }

        let finalSurvivors = orderedMatches.filter { kill($0.pid, 0) == 0 }
        ActivityLogger.log("browser", "orphaned app-owned Chromium termination finished", metadata: [
            "reason": reason,
            "initialCount": "\(orderedMatches.count)",
            "sigkillCount": "\(survivors.count)",
            "remaining": "\(finalSurvivors.count)",
            "remainingPids": finalSurvivors.map { String($0.pid) }.joined(separator: ",")
        ])
    }

    private func waitForProcessExit(pids: [pid_t], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func findAppOwnedBrowserProcesses() -> [AppOwnedBrowserProcess] {
        guard let output = Self.runPSAndReadOutput() else {
            ActivityLogger.log("browser", "orphaned Chromium scan failed: ps unavailable")
            return []
        }

        let browserRoot = AppGroupPaths.canonicalApplicationSupportURL()
            .appendingPathComponent("Browser", isDirectory: true)
            .path
        let userDataNeedle = "--user-data-dir=\(browserRoot)"
        let bundledPathNeedles = [
            "/Stats Widget from Website.app/Contents/Resources/Browsers/Chromium.app/Contents/",
            "/MacosWidgetsStatsFromWebsite.app/Contents/Resources/Browsers/Chromium.app/Contents/"
        ]

        return output.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  let separator = line.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                return nil
            }

            let pidString = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let command = String(line[separator...]).trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(pidString), pid > 0, pid != getpid() else {
                return nil
            }

            let ownsDedicatedProfile = command.contains(userDataNeedle)
            let ownsBundledPath = bundledPathNeedles.contains { command.contains($0) }
            guard ownsDedicatedProfile || ownsBundledPath else {
                return nil
            }

            let isBrowserParent = command.contains("Chromium.app/Contents/MacOS/Chromium")
                && !command.contains(" --type=")
            return AppOwnedBrowserProcess(
                pid: pid,
                command: command,
                isBrowserParent: isBrowserParent
            )
        }
    }

    func openTab(
        url: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        // v0.21.8 item #8: requestID + queueDepth let us trace a single openTab
        // call through the serialized target-creation pipeline. The same id is
        // logged at enqueue and dequeue so a stuck queue (the v0.21.5 failure
        // mode that wedged `targetCreationPortsInFlight`) shows up as an
        // "enqueued" entry with no matching "dequeued" entry within the
        // outer scrape's 30s timeout.
        let requestID = UUID().uuidString.prefix(8)
        queue.async { [weak self] in
            guard let self else { return }
            let port = configuration.cdpPort
            self.pendingTargetCreations[port, default: []].append(
                PendingTargetCreation(url: url, completion: completion)
            )
            let queueDepth = self.pendingTargetCreations[port]?.count ?? 0
            let inFlight = self.targetCreationPortsInFlight.contains(port)
            ActivityLogger.log("browser", "openTab enqueued", metadata: [
                "profile": configuration.profileName,
                "port": "\(port)",
                "requestID": String(requestID),
                "queueDepth": "\(queueDepth)",
                "inFlight": inFlight ? "true" : "false"
            ])
            self.drainTargetCreationQueue(configuration: configuration)
        }
    }

    private func drainTargetCreationQueue(configuration: ChromeBrowserLaunchConfiguration) {
        let port = configuration.cdpPort
        guard !targetCreationPortsInFlight.contains(port),
              var queue = pendingTargetCreations[port],
              !queue.isEmpty else {
            return
        }

        let request = queue.removeFirst()
        pendingTargetCreations[port] = queue.isEmpty ? nil : queue
        targetCreationPortsInFlight.insert(port)
        let remainingDepth = pendingTargetCreations[port]?.count ?? 0
        ActivityLogger.log("browser", "openTab dequeued", metadata: [
            "profile": configuration.profileName,
            "port": "\(port)",
            "remainingQueueDepth": "\(remainingDepth)"
        ])

        createTargetRequest(url: request.url, configuration: configuration, method: "PUT") { [weak self] result in
            request.completion(result)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.targetCreationPortsInFlight.remove(port)
                self.drainTargetCreationQueue(configuration: configuration)
            }
        }
    }

    /// Fire-and-forget HTTP `/json/close/<id>` fallback. The primary tab-close
    /// path lives in `ChromeCDPClient.closePageTarget` (sends `Page.close` over
    /// the existing page websocket BEFORE the websocket is cancelled) — this
    /// REST call is kept as a belt-and-suspenders cleanup for the case where
    /// the websocket was already dead when `finish()` ran. Logged so we can
    /// audit tab-leak claims via the activity log.
    func closeTarget(id: String, configuration: ChromeBrowserLaunchConfiguration) {
        guard !id.isEmpty,
              let url = URL(string: "/json/close/\(id)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            return
        }

        ChromeBrowserProfile.cdpRequestSession.dataTask(with: url) { _, response, error in
            if let error {
                ActivityLogger.log("browser", "REST tab close failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "target": id,
                    "error": error.localizedDescription
                ])
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            ActivityLogger.log("browser", "REST tab close request completed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "target": id,
                "status": "\(status)"
            ])
        }.resume()
    }

    /// v0.21.47 — fire-and-forget HTTP `/json/activate/<id>` REST call.
    ///
    /// Brings the given CDP page target to the front of its Chromium window
    /// (Chromium implements this as Target.activateTarget under the hood,
    /// which switches the tab strip's selected tab + raises the window).
    ///
    /// Why this exists: Identify-in-Chrome creates a new tab via `openTab` /
    /// `/json/new` so the user can hover + click the element they want
    /// extracted. Chromium does NOT automatically activate the newly-created
    /// tab — the previously-focused tab (typically the launch-spawned
    /// `about:blank` from `--user-data-dir` boot) STAYS foregrounded. The
    /// user then sees `about:blank` when they switch to Chrome, the picker
    /// overlay is sitting waiting in a background tab they can't see, and
    /// the whole flow looks broken (voice 4269: "extra about: tab opens,
    /// picker never appears").
    ///
    /// Pairing this REST call with `openTab` makes the target URL the
    /// active tab the moment the window comes to the front, so the user
    /// lands directly on the page where the overlay is injected.
    ///
    /// Fire-and-forget + idempotent (Chromium returns 200 with the target
    /// JSON on success, 404 if the target was already closed, neither of
    /// which is fatal here). Best-effort — logged for audit.
    func activateTarget(id: String, configuration: ChromeBrowserLaunchConfiguration) {
        guard !id.isEmpty,
              let url = URL(string: "/json/activate/\(id)", relativeTo: configuration.cdpURL)?.absoluteURL else {
            return
        }

        ChromeBrowserProfile.cdpRequestSession.dataTask(with: url) { _, response, error in
            if let error {
                ActivityLogger.log("browser", "REST tab activate failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "target": id,
                    "error": error.localizedDescription
                ])
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            ActivityLogger.log("browser", "REST tab activate request completed", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "target": id,
                "status": "\(status)"
            ])
        }.resume()
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

    /// Strict target lookup for foreground Identify launches.
    ///
    /// Unlike `bestExistingPageTarget`, this only succeeds when the target
    /// URL actually matches the requested page. Foreground Identify uses this
    /// while polling for the tab created by the Chromium launch URL. A loose
    /// "any usable HTTP tab" match is unsafe here because Chromium can restore
    /// stale session tabs from the dedicated profile before the launch URL
    /// commits, and selecting one of those stale tabs is exactly the wrong-tab
    /// flake this path is meant to prevent.
    func pageTargetStrictlyMatching(
        _ url: URL,
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<ChromeBrowserTarget, Error>) -> Void
    ) {
        listPageTargets(configuration: configuration) { result in
            switch result {
            case .success(let targets):
                let rankedTargets: [(score: Int, listIndex: Int, target: ChromeBrowserPageTarget)] = targets.enumerated().compactMap { index, target in
                    guard let score = Self.strictMatchScore(for: target, requestedURL: url) else { return nil }
                    return (score, index, target)
                }.sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    return lhs.listIndex < rhs.listIndex
                }

                if let bestTarget = rankedTargets.first?.target {
                    completion(.success(bestTarget.asTarget))
                    return
                }

                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("No CDP page target matched \(url.absoluteString).")))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func closePageTargetsExcept(
        configuration: ChromeBrowserLaunchConfiguration,
        keepTargetIDs: Set<String>,
        completion: ((Int) -> Void)? = nil
    ) {
        listPageTargets(configuration: configuration) { [weak self] result in
            switch result {
            case .success(let targets):
                guard let self else {
                    completion?(0)
                    return
                }

                let disposables = targets.filter { !keepTargetIDs.contains($0.id) }
                if disposables.isEmpty {
                    ActivityLogger.log("browser", "strict tab cleanup — nothing to close", metadata: [
                        "profile": configuration.profileName,
                        "port": "\(configuration.cdpPort)",
                        "tabCount": "\(targets.count)",
                        "keptIDs": keepTargetIDs.sorted().joined(separator: ",")
                    ])
                    completion?(0)
                    return
                }

                for target in disposables {
                    self.closeTarget(id: target.id, configuration: configuration)
                }

                ActivityLogger.log("browser", "strict tab cleanup — closed non-selected targets", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "before": "\(targets.count)",
                    "closed": "\(disposables.count)",
                    "kept": "\(targets.count - disposables.count)",
                    "keptIDs": keepTargetIDs.sorted().joined(separator: ",")
                ])
                completion?(disposables.count)
            case .failure(let error):
                ActivityLogger.log("browser", "strict tab cleanup — list failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "error": error.localizedDescription
                ])
                completion?(0)
            }
        }
    }

    private struct ForegroundWindowPlacement {
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var arguments: [String] {
            [
                "--window-position=\(x),\(y)",
                "--window-size=\(width),\(height)"
            ]
        }

        var cdpBounds: [String: Any] {
            [
                "left": x,
                "top": y,
                "width": width,
                "height": height,
                "windowState": "normal"
            ]
        }
    }

    private func foregroundWindowPlacementArguments() -> [String] {
        Self.foregroundWindowPlacement()?.arguments ?? []
    }

    func foregroundWindowPlacementBoundsForCDP() -> [String: Any]? {
        Self.foregroundWindowPlacement()?.cdpBounds
    }

    /// Places user-visible Chromium on the same physical display as the Stats
    /// app window. Without explicit placement, macOS/Chromium tends to open
    /// headed Identify windows on the main external monitor even when the
    /// user is configuring a tracker from another screen.
    private static func foregroundWindowPlacement() -> ForegroundWindowPlacement? {
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return nil }

        let referenceBounds = referenceWindowBoundsForCurrentProcess()
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())
        let display = referenceBounds.flatMap { bestDisplay(for: $0, displays: displays) }
            ?? displays.first(where: { $0.equalTo(mainDisplayBounds) })
            ?? displays[0]

        let margin: CGFloat = 24
        let width = min(CGFloat(1000), max(CGFloat(640), display.width - margin * 2))
        let height = min(CGFloat(720), max(CGFloat(480), display.height - margin * 2))

        let desiredX = referenceBounds?.minX ?? display.minX + margin
        let x = clamp(desiredX, min: display.minX + margin, max: display.maxX - width - margin)
        let y = clamp(display.minY + margin, min: display.minY + margin, max: display.maxY - height - margin)

        return ForegroundWindowPlacement(
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: Int(width.rounded()),
            height: Int(height.rounded())
        )
    }

    private static func activeDisplayBounds() -> [CGRect] {
        let screenBounds = onMainThread {
            NSScreen.screens.map(\.frame)
        }
        if !screenBounds.isEmpty {
            return screenBounds
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success,
              displayCount > 0 else {
            return []
        }

        return displayIDs.prefix(Int(displayCount)).map { CGDisplayBounds($0) }
    }

    private static func onMainThread<T>(_ work: @escaping () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }

        return DispatchQueue.main.sync(execute: work)
    }

    private static func referenceWindowBoundsForCurrentProcess() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let currentPID = Int(getpid())
        let candidates: [(bounds: CGRect, area: CGFloat)] = windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int) == currentPID,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary),
                  bounds.width >= 320,
                  bounds.height >= 200 else {
                return nil
            }

            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1.0
            guard alpha > 0 else { return nil }
            return (bounds, bounds.width * bounds.height)
        }

        return candidates.max { lhs, rhs in lhs.area < rhs.area }?.bounds
    }

    private static func bestDisplay(for bounds: CGRect, displays: [CGRect]) -> CGRect? {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        if let containing = displays.first(where: { $0.contains(center) }) {
            return containing
        }

        return displays.max { lhs, rhs in
            intersectionArea(lhs, bounds) < intersectionArea(rhs, bounds)
        }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return Swift.min(Swift.max(value, minimum), maximum)
    }

    private func buildChromeLaunchArguments(configuration: ChromeBrowserLaunchConfiguration, headless: Bool) -> [String] {
        var arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(configuration.cdpPort)",
            "--remote-allow-origins=*",
            "--user-data-dir=\(configuration.userDataDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--disable-background-networking",
            "--disable-component-update",
            // NOTE: The original "--disable-features=Translate,MediaRouter"
            // gate moved DOWN into the consolidated --disable-features
            // bundle in the v0.21.45 second-wave defensive block below.
            // Chromium only honors a SINGLE --disable-features flag value
            // (the last one wins on duplicates), so to add more features
            // we have to merge — not append a second flag.
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
            "--use-mock-keychain",
            // Crash fix (v0.21.40): defensive disables for macOS 26 (Tahoe) +
            // Chromium 150 startup-phase browser-main crashes (EXC_BREAKPOINT
            // / SIGTRAP on CrBrowserMain, ~6-9 s after launch, identical
            // stack frame offset 0x6816010 across multiple crashes). The
            // unified system log (`log show ... process == "Chromium"`)
            // captured immediately before each crash shows a burst of:
            //   • SiriTTSService #FactoryInstall errors (asset query "5")
            //   • AssistantServices  AFLocalization "No descriptor found
            //     for language code <private>, voice name <private>"
            //     (repeats 8-10 times in <300 ms)
            //   • CoreAudio HALC_ShellObject::SetPropertyData proxy errors
            //   • SafariServices SFUniversalLink "Process not entitled"
            //   • 45+ TCC access requests in a 7 s window
            // The dominant signal is that Chromium 150's Web Speech API
            // initialization probes the macOS speech-synthesis voice
            // catalog (Siri/AVSpeech infrastructure), the Tahoe TTS asset
            // query returns an unexpected null/empty result, and an
            // `IMMEDIATE_CRASH`/`CHECK` in browser-side speech code fires
            // → SIGTRAP. We don't need ANY of these APIs for the scraper:
            // scraping is pure DOM reads, never audio/speech/synth.
            // Belt-and-suspenders disable list:
            //   --disable-speech-api          → disables BOTH speech
            //                                   recognition + synthesis
            //   --disable-speech-synthesis-api→ also kills synth, in case
            //                                   --disable-speech-api flag
            //                                   stops working in a future
            //                                   Chromium build (defensive)
            //   --mute-audio                  → blocks any page-driven
            //                                   audio playback (HALC proxy)
            //   --disable-audio-output        → secondary HAL gate
            //   --disable-notifications       → kills macOS notification
            //                                   permission probes (one
            //                                   source of TCC flood)
            // Refs: LEARNINGS.md (chromium-tahoe-26-browser-main-crash),
            //       garrytan/gstack#867 (different but related Tahoe crash),
            //       crash reports ~/Library/Logs/DiagnosticReports/
            //       Chromium-2026-05-26-16{19,37,42}*.ips
            "--disable-speech-api",
            "--disable-speech-synthesis-api",
            "--mute-audio",
            "--disable-audio-output",
            "--disable-notifications",
            // Crash fix (v0.21.45): SECOND-WAVE defensive disables for a NEW
            // Tahoe browser-main crash signature that survived the v0.21.40
            // speech-API patch. Two crashes 18:15:59 + 18:48:59 BST 2026-05-26
            // landed at imageOffset 0x6816050 — 448 bytes BEYOND the original
            // 0x6816010 speech-API crash, i.e. a sibling Chromium-150
            // browser-init code path that we hadn't yet muzzled. The unified
            // log around both crashes shows the SAME bursts of macOS API
            // probes in the seconds before SIGTRAP:
            //   • CoreLocation / CLLocationManager init + authorization
            //     check (returns NotDetermined → triggers Tahoe TCC path)
            //   • LocalAuthentication / Biometry — `canEvaluatePolicy:4`
            //     LAContext create/dealloc cycles (Touch-ID / passkey /
            //     WebAuthn platform-authenticator probe). 18:15 crash
            //     showed FIVE LAContext allocations in <100 ms.
            //   • TCC kTCCServiceMicrophone + kTCCServiceCamera requests
            //     (getUserMedia / MediaDevices.enumerateDevices probe).
            //     18:48 crash showed mic + 2x camera TCC IPC sync calls
            //     ~5 s before SIGTRAP.
            //   • SafariServices SFUniversalLink "Process not entitled"
            //     repeatedly (cosmetic but burns startup time).
            // The previous --mute-audio / --disable-audio-output gate
            // disabled audio OUTPUT (page-driven playback) but did NOT
            // disable audio/video INPUT (capture) — Chromium 150 still
            // initializes MediaDevices, MediaStream, WebRTC peer-connection
            // factory at startup which probes Camera+Mic TCC. Similarly we
            // had no flag covering Geolocation (CLLocationManager) or
            // WebAuthn/PublicKeyCredentials (Biometry). All three were
            // hitting Tahoe-changed permission daemons and one of them is
            // landing the IMMEDIATE_CRASH/CHECK at 0x6816050.
            //
            // Cumulative defensive bundle below — none of these APIs are
            // ever exercised by the scraper (we read DOM via CDP, full
            // stop), so disabling them is free.
            //
            //   --use-fake-ui-for-media-stream   → auto-deny getUserMedia
            //                                      prompts (we won't ever
            //                                      hit this codepath but
            //                                      belt-and-suspenders)
            //   --use-fake-device-for-media-stream → return fake camera /
            //                                      mic descriptors instead
            //                                      of probing real ones via
            //                                      AVCaptureDevice → TCC
            //   --disable-features=... blob below → master kill-switch for
            //                                      the specific Chromium
            //                                      subsystems that init at
            //                                      browser-main and hit the
            //                                      crashing code path
            //
            // Feature kill-list rationale (one line per feature):
            //   MediaSession,HardwareMediaKeyHandling — kills NowPlaying /
            //     media-key registration (system audio-route + media-key
            //     hooks). Tahoe rewrote MPNowPlayingInfoCenter; common
            //     SIGTRAP source on early Tahoe builds.
            //   NotificationTriggers,WebNotifications — kills UserNotifications
            //     framework probe at init, on top of existing
            //     --disable-notifications (different layer; that flag
            //     gates web-API surface, this gates the macOS bridge).
            //   MediaCapture,WebAudio,WebRtcPipeWireCapturer,
            //     AudioServiceOutOfProcess — kills the entire AV-capture
            //     subsystem so MediaDevices.enumerateDevices doesn't
            //     enumerate AVCaptureDevice list at startup.
            //   WebMidi,WebUSB,WebBluetooth,WebHid,WebSerial,WebNFC —
            //     all hit macOS permission daemons. We do NONE of these.
            //   Geolocation,DeviceOrientationEvents — kills
            //     CLLocationManager init + motion-coprocessor probe.
            //   AmbientAuthenticationInPrivateModes,WebAuthentication —
            //     kills LocalAuthentication / Biometry probe path. Note
            //     the WebAuthentication flag has historically been
            //     "WebAuthentication" / "U2F" in Chromium; we cover both
            //     names defensively.
            //   IdleDetection,Serial,ContactsAPI — niche perm probes.
            //   Translate,MediaRouter — already in the --disable-features
            //     above; included again here in the consolidated list for
            //     readability (Chromium dedupes feature names internally).
            //
            // CAUTION: `--disable-features` only accepts ONE comma-list.
            // We REPLACE the earlier "--disable-features=Translate,MediaRouter"
            // entry (also above) with one combined comma-list below.
            // Refs: crash reports ~/Library/Logs/DiagnosticReports/
            //       Chromium-2026-05-26-{181559,184859}.ips
            //       (frame#0 imageOffset = 109142480 = 0x6816050)
            //       LEARNINGS.md "chromium-tahoe-26-browser-main-crash"
            // v0.21.48 — REMOVED `--use-fake-ui-for-media-stream`. Chromium 150
            // surfaces a yellow "You are using an unsupported command-line flag:
            // --use-fake-ui-for-media-stream. Stability and security will suffer."
            // BANNER inside the visible browser window when this flag is set in
            // headed mode. The banner is the source of voice 4277's "using an
            // unsupported command-line flag, use fake UI for media stream, and
            // security will suffer" complaint. The flag is also redundant with
            // the consolidated `--disable-features=MediaCapture,WebAudio,...`
            // bundle below — that bundle kills the entire AV-capture init path
            // BEFORE getUserMedia can ever prompt, so the auto-deny behaviour
            // this flag provided is no longer load-bearing.
            //
            // `--use-fake-device-for-media-stream` is KEPT (it doesn't trigger
            // the visible banner and is the belt-and-suspenders for any path
            // that does still enumerate `MediaDevices` before the feature
            // bundle bites).
            "--use-fake-device-for-media-stream",
            // Crash fix (v0.21.46): THIRD-WAVE defensive disables. v0.21.45's
            // bundle dropped the cluster mean but ~5/hour SIGTRAPs still hit
            // the same 0x6816xxx region (109142612 et al). The crashing region
            // is ~256 bytes wide in Chromium 150's browser-init code. We don't
            // know exactly which subsystem trips the next sibling crash; rather
            // than chase individual signatures, this bundle muzzles EVERY
            // Tahoe-rewritten daemon Chromium 150 still probes at startup.
            // Every flag below is safe for headless DOM-only scraping — we
            // never use WebGL, picture-in-picture, payments, screen capture,
            // background fetch/sync, contacts, SMS, ambient light, motion
            // sensors, screen AI, presentation API, etc. None of these are
            // exercised by the CDP DOM-read path.
            //
            // Individual command-line flags (Chromium switches.cc):
            //   --disable-3d-apis          → kills WebGL/WebGL2 ANGLE pipeline
            //                                init (no GPU command-buffer
            //                                bring-up; the IOSurface/Metal init
            //                                path on Tahoe has changed
            //                                materially in 26.4)
            //   --disable-webgl            → belt-and-suspenders WebGL gate
            //   --disable-webgl2           → same for WebGL2
            //   --disable-canvas-aa        → no GPU canvas antialiasing
            //                                (cheaper, no Metal probe)
            //   --disable-d3d11            → no D3D11 init attempt (no-op on
            //                                macOS but free defense)
            //   --disable-vulkan           → no Vulkan init attempt
            //   --no-experiments           → ignore field-trial overrides
            //                                that might re-enable a feature
            //                                we just disabled below
            //   --disable-back-forward-cache → don't probe the new bfcache
            //                                  IPC plumbing at init
            //   --disable-renderer-backgrounding → counterintuitive, but
            //                                      prevents an init-time race
            //                                      where renderers are
            //                                      backgrounded before their
            //                                      browser-side state is
            //                                      ready (cited in a few
            //                                      Chromium issues)
            //   --disable-component-extensions-with-background-pages
            //                              → kills the Hangouts/Cast/etc.
            //                                background-page extensions that
            //                                ship with Chromium and hit
            //                                various permission daemons.
            //   --disable-extensions       → master extension off-switch
            //                                (we don't use extensions)
            //   --disable-translate        → translate-bar / language detection
            //                                triggers an external infra probe
            //   --disable-pinch            → no pinch-zoom IPC plumbing
            //   --disable-search-engine-choice-screen → suppresses an init
            //                                            probe that's been
            //                                            crashy on Tahoe
            //   --metrics-recording-only / --disable-metrics → no UMA/UKM
            //                                                   pipeline init
            //   --disable-domain-reliability → kills the DRC reporting
            //                                  pipeline init
            //   --disable-crash-reporter   → kills Chromium's own crashpad
            //                                handler init (we have our own
            //                                .ips collection via macOS; this
            //                                avoids two crash handlers
            //                                fighting over the signal stack)
            //   --no-crash-upload          → defensive — never upload to Google
            //   --safebrowsing-disable-auto-update → kills SB definition
            //                                        download init
            //   --disable-features-from-field-trials → see --no-experiments
            //   --noerrdialogs             → suppress error dialogs (we're
            //                                headless, none should appear)
            //   --no-pings                 → no hyperlink ping probes
            //   --disable-breakpad         → secondary crash-handler gate
            "--disable-3d-apis",
            "--disable-webgl",
            "--disable-webgl2",
            "--disable-canvas-aa",
            "--disable-d3d11",
            "--disable-vulkan",
            "--no-experiments",
            "--disable-back-forward-cache",
            "--disable-renderer-backgrounding",
            "--disable-component-extensions-with-background-pages",
            "--disable-extensions",
            "--disable-translate",
            "--disable-pinch",
            "--disable-search-engine-choice-screen",
            "--metrics-recording-only",
            "--disable-domain-reliability",
            "--disable-crash-reporter",
            "--no-crash-upload",
            "--safebrowsing-disable-auto-update",
            "--noerrdialogs",
            "--no-pings",
            "--disable-breakpad",
            // CONSOLIDATED --disable-features (one flag, Chromium dedupes
            // internally; last value wins on duplicates). v0.21.46 adds the
            // following to the v0.21.45 list:
            //   GlobalMediaControls         — Now Playing media control bar
            //                                 (system-integration probe).
            //   Sharesheet                  — macOS Share Sheet integration.
            //   SystemNotifications         — UserNotificationCenter delegate
            //                                 install (separate from the
            //                                 webNotifications surface).
            //   UserMediaCaptureOnFocus     — focus-driven recapture probe.
            //   WebOTP                      — SMS OTP autofill API.
            //   SmsReceiver                 — same family as WebOTP.
            //   BackgroundFetch             — service worker background fetch.
            //   BackgroundSync              — service worker background sync.
            //   PaymentRequest              — payment-handler init.
            //   PictureInPicture            — PiP window service init.
            //   ScreenCapture               — getDisplayMedia probe.
            //   AccessibilityService        — Tahoe-rewrote VoiceOver IPC.
            //   PermissionsAPI              — permissions.query probe.
            //   PresentationAPI             — second-screen device probe.
            //   FaceTimeCalling             — tel: URL handler probe (new
            //                                 in Tahoe).
            //   AmbientLight                — ambient light sensor IPC.
            //   DeviceOrientationEvent      — motion-sensor probe (singular,
            //                                 v0.21.45 had the plural variant;
            //                                 different Chromium feature
            //                                 name, both covered now).
            //   DeviceMotionEvent           — same; both names.
            //   ContactsAPI                 — already in v0.21.45 list, kept.
            //   ScreenAI                    — Tahoe's on-device screen AI
            //                                 framework probe.
            //   AssistiveTouch              — accessibility input service
            //                                 probe.
            //   WebInstalledAppCheck        — getInstalledRelatedApps probe.
            //   ChromeWhatsNewUI            — first-run "what's new" prompt
            //                                 we never want to surface.
            //   InterestFeedV2,InterestFeedContentSuggestions
            //                                 → kills the Feed init that
            //                                   has been crashy on Tahoe.
            //   NTPCustomization            → new-tab-page customization
            //                                  service probe.
            //   ChromeRefresh2023           → fancy redesign that touches
            //                                  new system APIs.
            //   PrivacySandboxSettings4     → privacy sandbox setup.
            //   FedCm                       → federated credential management,
            //                                  hits the credentials daemon.
            //   StorageBuckets              → storage-bucket API init.
            //   AttributionReportingAPI     → conversion measurement API
            //                                  init (network init).
            //
            // Chromium dedupes feature names. Order doesn't matter. Final
            // string MUST be a single flag (otherwise the later one wins
            // and the earlier ones are silently dropped — Chromium
            // behavior, not a bug).
            "--disable-features=Translate,MediaRouter,MediaSession,HardwareMediaKeyHandling,NotificationTriggers,WebNotifications,Notifications,MediaCapture,WebAudio,WebRtcPipeWireCapturer,AudioServiceOutOfProcess,WebMidi,WebUSB,WebBluetooth,WebHid,WebSerial,WebNFC,Geolocation,DeviceOrientationEvents,DeviceMotionEvents,DeviceOrientationEvent,DeviceMotionEvent,AmbientAuthenticationInPrivateModes,WebAuthentication,U2F,IdleDetection,Serial,ContactsAPI,DigitalGoods,GlobalMediaControls,Sharesheet,SystemNotifications,UserMediaCaptureOnFocus,WebOTP,SmsReceiver,BackgroundFetch,BackgroundSync,PaymentRequest,PictureInPicture,ScreenCapture,AccessibilityService,PermissionsAPI,PresentationAPI,FaceTimeCalling,AmbientLight,ScreenAI,AssistiveTouch,WebInstalledAppCheck,ChromeWhatsNewUI,InterestFeedV2,InterestFeedContentSuggestions,NTPCustomization,ChromeRefresh2023,PrivacySandboxSettings4,FedCm,StorageBuckets,AttributionReportingAPI"
        ]

        if headless {
            arguments.append(contentsOf: [
                "--headless=new",
                "--disable-gpu",
                // Override the User-Agent so outbound HTTP requests don't carry
                // the `HeadlessChrome` tag. Many auth-gated sites (Claude.ai,
                // Google sign-in, OpenAI, Cloudflare) inspect the UA and either
                // serve a login wall OR refuse to honor the session cookie when
                // they detect HeadlessChrome — so the scraper would re-load the
                // page in a logged-out state and the captured selector (saved
                // from the logged-in headed Identify session) would no longer
                // match. The CDP /json/version endpoint reports the underlying
                // process UA (still HeadlessChrome) so our own headless-detection
                // logic via cdpVersionInfo is unaffected. Bumped per-release as
                // Chromium versions ship.
                "--user-agent=\(ChromeBrowserProfile.normalChromeUserAgent)"
            ])
        }

        return arguments
    }

    /// User-Agent matching a normal headed Chrome 150 on macOS arm64. Apple
    /// convention is to keep `Intel Mac OS X 10_15_7` in the UA on Apple
    /// Silicon for compatibility with sites that sniff the platform string —
    /// Chromium does the same on its own real-Chrome builds.
    private static let normalChromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/150.0.7836.0 Safari/537.36"

    private func launch(
        browser: ResolvedBrowser,
        configuration: ChromeBrowserLaunchConfiguration,
        foreground: Bool,
        initialURL: URL? = nil
    ) throws {
        // v0.21.48 — `initialURL` (Identify-in-Chrome flow) makes Chromium
        // boot DIRECTLY with the target page as its first/active tab. This
        // is what lets us avoid the "1 about:blank + 1 background openTab"
        // two-tab state that was the source of voice 4277's "extra about:
        // tab + wrong tab activated" bug.
        //
        // Headless launches always use `about:blank` because the scraper
        // opens its target tab via /json/new immediately after launch
        // anyway (the existing flow is correct there — multiple scrapes
        // share the long-running headless Chromium so we don't want the
        // browser-init page to load anything heavyweight).
        let startupURL: String
        if foreground, let initialURL {
            startupURL = initialURL.absoluteString
        } else {
            startupURL = "about:blank"
        }
        var arguments = buildChromeLaunchArguments(configuration: configuration, headless: !foreground)
        if foreground {
            arguments.append(contentsOf: foregroundWindowPlacementArguments())
        }
        arguments.append(startupURL)

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
        process.terminationHandler = { [weak self] proc in
            ActivityLogger.log("browser", "Chrome process terminated", metadata: [
                "profile": profileNameForLog,
                "port": cdpPortString,
                "foreground": foregroundForLog ? "true" : "false",
                "exit": "\(proc.terminationStatus)",
                "reason": "\(proc.terminationReason.rawValue)"
            ])
            self?.clearTerminatedProcessTracking(
                pid: proc.processIdentifier,
                port: configuration.cdpPort,
                foreground: foregroundForLog
            )
        }

        try process.run()

        // Drop a sentinel file inside `--user-data-dir` so any later session (or this one
        // after a UA-masking flag strips "HeadlessChrome" from the default UA) can prove
        // the Chrome bound to this CDP port is ours and therefore safe to close. The
        // sentinel write is best-effort — failure is logged inside the helper and the
        // fall-back UA/PS probes still apply.
        markUserDataDirAsAppSpawned(
            configuration: configuration,
            pid: process.processIdentifier,
            foreground: foreground
        )

        ActivityLogger.log("browser", foreground ? "spawned dedicated Chrome instance" : "launched headless app-owned Chrome", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "executable": executableURL.path,
            "userDataDir": configuration.userDataDirectory.path,
            "pid": "\(process.processIdentifier)",
            "windowPlacement": foreground ? arguments.filter { $0.hasPrefix("--window-") }.joined(separator: " ") : ""
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

    private func clearTerminatedProcessTracking(pid: pid_t, port: Int, foreground: Bool) {
        queue.async { [weak self] in
            guard let self else { return }

            var clearedProcess = false
            if self.backgroundLaunchedProcesses[port]?.processIdentifier == pid {
                self.backgroundLaunchedProcesses.removeValue(forKey: port)
                clearedProcess = true
            }
            if self.foregroundLaunchedProcesses[port]?.processIdentifier == pid {
                self.foregroundLaunchedProcesses.removeValue(forKey: port)
                clearedProcess = true
            }

            var clearedApplication = false
            if self.backgroundLaunchedApplications[port]?.processIdentifier == pid {
                self.backgroundLaunchedApplications.removeValue(forKey: port)
                clearedApplication = true
            }
            if self.foregroundLaunchedApplications[port]?.processIdentifier == pid {
                self.foregroundLaunchedApplications.removeValue(forKey: port)
                clearedApplication = true
            }

            if foreground {
                self.userVisiblePorts.remove(port)
            }

            if clearedProcess || clearedApplication || foreground {
                ActivityLogger.log("browser", "cleared terminated Chrome tracking", metadata: [
                    "port": "\(port)",
                    "pid": "\(pid)",
                    "foreground": foreground ? "true" : "false",
                    "clearedProcess": clearedProcess ? "true" : "false",
                    "clearedApplication": clearedApplication ? "true" : "false"
                ])
            }
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
                // v0.21.22: user-facing product name renamed to
                // "Stats Widget from Website" (voice 4002 / MBP-CC bridge
                // msg-65036391). The MACOS_WIDGETS_STATS_CHROME_PATH env
                // var name stays unchanged — it is a developer override
                // keyed off the internal product slug.
                "Browser executable at \(executableURL.path) is not executable. "
                    + "If you set MACOS_WIDGETS_STATS_CHROME_PATH, fix or unset it. Otherwise reinstall "
                    + "Stats Widget from Website so the bundled Chromium is restored."
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
        // v0.21.5 — replaced synchronous `Data(contentsOf:)` (which has no
        // request timeout and can stall the caller's queue indefinitely if
        // the CDP socket is half-open) with a bounded synchronous
        // URLSession fetch. 5s request / 10s resource. The outer 8s wait
        // for "previous Chrome still alive" in `startPendingLaunchWhenReady`
        // gave the impression of a timeout, but a stuck `Data(contentsOf:)`
        // call held the `queue.sync` lock past that deadline.
        //
        // v0.21.74 — tightened the probe budget from 5s/10s to 3s/5s. This is
        // a localhost loopback CDP probe (127.0.0.1:<cdpPort>/json/version):
        // a healthy Chromium answers in single-digit milliseconds, so a
        // multi-second wait only ever happens when the socket is wedged. The
        // old 10s resource ceiling meant a wedged socket cost ~11s
        // (semaphore.wait(timeoutForResource + 1)) per probe; for a background
        // scrape cadence that's pure dead time. 5s still leaves generous slack
        // over the realistic loopback latency while halving the worst-case
        // stall. Paired with the v0.21.74 main-thread-hop fix, this stall is
        // now also OFF the main thread — but a snappier budget still tightens
        // the scrape cadence and shortens the window before we fall through to
        // a fresh spawn.
        guard let url = URL(string: "/json/version", relativeTo: configuration.cdpURL)?.absoluteURL else {
            return nil
        }

        guard let data = synchronousProbe(url: url, timeoutForRequest: 3, timeoutForResource: 5),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        return json
    }

    /// Bounded synchronous HTTP GET used by CDP-reachability probes. Returns
    /// `nil` on any failure (timeout, network error, non-2xx). The semaphore
    /// wait is hard-capped at `timeoutForResource + 1` so a hung URLSession
    /// callback cannot deadlock the caller; explicit URLSession timeouts
    /// keep the underlying fetch from outliving the resource deadline.
    private static func synchronousProbe(
        url: URL,
        timeoutForRequest: TimeInterval,
        timeoutForResource: TimeInterval
    ) -> Data? {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutForRequest
        config.timeoutIntervalForResource = timeoutForResource
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        var resultData: Data?
        let semaphore = DispatchSemaphore(value: 0)
        let task = session.dataTask(with: url) { data, response, _ in
            defer { semaphore.signal() }
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return
            }
            resultData = data
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeoutForResource + 1)
        if waitResult == .timedOut {
            task.cancel()
            return nil
        }
        return resultData
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
        // v0.21.5 — explicit per-request timeout so a stuck `/json/new`
        // cannot wedge `targetCreationPortsInFlight` and back up every
        // subsequent serialized scrape behind it. URLRequest's default is
        // 60s, far too long given the outer 30s scraper timeout.
        request.timeoutInterval = 10

        // v0.21.8 item #3: per-request observability around `/json/new`. The
        // start log lets us measure how often the PUT→GET fallback fires
        // (some Chromium builds reject PUT). The end log captures elapsedMs +
        // HTTP status so we can spot a Chromium that's wedged at /json/new
        // (the failure mode that backed up `targetCreationPortsInFlight` in
        // the v0.21.5 incident).
        let startedAt = Date()
        ActivityLogger.log("browser", "createTargetRequest started", metadata: [
            "profile": configuration.profileName,
            "port": "\(configuration.cdpPort)",
            "method": method,
            "url": targetURL.absoluteString
        ])

        let fallbackMethod: String? = (method == "PUT") ? "GET" : nil
        let attemptSession = ChromeBrowserProfile.cdpRequestSession
        let primaryTask = attemptSession.dataTask(with: request) { [weak self] data, response, error in
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if let error {
                ActivityLogger.log("browser", "createTargetRequest ended", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "method": method,
                    "elapsedMs": "\(elapsedMs)",
                    "result": fallbackMethod != nil ? "errorWithFallback" : "errorNoFallback",
                    "error": error.localizedDescription
                ])
                // v0.21.5 — restore the PUT→GET fallback that was dropped
                // in c2aa024. Some Chromium builds reject the PUT verb on
                // `/json/new` with an error; the legacy GET form still
                // works as the escape hatch.
                if let fallbackMethod, let self {
                    self.createTargetRequest(
                        url: targetURL,
                        configuration: configuration,
                        method: fallbackMethod,
                        completion: completion
                    )
                    return
                }
                completion(.failure(error))
                return
            }

            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                ActivityLogger.log("browser", "createTargetRequest ended", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "method": method,
                    "elapsedMs": "\(elapsedMs)",
                    "status": "\(httpResponse.statusCode)",
                    "result": fallbackMethod != nil ? "httpErrorWithFallback" : "httpErrorNoFallback"
                ])
                if let fallbackMethod, let self {
                    self.createTargetRequest(
                        url: targetURL,
                        configuration: configuration,
                        method: fallbackMethod,
                        completion: completion
                    )
                    return
                }
                completion(.failure(ChromeBrowserProfileError.targetCreationFailed("CDP /json/new returned HTTP \(httpResponse.statusCode).")))
                return
            }

            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = json["id"] as? String,
                  let webSocketString = json["webSocketDebuggerUrl"] as? String,
                  let webSocketURL = URL(string: webSocketString) else {
                ActivityLogger.log("browser", "createTargetRequest ended", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "method": method,
                    "elapsedMs": "\(elapsedMs)",
                    "status": "\((response as? HTTPURLResponse)?.statusCode ?? 0)",
                    "result": "invalidResponse"
                ])
                completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
                return
            }

            ActivityLogger.log("browser", "createTargetRequest ended", metadata: [
                "profile": configuration.profileName,
                "port": "\(configuration.cdpPort)",
                "method": method,
                "elapsedMs": "\(elapsedMs)",
                "status": "\((response as? HTTPURLResponse)?.statusCode ?? 200)",
                "result": "success",
                "target": id
            ])
            completion(.success(ChromeBrowserTarget(id: id, webSocketDebuggerURL: webSocketURL)))
        }
        primaryTask.resume()
    }

    /// Shared URLSession used for short-lived CDP REST probes (`/json/new`,
    /// `/json/list`, `/json/close`). Explicit timeouts mirror the bounded
    /// `cdpVersionInfo` semaphore probe so a stuck CDP socket cannot
    /// outlive the outer 30s scraper timeout.
    private static let cdpRequestSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// Public-to-the-target wrapper for the same logic. Used by the
    /// tab-count diagnostic logging in ChromeCDPScraper + the orphan-tab
    /// sweep added in v0.21.6 (Ethan voice 3775 — "so many tabs open in
    /// this Chromium"). Keeps the original private implementation
    /// untouched so existing callers continue to compile.
    func listPageTargetsPublic(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<[ChromeBrowserPageTarget], Error>) -> Void
    ) {
        listPageTargets(configuration: configuration, completion: completion)
    }

    /// Diagnostic: best-effort tab count for the given CDP port. Falls
    /// through to the completion with nil on any error so the scrape
    /// pipeline never blocks on the count probe.
    func pageTargetCount(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Int?) -> Void
    ) {
        listPageTargets(configuration: configuration) { result in
            switch result {
            case .success(let targets):
                completion(targets.count)
            case .failure:
                completion(nil)
            }
        }
    }

    /// v0.21.81 battery-drain fix. Returns the first idle, reusable about:blank
    /// page target (or nil if none). Preserved-tab (Cloudflare-sensitive)
    /// scrapes park their tab at about:blank after each run so the heavy SPA
    /// stops running (see `ChromeCDPScraper` battery doc block). The NEXT scrape
    /// calls this to reuse that parked tab — navigating it back to the URL —
    /// instead of opening a brand-new tab every run, which keeps the tab count
    /// bounded (≤ ~1-2). Only genuine blank/new-tab pages qualify; a tab already
    /// sitting on a real http(s) URL (a concurrent scrape's live tab, or a
    /// user/login tab) is never returned, so we can't steal an in-flight scrape's
    /// page. Best-effort: a `/json/list` failure yields nil so the caller falls
    /// back to opening a fresh tab.
    // Returns a `ChromeBrowserTarget` (not the internal `ChromeBrowserPageTarget`)
    // so the conversion via `asTarget` — which is fileprivate to this file —
    // happens here; the scraper only ever needs the id + websocket URL.
    func firstReusableBlankPageTarget(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (ChromeBrowserTarget?) -> Void
    ) {
        listPageTargets(configuration: configuration) { result in
            switch result {
            case .success(let targets):
                let blank = targets.first { target in
                    ChromeBrowserProfile.isReusableBlankTabURL(target.url?.absoluteString ?? "")
                }
                completion(blank?.asTarget)
            case .failure:
                completion(nil)
            }
        }
    }

    /// True for tabs that are safe to REUSE as a scrape tab by navigating them
    /// to a URL — genuinely blank pages only (empty, about:blank, the Chromium
    /// new-tab placeholder). Deliberately narrower than `isOrphanCandidate`,
    /// which also treats chrome-extension:// and devtools:// as disposable — we
    /// must not hijack those as scrape tabs.
    private static func isReusableBlankTabURL(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        return lowered.isEmpty
            || lowered == "about:blank"
            || lowered.hasPrefix("chrome://newtab")
    }

    /// Closes any "orphan" page targets — about:blank / DevTools / new-tab
    /// pages that aren't currently being used by a scrape OR by an
    /// in-flight Identify flow. The `keepURLs` set is supplied by the
    /// caller (typically: the set of tracker URLs that may want to be
    /// reused for Identify, plus the URL of any tab that's currently being
    /// scraped). When `maxKeep` is positive, the N most-recently-listed
    /// targets matching `keepURLs` are also kept and everything else is
    /// closed — this is the conservative path for the agent startup sweep
    /// where we don't want to nuke a tab the user just logged into.
    ///
    /// `keepTargetIDs` is a HARD pin: any target whose Chromium target ID
    /// matches an entry here is unconditionally kept, even if the `maxKeep`
    /// cap would otherwise demote it to disposable. v0.21.12 flake fix
    /// (2026-05-24, Ethan voice 3981) — when two scrapes ran in parallel,
    /// the first one to finish would post-teardown trigger a sweep with
    /// `keepURLs: []`, and the still-running parallel scrape's tab was
    /// "oldest" → got nuked → its CDP websocket disconnected → 30s timeout
    /// → widget went stale. Callers MUST now pass the IDs of every
    /// in-flight scrape's target via `keepTargetIDs` so the sweep can never
    /// race-kill a concurrent scrape's page.
    ///
    /// Logged at info level so the activity log can attribute tab churn.
    func closeOrphanPageTargets(
        configuration: ChromeBrowserLaunchConfiguration,
        keepURLs: Set<String> = [],
        keepTargetIDs: Set<String> = [],
        maxKeep: Int = 8,
        completion: ((Int) -> Void)? = nil
    ) {
        listPageTargets(configuration: configuration) { [weak self] result in
            switch result {
            case .success(let targets):
                guard let self else {
                    completion?(0)
                    return
                }

                // Bucket: keepable (matches a known tracker URL) vs disposable
                // (about:blank, chrome://newtab/, mismatched).
                let normalizedKeeps = Set(keepURLs.map(ChromeBrowserProfile.normalizedTabKey))
                var keepers: [ChromeBrowserPageTarget] = []
                var pinnedKeepers: [ChromeBrowserPageTarget] = []
                var disposables: [ChromeBrowserPageTarget] = []
                for target in targets {
                    // HARD PIN: if this target is currently owned by an
                    // in-flight scrape (its CDP target ID is in keepTargetIDs),
                    // it CANNOT be swept regardless of URL or maxKeep cap.
                    // This is the critical fix for the parallel-scrape race
                    // described in the doc comment above.
                    if keepTargetIDs.contains(target.id) {
                        pinnedKeepers.append(target)
                        continue
                    }
                    let urlString = target.url?.absoluteString ?? ""
                    let normalized = ChromeBrowserProfile.normalizedTabKey(urlString)
                    if ChromeBrowserProfile.isOrphanCandidate(urlString) {
                        disposables.append(target)
                    } else if normalizedKeeps.contains(normalized) {
                        keepers.append(target)
                    } else {
                        // Unknown URL but not a blank/newtab — keep it so
                        // user-opened tabs (signin pages, OAuth bounces,
                        // dashboards) aren't silently destroyed.
                        keepers.append(target)
                    }
                }

                // Cap keepers at maxKeep (oldest-first removal). Anything
                // beyond the cap becomes disposable. NOTE: pinned keepers
                // (in-flight scrape targets) are NOT included in the cap —
                // they're always kept. So if maxKeep=8 and we have 3 pinned
                // + 12 ordinary keepers, we keep 3 pinned + the most-recent
                // 8 ordinary = 11 total kept, 4 closed. This guarantees
                // sweeping never kills a live scrape no matter how busy the
                // browser gets.
                if maxKeep > 0 && keepers.count > maxKeep {
                    let excess = keepers.count - maxKeep
                    let extra = Array(keepers.prefix(excess))
                    disposables.append(contentsOf: extra)
                }
                // Fold pinned keepers back into the keeper count for logging
                // purposes (they're already excluded from `disposables`).
                keepers.append(contentsOf: pinnedKeepers)

                if disposables.isEmpty {
                    ActivityLogger.log("browser", "orphan tab sweep — nothing to close", metadata: [
                        "profile": configuration.profileName,
                        "port": "\(configuration.cdpPort)",
                        "tabCount": "\(targets.count)"
                    ])
                    completion?(0)
                    return
                }

                for target in disposables {
                    self.closeTarget(id: target.id, configuration: configuration)
                }

                ActivityLogger.log("browser", "orphan tab sweep — closed disposable targets", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "before": "\(targets.count)",
                    "closed": "\(disposables.count)",
                    "kept": "\(targets.count - disposables.count)"
                ])
                completion?(disposables.count)

            case .failure(let error):
                ActivityLogger.log("browser", "orphan tab sweep — list failed", metadata: [
                    "profile": configuration.profileName,
                    "port": "\(configuration.cdpPort)",
                    "error": error.localizedDescription
                ])
                completion?(0)
            }
        }
    }

    /// Normalizes a URL string for tab-keep comparison: lowercased,
    /// trailing slash stripped, fragment + query removed. Best-effort —
    /// callers use this to coalesce "https://chat.openai.com/" and
    /// "https://chat.openai.com/?conversation_id=foo" into the same
    /// keepable bucket so a fresh login redirect doesn't get nuked.
    private static func normalizedTabKey(_ urlString: String) -> String {
        var trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hashRange = trimmed.range(of: "#") {
            trimmed.removeSubrange(hashRange.lowerBound..<trimmed.endIndex)
        }
        if let queryRange = trimmed.range(of: "?") {
            trimmed.removeSubrange(queryRange.lowerBound..<trimmed.endIndex)
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Returns true for tabs that are safe to nuke unconditionally during
    /// a sweep — blank pages, the Chromium new-tab placeholder, and the
    /// devtools/about scheme variants.
    private static func isOrphanCandidate(_ urlString: String) -> Bool {
        let lowered = urlString.lowercased()
        if lowered.isEmpty { return true }
        if lowered == "about:blank" { return true }
        if lowered.hasPrefix("chrome://newtab") { return true }
        if lowered.hasPrefix("chrome-extension://") { return true }
        if lowered.hasPrefix("devtools://") { return true }
        return false
    }

    private func listPageTargets(
        configuration: ChromeBrowserLaunchConfiguration,
        completion: @escaping (Result<[ChromeBrowserPageTarget], Error>) -> Void
    ) {
        guard let url = URL(string: "/json/list", relativeTo: configuration.cdpURL)?.absoluteURL else {
            completion(.failure(ChromeBrowserProfileError.invalidCDPResponse))
            return
        }

        ChromeBrowserProfile.cdpRequestSession.dataTask(with: url) { data, response, error in
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

    static func strictMatchScore(for target: ChromeBrowserPageTarget, requestedURL: URL) -> Int? {
        guard let targetURL = target.url,
              isUsableExistingPageURL(targetURL) else {
            return nil
        }

        if equivalentPageURL(targetURL, requestedURL) {
            return 1_000
        }

        guard let requestedHost = requestedURL.host?.lowercased(),
              targetURL.host?.lowercased() == requestedHost else {
            return nil
        }

        let requestedPath = normalizedPath(requestedURL)
        let targetPath = normalizedPath(targetURL)
        guard targetPath == requestedPath else {
            return nil
        }

        if requestedURL.query?.isEmpty == false,
           targetURL.query != requestedURL.query {
            return nil
        }

        // Same host/path, and the requested URL did not require a specific
        // query. This covers redirects that append benign campaign/session
        // parameters while still rejecting a stale tab when the requested
        // URL itself carried a meaningful query.
        return 750
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
        //
        // v0.21.22 (voice 4002 / MBP-CC bridge msg-65036391): the .app
        // wrapper was renamed from "MacosWidgetsStatsFromWebsite.app" to
        // "Stats Widget from Website.app". During the migration window we
        // resolve EITHER wrapper name — fresh installs use the new name,
        // Sparkle in-place updates from v0.21.21 preserve the legacy name
        // (Sparkle replaces the bundle CONTENTS but doesn't rename the
        // outer directory). Candidates are checked in order; the FIRST one
        // that exists wins, so the renamed wrapper is preferred when both
        // are present. Order matters — Sparkle update writes a new bundle
        // to the legacy directory, but the user is encouraged to switch
        // to the new wrapper, so the new name is canonical going forward.
        let mainAppCandidates = [
            "Stats Widget from Website.app",   // v0.21.22+ canonical
            "MacosWidgetsStatsFromWebsite.app" // legacy, retained during migration
        ]
        let mainAppRoots: [URL] = [
            URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
        for root in mainAppRoots {
            for candidate in mainAppCandidates {
                let appURL = root.appendingPathComponent(candidate, isDirectory: true)
                let resourcesURL = appURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
                if fileManager.fileExists(atPath: resourcesURL.path) {
                    roots.append(resourcesURL)
                }
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
