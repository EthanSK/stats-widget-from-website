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

    private let scrapeID = UUID()
    private let tracker: Tracker
    private let completion: Completion
    private var configuration: ChromeBrowserLaunchConfiguration?
    private var backgroundUseConfiguration: ChromeBrowserLaunchConfiguration?
    private var target: ChromeBrowserTarget?
    private var client: ChromeCDPClient?
    private var timeout: DispatchWorkItem?
    private var didComplete = false

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

        armTimeout()
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

            beginPhase("openTab")
            ChromeBrowserProfile.shared.openTab(url: url, configuration: configuration) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleTarget(result)
                }
            }
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

    private func handleTarget(_ result: Result<ChromeBrowserTarget, Error>) {
        let openTabElapsedMs = elapsedMsInPhase()
        switch result {
        case .success(let target):
            self.target = target
            ActivityLogger.log("scrape", "openTab ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "target": target.id,
                "elapsedMs": "\(openTabElapsedMs)",
                "result": "success"
            ])
            ActivityLogger.log("scrape", "opened CDP target", metadata: [
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
                    self.beginPhase("selectorPoll")
                    // v0.21.29 (voice 4019): selector-poll deadline tracks
                    // the outer scrape timeout. We keep a 5s buffer so the
                    // inner deadline expires first and we hit the proper
                    // "selectorPoll deadline" fallback path (which dumps
                    // lastSelectorStatus into the activity log) instead of
                    // racing the outer DispatchSource timer. ChatGPT
                    // trackers get 55s here (60s outer - 5s buffer);
                    // Claude trackers stay on 25s (30s outer - 5s buffer).
                    let selectorPollBudget = TimeInterval(self.tracker.scrapeTimeoutSec - 5)
                    self.waitForSelector(deadline: Date().addingTimeInterval(selectorPollBudget))
                }
            }
        case .failure(let error):
            ActivityLogger.log("scrape", "openTab ended", metadata: [
                "scrapeID": scrapeID.uuidString,
                "tracker": tracker.id.uuidString,
                "elapsedMs": "\(openTabElapsedMs)",
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

    private func finishSelectorFailure(finalStatus: [String: Any]) {
        if SelectorExtractionJS.boolValue(finalStatus["loginLikely"]) == true {
            finish(.failure(SelectorExtractionError.loginRequired))
        } else {
            finish(.failure(SelectorExtractionError.selectorDidNotMatch))
        }
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
            }
            ActivityLogger.log("scrape", "timeout fired", metadata: meta)
            self.finish(.failure(ScraperError.navigationFailed("Timed out loading \(self.tracker.url).")))
        }
        timeout = item
        // v0.21.29 (voice 4019): per-tracker outer timeout. ChatGPT-domain
        // trackers get 60s (Cloudflare JS-challenge headroom); everything
        // else stays on the original 30s. Computed from the same helper
        // (Tracker.scrapeTimeoutSec) the "started scrape" log entry uses
        // so the activity log + actual fire time can never disagree.
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
                if let configuration = captured.configuration, let target = captured.target {
                    ChromeBrowserProfile.shared.closeTarget(id: target.id, configuration: configuration)
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
                                let pinnedIDs = ChromeCDPScraper.activeScrapeTargetIDs(
                                    excluding: captured.scrapeID
                                )
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

        if let client = client, target != nil {
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
        } else {
            teardown()
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
