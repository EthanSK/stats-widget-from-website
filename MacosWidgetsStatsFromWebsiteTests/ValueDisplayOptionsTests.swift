//
//  ValueDisplayOptionsTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Focused guards for compact widget/list value display formatting.
//

import XCTest

final class ValueDisplayOptionsTests: XCTestCase {
    func testResetCaptionsExtractTheFullGeminiDuration() {
        let element = TrackerElement(name: "Resets")
        let examples = [
            ("You have used some of your 5-hour limit, it will fully refresh in 3 hours, 44 minutes.", "Resets in 3h 44m"),
            ("You have used some of your weekly limit, it will fully refresh in 6 days, 22 hours.", "Resets in 6d 22h"),
            ("Resets in 1 day and 1 hour.", "Resets in 1d 1h"),
            ("Fully refreshes in 2 minutes, 5 seconds", "Resets in 2m 5s")
        ]
        for (source, expected) in examples {
            XCTAssertEqual(element.displayValue(for: TrackerSecondaryValue(value: source)), expected)
        }
    }

    func testResetCaptionsPreserveDatesQualifiersAndUnknownText() {
        let element = TrackerElement(name: "Resets")
        for value in ["Resets Thursday 1:00 AM", "Refresh in about 2 hours", "Refresh in 1–2 hours", "Resets in 3h 44m", "Available now"] {
            XCTAssertEqual(element.displayValue(for: TrackerSecondaryValue(value: value)), value)
        }
        XCTAssertNil(element.displayValue(for: nil))
        XCTAssertNil(element.displayValue(for: TrackerSecondaryValue(lastError: "Selector did not match")))
    }

    func testExhaustedGeminiCaptionsKeepTheCorrectResetWindow() {
        let element = TrackerElement(name: "Resets")
        XCTAssertEqual(element.displayValue(for: TrackerSecondaryValue(value:
            "You have hit your 5-hour limit, it will refresh in 2 hours, 52 minutes. If on a supported paid plan, you can use AI credits in the interim."
        )), "Resets in 2h 52m")
        XCTAssertEqual(element.displayValue(for: TrackerSecondaryValue(value:
            "You have hit your 5-hour limit, so the weekly limit does not currently apply. Your 5-hour limit will refresh in 2 hours, 50 minutes."
        )), "5-hour reset in 2h 50m")
    }

    func testUnrelatedSecondaryCaptionsRemainVerbatim() {
        let value = "The service will fully refresh in 3 hours, 44 minutes."
        let element = TrackerElement(name: "Status")
        XCTAssertEqual(element.displayValue(for: TrackerSecondaryValue(value: value)), value)
    }

    func testDefaultFormattingRemovesLettersButKeepsPercentSymbol() {
        XCTAssertEqual(ValueDisplayOptions().formatted("100% remaining"), "100%")
        XCTAssertEqual(ValueDisplayOptions().formatted("0% used"), "0%")
        XCTAssertEqual(ValueDisplayOptions().formatted("Used: 80%"), "80%")
    }

    func testPercentSymbolCanBeRemovedSeparately() {
        let options = ValueDisplayOptions(stripLetters: true, stripPercentSymbol: true)

        XCTAssertEqual(options.formatted("100% remaining"), "100")
        XCTAssertEqual(options.formatted("12.5% used"), "12.5")
    }

    func testLettersCanBeKeptForOldVerboseDisplay() {
        let options = ValueDisplayOptions(stripLetters: false, stripPercentSymbol: false)

        XCTAssertEqual(options.formatted("99% remaining"), "99% remaining")
    }

    func testTrackerInvertUsesCompactDefaultDisplay() {
        let tracker = Tracker(
            name: "Claude",
            url: "https://claude.ai",
            selector: ".usage",
            valueTransform: .invertFromHundred
        )
        let reading = TrackerReading(currentValue: "1% used", currentNumeric: 1, status: .ok)

        XCTAssertEqual(tracker.displayValue(for: reading), "99%")
        XCTAssertEqual(tracker.displayNumeric(for: reading), 99)
    }

    func testTrackerInvertCanPreserveRemainingWord() {
        let tracker = Tracker(
            name: "Claude",
            url: "https://claude.ai",
            selector: ".usage",
            valueTransform: .invertFromHundred,
            valueDisplayOptions: ValueDisplayOptions(stripLetters: false)
        )
        let reading = TrackerReading(currentValue: "1% used", currentNumeric: 1, status: .ok)

        XCTAssertEqual(tracker.displayValue(for: reading), "99% remaining")
    }

    func testLegacyTrackerJSONDecodesWithDefaultDisplayOptions() throws {
        let json = """
        {
            "id": "66666666-6666-6666-6666-666666666666",
            "name": "Legacy",
            "url": "https://example.com",
            "selector": ".value",
            "renderMode": "text"
        }
        """.data(using: .utf8)!

        let tracker = try JSONDecoder().decode(Tracker.self, from: json)

        XCTAssertTrue(tracker.valueDisplayOptions.stripLetters)
        XCTAssertFalse(tracker.valueDisplayOptions.stripPercentSymbol)
    }

    func testPartialDisplayOptionsJSONDecodesWithDefaults() throws {
        let json = """
        {
            "stripLetters": false
        }
        """.data(using: .utf8)!

        let options = try JSONDecoder().decode(ValueDisplayOptions.self, from: json)

        XCTAssertFalse(options.stripLetters)
        XCTAssertFalse(options.stripPercentSymbol)
    }
}
