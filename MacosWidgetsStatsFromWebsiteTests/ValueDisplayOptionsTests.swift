//
//  ValueDisplayOptionsTests.swift
//  MacosWidgetsStatsFromWebsiteHookTests
//
//  Focused guards for compact widget/list value display formatting.
//

import XCTest

final class ValueDisplayOptionsTests: XCTestCase {
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
