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

    func testScrapePreparationDoesNotEnableAccessibilityDomain() {
        XCTAssertEqual(ChromeCDPClient.pagePreparationDomains, ["Page.enable", "Network.enable", "DOM.enable"])
        XCTAssertFalse(ChromeCDPClient.pagePreparationDomains.contains("Accessibility.enable"))
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
}
