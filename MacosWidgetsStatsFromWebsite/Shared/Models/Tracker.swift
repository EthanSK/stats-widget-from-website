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

struct ValueDisplayOptions: Codable, Equatable {
    var stripLetters: Bool
    var stripPercentSymbol: Bool

    init(
        stripLetters: Bool = true,
        stripPercentSymbol: Bool = false
    ) {
        self.stripLetters = stripLetters
        self.stripPercentSymbol = stripPercentSymbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stripLetters = try container.decodeIfPresent(Bool.self, forKey: .stripLetters) ?? true
        stripPercentSymbol = try container.decodeIfPresent(Bool.self, forKey: .stripPercentSymbol) ?? false
    }

    func formatted(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripLetters {
            value = Self.removingLetters(from: value)
        }
        if stripPercentSymbol {
            value = value.replacingOccurrences(of: "%", with: "")
        }
        return Self.normalizedSpacing(value)
    }

    private static func removingLetters(from value: String) -> String {
        let scalarsToStrip = CharacterSet.letters.union(.nonBaseCharacters)
        let keptScalars = value.unicodeScalars.filter { !scalarsToStrip.contains($0) }
        let withoutLetters = String(String.UnicodeScalarView(keptScalars))
        let trimmed = trimValueEdges(normalizedSpacing(withoutLetters))

        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func normalizedSpacing(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: " %", with: "%")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimValueEdges(_ value: String) -> String {
        let allowedEdgeScalars = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "%$£€¥+-.,"))
        var scalars = Array(value.unicodeScalars)

        while let first = scalars.first, !allowedEdgeScalars.contains(first) {
            scalars.removeFirst()
        }
        while let last = scalars.last, !allowedEdgeScalars.contains(last) {
            scalars.removeLast()
        }

        return String(String.UnicodeScalarView(scalars))
    }
}

struct Tracker: Codable, Identifiable {
    static let defaultBrowserProfile = "macos-widgets-stats-from-website"
    static let defaultIcon = "chart.line.uptrend.xyaxis"
    static let defaultAccentColorHex = "#10a37f"
    static let defaultGradientMode: GradientMode = .none
    static let defaultValueTransform: ValueTransform = .none
    static let defaultValueDisplayOptions = ValueDisplayOptions()

