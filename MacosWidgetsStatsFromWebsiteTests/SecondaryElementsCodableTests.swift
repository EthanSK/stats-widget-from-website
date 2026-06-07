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

    // MARK: - v0.21.78 MCP write parsing (SecondaryElementMCPParser)
    //
    // These cover the new WRITE path (Ethan voice 4501): turning the
    // loosely-typed JSON the MCP server receives into model mutations.
    // The dispatcher functions in MCPServer.swift are excluded from this
    // test target (project.yml drops Shared/MCP), so we test the pure
    // `SecondaryElementMCPParser` directly — that's exactly the logic the
    // update_tracker / update_widget_configuration handlers delegate to.

    /// Editing an existing secondary element's parser type via the
    /// update_tracker `secondaryElements` input — the core task case:
    /// flip a percent-parsed element to `raw` so verbatim text passes
    /// through. Field-merge must preserve the other fields (id, selector,
    /// name) that weren't part of the edit.
    func testApplySecondaryElementsEditsParserTypeInPlace() throws {
        let existingID = UUID()
        let existing = [
            TrackerElement(
                id: existingID,
                name: "Resets",
                selector: ".reset",
                valueParser: ValueParser(type: .percent)
            )
        ]

        // Mirror the read-payload shape: only send id + the valueParser
        // change (PATCH semantics — everything else should stay put).
        let input: [Any] = [
            [
                "id": existingID.uuidString,
                "valueParser": ["type": "raw"]
            ]
        ]

        let result = try SecondaryElementMCPParser.applySecondaryElements(input, to: existing)

        XCTAssertEqual(result.count, 1, "Editing must not add or drop elements.")
        XCTAssertEqual(result[0].id, existingID, "The element id must be preserved across an edit.")
        XCTAssertEqual(result[0].valueParser.type, .raw, "valueParser.type must flip to raw.")
        XCTAssertEqual(result[0].name, "Resets", "Omitted fields must be left untouched (PATCH semantics).")
        XCTAssertEqual(result[0].selector, ".reset", "Omitted selector must be left untouched.")
    }

    /// Adding a brand-new secondary element (no id supplied) generates a
    /// fresh UUID and applies the sent fields, defaulting the parser to the
    /// model default when not specified.
    func testApplySecondaryElementsAddsNewElementWithGeneratedID() throws {
        let input: [Any] = [
            [
                "name": "Resets",
                "selector": ".reset-line",
                "valueParser": ["type": "raw"]
            ]
        ]

        let result = try SecondaryElementMCPParser.applySecondaryElements(input, to: [])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].name, "Resets")
        XCTAssertEqual(result[0].selector, ".reset-line")
        XCTAssertEqual(result[0].valueParser.type, .raw)
        // A non-nil UUID was generated (UUID() never produces the all-zero
        // UUID in practice, but assert it's distinct from a fresh sentinel).
        XCTAssertNotEqual(result[0].id, UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }

    /// Removing a secondary element via `id` + `_delete: true`.
    func testApplySecondaryElementsRemovesByDeleteFlag() throws {
        let keepID = UUID()
        let dropID = UUID()
        let existing = [
            TrackerElement(id: keepID, name: "Keep", selector: ".keep"),
            TrackerElement(id: dropID, name: "Drop", selector: ".drop")
        ]

        let input: [Any] = [
            ["id": dropID.uuidString, "_delete": true]
        ]

        let result = try SecondaryElementMCPParser.applySecondaryElements(input, to: existing)
        XCTAssertEqual(result.map(\.id), [keepID], "Only the _delete-flagged element should be removed.")
    }

    /// An empty array clears all secondary elements (explicit, documented
    /// behaviour — distinct from omitting the key, which leaves them alone).
    func testApplySecondaryElementsEmptyArrayClearsAll() throws {
        let existing = [TrackerElement(name: "A", selector: ".a")]
        let result = try SecondaryElementMCPParser.applySecondaryElements([Any](), to: existing)
        XCTAssertEqual(result, [], "Sending [] must clear all secondary elements.")
    }

    /// Editing a non-existent id must fail loudly (elementNotFound) rather
    /// than silently creating a stray element.
    func testApplySecondaryElementsUnknownIDThrows() {
        let existing = [TrackerElement(name: "A", selector: ".a")]
        let input: [Any] = [["id": UUID().uuidString, "selector": ".b"]]
        XCTAssertThrowsError(try SecondaryElementMCPParser.applySecondaryElements(input, to: existing)) { error in
            guard case SecondaryElementParseError.elementNotFound = error else {
                return XCTFail("Expected elementNotFound, got \(error).")
            }
        }
    }

    /// An invalid valueParser.type must throw invalidParserType so typos
    /// surface instead of silently being ignored.
    func testApplySecondaryElementsInvalidParserTypeThrows() {
        let input: [Any] = [["selector": ".x", "valueParser": ["type": "verbatim"]]]
        XCTAssertThrowsError(try SecondaryElementMCPParser.applySecondaryElements(input, to: [])) { error in
            guard case SecondaryElementParseError.invalidParserType = error else {
                return XCTFail("Expected invalidParserType, got \(error).")
            }
        }
    }

    /// All three canonical parser types decode successfully.
    func testApplySecondaryElementsAcceptsAllParserTypes() throws {
        for raw in ["raw", "currencyOrNumber", "percent"] {
            let input: [Any] = [["selector": ".x", "valueParser": ["type": raw]]]
            let result = try SecondaryElementMCPParser.applySecondaryElements(input, to: [])
            XCTAssertEqual(result[0].valueParser.type.rawValue, raw)
        }
    }

    /// Decoding `secondaryElementIDsBySlot` from the update_widget_configuration
    /// input — maps slot-index strings to arrays of element UUIDs.
    func testParseSecondaryElementIDsBySlotDecodesMap() throws {
        let elementA = UUID()
        let elementB = UUID()
        let input: [String: Any] = [
            "0": [elementA.uuidString, elementB.uuidString],
            "1": [elementA.uuidString]
        ]

        let result = try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot(input)
        XCTAssertEqual(result["0"], [elementA, elementB])
        XCTAssertEqual(result["1"], [elementA])
    }

    /// An empty object clears all slot bindings; empty slot arrays are
    /// normalised away so the stored map stays tidy.
    func testParseSecondaryElementIDsBySlotEmptyAndNormalisation() throws {
        XCTAssertEqual(try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot([String: Any]()), [:])

        let withEmptySlot: [String: Any] = ["0": [UUID().uuidString], "5": [String]()]
        let result = try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot(withEmptySlot)
        XCTAssertEqual(result.count, 1, "Empty slot arrays should be dropped (identical to a missing key).")
        XCTAssertNotNil(result["0"])
        XCTAssertNil(result["5"])
    }

    /// Bad slot keys + bad UUIDs must throw malformedInput.
    func testParseSecondaryElementIDsBySlotRejectsBadInput() {
        XCTAssertThrowsError(try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot(["zero": [UUID().uuidString]]))
        XCTAssertThrowsError(try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot(["0": ["not-a-uuid"]]))
        XCTAssertThrowsError(try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot("not-an-object"))
    }
}
