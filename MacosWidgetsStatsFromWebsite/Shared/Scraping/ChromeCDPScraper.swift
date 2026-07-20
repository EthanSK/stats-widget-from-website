//
//  ChromeCDPScraper.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Chrome/Chromium CDP scraper backed by the app's persistent browser profile.
//

import CoreGraphics
import Foundation

final class ChromeCDPScraper {
    typealias Completion = (Result<TrackerReading, Error>) -> Void

    private static var activeScrapers: [UUID: ChromeCDPScraper] = [:]

    /// v0.21.8 observability: read-only count of in-flight scrapers so other
    /// subsystems (browser teardown) can log whether they collided with one.
    /// Stays main-thread because `activeScrapers` mutation goes through
    /// `DispatchQueue.main.async` in `scrape(tracker:completion:)` and
    /// `finish(_:)`. Worst case the count is briefly stale by ~1; that's
    /// acceptable for diagnostic logging.
    static var currentActiveScrapeCount: Int {
        activeScrapers.count
    }

    static func activeScrapeCount(profileName: String) -> Int {
        activeScrapers.values.lazy.filter { $0.tracker.browserProfile == profileName }.count
    }

    /// v0.21.12 race fix: returns the Chromium CDP target IDs currently
    /// owned by in-flight scrapers (excluding the scraper passed in
    /// `excluding`, which is the post-teardown caller about to sweep —
    /// its own target is already closed). The orphan-tab sweep MUST pin
    /// these so parallel scrapes don't race-kill each other's tabs.
    /// Read on the main queue for the same reason as
    /// `currentActiveScrapeCount`.
    static func activeScrapeTargetIDs(excluding excludeID: UUID? = nil) -> Set<String> {
        var ids = Set<String>()
        for (id, scraper) in activeScrapers {
            if let excludeID, id == excludeID { continue }
            if let targetID = scraper.target?.id {
                ids.insert(targetID)
            }
        }
        return ids
    }

    /// When the post-scrape tab count exceeds this, an orphan sweep fires
    /// automatically (v0.21.6 tab-leak mitigation, Ethan voice 3775).
    /// Healthy steady-state is 1–2 tabs (the headless about:blank
    /// placeholder + whatever's being scraped right now).
    static let tabCountOrphanSweepThreshold = 10

    // MARK: - v0.21.79 periodic forced reload (SPA stale-data fix)
    //
    // THE BUG (Ethan, 2026-06-21): for Cloudflare-sensitive domains
    // (ChatGPT / Claude) we KEEP one reusable scrape tab open between runs
    // (see `Tracker.preservesScrapeTabBetweenRuns`) so Cloudflare challenges
    // settle and sibling trackers can share the same loaded DOM. The downside:
    // single-page apps such as chatgpt.com/codex/cloud/settings/analytics cache
    // their usage numbers in in-memory JS state and DON'T re-fetch on a plain
    // DOM re-read. So the scraper kept reading a STALE pre-reset value — the
    // ChatGPT codex widget showed 43%/44% for hours after the real values had
    // reset to 98%/100%. A genuine fresh navigation (which destroys + rebuilds
    // the page's JS context, forcing the SPA to re-fetch on hydration) fixes it.
    //
    // THE FIX (Ethan's exact ask: "just make it reload… the reload doesn't have
    // to happen always maybe just every hour or two"): we do NOT force a fresh
    // navigation on every scrape — normal scrapes stay cheap DOM reads against
    // the warm tab. Instead, the FIRST time we reuse a given page's tab AND it's
    // been longer than `forcedReloadInterval` since that page was last freshly
    // navigated, we issue a real `Page.navigate` BEFORE polling the selector.
    // Otherwise we read the current DOM exactly as before.
    //
    // "Every hour or two" → 90 minutes is the chosen default. Make it a single
    // named constant so it's trivial to retune.
    static let forcedReloadInterval: TimeInterval = 90 * 60  // 90 minutes

    // Per-page "last forced navigation" watermark, keyed by browser profile
    // AND URL. Different signed-in accounts can visit the same URL, but a
    // navigation in one profile says nothing about freshness in another.
    //
    // Keyed by URL (not tracker id) on purpose: multiple trackers can point at
    // the SAME page (primary + sibling trackers sharing one warm tab), and a
    // forced reload by any one of them refreshes the shared DOM for all — so the
    // 90-min cadence should be per-PAGE, independent of each tracker's own
    // refreshIntervalSec. This lives as a `static` so it survives across the
    // short-lived per-scrape `ChromeCDPScraper` instances; the host app process
    // is long-running, so the in-memory watermark persists for the lifetime that
    // matters (a process restart simply forces one reload on first reuse, which
    // is harmless / desirable). Mutated only on the main queue (same discipline
    // as `activeScrapers`), so no extra locking is needed.
    private static var lastForcedNavigationByProfileAndURL: [String: Date] = [:]

    /// Whether the page at `url` is due for a periodic forced reload — i.e. it
    /// has never been force-navigated this process, or it was last navigated
    /// more than `forcedReloadInterval` ago. Read/written on the main queue.
    private static func isForcedReloadDue(forURL url: String, profileName: String) -> Bool {
        guard let last = lastForcedNavigationByProfileAndURL[navigationKey(url: url, profileName: profileName)] else {
            return true
        }
        return Date().timeIntervalSince(last) >= forcedReloadInterval
    }

    /// Stamp `url` as freshly navigated "now" so the next reuse within
    /// `forcedReloadInterval` skips the forced reload. Main queue only.
    private static func markForcedNavigation(forURL url: String, profileName: String) {
        lastForcedNavigationByProfileAndURL[navigationKey(url: url, profileName: profileName)] = Date()
    }

    private static func navigationKey(url: String, profileName: String) -> String {
        "\(profileName)\u{0}\(url)"
    }

    // MARK: - v0.21.81 battery-drain fix (park scrape tabs at about:blank)
    //
    // THE BUG (Ethan, 2026-07-11 — live logs + `ps`): Cloudflare-sensitive
    // trackers (claude.ai/usage, chatgpt.com analytics) KEEP their scrape tab
    // open between runs (`Tracker.preservesScrapeTabBetweenRuns`) so challenges
    // settle and sibling trackers share the loaded DOM. The old teardown then
    // "left reused scrape target open" with the FULL heavy React SPA still
    // loaded. Those SPAs never go quiet in the background — they keep polling,
    // animating, and firing timers — so a Chromium renderer sat pegged at
    // 55-78% CPU 24/7. Worse, the reuse-by-URL match plus the "leave open" path
    // let stale/duplicate scrape tabs ACCUMULATE (~10 tabs observed), each a
    // heavy page, compounding the drain. Net effect: constant battery burn even
    // though scraping only happens every ~30 min.
    //
    // THE FIX: scraping every 30 min is fine — the problem is heavy pages left
    // RUNNING in between. So after each preserved-tab scrape completes we
    // navigate that tab to `about:blank` (see `parkTabAtBlank` in `finish()`),
    // which tears down the SPA's JS context (timers / polling / rAF all stop) so
    // the idle tab costs ~0 CPU. We still keep ONE reusable tab alive per page
    // (preserving cookies / profile / the persistent-browser optimisation): the
    // NEXT scrape reuses the parked blank tab (`firstReusableBlankPageTarget`)
    // and navigates it back to the tracker URL at scrape start
    // (`needsInitialNavigation`). Blank tab in → URL → scrape → blank tab out.
    // This also bounds the tab count (≤ ~1-2 idle blank tabs) instead of leaking
    // a fresh heavy tab every run. Tradeoff vs. the old keep-warm strategy: each
    // scrape now re-navigates rather than re-reading a warm DOM, so Cloudflare is
    // hit slightly more often — but cookies persist (fast clearance), the 60s
    // per-domain timeout gives challenge headroom, and any mid-challenge miss is
    // already downgraded to a transient failure (`finishSelectorFailure`) that
    // keeps the last good value. As a bonus, re-navigating every run also makes
    // the SPA re-fetch fresh numbers, so the v0.21.79 staleness bug can't recur.

