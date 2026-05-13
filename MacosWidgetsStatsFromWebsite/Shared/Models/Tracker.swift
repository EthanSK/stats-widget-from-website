//
//  Tracker.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Tracker configuration row persisted in trackers.json.
//

import Foundation

/// Gradient color mode for the big-number value text in text-style widget
/// templates. Maps the parsed `currentNumeric` (clamped 0..100) onto a
/// smooth green → yellow → red interpolation in HSL space, so percentage-
/// style readings like "81% used" get a visual at-a-glance bias even when
/// the user isn't reading the digits.
///
/// `.highIsBad` — 0 = green, 100 = red. Quota / usage / error-rate style
///                  metrics where higher = worse.
/// `.highIsGood` — 0 = red, 100 = green. Performance / success-rate style
///                  metrics where higher = better.
/// `.none` — no gradient, default text color (current behavior).
enum GradientMode: String, Codable, CaseIterable, Equatable {
    case none
    case highIsBad
    case highIsGood

    var displayName: String {
        switch self {
        case .none:
            return "Off"
        case .highIsBad:
            return "High is bad (red when high)"
        case .highIsGood:
            return "High is good (green when high)"
        }
    }
}

struct Tracker: Codable, Identifiable {
    static let defaultBrowserProfile = "macos-widgets-stats-from-website"
    static let defaultIcon = "chart.line.uptrend.xyaxis"
    static let defaultAccentColorHex = "#10a37f"
    static let defaultGradientMode: GradientMode = .none

    var id: UUID
    var name: String
    var url: String
    var browserProfile: String
    var renderMode: RenderMode
    var selector: String
    var elementBoundingBox: ElementBoundingBox?
    var refreshIntervalSec: Int
    var label: String?
    var icon: String
    var accentColorHex: String
    var gradientMode: GradientMode
    var valueParser: ValueParser
    var history: TrackerHistory
    var hideElements: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        browserProfile: String = Tracker.defaultBrowserProfile,
        renderMode: RenderMode = .text,
        selector: String = "",
        elementBoundingBox: ElementBoundingBox? = nil,
        refreshIntervalSec: Int? = nil,
        label: String? = nil,
        icon: String = Tracker.defaultIcon,
        accentColorHex: String = Tracker.defaultAccentColorHex,
        gradientMode: GradientMode = Tracker.defaultGradientMode,
        valueParser: ValueParser = ValueParser(),
        history: TrackerHistory = TrackerHistory(),
        hideElements: [String] = []
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.browserProfile = browserProfile
        self.renderMode = renderMode
        self.selector = selector
        self.elementBoundingBox = elementBoundingBox
        self.refreshIntervalSec = refreshIntervalSec ?? renderMode.defaultRefreshIntervalSec
        self.label = label
        self.icon = icon
        self.accentColorHex = accentColorHex
        self.gradientMode = gradientMode
        self.valueParser = valueParser
        self.history = history
        self.hideElements = hideElements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let renderMode = try container.decodeIfPresent(RenderMode.self, forKey: .renderMode) ?? .text

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        browserProfile = try container.decodeIfPresent(String.self, forKey: .browserProfile) ?? Tracker.defaultBrowserProfile
        self.renderMode = renderMode
        selector = try container.decodeIfPresent(String.self, forKey: .selector) ?? ""
        elementBoundingBox = try container.decodeIfPresent(ElementBoundingBox.self, forKey: .elementBoundingBox)
        refreshIntervalSec = try container.decodeIfPresent(Int.self, forKey: .refreshIntervalSec)
            ?? renderMode.defaultRefreshIntervalSec
        label = try container.decodeIfPresent(String.self, forKey: .label)
        icon = try container.decodeIfPresent(String.self, forKey: .icon) ?? Tracker.defaultIcon
        accentColorHex = try container.decodeIfPresent(String.self, forKey: .accentColorHex)
            ?? Tracker.defaultAccentColorHex
        // gradientMode was added in 0.17.7; existing trackers.json files
        // predate the key, so default to .none on migration so users don't
        // get a surprise color change on existing trackers.
        gradientMode = try container.decodeIfPresent(GradientMode.self, forKey: .gradientMode)
            ?? Tracker.defaultGradientMode
        valueParser = try container.decodeIfPresent(ValueParser.self, forKey: .valueParser) ?? ValueParser()
        history = try container.decodeIfPresent(TrackerHistory.self, forKey: .history) ?? TrackerHistory()
        hideElements = try container.decodeIfPresent([String].self, forKey: .hideElements) ?? []
    }
}

struct ElementBoundingBox: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var viewportWidth: Double
    var viewportHeight: Double
    var devicePixelRatio: Double
}

struct ValueParser: Codable, Equatable {
    enum ParserType: String, Codable {
        case currencyOrNumber
        case percent
        case raw
    }

    var type: ParserType
    var stripChars: [String]

    init(type: ParserType = .currencyOrNumber, stripChars: [String] = ["$", ",", " "]) {
        self.type = type
        self.stripChars = stripChars
    }
}

struct TrackerHistory: Codable, Equatable {
    enum RetentionPolicy: String, Codable {
        case count
        case days
    }

    var retentionPolicy: RetentionPolicy
    var retentionValue: Int
    var displayWindow: Int

    init(retentionPolicy: RetentionPolicy = .days, retentionValue: Int = 7, displayWindow: Int = 24) {
        self.retentionPolicy = retentionPolicy
        self.retentionValue = retentionValue
        self.displayWindow = displayWindow
    }
}
