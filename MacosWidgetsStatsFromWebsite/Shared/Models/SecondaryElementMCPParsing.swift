//
//  SecondaryElementMCPParsing.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Pure (no-I/O, no-singleton) parsing helpers that turn the loosely-typed
//  JSON dictionaries the MCP server receives into strongly-typed model
//  mutations for the v0.21.78 "MCP can WRITE secondary elements + slot
//  bindings" feature (Ethan voice 4501).
//
//  WHY this lives in Shared/Models/ and NOT in Shared/MCP/:
//  -------------------------------------------------------
//  The unit-test target (`MacosWidgetsStatsFromWebsiteHookTests` in
//  project.yml) compiles `Shared/` but EXCLUDES the `MCP` subdirectory
//  (it pulls in only the model/store layer so the suite stays fast and has
//  no JSON-RPC / socket surface). If the parsing logic lived inside
//  `MCPServer.swift` it could not be unit-tested at all — the dispatcher
//  functions there are `private static` AND the whole file is excluded
//  from the test target. Putting the PURE parsing here (a non-excluded
//  directory) lets `MCPServer.swift` call it from the app while
//  `SecondaryElementsCodableTests` exercises it directly. Keep this file
//  free of any MCPError / socket / Sparkle references so the test target
//  keeps compiling it cleanly.
//
//  The error type is a local lightweight enum (`SecondaryElementParseError`)
//  rather than the MCP server's private `MCPError`, again so this file does
//  not drag the excluded MCP layer into the test target. `MCPServer.swift`
//  maps these errors onto `MCPError.invalidParams` / `.validation` at the
//  call site.
//

import Foundation

/// Lightweight parse error surfaced by the secondary-element MCP parsing
/// helpers. `MCPServer.swift` catches these and rethrows as the matching
/// `MCPError` case so the JSON-RPC client still gets a -32602 code.
enum SecondaryElementParseError: Error, Equatable {
    /// The `secondaryElements` argument (or one of its entries) had the
    /// wrong shape — not an array, an entry that isn't an object, a
    /// non-string field where a string was required, etc.
    case malformedInput(String)
    /// An entry referenced an existing secondary element by `id` for an
    /// edit/remove, but no element with that id exists on the tracker.
    case elementNotFound(String)
    /// `valueParser.type` was present but not one of the canonical
    /// `ParserType` raw values (`raw` | `currencyOrNumber` | `percent`).
    case invalidParserType(String)

    var message: String {
        switch self {
        case .malformedInput(let detail): return detail
        case .elementNotFound(let detail): return detail
        case .invalidParserType(let detail): return detail
        }
    }
}

enum SecondaryElementMCPParser {

    // MARK: - update_tracker → secondaryElements

