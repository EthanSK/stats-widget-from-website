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

    static func scrape(tracker: Tracker, completion: @escaping Completion) {
        let scraper = ChromeCDPScraper(tracker: tracker, completion: completion)
        DispatchQueue.main.async {
            activeScrapers[scraper.scrapeID] = scraper
            scraper.start()
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
        ActivityLogger.log("scrape", "started scrape", metadata: [
            "tracker": tracker.id.uuidString,
            "profile": tracker.browserProfile
        ])
        ChromeBrowserProfile.shared.ensureLaunched(profileName: tracker.browserProfile) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleBrowserLaunch(result)
            }
        }
    }

    private func handleBrowserLaunch(_ result: Result<ChromeBrowserLaunchConfiguration, Error>) {
        switch result {
        case .success(let configuration):
            self.configuration = configuration
            ActivityLogger.log("scrape", "browser ready", metadata: [
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

            ChromeBrowserProfile.shared.openTab(url: url, configuration: configuration) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleTarget(result)
                }
            }
        case .failure(let error):
            ActivityLogger.log("scrape", "browser launch failed", metadata: [
                "tracker": tracker.id.uuidString,
                "error": error.localizedDescription
            ])
            finish(.failure(error))
        }
    }

    private func handleTarget(_ result: Result<ChromeBrowserTarget, Error>) {
        switch result {
        case .success(let target):
            self.target = target
            ActivityLogger.log("scrape", "opened CDP target", metadata: [
                "tracker": tracker.id.uuidString,
                "target": target.id
            ])
            let client = ChromeCDPClient(webSocketURL: target.webSocketDebuggerURL)
            self.client = client
            client.connect()
            client.prepareOpenClawStylePage { [weak self] in
                DispatchQueue.main.async {
                    self?.waitForSelector(deadline: Date().addingTimeInterval(25))
                }
            }
        case .failure(let error):
            ActivityLogger.log("scrape", "target open failed", metadata: [
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

        client.evaluate(SelectorExtractionJS.validationScript(for: tracker.selector)) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSelectorPoll(result, deadline: deadline, lastStatus: lastStatus)
            }
        }
    }

    private func handleSelectorPoll(_ result: Result<Any?, Error>, deadline: Date, lastStatus: [String: Any]?) {
        switch result {
        case .success(let value):
            guard let status = SelectorExtractionJS.dictionary(from: value) else {
                finish(.failure(SelectorExtractionError.invalidEvaluationResult))
                return
            }

            if let scriptError = status["error"] as? String, !scriptError.isEmpty {
                finish(.failure(SelectorExtractionError.invalidSelector(scriptError)))
                return
            }

            let count = SelectorExtractionJS.intValue(status["count"]) ?? 0
            if count > 0 {
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
                attemptContentFallback(finalStatus: finalStatus)
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForSelector(deadline: deadline, lastStatus: status)
            }
        case .failure(let error):
            guard Date() < deadline else {
                finish(.failure(error))
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.waitForSelector(deadline: deadline, lastStatus: lastStatus)
            }
        }
    }

    private func attemptContentFallback(finalStatus: [String: Any]) {
        guard let client else {
            finishSelectorFailure(finalStatus: finalStatus)
            return
        }

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

        let reading = TrackerReading(
            currentValue: value,
            currentNumeric: tracker.valueParser.parseNumeric(from: value),
            lastUpdatedAt: Date(),
            status: .ok
        )
        finish(.success(reading))
    }

    private func scrapeSnapshot() {
        guard let client else {
            finish(.failure(ChromeCDPClientError.disconnected))
            return
        }

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
            self.finish(.failure(ScraperError.navigationFailed("Timed out loading \(self.tracker.url).")))
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: item)
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
                                ActivityLogger.log("scrape", "tab count over threshold, sweeping orphan tabs", metadata: [
                                    "port": "\(configuration.cdpPort)",
                                    "tabCount": "\(count)",
                                    "threshold": "\(ChromeCDPScraper.tabCountOrphanSweepThreshold)"
                                ])
                                ChromeBrowserProfile.shared.closeOrphanPageTargets(
                                    configuration: configuration,
                                    keepURLs: [],
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
            "tracker": tracker.id.uuidString,
            "profile": tracker.browserProfile
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
