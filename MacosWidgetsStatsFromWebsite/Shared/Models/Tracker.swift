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

/// Optional numeric transform applied to `currentNumeric` BEFORE the
/// gradient interpolation and BEFORE the value is rendered in the widget.
/// Use this when the scraped value represents one half of a complementary
/// pair (e.g. "% used") but you want the widget to communicate the other
/// half (e.g. "% remaining"). The transform is symmetric — flip the
/// gradient mode accordingly (highIsBad → highIsGood or vice versa) so
/// the color sweep still reads correctly under the new framing.
///
/// `.none` — display the raw scraped value (current behavior).
/// `.invertFromHundred` — display `100 - numeric`. Useful for usage
///                         percentages that should read as "amount
///                         remaining" instead of "amount used".
enum ValueTransform: String, Codable, CaseIterable, Equatable {
    case none
    case invertFromHundred

    var displayName: String {
        switch self {
        case .none:
            return "As-is"
        case .invertFromHundred:
            return "100 minus value (remaining)"
        }
    }
}

struct Tracker: Codable, Identifiable {
    static let defaultBrowserProfile = "macos-widgets-stats-from-website"
    static let defaultIcon = "chart.line.uptrend.xyaxis"
    static let defaultAccentColorHex = "#10a37f"
    static let defaultGradientMode: GradientMode = .none
    static let defaultValueTransform: ValueTransform = .none

    var id: UUID
    var name: String
    var url: String
    var browserProfile: String
    var renderMode: RenderMode
    var selector: String
    var contentSelectorHint: String?
    var elementBoundingBox: ElementBoundingBox?
    var refreshIntervalSec: Int
    var label: String?
    var icon: String
    var accentColorHex: String
    var gradientMode: GradientMode
    var valueTransform: ValueTransform
    var valueParser: ValueParser
    var history: TrackerHistory
    var hideElements: [String]
    /// Per-tracker scrape lifecycle hooks (0.18.0+). New trackers get the
    /// default scaffold from `TrackerHooks.defaultScaffold()` (one built-in
    /// auto-repair failure hook). Pre-0.18 trackers.json files decode with
    /// an empty hooks bag and miss the default scaffold — see
    /// `applyMissingDefaultHookScaffold(_:)` in AppGroupStore for the
    /// migration that backfills it.
    var hooks: TrackerHooks

    init(
        id: UUID = UUID(),
        name: String = "",
        url: String = "",
        browserProfile: String = Tracker.defaultBrowserProfile,
        renderMode: RenderMode = .text,
        selector: String = "",
        contentSelectorHint: String? = nil,
        elementBoundingBox: ElementBoundingBox? = nil,
        refreshIntervalSec: Int? = nil,
        label: String? = nil,
        icon: String = Tracker.defaultIcon,
        accentColorHex: String = Tracker.defaultAccentColorHex,
        gradientMode: GradientMode = Tracker.defaultGradientMode,
        valueTransform: ValueTransform = Tracker.defaultValueTransform,
        valueParser: ValueParser = ValueParser(),
        history: TrackerHistory = TrackerHistory(),
        hideElements: [String] = [],
        hooks: TrackerHooks? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.browserProfile = browserProfile
        self.renderMode = renderMode
        self.selector = selector
        self.contentSelectorHint = Self.normalizedContentSelectorHint(contentSelectorHint)
        self.elementBoundingBox = elementBoundingBox
        self.refreshIntervalSec = refreshIntervalSec ?? renderMode.defaultRefreshIntervalSec
        self.label = label
        self.icon = icon
        self.accentColorHex = accentColorHex
        self.gradientMode = gradientMode
        self.valueTransform = valueTransform
        self.valueParser = valueParser
        self.history = history
        self.hideElements = hideElements
        self.hooks = hooks ?? TrackerHooks.defaultScaffold()
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
        contentSelectorHint = Self.normalizedContentSelectorHint(
            try container.decodeIfPresent(String.self, forKey: .contentSelectorHint)
        )
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
        // valueTransform was added in 0.17.9; default to .none on migration so
        // existing trackers continue to display the raw scraped value.
        valueTransform = try container.decodeIfPresent(ValueTransform.self, forKey: .valueTransform)
            ?? Tracker.defaultValueTransform
        valueParser = try container.decodeIfPresent(ValueParser.self, forKey: .valueParser) ?? ValueParser()
        history = try container.decodeIfPresent(TrackerHistory.self, forKey: .history) ?? TrackerHistory()
        hideElements = try container.decodeIfPresent([String].self, forKey: .hideElements) ?? []
        // hooks was added in 0.18.0. Pre-0.18 trackers decode an empty bag here;
        // the BackgroundScheduler-side migration backfills the auto-repair
        // scaffold for existing trackers on first load (so users get the
        // self-heal benefit without opting in).
        hooks = try container.decodeIfPresent(TrackerHooks.self, forKey: .hooks) ?? TrackerHooks()
    }

    private static func normalizedContentSelectorHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
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