    /// Applies a `secondaryElements` MCP input array onto an existing list of
    /// secondary `TrackerElement`s and returns the resulting list.
    ///
    /// The input array MIRRORS the exact shape `secondaryElementPayload`
    /// EMITS in the read path (so a caller can round-trip: read a tracker,
    /// tweak one element's `valueParser.type`, send the whole array back).
    /// Each entry is an object with any of:
    ///   - `id`            (string UUID) — when present + matches an existing
    ///                      element → EDIT that element in place; when present
    ///                      but no match → error (so typo'd ids fail loudly
    ///                      instead of silently creating a stray element).
    ///                      When ABSENT → ADD a new element (a fresh UUID is
    ///                      generated).
    ///   - `name`          (string)
    ///   - `selector`      (string)
    ///   - `contentSelectorHint` (string | null | "")  — null/empty clears it
    ///   - `hideElements`  (array of strings)
    ///   - `valueParser`   (object: `{ type, stripChars }`) — `type` must be
    ///                      one of raw | currencyOrNumber | percent
    ///   - `elementBoundingBox` (object | null) — same 7-field shape as the
    ///                      primary element box; null clears it
    ///   - `_delete`       (bool) — when true AND `id` matches, REMOVE that
    ///                      element. Mutually exclusive with editing fields
    ///                      (delete wins; other fields are ignored for a
    ///                      delete entry).
    ///
    /// EDIT semantics are FIELD-LEVEL MERGE: only keys present in the entry
    /// are changed; omitted keys keep the element's current value. This is
    /// the same "omit = leave alone" contract the rest of update_tracker
    /// uses, so an agent can PATCH just `valueParser.type` without having to
    /// resend selector/name/etc.
    ///
    /// ADD semantics: a fresh `TrackerElement()` is created (default parser =
    /// currencyOrNumber, matching the model default) and then the same
    /// field-merge is applied, so the agent only needs to supply the fields
    /// it cares about (typically `selector`, `name`, and maybe
    /// `valueParser.type: "raw"`).
    ///
    /// - Throws: `SecondaryElementParseError` on malformed shape, an
    ///   edit/delete that references a missing id, or a bad parser type.
    static func applySecondaryElements(
        _ rawValue: Any?,
        to existing: [TrackerElement]
    ) throws -> [TrackerElement] {
        // Must be an array of objects. (A `null` is treated as malformed
        // rather than "clear all" — clearing every secondary element is a
        // destructive action that an agent should do explicitly by sending
        // an empty array `[]`, which IS supported and clears the list.)
        guard let entries = rawValue as? [Any] else {
            throw SecondaryElementParseError.malformedInput(
                "secondaryElements must be an array of element objects (send [] to clear all)."
            )
        }

        // Work on a mutable copy so partial application never corrupts the
        // caller's input on a thrown error (the MCP dispatcher discards the
        // whole mutation transaction on throw anyway, but keeping this pure
        // makes the unit tests trivial).
        var result = existing

        for (offset, rawEntry) in entries.enumerated() {
            guard let entry = rawEntry as? [String: Any] else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)] must be an object."
                )
            }

            // Resolve an optional id. A present-but-not-a-valid-UUID id is a
            // hard error (loud failure beats silently treating it as an add).
            let elementID: UUID?
            if entry.keys.contains("id") {
                if entry["id"] is NSNull {
                    elementID = nil
                } else if let idString = entry["id"] as? String, !idString.isEmpty {
                    guard let parsed = UUID(uuidString: idString) else {
                        throw SecondaryElementParseError.malformedInput(
                            "secondaryElements[\(offset)].id is not a valid UUID: \(idString)."
                        )
                    }
                    elementID = parsed
                } else {
                    elementID = nil
                }
            } else {
                elementID = nil
            }

            // ---- DELETE branch -------------------------------------------
            // `_delete: true` removes the referenced element. Requires a
            // matching id; deleting by anything else is ambiguous so we
            // error rather than guess.
            if let shouldDelete = boolFromAny(entry["_delete"]), shouldDelete {
                guard let elementID else {
                    throw SecondaryElementParseError.malformedInput(
                        "secondaryElements[\(offset)] requested _delete but supplied no id to identify which element to remove."
                    )
                }
                guard let index = result.firstIndex(where: { $0.id == elementID }) else {
                    throw SecondaryElementParseError.elementNotFound(
                        "secondaryElements[\(offset)] _delete referenced unknown element id \(elementID.uuidString)."
                    )
                }
                result.remove(at: index)
                continue
            }

            // ---- EDIT branch ---------------------------------------------
            if let elementID {
                guard let index = result.firstIndex(where: { $0.id == elementID }) else {
                    throw SecondaryElementParseError.elementNotFound(
                        "secondaryElements[\(offset)] referenced unknown element id \(elementID.uuidString). Omit id to add a NEW element."
                    )
                }
                var element = result[index]
                try mergeFields(into: &element, from: entry, offset: offset)
                result[index] = element
                continue
            }

            // ---- ADD branch ----------------------------------------------
            // No id supplied → brand-new element with a generated UUID.
            var element = TrackerElement()
            try mergeFields(into: &element, from: entry, offset: offset)
            result.append(element)
        }

        return result
    }

    /// Field-level merge of one input object onto a `TrackerElement`. Only
    /// keys PRESENT in `entry` mutate the element; everything else is left
    /// untouched (PATCH semantics). Shared by the edit + add branches.
    private static func mergeFields(
        into element: inout TrackerElement,
        from entry: [String: Any],
        offset: Int
    ) throws {
        if entry.keys.contains("name") {
            guard let name = entry["name"] as? String else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)].name must be a string."
                )
            }
            element.name = name
        }

        if entry.keys.contains("selector") {
            guard let selector = entry["selector"] as? String else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)].selector must be a string."
                )
            }
            element.selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if entry.keys.contains("contentSelectorHint") {
            // null or empty-string clears the hint; otherwise trim + set.
            if entry["contentSelectorHint"] is NSNull {
                element.contentSelectorHint = nil
            } else if let hint = entry["contentSelectorHint"] as? String {
                let trimmed = hint.trimmingCharacters(in: .whitespacesAndNewlines)
                element.contentSelectorHint = trimmed.isEmpty ? nil : trimmed
            } else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)].contentSelectorHint must be a string or null."
                )
            }
        }

        if entry.keys.contains("hideElements") {
            guard let hide = entry["hideElements"] as? [String] else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)].hideElements must be an array of strings."
                )
            }
            element.hideElements = hide
        }

        if entry.keys.contains("valueParser") {
            element.valueParser = try parseValueParser(
                entry["valueParser"],
                existing: element.valueParser,
                offset: offset
            )
        }

        if entry.keys.contains("elementBoundingBox") {
            element.elementBoundingBox = try parseBoundingBox(
                entry["elementBoundingBox"],
                offset: offset
            )
        }
    }

    /// Parses the `valueParser` object. Field-level merge against the
    /// element's existing parser so an agent can change ONLY `type` (the
    /// common case — flipping a percent-parsed element to `raw` so verbatim
    /// text like "Resets Friday" passes through) without having to resend
    /// `stripChars`.
    ///
    /// `type` accepts exactly the `ValueParser.ParserType` raw values:
    ///   - `raw`              → verbatim text passthrough (no numeric coercion)
    ///   - `currencyOrNumber` → strip currency/grouping, parse a number
    ///   - `percent`          → parse a percentage
    private static func parseValueParser(
        _ rawValue: Any?,
        existing: ValueParser,
        offset: Int
    ) throws -> ValueParser {
        guard let object = rawValue as? [String: Any] else {
            throw SecondaryElementParseError.malformedInput(
                "secondaryElements[\(offset)].valueParser must be an object with optional type + stripChars."
            )
        }

        var parser = existing

        if object.keys.contains("type") {
            guard let typeString = object["type"] as? String else {
                throw SecondaryElementParseError.invalidParserType(
                    "secondaryElements[\(offset)].valueParser.type must be a string."
                )
            }
            guard let parsed = ValueParser.ParserType(rawValue: typeString) else {
                let allowed = ["raw", "currencyOrNumber", "percent"].joined(separator: ", ")
                throw SecondaryElementParseError.invalidParserType(
                    "secondaryElements[\(offset)].valueParser.type must be one of: \(allowed). Got \"\(typeString)\"."
                )
            }
            parser.type = parsed
        }

        if object.keys.contains("stripChars") {
            guard let strip = object["stripChars"] as? [String] else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElements[\(offset)].valueParser.stripChars must be an array of strings."
                )
            }
            parser.stripChars = strip
        }

        return parser
    }

    /// Parses an `elementBoundingBox` object (or null). Mirrors the primary
    /// element's box shape (7 numeric fields). Returns nil when the value is
    /// null so callers can clear a stale box.
    private static func parseBoundingBox(
        _ rawValue: Any?,
        offset: Int
    ) throws -> ElementBoundingBox? {
        if rawValue is NSNull { return nil }
        guard let object = rawValue as? [String: Any] else {
            throw SecondaryElementParseError.malformedInput(
                "secondaryElements[\(offset)].elementBoundingBox must be an object or null."
            )
        }
        guard let x = doubleFromAny(object["x"]),
              let y = doubleFromAny(object["y"]),
              let width = doubleFromAny(object["width"]),
              let height = doubleFromAny(object["height"]),
              let viewportWidth = doubleFromAny(object["viewportWidth"]),
              let viewportHeight = doubleFromAny(object["viewportHeight"]),
              let devicePixelRatio = doubleFromAny(object["devicePixelRatio"]) else {
            throw SecondaryElementParseError.malformedInput(
                "secondaryElements[\(offset)].elementBoundingBox must include numeric x, y, width, height, viewportWidth, viewportHeight, devicePixelRatio."
            )
        }
        return ElementBoundingBox(
            x: x, y: y, width: width, height: height,
            viewportWidth: viewportWidth, viewportHeight: viewportHeight,
            devicePixelRatio: devicePixelRatio
        )
    }

    // MARK: - update_widget_configuration → secondaryElementIDsBySlot

    /// Parses a `secondaryElementIDsBySlot` MCP input object into the strongly
    /// typed `[String: [UUID]]` the model stores. Mirrors the read payload
    /// shape exactly (slot-index-string → array of element-UUID strings), so
    /// it round-trips: read a widget config, append an element id to a slot,
    /// send the whole map back.
    ///
    /// Validation:
    ///   - the value itself must be an object (map)
    ///   - each KEY must be a string that parses to a non-negative Int slot
    ///     index (we keep it as a string in the model, but reject keys that
    ///     aren't valid slot indices so typos surface)
    ///   - each VALUE must be an array of valid UUID strings
    ///
    /// An empty object `{}` clears all slot bindings. This whole argument is
    /// "replace" semantics (the agent sends the COMPLETE desired map), unlike
    /// the per-field merge used for trackers — slot bindings are small and
    /// the read payload gives the agent the full current map to edit.
    static func parseSecondaryElementIDsBySlot(
        _ rawValue: Any?
    ) throws -> [String: [UUID]] {
        guard let object = rawValue as? [String: Any] else {
            throw SecondaryElementParseError.malformedInput(
                "secondaryElementIDsBySlot must be an object mapping slot-index strings to arrays of element UUID strings (send {} to clear)."
            )
        }

        var result: [String: [UUID]] = [:]
        for (slotKey, rawIDs) in object {
            // Slot key must be a non-negative integer index (stored as a
            // string for JSON friendliness, matching the model + read shape).
            guard let slotInt = Int(slotKey), slotInt >= 0 else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElementIDsBySlot key \"\(slotKey)\" must be a non-negative integer slot index string."
                )
            }

            guard let idStrings = rawIDs as? [String] else {
                throw SecondaryElementParseError.malformedInput(
                    "secondaryElementIDsBySlot[\"\(slotKey)\"] must be an array of element UUID strings."
                )
            }

            var ids: [UUID] = []
            for idString in idStrings {
                guard let parsed = UUID(uuidString: idString) else {
                    throw SecondaryElementParseError.malformedInput(
                        "secondaryElementIDsBySlot[\"\(slotKey)\"] contains an invalid UUID: \(idString)."
                    )
                }
                ids.append(parsed)
            }

            // Skip empty arrays so the stored map stays clean (an empty slot
            // binding is identical to a missing key — both render no secondary
            // text). Normalising here keeps the read payload tidy.
            if !ids.isEmpty {
                result[String(slotInt)] = ids
            }
        }

        return result
    }

    // MARK: - Tiny local coercion helpers
    //
    // Duplicated (deliberately) from MCPServer's private helpers so this file
    // stays standalone + compilable into the MCP-excluded test target. Kept
    // minimal — only the coercions the parsing above needs.

    private static func doubleFromAny(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func boolFromAny(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }
}
