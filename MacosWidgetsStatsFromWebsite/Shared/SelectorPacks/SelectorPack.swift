//
//  SelectorPack.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Strict JSON import/export for shareable selector packs.
//

import Foundation

struct SelectorPack: Codable {
    static let currentSchemaVersion = 1
    static let fileExtension = "selectorpack"
    static let contentTypeIdentifier = "com.ethansk.macos-widgets-stats-from-website.selectorpack"

    var schemaVersion: Int
    var name: String
    var url: String
    var mode: RenderMode
    var selector: String
    var contentSelectorHint: String?
    var cropRegion: ElementBoundingBox?
    var label: String?
    var icon: String?
    var hideElements: [String]

    init(
        schemaVersion: Int = SelectorPack.currentSchemaVersion,
        name: String,
        url: String,
        mode: RenderMode,
        selector: String,
        contentSelectorHint: String? = nil,
        cropRegion: ElementBoundingBox? = nil,
        label: String? = nil,
        icon: String? = nil,
        hideElements: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.url = url
        self.mode = mode
        self.selector = selector
        self.contentSelectorHint = contentSelectorHint?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.cropRegion = cropRegion
        self.label = label
        self.icon = icon
        self.hideElements = hideElements
    }

    init(tracker: Tracker) {
        self.init(
            name: tracker.name,
            url: tracker.url,
            mode: tracker.renderMode,
            selector: tracker.selector,
            contentSelectorHint: tracker.contentSelectorHint,
            cropRegion: tracker.elementBoundingBox,
            label: tracker.label,
            icon: tracker.icon,
            hideElements: tracker.hideElements
        )
    }

    func makeTracker() throws -> Tracker {
        try Self.validateURL(url)
        try Self.validateSelector(selector)
        try hideElements.forEach(Self.validateSelector)

        return Tracker(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Imported Tracker",
            url: url,
            renderMode: mode,
            selector: selector,
            contentSelectorHint: contentSelectorHint,
            elementBoundingBox: cropRegion,
            label: label?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            icon: icon?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Tracker.defaultIcon,
            hideElements: hideElements
        )
    }

    func encodedData() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func jsonObject() throws -> [String: Any] {
        let data = try encodedData()
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelectorPackError.invalidJSON
        }
        return object
    }

    func validate() throws {
        guard schemaVersion == SelectorPack.currentSchemaVersion else {
            throw SelectorPackError.unsupportedSchemaVersion(schemaVersion)
        }
        try Self.validateURL(url)
        try Self.validateSelector(selector)
        try hideElements.forEach(Self.validateSelector)
    }

    static func decodeStrict(from data: Data) throws -> SelectorPack {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SelectorPackError.invalidJSON
        }

        try validateObjectShape(object)

        let decoder = JSONDecoder()
        let pack = try decoder.decode(SelectorPack.self, from: data)
        try pack.validate()
        return pack
    }

    static func decodeStrict(from object: [String: Any]) throws -> SelectorPack {
        try validateObjectShape(object)
        let data = try JSONSerialization.data(withJSONObject: object)
        return try decodeStrict(from: data)
    }

    private static func validateObjectShape(_ object: [String: Any]) throws {
        let allowedKeys: Set<String> = [
            "schemaVersion",
            "name",
            "url",
            "mode",
            "selector",
            "contentSelectorHint",
            "cropRegion",
            "label",
            "icon",
            "hideElements"
        ]
        let keys = Set(object.keys)
        let unexpectedKeys = keys.subtracting(allowedKeys)
        guard unexpectedKeys.isEmpty else {
            throw SelectorPackError.unexpectedFields(unexpectedKeys.sorted())
        }

        try rejectScriptLikeFields(in: object)
        guard (object["schemaVersion"] as? Int) == SelectorPack.currentSchemaVersion else {
            throw SelectorPackError.unsupportedSchemaVersion(object["schemaVersion"] as? Int ?? -1)
        }
    }

    private static func rejectScriptLikeFields(in value: Any, keyPath: String = "") throws {
        if let dictionary = value as? [String: Any] {
            for (key, nestedValue) in dictionary {
                let lowered = key.lowercased()
                if lowered.contains("script") || lowered.contains("javascript") {
                    throw SelectorPackError.scriptField(keyPath.isEmpty ? key : "\(keyPath).\(key)")
                }
                try rejectScriptLikeFields(in: nestedValue, keyPath: keyPath.isEmpty ? key : "\(keyPath).\(key)")
            }
        } else if let array = value as? [Any] {
            for (index, nestedValue) in array.enumerated() {
                try rejectScriptLikeFields(in: nestedValue, keyPath: "\(keyPath)[\(index)]")
            }
        } else if let string = value as? String {
            let lowered = string.lowercased()
            if lowered.contains("<script") || lowered.contains("javascript:") {
                throw SelectorPackError.scriptValue(keyPath)
            }
        }
    }

    private static func validateURL(_ string: String) throws {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw SelectorPackError.invalidURL
        }

        if scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")) {
            return
        }

        throw SelectorPackError.invalidURL
    }

    private static func validateSelector(_ selector: String) throws {
        let trimmed = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SelectorPackError.emptySelector
        }

        let lowered = trimmed.lowercased()
        guard !lowered.contains("<script"), !lowered.contains("javascript:") else {
            throw SelectorPackError.scriptValue("selector")
        }
    }
}

enum SelectorPackError: LocalizedError {
    case invalidJSON
    case unsupportedSchemaVersion(Int)
    case unexpectedFields([String])
    case scriptField(String)
    case scriptValue(String)
    case invalidURL
    case emptySelector

    var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "Selector pack JSON must be an object."
        case .unsupportedSchemaVersion(let version):
            return "Unsupported selector pack schemaVersion \(version)."
        case .unexpectedFields(let fields):
            return "Selector pack contains unsupported fields: \(fields.joined(separator: ", "))."
        case .scriptField(let field):
            return "Selector packs cannot contain script-like field '\(field)'."
        case .scriptValue(let field):
            return "Selector packs cannot contain script-like values in '\(field)'."
        case .invalidURL:
            return "Selector pack URL must be https://, or http://localhost for testing."
        case .emptySelector:
            return "Selector pack selector cannot be empty."
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
