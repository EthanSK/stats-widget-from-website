//
//  IdentifyElementRegressionTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Focused pure-function guards for the Identify-in-Chrome tab picker.
//

import XCTest
import JavaScriptCore

final class IdentifyElementRegressionTests: XCTestCase {
    func testTrackerURLValidatorRejectsRepeatedPastedSchemes() {
        XCTAssertNil(TrackerURLValidator.httpOrHTTPSURL(from: "https://example.comhttps://example.comhttps://example.com"))
    }

    func testTrackerURLValidatorAllowsNestedRedirectURLInQuery() {
        let url = TrackerURLValidator.httpOrHTTPSURL(from: "https://example.com/login?next=https://example.com/dashboard")
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.query, "next=https://example.com/dashboard")
    }

    func testTrackerScrapeReadinessRequiresNonBlankSelector() {
        XCTAssertFalse(Tracker(name: "pending", url: "https://example.com", selector: "").isScrapeReady)
        XCTAssertFalse(Tracker(name: "pending", url: "https://example.com", selector: " \n\t ").isScrapeReady)
        XCTAssertTrue(Tracker(name: "ready", url: "https://example.com", selector: "h1").isScrapeReady)
    }

    func testIdentifyPollTreatsMissingOverlayDOMAsInactive() throws {
        XCTAssertFalse(try pollActive(cleanupPresent: true, bannerPresent: false, outlinePresent: true))
        XCTAssertFalse(try pollActive(cleanupPresent: true, bannerPresent: true, outlinePresent: false))
    }

    func testIdentifyPollRequiresCleanupHookAndOverlayMarkers() throws {
        XCTAssertTrue(try pollActive(cleanupPresent: true, bannerPresent: true, outlinePresent: true))
        XCTAssertFalse(try pollActive(cleanupPresent: false, bannerPresent: true, outlinePresent: true))
    }

    func testStrictIdentifyTargetMatchRejectsUnrelatedHTTPPage() throws {
        let staleTarget = try pageTarget(id: "old", url: "https://unrelated.example/dashboard")
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/dashboard"))

        XCTAssertNil(ChromeBrowserProfile.strictMatchScore(for: staleTarget, requestedURL: requestedURL))
    }

    func testStrictIdentifyTargetMatchRejectsSameHostWrongPath() throws {
        let staleTarget = try pageTarget(id: "old", url: "https://example.com/settings")
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/dashboard"))

        XCTAssertNil(ChromeBrowserProfile.strictMatchScore(for: staleTarget, requestedURL: requestedURL))
    }

    func testStrictIdentifyTargetMatchAcceptsExactURL() throws {
        let target = try pageTarget(id: "new", url: "https://example.com/dashboard?range=week")
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/dashboard?range=week"))

        XCTAssertEqual(ChromeBrowserProfile.strictMatchScore(for: target, requestedURL: requestedURL), 1_000)
    }

    func testStrictIdentifyTargetMatchAcceptsSamePathWhenQueryChanges() throws {
        let target = try pageTarget(id: "new", url: "https://example.com/dashboard?utm_source=login")
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/dashboard"))

        XCTAssertEqual(ChromeBrowserProfile.strictMatchScore(for: target, requestedURL: requestedURL), 750)
    }

    func testStrictIdentifyTargetMatchAcceptsCloudflareChallengeQueryForSamePage() throws {
        let target = try pageTarget(id: "challenge", url: "https://claude.ai/settings/usage?__cf_chl_rt_tk=abc")
        let requestedURL = try XCTUnwrap(URL(string: "https://claude.ai/settings/usage"))

        XCTAssertEqual(ChromeBrowserProfile.strictMatchScore(for: target, requestedURL: requestedURL), 750)
    }

    func testStrictIdentifyTargetMatchRejectsDifferentQueryWhenRequestedURLHasQuery() throws {
        let staleTarget = try pageTarget(id: "old", url: "https://example.com/dashboard?account=old")
        let requestedURL = try XCTUnwrap(URL(string: "https://example.com/dashboard?account=new"))

        XCTAssertNil(ChromeBrowserProfile.strictMatchScore(for: staleTarget, requestedURL: requestedURL))
    }

    func testInspectOverlayBannerIncludesTrackerName() {
        XCTAssertEqual(
            IdentifyOverlayBanner.bannerText(contextLabel: "chatgpt"),
            "Identify Element for \"chatgpt\" — hover the value you want, click to capture, or press Esc to cancel."
        )
        XCTAssertEqual(
            IdentifyOverlayBanner.bannerText(contextLabel: " \n\t "),
            "Identify Element — hover the value you want, click to capture, or press Esc to cancel."
        )
    }

    func testInspectOverlayBannerEscapesTrackerNameForJavaScript() throws {
        let original = "Tracker \"Quotes\" \\ line\nnext"
        let literal = IdentifyOverlayBanner.javaScriptStringLiteral(original)
        let context = try XCTUnwrap(JSContext())
        let value = try XCTUnwrap(context.evaluateScript("var label = \(literal); label;"))

        XCTAssertEqual(value.toString(), original)
    }

    // v0.21.77 — pre-Start banner copy guards. The Start-button gate
    // requires a distinct prepare-state banner text; we pin it so a
    // future agent rewriting the prose can't silently drop the "press
    // Start" call-to-action that closes the loop with the button.
    func testPrepareBannerTextIncludesTrackerLabel() {
        XCTAssertEqual(
            IdentifyOverlayBanner.prepareBannerText(contextLabel: "chatgpt"),
            "Log in or navigate, then press Start to identify \"chatgpt\"."
        )
    }

    func testPrepareBannerTextFallsBackWhenLabelMissing() {
        XCTAssertEqual(
            IdentifyOverlayBanner.prepareBannerText(contextLabel: nil),
            "Log in or navigate to the right page, then press Start to pick the element."
        )
        XCTAssertEqual(
            IdentifyOverlayBanner.prepareBannerText(contextLabel: " \n\t "),
            "Log in or navigate to the right page, then press Start to pick the element."
        )
    }

    // v0.21.77 — the inject-JS must contain a Start button + the
    // inspectionActive state flag. If a refactor accidentally drops
    // either, the user-facing behavior regresses (overlay would auto-
    // arm again like pre-v0.21.77, eating the user's first click). Pin
    // the structural markers here so any such regression breaks CI.
    func testInspectOverlayJSContainsStartButtonGating() {
        let script = InspectOverlayJS.inspectOverlayJS(contextLabel: nil)
        XCTAssertTrue(
            script.contains("data-stats-widget-inspect-start"),
            "Inject-JS lost the Start button marker — overlay would auto-arm and eat the user's first click."
        )
        XCTAssertTrue(
            script.contains("inspectionActive"),
            "Inject-JS lost the inspectionActive gating flag — click handler would fire pre-Start."
        )
    }

    // v0.21.85 — the identify instructions can shrink to a small tab so
    // they do not hide top-of-page controls. Pin both the discoverable
    // control and the active-inspection exclusion: without the latter,
    // the document capture listener would select the toggle itself.
    func testInspectOverlayJSContainsCollapsibleBanner() {
        let script = InspectOverlayJS.inspectOverlayJS(contextLabel: nil)

        XCTAssertTrue(
            script.contains("data-stats-widget-inspect-banner-toggle"),
            "Inject-JS lost the collapse / expand control."
        )
        XCTAssertTrue(
            script.contains("aria-label', 'Minimize instructions"),
            "Expanded banner toggle lost its accessible name."
        )
        XCTAssertTrue(
            script.contains("aria-label', 'Expand instructions"),
            "Collapsed banner toggle lost its accessible name."
        )
        XCTAssertTrue(
            script.contains("if (isElement(event.target) && banner.contains(event.target))"),
            "Active picker no longer excludes banner controls from element capture."
        )
    }

    func testInspectOverlayBannerCollapsesAndExpandsWithoutCapturingItsToggle() throws {
        let context = try overlayDOMContext()
        context.evaluateScript(InspectOverlayJS.inspectOverlayJS(contextLabel: "Example"))

        XCTAssertNil(context.exception)
        XCTAssertTrue(try XCTUnwrap(context.evaluateScript("window.__statsWidgetInspectError === null")).toBool())

        let value = try XCTUnwrap(context.evaluateScript("""
        (() => {
          const banner = document.querySelector('[data-stats-widget-inspect-banner]');
          const label = document.querySelector('[data-stats-widget-inspect-banner-label]');
          const start = document.querySelector('[data-stats-widget-inspect-start]');
          const toggle = document.querySelector('[data-stats-widget-inspect-banner-toggle]');

          const click = target => ({
            target,
            preventDefault() {},
            stopPropagation() {},
            stopImmediatePropagation() {}
          });

          toggle.listeners.click(click(toggle));
          const collapsed = {
            width: banner.style.width,
            left: banner.style.left,
            labelHidden: label.style.display === 'none',
            startHidden: start.style.display === 'none',
            expanded: toggle.getAttribute('aria-expanded')
          };

          toggle.listeners.click(click(toggle));
          const restoredBeforeStart = {
            width: banner.style.width,
            labelVisible: label.style.display === '',
            startVisible: start.style.display === '',
            expanded: toggle.getAttribute('aria-expanded')
          };

          start.listeners.click(click(start));
          const activeToggleClick = click(toggle);
          document.listeners.click(activeToggleClick);
          toggle.listeners.click(activeToggleClick);

          return {
            collapsed,
            restoredBeforeStart,
            activeCollapseWidth: banner.style.width,
            didCaptureToggle: window.__statsWidgetPicked !== null
          };
        })()
        """))
        let result = try XCTUnwrap(value.toDictionary() as? [String: Any])
        let collapsed = try XCTUnwrap(result["collapsed"] as? [String: Any])
        let restored = try XCTUnwrap(result["restoredBeforeStart"] as? [String: Any])

        XCTAssertEqual(collapsed["width"] as? String, "32px")
        XCTAssertEqual(collapsed["left"] as? String, "50%")
        XCTAssertEqual(collapsed["labelHidden"] as? Bool, true)
        XCTAssertEqual(collapsed["startHidden"] as? Bool, true)
        XCTAssertEqual(collapsed["expanded"] as? String, "false")
        XCTAssertEqual(restored["width"] as? String, "auto")
        XCTAssertEqual(restored["labelVisible"] as? Bool, true)
        XCTAssertEqual(restored["startVisible"] as? Bool, true)
        XCTAssertEqual(restored["expanded"] as? String, "true")
        XCTAssertEqual(result["activeCollapseWidth"] as? String, "32px")
        XCTAssertEqual(result["didCaptureToggle"] as? Bool, false)
    }

    func testScrapePreparationDoesNotEnableAccessibilityDomain() {
        XCTAssertEqual(ChromeCDPClient.pagePreparationDomains, ["Page.enable", "Network.enable", "DOM.enable"])
        XCTAssertFalse(ChromeCDPClient.pagePreparationDomains.contains("Accessibility.enable"))
    }

    func testValidationScriptFlagsCloudflareChallengeAsTransient() throws {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = {
          location: { href: 'https://claude.ai/usage?__cf_chl_rt_tk=abc' },
          innerWidth: 1200,
          innerHeight: 800,
          devicePixelRatio: 2
        };
        var document = {
          readyState: 'complete',
          title: 'Just a moment...',
          body: { innerText: 'Checking your browser before accessing claude.ai' },
          querySelectorAll: function(selector) { return []; },
          querySelector: function(selector) { return null; }
        };
        """)

        let value = try XCTUnwrap(
            context.evaluateScript(SelectorExtractionJS.validationScript(for: ".usage"))
        )
        let status = try XCTUnwrap(value.toDictionary() as? [String: Any])

        XCTAssertEqual(status["count"] as? Int32, 0)
        XCTAssertEqual(status["challengeLikely"] as? Bool, true)
        XCTAssertEqual(status["loginLikely"] as? Bool, false)
    }

    func testClaudeFableDisclosureRevealsItsOwnPercentageWithoutRetoggling() throws {
        let context = try fableUsageContext(hostname: "claude.ai", mountAfterClick: true)
        let selector = "[data-testid=\"pace-week-scoped\"] span"
        for _ in 0..<2 {
            let value = try XCTUnwrap(context.evaluateScript(SelectorExtractionJS.validationScript(for: selector)))
            let status = try XCTUnwrap(value.toDictionary())
            XCTAssertEqual(status["count"] as? Int, 1)
            XCTAssertEqual(status["text"] as? String, "53% used")
            XCTAssertNil(context.exception)
        }
        XCTAssertEqual(context.evaluateScript("clicks")?.toInt32(), 1)
    }

    func testClaudeFableDisclosureDoesNotToggleWeeklyOrAnotherSite() throws {
        for (hostname, selector) in [
            ("claude.ai", "[data-testid=\"pace-week\"] span"),
            ("example.com", "[data-testid=\"pace-week-scoped\"] span")
        ] {
            let context = try fableUsageContext(hostname: hostname, mountAfterClick: true)
            _ = context.evaluateScript(SelectorExtractionJS.validationScript(for: selector))
            XCTAssertNil(context.exception)
            XCTAssertEqual(context.evaluateScript("clicks")?.toInt32(), 0)
        }
    }

    func testClaudeFableDisclosureWaitsForMountWithoutRepeatedClicks() throws {
        let context = try fableUsageContext(hostname: "claude.ai", mountAfterClick: false)
        for _ in 0..<2 {
            let value = try XCTUnwrap(context.evaluateScript(
                SelectorExtractionJS.validationScript(for: "[data-testid=\"pace-week-scoped\"] span")
            ))
            XCTAssertEqual(value.toDictionary()?["count"] as? Int, 0)
            XCTAssertNil(context.exception)
        }
        XCTAssertEqual(context.evaluateScript("clicks")?.toInt32(), 1)
    }

    private func fableUsageContext(hostname: String, mountAfterClick: Bool) throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        let hostnameLiteral = String(decoding: try JSONEncoder().encode(hostname), as: UTF8.self)
        context.evaluateScript("""
        var clicks = 0, mounted = false, attributes = {};
        var window = {
          location: {hostname: \(hostnameLiteral), href: 'https://' + \(hostnameLiteral) + '/settings/usage'},
          innerWidth: 1200, innerHeight: 800, devicePixelRatio: 2
        };
        var percentage = {innerText: '53% used', getBoundingClientRect: () => ({left: 0, top: 0, width: 60, height: 20})};
        var toggle = {
          hasAttribute: name => name in attributes,
          setAttribute: (name, value) => { attributes[name] = value; },
          click: () => { clicks++; mounted = \(mountAfterClick); }
        };
        var document = {
          readyState: 'complete', title: 'Claude', body: {innerText: 'Your usage This week 69% used'},
          querySelector: selector => selector === '[data-testid="pace-week-toggle"]' ? toggle :
            (selector.startsWith('[data-testid="pace-week-scoped"]') && mounted ? percentage : null),
          querySelectorAll: selector => selector.startsWith('[data-testid="pace-week-scoped"]') && mounted ? [percentage] : []
        };
        """)
        XCTAssertNil(context.exception)
        return context
    }

    func testCloudflareChallengeClassificationDoesNotSuggestReidentify() throws {
        let message = try XCTUnwrap(SelectorExtractionError.browserChallengeInProgress.errorDescription)
        let reading = TrackerReading(status: .stale, lastError: message, consecutiveFailureCount: 0)
        let kind = try XCTUnwrap(TrackerFailureKind.classify(reading: reading))

        XCTAssertEqual(kind.headline, "Verification pending")
        XCTAssertNil(kind.actionHint)
        XCTAssertFalse(kind.benefitsFromReIdentify)
        XCTAssertFalse(kind.countsTowardBroken)
    }

    func testClaudeUsesCloudflareFriendlyScrapeBudgetAndCadence() {
        let tracker = Tracker(
            name: "Claude",
            url: "https://claude.ai/settings/usage",
            selector: ".usage",
            refreshIntervalSec: 180
        )

        XCTAssertTrue(Tracker.isClaudeDomain(url: tracker.url))
        XCTAssertTrue(Tracker.isCloudflareSensitiveDomain(url: tracker.url))
        XCTAssertEqual(tracker.scrapeTimeoutSec, 60)
        XCTAssertEqual(tracker.effectiveRefreshIntervalSec, 900)
        XCTAssertTrue(tracker.preservesScrapeTabBetweenRuns)
    }

    func testOnlyProtectedDomainsPreserveScrapeTabsBetweenRuns() {
        XCTAssertTrue(Tracker(name: "ChatGPT", url: "https://chatgpt.com/codex/cloud/settings/analytics").preservesScrapeTabBetweenRuns)
        XCTAssertTrue(Tracker(name: "Claude", url: "https://claude.ai/settings/usage").preservesScrapeTabBetweenRuns)
        XCTAssertFalse(Tracker(name: "Example", url: "https://example.com/dashboard").preservesScrapeTabBetweenRuns)
    }

    func testDuePolicyUsesEffectiveProtectedDomainCadence() {
        let tracker = Tracker(
            name: "Claude",
            url: "https://claude.ai/settings/usage",
            selector: ".usage",
            refreshIntervalSec: 180
        )
        let reading = TrackerReading(
            lastUpdatedAt: Date(timeIntervalSince1970: 1_000),
            lastAttemptedAt: Date(timeIntervalSince1970: 1_000),
            status: .ok
        )

        XCTAssertFalse(ScrapeDuePolicy.isDue(
            tracker: tracker,
            reading: reading,
            now: Date(timeIntervalSince1970: 1_500)
        ))
        XCTAssertTrue(ScrapeDuePolicy.isDue(
            tracker: tracker,
            reading: reading,
            now: Date(timeIntervalSince1970: 1_901)
        ))
    }

    private func pageTarget(id: String, url: String) throws -> ChromeBrowserPageTarget {
        ChromeBrowserPageTarget(
            id: id,
            url: try XCTUnwrap(URL(string: url)),
            title: "",
            webSocketDebuggerURL: try XCTUnwrap(URL(string: "ws://127.0.0.1/devtools/page/\(id)"))
        )
    }

    private func pollActive(
        cleanupPresent: Bool,
        bannerPresent: Bool,
        outlinePresent: Bool
    ) throws -> Bool {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = {
          __statsWidgetPicked: null,
          __statsWidgetInspectError: null,
          __statsWidgetInspectCanceled: false,
          __statsWidgetInspectCleanup: \(cleanupPresent ? "function() {}" : "null")
        };
        var document = {
          querySelector: function(selector) {
            if (selector === '[data-stats-widget-inspect-banner]') {
              return \(bannerPresent ? "{}" : "null");
            }
            if (selector === '[data-stats-widget-inspect-outline]') {
              return \(outlinePresent ? "{}" : "null");
            }
            return null;
          }
        };
        """)
        let value = try XCTUnwrap(context.evaluateScript(IdentifyOverlayPollJS.pollScript))
        let state = try XCTUnwrap(value.toDictionary() as? [String: Any])
        return try XCTUnwrap(state["active"] as? Bool)
    }

    private func overlayDOMContext() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var Node = { ELEMENT_NODE: 1 };

        function makeElement(tagName) {
          return {
            nodeType: Node.ELEMENT_NODE,
            tagName: String(tagName).toUpperCase(),
            style: { cssText: '' },
            attributes: {},
            children: [],
            listeners: {},
            parentNode: null,
            parentElement: null,
            previousElementSibling: null,
            textContent: '',
            innerText: '',
            setAttribute(name, value) { this.attributes[name] = String(value); },
            getAttribute(name) { return this.attributes[name] || null; },
            appendChild(child) {
              child.parentNode = this;
              child.parentElement = this;
              this.children.push(child);
              return child;
            },
            removeChild(child) {
              this.children = this.children.filter(candidate => candidate !== child);
              child.parentNode = null;
              child.parentElement = null;
              return child;
            },
            addEventListener(type, listener) { this.listeners[type] = listener; },
            removeEventListener(type, listener) {
              if (this.listeners[type] === listener) delete this.listeners[type];
            },
            contains(candidate) {
              return candidate === this || this.children.some(child => child.contains(candidate));
            },
            getBoundingClientRect() {
              return { left: 0, top: 0, width: 20, height: 20 };
            }
          };
        }

        function findByAttribute(node, attribute) {
          if (node.attributes && node.attributes[attribute]) return node;
          for (const child of node.children || []) {
            const match = findByAttribute(child, attribute);
            if (match) return match;
          }
          return null;
        }

        var document = {
          body: makeElement('body'),
          documentElement: null,
          listeners: {},
          createElement: makeElement,
          addEventListener(type, listener) { this.listeners[type] = listener; },
          removeEventListener(type, listener) {
            if (this.listeners[type] === listener) delete this.listeners[type];
          },
          querySelector(selector) {
            const match = selector.match(/^\\[([^\\]]+)\\]$/);
            return match ? findByAttribute(this.body, match[1]) : null;
          },
          querySelectorAll() { return []; }
        };
        var window = {
          __statsWidgetInspectCleanup: null,
          __statsWidgetPicked: null,
          __statsWidgetInspectError: null,
          __statsWidgetInspectCanceled: false,
          innerWidth: 1200,
          innerHeight: 800,
          devicePixelRatio: 2
        };
        """)
        return context
    }
}
