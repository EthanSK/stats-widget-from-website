//
//  SecondaryElementsCodableTests.swift
//  MacosWidgetsStatsFromWebsiteTests
//
//  Round-trip + backcompat tests for the v0.21.9 multi-element-array
//  feature (Ethan voice 3797). Verifies the backcompat-critical
//  invariants: pre-v0.21.9 JSON decodes with empty
//  secondaryElements/secondaryValues/secondaryElementIDsBySlot, and
//  the on-disk shape round-trips losslessly.
//

import XCTest

final class SecondaryElementsCodableTests: XCTestCase {

    // MARK: - Tracker.secondaryElements

    func testTrackerWithoutSecondaryElementsRoundTrips() throws {
        let tracker = Tracker(name: "Primary only", url: "https://example.com", selector: ".x")
        let data = try JSONEncoder().encode(tracker)
        let decoded = try JSONDecoder().decode(Tracker.self, from: data)
        XCTAssertEqual(decoded.secondaryElements, [])
        XCTAssertEqual(decoded.selector, ".x")
    }

    func testTrackerWithSecondaryElementsRoundTrips() throws {
        var tracker = Tracker(name: "Multi", url: "https://example.com", selector: ".primary")
        tracker.secondaryElements = [
            TrackerElement(name: "Element 2", selector: ".reset-date"),
            TrackerElement(name: "Quota cap", selector: ".cap", valueParser: ValueParser(type: .percent))
        ]
        let data = try JSONEncoder().encode(tracker)
        let decoded = try JSONDecoder().decode(Tracker.self, from: data)
        XCTAssertEqual(decoded.secondaryElements.count, 2)
        XCTAssertEqual(decoded.secondaryElements[0].name, "Element 2")
        XCTAssertEqual(decoded.secondaryElements[0].selector, ".reset-date")
        XCTAssertEqual(decoded.secondaryElements[1].valueParser.type, .percent)
    }

    func testPreV0219TrackerJSONDecodesWithEmptySecondaryElements() throws {
        // Simulate a pre-0.21.9 trackers.json blob — no secondaryElements key.
        let json = """
        {
            "id": "44444444-4444-4444-4444-444444444444",
            "name": "Pre-0.21.9 tracker",
            "url": "https://example.com",
            "selector": ".legacy",
            "renderMode": "text"
        }
        """.data(using: .utf8)!
        let tracker = try JSONDecoder().decode(Tracker.self, from: json)
        XCTAssertEqual(tracker.secondaryElements, [], "Pre-0.21.9 trackers must decode with no secondary elements so single-element trackers behave exactly as before.")
        XCTAssertEqual(tracker.selector, ".legacy")
    }

    // MARK: - TrackerReading.secondaryValues

    func testTrackerReadingWithoutSecondaryValuesRoundTrips() throws {
        let reading = TrackerReading(currentValue: "73%", currentNumeric: 73, status: .ok)
        let data = try JSONEncoder().encode(reading)
        let decoded = try JSONDecoder().decode(TrackerReading.self, from: data)
        XCTAssertEqual(decoded.secondaryValues, [:])
        XCTAssertEqual(decoded.currentValue, "73%")
    }

    func testTrackerReadingWithSecondaryValuesRoundTrips() throws {
        let elementID = "55555555-5555-5555-5555-555555555555"
        let reading = TrackerReading(
            currentValue: "73%",
            currentNumeric: 73,
            status: .ok,
            secondaryValues: [
                elementID: TrackerSecondaryValue(value: "resets in 4d", numeric: nil, lastError: nil)
            ]
        )
        let data = try JSONEncoder().encode(reading)
        let decoded = try JSONDecoder().decode(TrackerReading.self, from: data)
        XCTAssertEqual(decoded.secondaryValues.count, 1)
        XCTAssertEqual(decoded.secondaryValues[elementID]?.value, "resets in 4d")
    }

    func testPreV0219TrackerReadingJSONDecodesWithEmptySecondaryValues() throws {
        let json = """
        {
            "currentValue": "73%",
            "status": "ok",
            "sparkline": []
        }
        """.data(using: .utf8)!
        let reading = try JSONDecoder().decode(TrackerReading.self, from: json)
        XCTAssertEqual(reading.secondaryValues, [:], "Pre-0.21.9 readings must decode with no secondary values so existing widgets render unchanged.")
        XCTAssertEqual(reading.currentValue, "73%")
    }

    // MARK: - WidgetConfiguration.secondaryElementIDsBySlot

    func testWidgetConfigurationWithoutSecondaryBindingsRoundTrips() throws {
        let config = WidgetConfiguration(
            name: "Test",
            templateID: .singleBigNumber,
            trackerIDs: [UUID()]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WidgetConfiguration.self, from: data)
        XCTAssertEqual(decoded.secondaryElementIDsBySlot, [:])
        XCTAssertEqual(decoded.secondaryElementIDs(forSlot: 0), [])
    }

    func testWidgetConfigurationWithSecondaryBindingsRoundTrips() throws {
        // v0.21.41 — `.dashboard3Up` removed; switched to
        // `.singleBigNumber`. The test still exercises slot-0 / slot-2
        // bindings (with no slot-1 binding) — secondaryElementIDsBySlot
        // is keyed by slot index regardless of how many slots the
        // template actually exposes, so the data path round-trips fine.
        let elementA = UUID()
        let elementB = UUID()
        let trackerID = UUID()
        let config = WidgetConfiguration(
            name: "Multi",
            templateID: .singleBigNumber,
            trackerIDs: [trackerID, trackerID, trackerID],
            secondaryElementIDsBySlot: [
                "0": [elementA, elementB],
                "2": [elementA]
            ]
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WidgetConfiguration.self, from: data)
        XCTAssertEqual(decoded.secondaryElementIDs(forSlot: 0), [elementA, elementB])
        XCTAssertEqual(decoded.secondaryElementIDs(forSlot: 1), [])
        XCTAssertEqual(decoded.secondaryElementIDs(forSlot: 2), [elementA])
    }

    func testPreV0219WidgetConfigurationJSONDecodesWithEmptyBindings() throws {
        let json = """
        {
            "id": "66666666-6666-6666-6666-666666666666",
            "name": "Pre-0.21.9 widget",
            "templateID": "single-big-number",
            "size": "small",
            "layout": "single",
            "trackerIDs": ["77777777-7777-7777-7777-777777777777"],
            "showSparklines": true,
            "showLabels": true
        }
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(WidgetConfiguration.self, from: json)
        XCTAssertEqual(config.secondaryElementIDsBySlot, [:], "Pre-0.21.9 widget configurations must decode with no secondary bindings so existing widgets render exactly as before.")
        XCTAssertEqual(config.secondaryElementIDs(forSlot: 0), [])
    }
}
