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

    private let scrapeID = UUID()
    private let tracker: Tracker
    private let completion: Completion
    private var configuration: ChromeBrowserLaunchConfiguration?
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
            finish(.failure(error))
        }
    }

    private func handleTarget(_ result: Result<ChromeBrowserTarget, Error>) {
        switch result {
        case .success(let target):
            self.target = target
            let client = ChromeCDPClient(webSocketURL: target.webSocketDebuggerURL)
            self.client = client
            client.connect()
            client.prepareOpenClawStylePage { [weak self] in
                DispatchQueue.main.async {
                    self?.waitForSelector(deadline: Date().addingTimeInterval(12))
                }
            }
        case .failure(let error):
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
                if SelectorExtractionJS.boolValue(finalStatus["loginLikely"]) == true {
                    finish(.failure(SelectorExtractionError.loginRequired))
                } else {
                    finish(.failure(SelectorExtractionError.selectorDidNotMatch))
                }
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
        client?.close()
        if let configuration, let target {
            ChromeBrowserProfile.shared.closeTarget(id: target.id, configuration: configuration)
        }
        completion(result)
        Self.activeScrapers[scrapeID] = nil
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