    private let scrapeID = UUID()
    private let tracker: Tracker
    private let completion: Completion
    private var configuration: ChromeBrowserLaunchConfiguration?
    private var backgroundUseConfiguration: ChromeBrowserLaunchConfiguration?
    private var target: ChromeBrowserTarget?
    private var shouldCloseTargetOnFinish = false
    // v0.21.81 battery-drain fix: true when this scrape REUSED a parked
    // about:blank tab (see the battery doc block below + `finish()`'s
    // park-at-blank teardown). A blank tab has no page loaded, so before we
    // can poll the selector we MUST navigate it to the tracker URL —
    // unconditionally, independent of the 90-min periodic-forced-reload
    // cadence. Consumed in `maybeForceReloadThenPollSelector`.
    private var needsInitialNavigation = false
    private var client: ChromeCDPClient?
    private var timeout: DispatchWorkItem?
    private var didComplete = false
    private var didRetryAfterBrowserDisconnect = false

    // v0.21.8 phase-level instrumentation (observability-only, no behavior change).
    // Tracks where the scraper is in its pipeline so the 30s timeout-trip
    // log can dump phase + elapsed-in-phase + lastCDPMethod + lastSelectorStatus.
    // See ActivityLogger calls in start(), handleBrowserLaunch(), handleTarget(),
    // handleSelectorPoll(), and armTimeout()'s expiration block.
    private let scrapeStartedAt: Date = Date()
    private var phaseStartedAt: Date = Date()
    private var currentPhase: String = "init"
    private var lastCDPMethod: String?
    private var lastSelectorStatus: [String: Any]?
    private var selectorPollAttempts: Int = 0
    /// Cadence for selector-poll logs: emit the FIRST poll, the FINAL poll, plus
    /// every Nth in between. Avoids spamming the activity log during normal
    /// 2-3-poll scrapes while still giving signal on slow ones (10–60 polls).
    private static let selectorPollLogEveryN: Int = 8