    var id: UUID
    var name: String
    var url: String
    var browserProfile: String
    var renderMode: RenderMode
    /// Primary selector — this is "element 0" in the multi-element model
    /// introduced in v0.21.9. Existing trackers keep working unchanged
    /// because the primary fields live at the top level of Tracker (no
    /// wrap-in-array migration required). When the user adds a "secondary
    /// element" via the tracker editor, it lands in `secondaryElements`
    /// below; the primary stays here.
    var selector: String
    var contentSelectorHint: String?
    var elementBoundingBox: ElementBoundingBox?
    var refreshIntervalSec: Int
    var label: String?
    var icon: String
    var accentColorHex: String
    var gradientMode: GradientMode
    var valueTransform: ValueTransform
    var valueDisplayOptions: ValueDisplayOptions
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
    /// Additional elements scraped from the SAME page on each scrape cycle
    /// (v0.21.9, Ethan voice 3797). Default empty — a tracker with no
    /// secondary elements behaves exactly as it did pre-v0.21.9. The
    /// primary element (top-level selector/valueParser/etc) is element 0;
    /// these are 1, 2, 3, ... The widget config UI exposes them as
    /// secondary-text slots so the user can pick which one to render
    /// alongside the primary value (e.g. "claude usage 73% (resets in 4d)").
    var secondaryElements: [TrackerElement]

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
        valueDisplayOptions: ValueDisplayOptions = Tracker.defaultValueDisplayOptions,
        valueParser: ValueParser = ValueParser(),
        history: TrackerHistory = TrackerHistory(),
        hideElements: [String] = [],
        hooks: TrackerHooks? = nil,
        secondaryElements: [TrackerElement] = []
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
        self.valueDisplayOptions = valueDisplayOptions
        self.valueParser = valueParser
        self.history = history
        self.hideElements = hideElements
        self.hooks = hooks ?? TrackerHooks.defaultScaffold()
        self.secondaryElements = secondaryElements
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
        // valueDisplayOptions was added in 0.21.65. Defaulting
        // stripLetters to true removes suffixes like "remaining" from the
        // widget number while preserving percent signs unless the user opts
        // into stripping them too.
        valueDisplayOptions = try container.decodeIfPresent(ValueDisplayOptions.self, forKey: .valueDisplayOptions)
            ?? Tracker.defaultValueDisplayOptions
        valueParser = try container.decodeIfPresent(ValueParser.self, forKey: .valueParser) ?? ValueParser()
        history = try container.decodeIfPresent(TrackerHistory.self, forKey: .history) ?? TrackerHistory()
        hideElements = try container.decodeIfPresent([String].self, forKey: .hideElements) ?? []
        // hooks was added in 0.18.0. Pre-0.18 trackers decode an empty bag here;
        // the BackgroundScheduler-side migration backfills the auto-repair
        // scaffold for existing trackers on first load (so users get the
        // self-heal benefit without opting in).
        hooks = try container.decodeIfPresent(TrackerHooks.self, forKey: .hooks) ?? TrackerHooks()
        // secondaryElements was added in 0.21.9 (Ethan voice 3797). Pre-0.21.9
        // trackers.json files predate the key so default to []. Backcompat-
        // critical: an empty array means the tracker behaves exactly as it
        // did before — single-element scrape, single-element widget binding.
        secondaryElements = try container.decodeIfPresent([TrackerElement].self, forKey: .secondaryElements) ?? []
    }

    func displayValue(for reading: TrackerReading?) -> String? {
        if valueTransform == .invertFromHundred, let raw = reading?.currentNumeric {
            let inverted = max(0.0, min(100.0, 100.0 - raw))
            return valueDisplayOptions.formatted(
                Self.formattedInvertedValue(inverted, originalValue: reading?.currentValue)
            )
        }

        guard let currentValue = reading?.currentValue,
              !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return valueDisplayOptions.formatted(currentValue)
    }

    func displayNumeric(for reading: TrackerReading?) -> Double? {
        guard let raw = reading?.currentNumeric else {
            return nil
        }
        switch valueTransform {
        case .none:
            return raw
        case .invertFromHundred:
            return max(0.0, min(100.0, 100.0 - raw))
        }
    }

    private static func formattedInvertedValue(_ inverted: Double, originalValue: String?) -> String {
        let formatted: String
        if inverted == inverted.rounded() {
            formatted = String(Int(inverted))
        } else {
            formatted = String(format: "%.1f", inverted)
        }

        if originalValue?.contains("%") == true {
            return "\(formatted)% remaining"
        }
        return "\(formatted) remaining"
    }

    private static func normalizedContentSelectorHint(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Per-domain scraping behaviour (v0.21.29, Ethan voice 4019)
    //
    // ChatGPT (chatgpt.com / openai.com) pages sit behind Cloudflare's
    // bot-protection layer and consistently take longer to settle than
    // Claude (claude.ai) pages. Two observed behaviours:
    //   1. Initial DOMContentLoaded fires fast but Cloudflare's JS
    //      challenge can hold the metric element offscreen for 10-20s
    //      while it computes the bot-score. Our 30s outer scrape timeout
    //      (with 25s inner selector-poll deadline) was clipping that
    //      window on slow days — see activity.log "selectorPoll deadline"
    //      entries that have ~24-25s elapsed.
    //   2. Repeatedly hammering the same ChatGPT URL every 30 min
    //      (the default text-tracker cadence) eventually trips
    //      Cloudflare's per-IP request-rate heuristic, which then
    //      returns the JS challenge to EVERY scrape until it ages out
    //      (~1-2h). Spacing requests to 15 min keeps us under the
    //      threshold Ethan's observed (he never gets rate-limited at
    //      that cadence in normal browsing).
    //
    // Both fixes are gated on URL match so Claude trackers stay on the
    // existing 30s timeout + 30 min cadence — no behavioural drift for
    // the trackers that were already working fine.

    /// Returns true if `url` points at a ChatGPT/OpenAI host that needs
    /// the Cloudflare-friendly scrape behaviour. Case-insensitive host
    /// match against the common variants we've seen in trackers.json
    /// (chatgpt.com, chat.openai.com, platform.openai.com).
    static func isChatGPTDomain(url rawURL: String) -> Bool {
        guard let host = URLComponents(string: rawURL)?.host?.lowercased() else {
            // No parseable host means we can't be sure — bias toward
            // the safer (longer-timeout, slower-cadence) ChatGPT path
            // ONLY when the raw string contains the keyword, so we
            // don't accidentally slow down arbitrary unparseable URLs.
            let lower = rawURL.lowercased()
            return lower.contains("chatgpt.com") || lower.contains("openai.com")
        }
        // Match the bare host AND any subdomain (e.g. chat.openai.com,
        // platform.openai.com). hasSuffix on a dotted form prevents
        // false-positives like "fakeopenai.com.example.com".
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            return true
        }
        if host == "openai.com" || host.hasSuffix(".openai.com") {
            return true
        }
        return false
    }

    /// Outer scrape timeout (seconds) for this tracker. ChatGPT-domain
    /// trackers get 60s (v0.21.29, voice 4019) so Cloudflare's JS
    /// challenge has room to complete; everything else stays on 30s.
    var scrapeTimeoutSec: Int {
        Tracker.isChatGPTDomain(url: url) ? 60 : 30
    }

    /// Effective scheduler interval for this tracker. ChatGPT-domain
    /// trackers are floored at 15 min (900s) to stay under Cloudflare's
    /// per-IP rate limit (v0.21.29, voice 4019). The tracker's own
    /// `refreshIntervalSec` still wins if the user explicitly set
    /// something longer — we only override when their value is faster
    /// than 15 min. Non-ChatGPT trackers use their stored interval
    /// unchanged.
    var effectiveRefreshIntervalSec: Int {
        if Tracker.isChatGPTDomain(url: url) {
            return max(900, refreshIntervalSec)
        }
        return refreshIntervalSec
    }

    /// Pending Identify-created trackers are persisted before the user picks
    /// an element, so they must not enter scheduled/on-demand scraping yet.
    var isScrapeReady: Bool {
        !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// One secondary element on a tracker (v0.21.9+). The primary element's
/// fields live on Tracker itself (selector, valueParser, elementBoundingBox,
/// hideElements, contentSelectorHint) for zero-migration backcompat — secondary
/// elements get their own copy of those fields plus a stable UUID + a
/// human-readable name the widget config UI can show in pickers.
///
/// All elements share the tracker's URL and browserProfile: the scrape
/// pipeline loads the page once and then queries each element's selector
/// against the same loaded DOM. This is the efficient one-navigation-N-
/// extractions design Ethan asked for (no extra latency for the primary
/// element when secondaries are present, because we'd be navigating anyway).
struct TrackerElement: Codable, Identifiable, Equatable {
    var id: UUID
    /// Human-readable label shown in the widget-config secondary-text picker.
    /// Auto-generated as "Element 2", "Element 3", ... when the user adds one
    /// via the Identify Element flow, but they can rename it.
    var name: String
    var selector: String
    var contentSelectorHint: String?
    var elementBoundingBox: ElementBoundingBox?
    var valueParser: ValueParser
    var hideElements: [String]

    init(
        id: UUID = UUID(),
        name: String = "",
        selector: String = "",
        contentSelectorHint: String? = nil,
        elementBoundingBox: ElementBoundingBox? = nil,
        valueParser: ValueParser = ValueParser(),
        hideElements: [String] = []
    ) {
        self.id = id
        self.name = name
        self.selector = selector
        let trimmedHint = contentSelectorHint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.contentSelectorHint = trimmedHint.isEmpty ? nil : trimmedHint
        self.elementBoundingBox = elementBoundingBox
        self.valueParser = valueParser
        self.hideElements = hideElements
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        selector = try container.decodeIfPresent(String.self, forKey: .selector) ?? ""
        contentSelectorHint = try container.decodeIfPresent(String.self, forKey: .contentSelectorHint)
        elementBoundingBox = try container.decodeIfPresent(ElementBoundingBox.self, forKey: .elementBoundingBox)
        valueParser = try container.decodeIfPresent(ValueParser.self, forKey: .valueParser) ?? ValueParser()
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