    static func scrape(tracker: Tracker, completion: @escaping Completion) {
        let scraper = ChromeCDPScraper(tracker: tracker, completion: completion)

        // v0.21.14 — stagger scrape kickoffs on the same profile by at
        // least `ChromeBrowserProfile.minScrapeStartGap` seconds (15s).
        // `reserveScrapeStart` atomically advances the per-profile
        // watermark BEFORE returning the delay, so concurrent callers
        // race-correctly serialize (see ChromeBrowserProfile.reserveScrapeStart
        // docstring for race-correctness rationale).
        //
        // Fixes the multi-tracker CDP parallel-scrape flake (Ethan voice
        // 3988): the MBP-side activity.log was showing intermittent
        // `CDP websocket disconnected` + `scrape failed` storms whenever
        // two trackers' NSBackgroundActivityScheduler windows fired
        // within a second of each other. Layered ON TOP OF v0.21.12's
        // `pinnedActiveScrapeTargets` orphan-sweep pin, which handles
        // the residual case where two starts still happen to overlap
        // (e.g. one already in flight when the next is forced via
        // Scrape Now).
        let delay = ChromeBrowserProfile.shared.reserveScrapeStart(profileName: tracker.browserProfile)

        let kickoff = {
            activeScrapers[scraper.scrapeID] = scraper
            scraper.start()
        }

        // v0.21.48 — defer the kickoff if an Identify-in-Chrome flow is
        // currently driving the foreground Chromium for this profile's
        // CDP port. Voice 4277 root cause: background scrapers fired
        // their NSBackgroundActivityScheduler windows DURING an Identify
        // session, each called `ensureLaunched(foreground: false)`, hit
        // the `joined in-flight Chrome launch` path inside the same
        // pending-launch slot the foreground identify was using, and
        // ALL of those scrape completions ran `openTab(...)` the moment
        // the visible Chromium booted — opening 3-4 extra tracker tabs
        // in the user's window between the about:blank placeholder
        // (now removed) and the Identify-target tab.
        //
        // `whenIdentifyClear` runs `body` immediately if the port is
        // free, otherwise enqueues it. Combined with the v0.21.48
        // `ensureLaunched(foreground: true)` rewrite that ALWAYS tears
        // down + spawns fresh for foreground requests, this gives a
        // single-tab Chromium window during Identify. Pending scrapes
        // drain naturally when Identify finishes.
        let port = ChromeBrowserProfile.shared.configuration(profileName: tracker.browserProfile).cdpPort
        let dispatchKickoff = {
            ChromeBrowserProfile.shared.whenIdentifyClear(port: port, kickoff)
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dispatchKickoff)
        } else {
            DispatchQueue.main.async(execute: dispatchKickoff)
        }
    }

    /// One-shot scrape used by the in-app preview UX in TrackerEditorView.
    ///
    /// Unlike the regular scheduler-driven `scrape(tracker:completion:)`, this
    /// forces text-mode extraction regardless of the tracker's saved
    /// `renderMode`. The intent is to show the user the live text that their
    /// CSS selector would capture — for snapshot trackers we still surface
    /// the matched element's text content as a sanity check, even though the
    /// production scrape will capture an image clip of the same bounding
    /// rect. Runs through the existing background (headless) Chrome flow so
    /// no visible browser window pops up on every preview click.
    static func previewScrape(tracker: Tracker, completion: @escaping Completion) {
        var textTracker = tracker
        textTracker.renderMode = .text
        scrape(tracker: textTracker, completion: completion)
    }

    private init(tracker: Tracker, completion: @escaping Completion) {
        self.tracker = tracker
        self.completion = completion
    }

    private func start() {
        guard validatedURL(from: tracker.url) != nil else {
            finish(.failure(ScraperError.invalidURL))
            return
        }

        backgroundUseConfiguration = ChromeBrowserProfile.shared.beginBackgroundUse(profileName: tracker.browserProfile)
        // v0.21.8 item #1: emit the full scrape-context at start so any later
        // log entry can be cross-referenced via scrapeID + tracker. Replaces
        // the prior single-line "started scrape" entry. Fields chosen to match
        // the Codex audit recommendations (scrapeID, tracker, url, renderMode,
        // selector hash, timeout, cdpPort).
        ActivityLogger.log("scrape", "started scrape", metadata: [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "trackerName": tracker.name,
            "profile": tracker.browserProfile,
            "url": tracker.url,
            "renderMode": tracker.renderMode.rawValue,
            "selectorHash": Self.shortHash(tracker.selector),
            "selectorLength": "\(tracker.selector.count)",
            // v0.21.29 (Ethan voice 4019): per-domain timeout. ChatGPT
            // trackers get 60s (Cloudflare challenge headroom); everything
            // else stays on 30s. Log the actual value so post-hoc forensics
            // can tell which path a stuck scrape took.
            "timeoutSec": "\(tracker.scrapeTimeoutSec)",
            "cdpPort": "\(ChromeBrowserProfile.shared.configuration(profileName: tracker.browserProfile).cdpPort)"
        ])
        beginPhase("ensureLaunched")
        ChromeBrowserProfile.shared.ensureLaunched(profileName: tracker.browserProfile) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleBrowserLaunch(result)
            }
        }
    }

    private func handleBrowserLaunch(_ result: Result<ChromeBrowserLaunchConfiguration, Error>) {
        // v0.21.8 item #2: emit phase end with elapsedMs so we can tell whether
        // a slow scrape was stuck waiting for Chrome to launch vs. stuck later
        // in selector polling. wasCDPReachable + detectedMode are best-effort
        // post-hoc checks against the now-running browser (probe is bounded;
        // failure is silent so logging never affects scrape behavior).
        let ensureElapsedMs = elapsedMsInPhase()
        switch result {
        case .success(let configuration):
            self.configuration = configuration
            armTimeout()
            ActivityLogger.log("scrape", "ensureLaunched ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "port": "\(configuration.cdpPort)",
                "elapsedMs": "\(ensureElapsedMs)",
                "result": "success"
            ])
            ActivityLogger.log("scrape", "browser ready", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "port": "\(configuration.cdpPort)"
            ])
            // Diagnostic: tab count at scrape start. Paired with the
            // "finished scrape" entry's tabCount metadata so we can spot
            // tab leaks in the activity log (v0.21.6, Ethan voice 3775).
            ChromeBrowserProfile.shared.pageTargetCount(configuration: configuration) { [weak self] count in
                guard let self else { return }
                if let count {
                    ActivityLogger.log("scrape", "tab count at scrape start", metadata: [
                        "tracker": self.tracker.id.uuidString,
                        "port": "\(configuration.cdpPort)",
                        "tabCount": "\(count)"
                    ])
                }
            }
            guard let url = validatedURL(from: tracker.url) else {
                finish(.failure(ScraperError.invalidURL))
                return
            }

            beginPhase("selectTarget")
            selectTarget(for: url, configuration: configuration)
        case .failure(let error):
            ActivityLogger.log("scrape", "ensureLaunched ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "elapsedMs": "\(ensureElapsedMs)",
                "result": "failure",
                "error": error.localizedDescription
            ])
            ActivityLogger.log("scrape", "browser launch failed", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "error": error.localizedDescription
            ])
            finish(.failure(error))
        }
    }

    private func selectTarget(for url: URL, configuration: ChromeBrowserLaunchConfiguration) {
        ChromeBrowserProfile.shared.pageTargetStrictlyMatching(url, configuration: configuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.didComplete else { return }

                switch result {
                case .success(let target):
                    // A tab currently sits on this exact URL (e.g. a sibling
                    // tracker scraped it moments ago and it hasn't been parked
                    // yet). Reuse it as-is — no navigation needed.
                    self.handleTarget(.success(target), shouldCloseOnFinish: false)
                case .failure(let reuseError):
                    // No tab is on this URL. `openNewTab` opens a brand-new tab;
                    // for preserved trackers we first try to REUSE a parked
                    // about:blank tab (v0.21.81 battery fix — see doc block) so
                    // we don't leak a fresh heavy tab on every scrape.
                    let shouldCloseNewTarget = !self.tracker.preservesScrapeTabBetweenRuns
                    let openNewTab = {
                        ActivityLogger.log("scrape", "no reusable scrape target, opening new tab", metadata: [
                            "scrapeID": self.scrapeID.uuidString,
                            "tracker": self.tracker.id.uuidString,
                            "url": url.absoluteString,
                            "willPreserveNewTarget": shouldCloseNewTarget ? "false" : "true",
                            "reason": reuseError.localizedDescription
                        ])
                        ChromeBrowserProfile.shared.openTab(url: url, configuration: configuration) { [weak self] openResult in
                            DispatchQueue.main.async {
                                self?.handleTarget(openResult, shouldCloseOnFinish: shouldCloseNewTarget)
                            }
                        }
                    }

                    guard self.tracker.preservesScrapeTabBetweenRuns else {
                        // Non-preserved trackers never reuse — open + close each run.
                        openNewTab()
                        return
                    }

                    // Preserved tracker: look for an idle parked about:blank tab
                    // to reuse. Found → navigate it to the URL (needsInitialNavigation)
                    // and keep it after finish. None → fall back to a fresh tab.
                    ChromeBrowserProfile.shared.firstReusableBlankPageTarget(configuration: configuration) { [weak self] blank in
                        DispatchQueue.main.async {
                            guard let self, !self.didComplete else { return }
                            if let blank {
                                ActivityLogger.log("scrape", "reusing parked blank scrape tab", metadata: [
                                    "scrapeID": self.scrapeID.uuidString,
                                    "tracker": self.tracker.id.uuidString,
                                    "target": blank.id
                                ])
                                self.handleTarget(
                                    .success(blank),
                                    shouldCloseOnFinish: false,
                                    needsInitialNavigation: true
                                )
                            } else {
                                openNewTab()
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleTarget(
        _ result: Result<ChromeBrowserTarget, Error>,
        shouldCloseOnFinish: Bool,
        // v0.21.81 battery fix: set true only when we reused a parked
        // about:blank tab, so `maybeForceReloadThenPollSelector` navigates it
        // to the URL before polling (a blank tab has nothing to read yet).
        needsInitialNavigation: Bool = false
    ) {
        let targetSelectionElapsedMs = elapsedMsInPhase()
        switch result {
        case .success(let target):
            self.target = target
            self.shouldCloseTargetOnFinish = shouldCloseOnFinish
            self.needsInitialNavigation = needsInitialNavigation
            ActivityLogger.log("scrape", "target selection ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "target": target.id,
                "elapsedMs": "\(targetSelectionElapsedMs)",
                "result": "success",
                "reusedTarget": shouldCloseOnFinish ? "false" : "true"
            ])
            ActivityLogger.log("scrape", shouldCloseOnFinish ? "opened CDP target" : "reused CDP target", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "target": target.id
            ])
            beginPhase("prepareOpenClawStylePage")
            let client = ChromeCDPClient(webSocketURL: target.webSocketDebuggerURL)
            self.client = client
            client.connect()
            client.prepareOpenClawStylePage { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let prepElapsedMs = self.elapsedMsInPhase()
                    ActivityLogger.log("scrape", "prepareOpenClawStylePage ended", metadata: [
                        "scrapeID": self.scrapeID.uuidString,
                        "tracker": self.tracker.id.uuidString,
                        "elapsedMs": "\(prepElapsedMs)"
                    ])
                    // v0.21.79 SPA stale-data fix: decide whether this scrape
                    // needs a periodic FORCED fresh navigation before reading
                    // the selector. See the `forcedReloadInterval` doc block at
                    // the top of this file for the full rationale.
                    self.maybeForceReloadThenPollSelector(shouldCloseOnFinish: shouldCloseOnFinish)
                }
            }
        case .failure(let error):
            if retryOnceAfterBrowserDisconnect(error, context: "openTab") {
                return
            }
            ActivityLogger.log("scrape", "target selection ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "elapsedMs": "\(targetSelectionElapsedMs)",
                "result": "failure",
                "error": error.localizedDescription
            ])
            ActivityLogger.log("scrape", "target open failed", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "error": error.localizedDescription
            ])
            finish(.failure(error))
        }
    }

    /// v0.21.79 SPA stale-data fix — gate the periodic forced reload, then
    /// start the normal selector-poll loop.
    ///
    /// Two cases:
    ///   1. A BRAND-NEW tab was just opened for this scrape
    ///      (`shouldCloseOnFinish == true`). That open already navigated the
    ///      page fresh, so there's nothing stale to fix — we just stamp the
    ///      per-page watermark "now" (so a reuse within the next 90 min won't
    ///      needlessly re-navigate) and go straight to polling.
    ///   2. We REUSED an already-open warm tab (`shouldCloseOnFinish == false`,
    ///      the Cloudflare-sensitive ChatGPT/Claude path). This is the only
    ///      place SPA staleness can bite. If this page hasn't been freshly
    ///      navigated in `forcedReloadInterval` (~90 min), force a real
    ///      `Page.navigate` BEFORE polling so the SPA re-fetches its numbers.
    ///      Otherwise read the warm DOM exactly as before (cheap, no reload).
    ///
    /// Robustness: a forced navigation is best-effort. If `Page.navigate`
    /// fails or times out we LOG it and fall through to polling the current
    /// DOM anyway — a flaky reload must never turn into a failed scrape. The
    /// watermark is stamped optimistically once we DECIDE to navigate (success
    /// or not) so a persistently-failing navigate can't hot-loop a reload on
    /// every single scrape.
    private func maybeForceReloadThenPollSelector(shouldCloseOnFinish: Bool) {
        let urlString = tracker.url

        // Case 0 (v0.21.81 battery fix): we reused a PARKED about:blank tab.
        // The tab has nothing loaded, so we ALWAYS navigate it to the URL before
        // polling, regardless of the periodic-forced-reload cadence. Stamp the
        // per-page watermark so a subsequent within-90-min reuse (if any) skips
        // the periodic reload — this navigation already made the DOM fresh.
        if needsInitialNavigation, let url = validatedURL(from: tracker.url), let client {
            Self.markForcedNavigation(forURL: urlString, profileName: tracker.browserProfile)
            navigateThenPoll(to: url, client: client, logReason: "reused parked blank tab")
            return
        }

        // Case 1: fresh tab — already navigated, just stamp + poll.
        guard !shouldCloseOnFinish else {
            Self.markForcedNavigation(forURL: urlString, profileName: tracker.browserProfile)
            startSelectorPoll()
            return
        }

        // Case 2: reused warm tab still on the URL — only reload if the page is
        // due. (In practice, since the battery fix parks preserved tabs at
        // about:blank after each run, this warm-DOM path now mostly fires for
        // back-to-back sibling trackers whose shared tab hasn't been parked yet.)
        guard Self.isForcedReloadDue(forURL: urlString, profileName: tracker.browserProfile),
              let url = validatedURL(from: tracker.url),
              let client else {
            // Not due (or no client/url) → read the warm DOM as today.
            startSelectorPoll()
            return
        }

        let lastNav = Self.lastForcedNavigationByProfileAndURL[
            Self.navigationKey(url: urlString, profileName: tracker.browserProfile)
        ]
        let minutesSince = lastNav.map { Int(Date().timeIntervalSince($0) / 60) }
        ActivityLogger.log("scrape", "periodic forced reload (SPA stale-data guard)", metadata: [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "trackerName": tracker.name,
            "url": urlString,
            "minutesSinceLastNav": minutesSince.map { "\($0)" } ?? "never",
            "intervalMin": "\(Int(Self.forcedReloadInterval / 60))"
        ])
        // Stamp BEFORE navigating so a failing navigate can't reload-loop.
        Self.markForcedNavigation(forURL: urlString, profileName: tracker.browserProfile)
        navigateThenPoll(to: url, client: client, logReason: "periodic forced reload")
    }

    /// Force a genuine `Page.navigate` to `url`, then start the selector poll.
    /// Shared by both the reused-parked-blank-tab path (v0.21.81) and the
    /// periodic-forced-reload path (v0.21.79). Best-effort: a navigate
    /// failure/timeout is logged and we still poll the current DOM — a flaky
    /// navigation must never turn into a failed scrape.
    private func navigateThenPoll(to url: URL, client: ChromeCDPClient, logReason: String) {
        beginPhase("forcedReload")
        client.navigate(to: url) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, !self.didComplete else { return }
                switch result {
                case .success:
                    ActivityLogger.log("scrape", "forced reload navigated", metadata: [
                        "scrapeID": self.scrapeID.uuidString,
                        "tracker": self.tracker.id.uuidString,
                        "reason": logReason,
                        "elapsedMs": "\(self.elapsedMsInPhase())"
                    ])
                case .failure(let error):
                    // The existing selector-poll deadline absorbs any partial
                    // load; if the element genuinely never appears the normal
                    // transient/selector-miss classification handles it.
                    ActivityLogger.log("scrape", "forced reload failed; reading current DOM", metadata: [
                        "scrapeID": self.scrapeID.uuidString,
                        "tracker": self.tracker.id.uuidString,
                        "reason": logReason,
                        "error": error.localizedDescription
                    ])
                }
                self.startSelectorPoll()
            }
        }
    }

    /// Begin the selector-poll phase + loop. Extracted so both the
    /// reload-then-poll and read-warm-DOM paths share one entry point.
    private func startSelectorPoll() {
        beginPhase("selectorPoll")
        // v0.21.29/v0.21.68: selector-poll deadline tracks the outer scrape
        // timeout. Keep a 5s buffer so the inner deadline hits the diagnosable
        // "selectorPoll deadline" path before the outer DispatchSource timer
        // fires. Cloudflare-sensitive trackers get 55s here (60s outer - 5s).
        // Note: the budget is computed from `scrapeStartedAt`-relative wall
        // clock via the outer timeout, so any time spent in a forced reload
        // above is already counted against the same overall scrape timeout.
        let selectorPollBudget = TimeInterval(tracker.scrapeTimeoutSec - 5)
        waitForSelector(deadline: Date().addingTimeInterval(selectorPollBudget))
    }

    private func waitForSelector(deadline: Date, lastStatus: [String: Any]? = nil) {
        guard let client else {
            finish(.failure(ChromeCDPClientError.disconnected))
            return
        }

        // v0.21.8: stamp last-CDP-method for timeout-dump cross-reference.
        lastCDPMethod = "Runtime.evaluate(validationScript)"
        client.evaluate(SelectorExtractionJS.validationScript(for: tracker.selector)) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSelectorPoll(result, deadline: deadline, lastStatus: lastStatus)
            }
        }
    }

    private func handleSelectorPoll(_ result: Result<Any?, Error>, deadline: Date, lastStatus: [String: Any]?) {
        selectorPollAttempts += 1
        let attempts = selectorPollAttempts
        switch result {
        case .success(let value):
            guard let status = SelectorExtractionJS.dictionary(from: value) else {
                finish(.failure(SelectorExtractionError.invalidEvaluationResult))
                return
            }
            // v0.21.8 item #4: cache the most recent poll status so the
            // timeout-trip log (armTimeout) can dump it as `lastSelectorStatus`.
            lastSelectorStatus = status

            if let scriptError = status["error"] as? String, !scriptError.isEmpty {
                logSelectorPoll(attempts: attempts, status: status, kind: "scriptError")
                finish(.failure(SelectorExtractionError.invalidSelector(scriptError)))
                return
            }

            let count = SelectorExtractionJS.intValue(status["count"]) ?? 0
            if count > 0 {
                // Always log the "matched" poll — this is the final useful one.
                logSelectorPoll(attempts: attempts, status: status, kind: "matched")
                switch tracker.renderMode {
                case .text:
                    scrapeText(from: status)
                case .snapshot:
                    scrapeSnapshot()
                }
                return
            }

            guard Date() < deadline else {
                let finalStatus = lastStatus ?? status
                // Final log before giving up to fallback path.
                logSelectorPoll(attempts: attempts, status: finalStatus, kind: "deadline")
                attemptContentFallback(finalStatus: finalStatus)
                return
            }

            // First poll + every Nth poll thereafter to keep log volume sane.
            if attempts == 1 || attempts % Self.selectorPollLogEveryN == 0 {
                logSelectorPoll(attempts: attempts, status: status, kind: "polling")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForSelector(deadline: deadline, lastStatus: status)
            }
        case .failure(let error):
            if retryOnceAfterBrowserDisconnect(error, context: "selectorPoll") {
                return
            }
            // CDP evaluate failed — log every Nth (errors are rarer and noisier).
            if attempts == 1 || attempts % Self.selectorPollLogEveryN == 0 {
                ActivityLogger.log("scrape", "selector poll", metadata: [
                    "scrapeID": scrapeID.uuidString,
                    "tracker": tracker.id.uuidString,
                    "kind": "evaluateError",
                    "attempts": "\(attempts)",
                    "elapsedMs": "\(elapsedMsInPhase())",
                    "error": error.localizedDescription
                ])
            }
            guard Date() < deadline else {
                finish(.failure(error))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForSelector(deadline: deadline, lastStatus: lastStatus)
            }
        }
    }

    private func retryOnceAfterBrowserDisconnect(_ error: Error, context: String) -> Bool {
        guard !didComplete,
              !didRetryAfterBrowserDisconnect,
              Self.isBrowserDisconnect(error) else {
            return false
        }

        didRetryAfterBrowserDisconnect = true
        ActivityLogger.log("scrape", "browser disconnected; retrying scrape once", metadata: [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "trackerName": tracker.name,
            "context": context,
            "error": error.localizedDescription,
            "elapsedMs": "\(elapsedMsSinceStart())"
        ])

        client?.close()
        if shouldCloseTargetOnFinish, let configuration, let target {
            ChromeBrowserProfile.shared.closeTarget(id: target.id, configuration: configuration)
        }
        if let backgroundUseConfiguration {
            ChromeBrowserProfile.shared.endBackgroundUse(configuration: backgroundUseConfiguration)
        }

        client = nil
        target = nil
        shouldCloseTargetOnFinish = false
        needsInitialNavigation = false
        configuration = nil
        backgroundUseConfiguration = nil
        timeout?.cancel()
        timeout = nil
        selectorPollAttempts = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.didComplete else { return }
            self.start()
        }
        return true
    }

    private static func isBrowserDisconnect(_ error: Error) -> Bool {
        if let cdpError = error as? ChromeCDPClientError {
            if case .disconnected = cdpError {
                return true
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("cdp websocket disconnected")
            || message.contains("socket is not connected")
            || message.contains("connection reset")
            || message.contains("connection was lost")
            || message.contains("could not connect to the server")
    }

    /// v0.21.8 item #4: emit a single structured poll entry. Called for the
    /// first poll, every Nth subsequent poll, the final "deadline" poll, and
    /// the matched/scriptError terminal cases.
    private func logSelectorPoll(attempts: Int, status: [String: Any], kind: String) {
        var meta: [String: String] = [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "kind": kind,
            "attempts": "\(attempts)",
            "elapsedMs": "\(elapsedMsInPhase())"
        ]
        if let count = SelectorExtractionJS.intValue(status["count"]) {
            meta["count"] = "\(count)"
        }
        if let readyState = status["readyState"] as? String {
            meta["readyState"] = readyState
        } else if let readyState = status["documentReadyState"] as? String {
            meta["readyState"] = readyState
        }
        if let url = status["url"] as? String, !url.isEmpty {
            meta["url"] = url
        }
        if let title = status["title"] as? String, !title.isEmpty {
            meta["title"] = title
        }
        if let loginLikely = SelectorExtractionJS.boolValue(status["loginLikely"]) {
            meta["loginLikely"] = loginLikely ? "true" : "false"
        }
        if let challengeLikely = SelectorExtractionJS.boolValue(status["challengeLikely"]) {
            meta["challengeLikely"] = challengeLikely ? "true" : "false"
        }
        // v0.21.73: surface body length so the activity log shows WHY a
        // selector miss was downgraded to transient (blank / not-real page).
        if let bodyTextLength = SelectorExtractionJS.intValue(status["bodyTextLength"]) {
            meta["bodyTextLength"] = "\(bodyTextLength)"
        }
        ActivityLogger.log("scrape", "selector poll", metadata: meta)
    }

    private func attemptContentFallback(finalStatus: [String: Any]) {
        guard let client else {
            finishSelectorFailure(finalStatus: finalStatus)
            return
        }

        lastCDPMethod = "Runtime.evaluate(contentFallbackScript)"
        beginPhase("contentFallback")
        client.evaluate(
            SelectorExtractionJS.contentFallbackScript(
                trackerName: tracker.name,
                hint: tracker.contentSelectorHint
            )
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleContentFallback(result, finalStatus: finalStatus)
            }
        }
    }

    private func handleContentFallback(_ result: Result<Any?, Error>, finalStatus: [String: Any]) {
        switch result {
        case .success(let value):
            guard let status = SelectorExtractionJS.dictionary(from: value) else {
                finishSelectorFailure(finalStatus: finalStatus)
                return
            }

            let count = SelectorExtractionJS.intValue(status["count"]) ?? 0
            guard count > 0 else {
                finishSelectorFailure(finalStatus: finalStatus)
                return
            }

            ActivityLogger.log("scrape", "WARN selector content fallback fired", metadata: [
                "tracker": tracker.id.uuidString,
                "trackerName": tracker.name,
                "selector": tracker.selector,
                "hint": tracker.contentSelectorHint ?? "",
                "value": (status["text"] as? String) ?? "",
                "candidateCount": "\(SelectorExtractionJS.intValue(status["candidates"]) ?? count)",
                "matchedTerms": ((status["matchedTerms"] as? [String]) ?? []).joined(separator: ",")
            ])

            switch tracker.renderMode {
            case .text:
                scrapeText(from: status)
            case .snapshot:
                guard let rect = SelectorExtractionJS.rect(from: status["bbox"]) else {
                    finish(.failure(ScraperError.selectedElementHasNoVisibleRect))
                    return
                }
                capture(rect: rect)
            }
        case .failure:
            finishSelectorFailure(finalStatus: finalStatus)
        }
    }

    /// Decide which failure to report when the selector never matched within
    /// the poll deadline. ORDER MATTERS — we want the LEAST-alarming accurate
    /// classification so we don't fire the auto-repair agent on a page that
    /// just hadn't loaded real content yet.
    ///
    /// v0.21.73 (Ethan voice 4417): the auto-repair agent (which re-IDENTIFIES
    /// the scraped element via a Claude Code session) was firing "all the
    /// time" for the WRONG reasons. The element itself doesn't change — the
    /// page was simply lagging / mid-challenge / blank / not-yet-rendered, yet
    /// that raw outcome surfaced as "Selector did not match any element."
    /// which `TrackerFailureKind.classify` maps to `.selectorNotFound`
    /// (countsTowardBroken = true → increments the consecutive-failure counter
    /// → eventually trips the auto-repair hook). The element was never gone;
    /// re-identifying it is pointless churn.
    ///
    /// The fix is to refuse to call a non-rendered page `selectorDidNotMatch`.
    /// We only emit a GENUINE `.selectorDidNotMatch` when the page actually
    /// finished loading AND has real, non-trivial body content — i.e. the
    /// element really is absent from a fully-rendered real page. Otherwise we
    /// emit `.browserChallengeInProgress`, which is treated as a TRANSIENT
    /// failure (`TrackerFailureKind.browserChallenge`,
    /// `countsTowardBroken == false`): it keeps the last good value, does NOT
    /// increment the consecutive-failure counter, and therefore never trips
    /// the auto-repair agent. The next scrape — once the page is real — either
    /// matches cleanly or, if the element is genuinely gone, accumulates real
    /// `.selectorDidNotMatch` failures that DO eventually trigger repair.
    private func finishSelectorFailure(finalStatus: [String: Any]) {
        if SelectorExtractionJS.boolValue(finalStatus["challengeLikely"]) == true {
            finish(.failure(SelectorExtractionError.browserChallengeInProgress))
            return
        }
        if SelectorExtractionJS.boolValue(finalStatus["loginLikely"]) == true {
            finish(.failure(SelectorExtractionError.loginRequired))
            return
        }

        // Anti-false-positive guard: was the page actually a real, fully
        // rendered page when the selector failed? Two transient signals:
        //   1. readyState != "complete" — the document never finished
        //      loading within our poll window (slow network / SPA still
        //      hydrating / interstitial redirect). The element may well be
        //      there once it finishes; this is lag, not a missing element.
        //   2. body text is essentially empty (< 24 trimmed chars) — a blank
        //      page / SPA shell / silent challenge with no visible cloudflare
        //      marker. Nothing to match yet; not a real "element gone".
        // In either case we DOWNGRADE to the transient browserChallenge kind
        // so the failure does NOT count toward broken and does NOT spawn the
        // re-identify agent. We log the downgrade so the activity log makes
        // the reason explicit (and so a genuinely-broken selector on a real
        // page is still distinguishable in the logs).
        let readyState = (finalStatus["readyState"] as? String) ?? ""
        let bodyTextLength = SelectorExtractionJS.intValue(finalStatus["bodyTextLength"]) ?? 0
        let pageNotReady = !readyState.isEmpty && readyState.lowercased() != "complete"
        let bodyEffectivelyBlank = bodyTextLength < 24

        if pageNotReady || bodyEffectivelyBlank {
            ActivityLogger.log("scrape", "selector miss downgraded to transient (page not real content yet)", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "trackerName": tracker.name,
                "readyState": readyState,
                "bodyTextLength": "\(bodyTextLength)",
                "reason": pageNotReady ? "readyState!=complete" : "bodyEffectivelyBlank"
            ])
            finish(.failure(SelectorExtractionError.browserChallengeInProgress))
            return
        }

        // Page was real + fully loaded + non-blank, and the element still
        // wasn't there ⇒ this is a GENUINE element-not-found. Only this path
        // is eligible (after the 3-consecutive gate in BackgroundScheduler) to
        // trigger the auto-repair re-identify agent.
        finish(.failure(SelectorExtractionError.selectorDidNotMatch))
    }

    private func scrapeText(from status: [String: Any]) {
        let value = (status["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            finish(.failure(ScraperError.selectedElementHasNoText))
            return
        }

        let primaryReading = TrackerReading(
            currentValue: value,
            currentNumeric: tracker.valueParser.parseNumeric(from: value),
            lastUpdatedAt: Date(),
            status: .ok
        )

        // v0.21.9: scrape any secondary elements from the same loaded DOM
        // before completing. Single-element trackers (the default case)
        // skip this entirely and finish exactly as before — no extra
        // latency, no extra logging, no extra CDP traffic.
        guard !tracker.secondaryElements.isEmpty else {
            finish(.success(primaryReading))
            return
        }

        scrapeSecondaryElements(primaryReading: primaryReading)
    }

    /// v0.21.9: extract every secondary element's text from the SAME loaded
    /// page. One CDP `Runtime.evaluate` per element, run sequentially so
    /// the activity log stays readable. Failures on individual elements
    /// are best-effort — they get stored as `lastError` on the per-element
    /// `TrackerSecondaryValue` but never mark the parent reading broken.
    /// The primary already succeeded by the time we get here.
    private func scrapeSecondaryElements(primaryReading: TrackerReading) {
        guard let client else {
            finish(.success(primaryReading))
            return
        }

        beginPhase("secondaryElements")
        ActivityLogger.log("scrape", "scraping secondary elements", metadata: [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "count": "\(tracker.secondaryElements.count)"
        ])

        let elements = tracker.secondaryElements
        var collected: [String: TrackerSecondaryValue] = [:]
        var elementIndex = 0

        func processNext() {
            guard elementIndex < elements.count else {
                var reading = primaryReading
                reading.secondaryValues = collected
                finish(.success(reading))
                return
            }

            let element = elements[elementIndex]
            elementIndex += 1
            lastCDPMethod = "Runtime.evaluate(secondaryElementText)"
            client.evaluate(SelectorExtractionJS.validationScript(for: element.selector)) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let value):
                        guard let status = SelectorExtractionJS.dictionary(from: value) else {
                            collected[element.id.uuidString] = TrackerSecondaryValue(
                                lastError: "Invalid evaluation result"
                            )
                            processNext()
                            return
                        }
                        if let scriptError = status["error"] as? String, !scriptError.isEmpty {
                            collected[element.id.uuidString] = TrackerSecondaryValue(lastError: scriptError)
                            processNext()
                            return
                        }
                        let count = SelectorExtractionJS.intValue(status["count"]) ?? 0
                        guard count > 0 else {
                            collected[element.id.uuidString] = TrackerSecondaryValue(
                                lastError: "Selector did not match"
                            )
                            processNext()
                            return
                        }
                        let text = ((status["text"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else {
                            collected[element.id.uuidString] = TrackerSecondaryValue(
                                lastError: "Element has no text"
                            )
                            processNext()
                            return
                        }
                        collected[element.id.uuidString] = TrackerSecondaryValue(
                            value: text,
                            numeric: element.valueParser.parseNumeric(from: text),
                            lastError: nil
                        )
                        ActivityLogger.log("scrape", "secondary element scraped", metadata: [
                            "scrapeID": self.scrapeID.uuidString,
                            "tracker": self.tracker.id.uuidString,
                            "elementID": element.id.uuidString,
                            "elementName": element.name,
                            "value": text
                        ])
                        processNext()
                    case .failure(let error):
                        collected[element.id.uuidString] = TrackerSecondaryValue(
                            lastError: error.localizedDescription
                        )
                        ActivityLogger.log("scrape", "secondary element failed", metadata: [
                            "scrapeID": self.scrapeID.uuidString,
                            "tracker": self.tracker.id.uuidString,
                            "elementID": element.id.uuidString,
                            "error": error.localizedDescription
                        ])
                        processNext()
                    }
                }
            }
        }

        processNext()
    }

    private func scrapeSnapshot() {
        guard let client else {
            finish(.failure(ChromeCDPClientError.disconnected))
            return
        }

        lastCDPMethod = "Runtime.evaluate(snapshotRect)"
        beginPhase("snapshotRect")
        client.evaluate(chromeSnapshotRectScript(for: tracker.selector, hideElements: tracker.hideElements)) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSnapshotRect(result)
            }
        }
    }

    private func handleSnapshotRect(_ result: Result<Any?, Error>) {
        switch result {
        case .success(let value):
            let resolvedRect = SelectorExtractionJS.rect(from: value)
            let fallbackRect = tracker.elementBoundingBox.map { bbox in
                CGRect(x: bbox.x, y: bbox.y, width: bbox.width, height: bbox.height)
            }
            guard let rect = resolvedRect ?? fallbackRect,
                  rect.width > 0,
                  rect.height > 0 else {
                finish(.failure(ScraperError.selectedElementHasNoVisibleRect))
                return
            }

            capture(rect: rect)
        case .failure(let error):
            finish(.failure(error))
        }
    }

    private func capture(rect: CGRect) {
        guard let client else {
            finish(.failure(ChromeCDPClientError.disconnected))
            return
        }

        let clip: [String: Any] = [
            "x": max(0, rect.origin.x),
            "y": max(0, rect.origin.y),
            "width": max(1, rect.width),
            "height": max(1, rect.height),
            "scale": 1
        ]

        lastCDPMethod = "Page.captureScreenshot"
        beginPhase("captureScreenshot")
        client.captureScreenshot(clip: clip) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSnapshotData(result)
            }
        }
    }

    private func handleSnapshotData(_ result: Result<Data, Error>) {
        switch result {
        case .success(let data):
            do {
                let cacheKey = try SnapshotSharedCache.shared.store(data, for: tracker.id)
                let now = Date()
                let reading = TrackerReading(
                    snapshotCacheKey: cacheKey,
                    snapshotCapturedAt: now,
                    lastUpdatedAt: now,
                    status: .ok
                )
                finish(.success(reading))
            } catch {
                finish(.failure(error))
            }
        case .failure(let error):
            finish(.failure(error))
        }
    }

    private func chromeSnapshotRectScript(for selector: String, hideElements: [String]) -> String {
        """
        (() => {
          for (const selector of \(javaScriptArrayLiteral(hideElements))) {
            try {
              document.querySelectorAll(selector).forEach(element => {
                element.setAttribute('data-stats-widget-hidden', 'true');
                element.style.visibility = 'hidden';
              });
            } catch (_) {}
          }

          const element = document.querySelector(\(javaScriptStringLiteral(selector)));
          if (!element) {
            return null;
          }

          try {
            element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'auto' });
          } catch (_) {
            try { element.scrollIntoView(false); } catch (_) {}
          }

          const rect = element.getBoundingClientRect();
          return {
            x: Math.max(0, rect.left + window.scrollX),
            y: Math.max(0, rect.top + window.scrollY),
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio || 1
          };
        })()
        """
    }

    private func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return literal
    }

    private func javaScriptArrayLiteral(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return literal
    }

    private func armTimeout() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // v0.21.8 item #5 (CRITICAL): when the 30s timeout fires, dump
            // everything we know about where the scraper was stuck so the
            // next stale-tracker incident is diagnosable. Captures: which
            // phase we were in, how long we'd been there, total elapsed,
            // last CDP method we issued, last selector poll status JSON
            // (count/readyState/url/loginLikely), Chrome configuration.
            // This is the single highest-value entry in the v0.21.8
            // instrumentation pass — it's the log entry that should have
            // existed during the 2026-05-22 22:11Z "claude weekly usij"
            // stale incident.
            var meta: [String: String] = [
                "scrapeID": self.scrapeID.uuidString,
                "tracker": self.tracker.id.uuidString,
                "trackerName": self.tracker.name,
                "url": self.tracker.url,
                "currentPhase": self.currentPhase,
                "phaseElapsedMs": "\(self.elapsedMsInPhase())",
                "totalElapsedMs": "\(self.elapsedMsSinceStart())",
                "selectorPollAttempts": "\(self.selectorPollAttempts)",
                "lastCDPMethod": self.lastCDPMethod ?? ""
            ]
            if let configuration = self.configuration {
                meta["cdpPort"] = "\(configuration.cdpPort)"
                meta["profile"] = configuration.profileName
            }
            if let target = self.target {
                meta["target"] = target.id
            }
            if let status = self.lastSelectorStatus {
                if let count = SelectorExtractionJS.intValue(status["count"]) {
                    meta["lastCount"] = "\(count)"
                }
                if let readyState = status["readyState"] as? String {
                    meta["lastReadyState"] = readyState
                }
                if let url = status["url"] as? String, !url.isEmpty {
                    meta["lastDocURL"] = url
                }
                if let loginLikely = SelectorExtractionJS.boolValue(status["loginLikely"]) {
                    meta["lastLoginLikely"] = loginLikely ? "true" : "false"
                }
                if let challengeLikely = SelectorExtractionJS.boolValue(status["challengeLikely"]) {
                    meta["lastChallengeLikely"] = challengeLikely ? "true" : "false"
                }
            }
            ActivityLogger.log("scrape", "timeout fired", metadata: meta)
            self.finish(.failure(ScraperError.navigationFailed("Timed out loading \(self.tracker.url).")))
        }
        timeout = item
        // v0.21.67: arm this only after Chromium/CDP is reachable. Cold
        // Chromium launches after install/restart can take tens of seconds
        // before the DevTools socket is ready; counting that bootstrap time
        // against the page/selector budget recorded false tracker failures
        // even though the browser recovered and later scrapes succeeded.
        //
        // v0.21.29/v0.21.68: per-tracker page/selector timeout.
        // Cloudflare-sensitive trackers get 60s challenge headroom;
        // everything else stays on the original 30s. Computed from the
        // same helper the "started scrape" log uses so the activity log +
        // actual fire time can never disagree.
        let outerTimeoutSec = TimeInterval(tracker.scrapeTimeoutSec)
        DispatchQueue.main.asyncAfter(deadline: .now() + outerTimeoutSec, execute: item)
    }

    // MARK: - v0.21.8 phase + helpers

    /// Record entering a new pipeline phase so the timeout-trip log can
    /// report where we were stuck. Resets `phaseStartedAt` so per-phase
    /// elapsedMs is meaningful even after a long preceding phase.
    private func beginPhase(_ name: String) {
        currentPhase = name
        phaseStartedAt = Date()
    }

    private func elapsedMsInPhase() -> Int {
        Int(Date().timeIntervalSince(phaseStartedAt) * 1000)
    }

    private func elapsedMsSinceStart() -> Int {
        Int(Date().timeIntervalSince(scrapeStartedAt) * 1000)
    }

    /// Stable short hash of a CSS selector, used so logs can correlate scrapes
    /// against the same selector without spilling the full selector text into
    /// every entry. Java's String.hashCode-style algorithm (deterministic across
    /// machines, no Foundation dependency, no crypto needed).
    private static func shortHash(_ value: String) -> String {
        var hash: UInt32 = 5381
        for byte in value.utf8 {
            hash = (hash &* 33) &+ UInt32(byte)
        }
        return String(hash, radix: 16)
    }

    private func finish(_ result: Result<TrackerReading, Error>) {
        guard !didComplete else {
            return
        }

        didComplete = true
        timeout?.cancel()

        // Tab-leak fix (v0.17.x): close the page target BEFORE the rest of the
        // teardown. The previous flow cancelled the websocket via `client.close()`
        // and then fired a fire-and-forget HTTP `/json/close/<id>`; under load
        // the REST call did not always reach Chromium in time, leaving tabs
        // open and the headless Chrome's RAM growing per scrape iteration
        // (Ethan voice 2964 — "loads of tabs open in the manual Chromium").
        //
        // Primary path: send `Page.close` over the existing page websocket
        // (best-effort, 1s timeout). The browser disposes of the target as
        // part of the protocol command, so this is the most reliable single
        // tab close path.
        //
        // Belt-and-suspenders: still call `closeTarget` (REST `/json/close`)
        // afterwards in case the websocket was already gone — it's now logged
        // so we can audit any future leaks via the activity log. The REST
        // call is idempotent against already-closed targets (Chromium returns
        // 404, which we log but don't surface as an error).
        let captured = self
        let teardown: () -> Void = {
            DispatchQueue.main.async {
                captured.client?.close()
                if captured.shouldCloseTargetOnFinish,
                   let configuration = captured.configuration,
                   let target = captured.target {
                    ChromeBrowserProfile.shared.closeTarget(id: target.id, configuration: configuration)
                } else if let target = captured.target {
                    // v0.21.81 battery fix: preserved tab — it has just been
                    // navigated to about:blank (see park-at-blank branch below)
                    // so the heavy SPA is no longer running. The tab stays alive
                    // for the next scrape to reuse (idle CPU ~0 in between).
                    ActivityLogger.log("scrape", "parked reused scrape tab at about:blank (idle CPU ~0)", metadata: [
                        "tracker": captured.tracker.id.uuidString,
                        "target": target.id
                    ])
                }
                // Diagnostic: tab count AFTER our explicit close. Logged
                // before endBackgroundUse so the count reflects the state
                // when the page-close REST request reached Chromium.
                // Best-effort, so we don't block teardown on the probe.
                // If the count exceeds the orphan-sweep threshold (10),
                // fire a sweep automatically so a buggy identify-tab or
                // accidental popup doesn't snowball into the "loads of
                // tabs open" state Ethan reported (voice 3775).
                if let configuration = captured.configuration {
                    ChromeBrowserProfile.shared.pageTargetCount(configuration: configuration) { count in
                        if let count {
                            ActivityLogger.log("scrape", "tab count at scrape end", metadata: [
                                "tracker": captured.tracker.id.uuidString,
                                "port": "\(configuration.cdpPort)",
                                "tabCount": "\(count)"
                            ])
                            if count > ChromeCDPScraper.tabCountOrphanSweepThreshold {
                                // v0.21.12 race fix: harvest the target IDs of
                                // every OTHER in-flight scraper so the sweep
                                // never closes a parallel scrape's live tab.
                                // `captured.scrapeID` is the just-finishing
                                // scraper — its target is already closed via
                                // Page.close above and excluded from the pin
                                // set (else we'd pin a dead ID, harmless but
                                // misleading in logs).
                                var pinnedIDs = ChromeCDPScraper.activeScrapeTargetIDs(
                                    excluding: captured.scrapeID
                                )
                                if !captured.shouldCloseTargetOnFinish,
                                   let targetID = captured.target?.id {
                                    pinnedIDs.insert(targetID)
                                }
                                ActivityLogger.log("scrape", "tab count over threshold, sweeping orphan tabs", metadata: [
                                    "port": "\(configuration.cdpPort)",
                                    "tabCount": "\(count)",
                                    "threshold": "\(ChromeCDPScraper.tabCountOrphanSweepThreshold)",
                                    "pinnedActiveScrapeTargets": "\(pinnedIDs.count)"
                                ])
                                ChromeBrowserProfile.shared.closeOrphanPageTargets(
                                    configuration: configuration,
                                    keepURLs: [],
                                    keepTargetIDs: pinnedIDs,
                                    maxKeep: 8,
                                    completion: nil
                                )
                            }
                        }
                    }
                }
                if let backgroundUseConfiguration = captured.backgroundUseConfiguration {
                    ChromeBrowserProfile.shared.endBackgroundUse(configuration: backgroundUseConfiguration)
                }
                ActivityLogger.log("scrape", captured.logMessage(for: result), metadata: captured.logMetadata(for: result))
                captured.completion(result)
                Self.activeScrapers[captured.scrapeID] = nil
            }
        }

        if shouldCloseTargetOnFinish, let client = client, target != nil {
            client.closePageTarget { closeResult in
                switch closeResult {
                case .success:
                    ActivityLogger.log("scrape", "closed scrape tab via Page.close", metadata: [
                        "tracker": captured.tracker.id.uuidString,
                        "target": captured.target?.id ?? ""
                    ])
                case .failure(let error):
                    ActivityLogger.log("scrape", "Page.close failed; falling back to REST close", metadata: [
                        "tracker": captured.tracker.id.uuidString,
                        "target": captured.target?.id ?? "",
                        "error": error.localizedDescription
                    ])
                }
                teardown()
            }
        } else if let client = client, target != nil {
            // v0.21.81 battery-drain fix: preserved-tab tracker. Instead of
            // leaving the heavy claude.ai / chatgpt.com SPA loaded and burning
            // CPU 24/7, navigate the tab to about:blank so its JS context is
            // torn down (timers / polling / animation all stop) → ~0 CPU while
            // idle. The tab object stays alive for the next scrape to reuse.
            // Must run BEFORE `teardown()` closes the websocket.
            parkTabAtBlank(client: client) {
                teardown()
            }
        } else {
            teardown()
        }
    }

    /// v0.21.81 battery-drain fix. Navigate the (preserved) scrape tab to
    /// about:blank so the heavy SPA stops executing between scrapes. Best-effort
    /// with a short timeout: on failure we log and still tear down — worst case
    /// the tab idles on the old page for one more cycle, no correctness impact.
    /// `about:blank` is a valid `Page.navigate` target and commits instantly, so
    /// closing the websocket right after (in `teardown`) is safe.
    private func parkTabAtBlank(client: ChromeCDPClient, completion: @escaping () -> Void) {
        guard let blank = URL(string: "about:blank") else {
            completion()
            return
        }
        client.navigate(to: blank, timeout: 3) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure(let error) = result {
                    ActivityLogger.log("scrape", "park-at-about:blank failed (tab idles on heavy page one cycle)", metadata: [
                        "tracker": self?.tracker.id.uuidString ?? "",
                        "error": error.localizedDescription
                    ])
                }
                completion()
            }
        }
    }

    private func logMessage(for result: Result<TrackerReading, Error>) -> String {
        switch result {
        case .success:
            return "finished scrape"
        case .failure:
            return "scrape failed"
        }
    }

    private func logMetadata(for result: Result<TrackerReading, Error>) -> [String: String] {
        var metadata: [String: String] = [
            "scrapeID": scrapeID.uuidString,
            "tracker": tracker.id.uuidString,
            "profile": tracker.browserProfile,
            "totalElapsedMs": "\(elapsedMsSinceStart())",
            "selectorPollAttempts": "\(selectorPollAttempts)"
        ]

        switch result {
        case .success(let reading):
            metadata["status"] = reading.status.rawValue
            if let currentValue = reading.currentValue {
                metadata["value"] = currentValue
            }
        case .failure(let error):
            metadata["error"] = error.localizedDescription
        }

        return metadata
    }

    private func validatedURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        return url
    }
}
