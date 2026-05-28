//
//  StatsWidget.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  App Group backed WidgetKit renderer.
//

import AppIntents
import AppKit
import SwiftUI
import WidgetKit

struct StatsWidgetEntry: TimelineEntry {
    let date: Date
    let configuration: WidgetConfiguration?
    let trackers: [Tracker]
    let readings: [UUID: TrackerReading]

    var valueFingerprint: String {
        trackers.map { tracker in
            let reading = readings[tracker.id]
            return "\(tracker.id.uuidString):\(reading?.currentValue ?? ""):\(reading?.status.rawValue ?? "missing"):\(reading?.snapshotCapturedAt?.timeIntervalSince1970 ?? 0)"
        }
        .joined(separator: "|")
    }

    var accessibilitySummary: Text {
        let values = trackers.map { tracker in
            let item = WidgetTrackerItem(tracker: tracker, reading: readings[tracker.id])
            return item.accessibilityDescription
        }
        .joined(separator: ", ")
        // VoiceOver / accessibility label when no trackers configured. The
        // user-facing product name was renamed to "Stats Widget from
        // Website" in v0.21.22 (voice 4002 / MBP-CC bridge msg-65036391),
        // and we softened the empty-state wording (em dash + "yet") so a
        // first-launch widget sounds like guidance rather than an error.
        return Text(values.isEmpty ? "Stats Widget from Website — no trackers configured yet" : values)
    }
}

private enum StatsWidgetEntryFactory {
    /// WidgetKit calls `placeholder` while it's still rebuilding the
    /// timeline after a `reloadTimelines()` call (e.g. after the user
    /// taps the refresh button). The previous implementation returned a
    /// gallery-preview entry with fake "$42.18" / "$157" demo data,
    /// which on a placed widget rendered as a brief "fake numbers" flash
    /// between the old value and the new one. Ethan voice 4206 reported
    /// it as "after a minute, it's now showing nothing" — the widget
    /// actually swapped from the real number to the placeholder gallery
    /// preview and back. We now build the placeholder from the LIVE
    /// readings.json data so the placeholder visually matches the real
    /// entry; if the live data isn't there yet (extension cold start,
    /// missing app group, etc.) we fall back to the demo entry.
    static func placeholder(family: WidgetFamily = .systemSmall) -> StatsWidgetEntry {
        // Try to build a real entry first — if any tracker has a current
        // value cached on disk, we can render it during the reload window
        // instead of showing fake numbers. This is the fix for the
        // "widget showed nothing after refresh tap" issue (voice 4206):
        // the placeholder path used to overwrite the live value with the
        // gallery preview while WidgetKit was still rebuilding the
        // timeline post-reloadTimelines(). Now the placeholder still
        // surfaces the most-recent reading so the user sees continuity.
        let live = makeEntry(configurationID: nil)
        if !live.trackers.isEmpty {
            return live
        }
        // No configured trackers at all — show the gallery-style demo
        // entry so the widget gallery has something to draw. Real placed
        // widgets only hit this branch on first install before any
        // trackers exist.
        return galleryPreview(family: family)
    }

    static func galleryPreview(family: WidgetFamily) -> StatsWidgetEntry {
        // v0.21.41 — only the systemSmall family is supported and only
        // one template (`.singleBigNumber`) exists. The previous large /
        // medium / extraLarge branches were dropped per Ethan voice 4206
        // ("just have the small size widget"). `family` is still threaded
        // in for the StatsWidgetEntryView's family-aware behaviour, but
        // the gallery preview itself is always small.
        let trackers = previewTrackers
        let selectedTrackers = Array(trackers.prefix(1))
        let configuration = WidgetConfiguration(
            name: "AI Spend Dashboard",
            templateID: .singleBigNumber,
            size: .small,
            layout: .single,
            trackerIDs: selectedTrackers.map(\.id)
        )

        return StatsWidgetEntry(
            date: Date(),
            configuration: configuration,
            trackers: selectedTrackers,
            readings: previewReadings(for: selectedTrackers)
        )
    }

    static func makeEntry(configurationID: String? = nil) -> StatsWidgetEntry {
        let appConfiguration = AppGroupStore.loadSharedConfiguration()
        let readingsFile = AppGroupStore.loadReadings()
        let selectedConfiguration = selectConfiguration(from: appConfiguration, configurationID: configurationID)
        let configuredTrackerIDs = selectedConfiguration?.trackerIDs ?? []
        let trackerIDs = configuredTrackerIDs.isEmpty
            ? appConfiguration.trackers.prefix(1).map(\.id)
            : configuredTrackerIDs
        // v0.21.41 — singleBigNumber template only renders one tracker, so
        // cap the resolved tracker list at 1. Pre-v0.21.41 multi-slot
        // templates (dashboard, watchlist) needed the full list; with
        // those gone we don't need the extra items here either.
        var trackers = trackerIDs.prefix(1).compactMap { id in
            appConfiguration.trackers.first { $0.id == id }
        }

        if trackers.isEmpty, let firstTracker = appConfiguration.trackers.first {
            trackers = [firstTracker]
        }

        let readings = Dictionary(uniqueKeysWithValues: readingsFile.readings.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })

        ActivityLogger.log("widget", "loaded timeline entry", metadata: [
            "trackers": "\(appConfiguration.trackers.count)",
            "widgets": "\(appConfiguration.widgetConfigurations.count)",
            "selectedTrackers": "\(trackers.count)",
            "configurationID": selectedConfiguration?.id.uuidString ?? "none"
        ])

        return StatsWidgetEntry(
            date: Date(),
            configuration: selectedConfiguration,
            trackers: trackers,
            readings: readings
        )
    }

    private static var previewTrackers: [Tracker] {
        [
            Tracker(name: "Codex spend", url: "https://example.com/codex", selector: "#spend", label: "Codex", accentColorHex: "#10a37f"),
            Tracker(name: "OpenAI credits", url: "https://example.com/openai", selector: "#credits", label: "Credits", accentColorHex: "#0ea5e9"),
            Tracker(name: "API usage", url: "https://example.com/api", selector: "#usage", label: "Usage", accentColorHex: "#f59e0b"),
            Tracker(name: "Claude balance", url: "https://example.com/claude", selector: "#balance", label: "Claude", accentColorHex: "#8b5cf6"),
            Tracker(name: "Runway minutes", url: "https://example.com/runway", selector: "#minutes", label: "Runway", accentColorHex: "#ef4444"),
            Tracker(name: "Replicate", url: "https://example.com/replicate", selector: "#replicate", label: "Replicate", accentColorHex: "#22c55e")
        ]
    }

    private static func previewReadings(for trackers: [Tracker]) -> [UUID: TrackerReading] {
        let values: [(String, Double, [Double])] = [
            ("$42.18", 42.18, [30, 33, 36, 38, 41, 42.18]),
            ("$157", 157, [180, 172, 166, 163, 159, 157]),
            ("18.4k", 18400, [11200, 12800, 14200, 15600, 17100, 18400]),
            ("$23.70", 23.70, [16, 18, 19, 21, 22, 23.7]),
            ("74 min", 74, [91, 86, 82, 79, 76, 74]),
            ("$8.12", 8.12, [4, 5.2, 6.1, 6.8, 7.4, 8.12])
        ]

        return Dictionary(uniqueKeysWithValues: trackers.enumerated().map { index, tracker in
            let value = values[index % values.count]
            return (tracker.id, TrackerReading(
                currentValue: value.0,
                currentNumeric: value.1,
                lastUpdatedAt: Date(),
                status: .ok,
                sparkline: value.2
            ))
        })
    }

    private static func selectConfiguration(from appConfiguration: AppConfiguration, configurationID: String?) -> WidgetConfiguration? {
        if let configurationID,
           let id = UUID(uuidString: configurationID.trimmingCharacters(in: .whitespacesAndNewlines)) {
            if let match = appConfiguration.widgetConfigurations.first(where: { $0.id == id }) {
                return match
            }

            if let tracker = appConfiguration.trackers.first(where: { $0.id == id }) {
                return singleTrackerConfiguration(for: tracker)
            }
        }

        if let first = appConfiguration.widgetConfigurations.first {
            return first
        }

        guard let tracker = appConfiguration.trackers.first else {
            return nil
        }

        return singleTrackerConfiguration(for: tracker)
    }

    private static func singleTrackerConfiguration(for tracker: Tracker) -> WidgetConfiguration {
        WidgetConfiguration(
            name: tracker.label ?? tracker.name,
            templateID: .singleBigNumber,
            size: .small,
            layout: .single,
            trackerIDs: [tracker.id]
        )
    }
}

struct StatsWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> StatsWidgetEntry {
        StatsWidgetEntryFactory.placeholder(family: context.family)
    }

    func snapshot(for configuration: StatsWidgetConfigurationIntent, in context: Context) async -> StatsWidgetEntry {
        if context.isPreview {
            return StatsWidgetEntryFactory.galleryPreview(family: context.family)
        }

        return StatsWidgetEntryFactory.makeEntry(configurationID: configuration.configuration?.id)
    }

    func timeline(for configuration: StatsWidgetConfigurationIntent, in context: Context) async -> Timeline<StatsWidgetEntry> {
        let entry = StatsWidgetEntryFactory.makeEntry(configurationID: configuration.configuration?.id)
        logTimelineDiagnostics(entry: entry, configurationID: configuration.configuration?.id)
        let nextDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        return Timeline(entries: [entry], policy: .after(nextDate))
    }

    func recommendations() -> [AppIntentRecommendation<StatsWidgetConfigurationIntent>] {
        WidgetConfigurationQuery.allEntities().map { entity in
            let intent = StatsWidgetConfigurationIntent(configuration: entity)
            return AppIntentRecommendation(intent: intent, description: entity.recommendationDescription)
        }
    }

    private func logTimelineDiagnostics(entry: StatsWidgetEntry, configurationID: String?) {
        let bundle = Bundle.main
        let formatter = ISO8601DateFormatter()
        let selectedTrackerIDs = entry.trackers.map(\.id.uuidString).joined(separator: ",")
        let readingSummary = entry.trackers.map { tracker in
            let reading = entry.readings[tracker.id]
            let value = reading?.currentValue ?? "<nil>"
            let status = reading?.status.rawValue ?? "missing"
            let updated = reading?.lastUpdatedAt.map { formatter.string(from: $0) } ?? "<nil>"
            return "\(tracker.id.uuidString)=value:\(value),status:\(status),updated:\(updated)"
        }
        .joined(separator: "|")

        ActivityLogger.log("widget", "TimelineProvider.getTimeline", metadata: [
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "extensionBundlePath": bundle.bundleURL.path,
            "version": (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "build": (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown",
            "configurationID": configurationID ?? entry.configuration?.id.uuidString ?? "none",
            "selectedTrackerIDs": selectedTrackerIDs,
            "readings": readingSummary
        ])
    }
}

struct StatsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Stats Widget"
    static var description = IntentDescription("Pick a saved widget composition from the main app.")

    // Title is intentionally kept SHORT ("Widget") so the macOS Intents
    // system-rendered placeholder reads "Select a Widget" instead of
    // "Select a Configuration" which truncates to "Select a..." in the
    // narrow widget edit-sheet popover. See PLAN.md §9 and the v0.16.4
    // changelog.
    @Parameter(title: "Widget")
    var configuration: WidgetConfigurationEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$configuration)")
    }

    init() {
        self.configuration = WidgetConfigurationQuery.defaultEntity()
    }

    init(configuration: WidgetConfigurationEntity) {
        self.configuration = configuration
    }
}

struct WidgetConfigurationEntity: AppEntity, Identifiable {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Widget Configuration")
    static var defaultQuery = WidgetConfigurationQuery()

    let id: String
    let displayName: String
    let details: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: displayName),
            subtitle: details.isEmpty ? nil : LocalizedStringResource(stringLiteral: details)
        )
    }

    var recommendationDescription: String {
        details.isEmpty ? displayName : "\(displayName) — \(details)"
    }

    static let fallback = WidgetConfigurationEntity(
        id: "",
        displayName: "Default configuration",
        details: "Uses the first saved tracker"
    )

    init(id: String, displayName: String, details: String = "") {
        self.id = id
        self.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled widget" : displayName
        self.details = details
    }

    init(configuration: WidgetConfiguration, trackers: [Tracker]) {
        let selectedTrackerCount = configuration.trackerIDs.filter { trackerID in
            trackers.contains { $0.id == trackerID }
        }.count
        let trackerLabel = selectedTrackerCount == 1 ? "1 tracker" : "\(selectedTrackerCount) trackers"

        self.init(
            id: configuration.id.uuidString,
            displayName: configuration.name,
            details: "\(configuration.templateID.displayName) · \(configuration.size.displayName) · \(trackerLabel)"
        )
    }

    init(tracker: Tracker) {
        self.init(
            id: tracker.id.uuidString,
            displayName: tracker.label?.isEmpty == false ? tracker.label! : tracker.name,
            details: "Single tracker"
        )
    }
}

struct WidgetConfigurationQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [WidgetConfigurationEntity.ID]) async throws -> [WidgetConfigurationEntity] {
        let wanted = Set(identifiers.map { $0.uppercased() })
        var matches = Self.allEntities().filter { wanted.contains($0.id.uppercased()) }
        if wanted.contains(WidgetConfigurationEntity.fallback.id.uppercased()) {
            matches.append(WidgetConfigurationEntity.fallback)
        }
        return matches
    }

    func suggestedEntities() async throws -> [WidgetConfigurationEntity] {
        Self.allEntities()
    }

    func defaultResult() async -> WidgetConfigurationEntity? {
        Self.defaultEntity()
    }

    static func defaultEntity() -> WidgetConfigurationEntity {
        allEntities().first ?? .fallback
    }

    static func allEntities() -> [WidgetConfigurationEntity] {
        let appConfiguration = AppGroupStore.loadSharedConfiguration()
        let widgetEntities = appConfiguration.widgetConfigurations.map { configuration in
            WidgetConfigurationEntity(configuration: configuration, trackers: appConfiguration.trackers)
        }

        if widgetEntities.isEmpty {
            return appConfiguration.trackers.map(WidgetConfigurationEntity.init(tracker:))
        }

        return widgetEntities
    }
}

struct StatsWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let entry: StatsWidgetEntry

    var body: some View {
        Group {
            if entry.trackers.isEmpty {
                EmptyWidgetView()
            } else {
                templateView
            }
        }
        .widgetCompatibleBackground()
        .dynamicTypeSize(.xSmall ... .accessibility3)
        .overlay(alignment: .topTrailing) {
            // Only the error badge lives at top-trailing now. The
            // configuration-name chip was dropped in v0.21.41 because it
            // never rendered on `.systemSmall` widgets anyway (the only
            // family we ship — see `visibleConfigurationName`'s
            // systemSmall guard) and the medium/large families that did
            // render it were removed in this version.
            if let item = firstAttentionItem {
                ErrorStateBadge(item: item)
                    .padding(8)
            }
        }
        .animation(NumberAnimation.spring(reduceMotion: reduceMotion), value: entry.valueFingerprint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilitySummary)
    }

    // v0.21.41 — `visibleConfigurationName` was deleted. The chip it fed
    // was suppressed on `.systemSmall` (the only family we ship now), so
    // the function only ever returned nil. Dead code.

    // v0.21.41 — radical simplification per voice 4206. The previous
    // 12-template switch is gone; every widget renders as
    // `SingleBigNumberTemplate`. Legacy WidgetConfigurations on disk that
    // referenced removed templates (gauge, dashboard, watchlist, etc.)
    // still load — the WidgetTemplate decoder coerces unknown raw values
    // to `.singleBigNumber`, so they render here exactly as if the user
    // had picked single-big-number from the start.
    //
    // `fallbackView` and `defaultTemplate` (the family-aware multi-template
    // dispatch) were dropped — we only ship the systemSmall family and
    // only one template, so dispatch is no longer necessary.
    @ViewBuilder
    private var templateView: some View {
        SingleBigNumberTemplate(item: item(at: 0))
    }

    private func item(at index: Int) -> WidgetTrackerItem? {
        guard entry.trackers.indices.contains(index) else {
            return nil
        }

        let tracker = entry.trackers[index]
        return WidgetTrackerItem(
            tracker: tracker,
            reading: entry.readings[tracker.id],
            secondaryElementIDs: secondaryIDs(forSlot: index),
            family: family
        )
    }

    // v0.21.41 — `items(limit:)`, `snapshotItem()`, and `textItem(excluding:)`
    // were removed along with the multi-tracker templates that called them
    // (Dashboard3Up, StatsListWatchlist, SnapshotPlusStat, MegaDashboardGrid,
    // DualStatCompare). Only `item(at:)` remains — it serves the single-slot
    // SingleBigNumberTemplate path.

    private var firstAttentionItem: WidgetTrackerItem? {
        for (offset, tracker) in entry.trackers.enumerated() {
            let item = WidgetTrackerItem(
                tracker: tracker,
                reading: entry.readings[tracker.id],
                secondaryElementIDs: secondaryIDs(forSlot: offset),
                family: family
            )
            if item.needsAttention {
                return item
            }
        }
        return nil
    }

    /// v0.21.9: look up the per-slot secondary-element bindings from the
    /// active widget configuration. Returns [] when no configuration
    /// (placeholder/gallery preview) or when the slot has nothing bound
    /// — both yield the existing single-value rendering.
    private func secondaryIDs(forSlot slotIndex: Int) -> [UUID] {
        entry.configuration?.secondaryElementIDs(forSlot: slotIndex) ?? []
    }
}

struct StatsWidget: Widget {
    static let kind = "MacosWidgetsStatsFromWebsite"

    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: StatsWidgetConfigurationIntent.self, provider: StatsWidgetProvider()) { entry in
            StatsWidgetEntryView(entry: entry)
        }
        // WidgetKit display name in the macOS widget picker. WidgetKit
        // `kind` ("MacosWidgetsStatsFromWebsite", set above) is the stable
        // identifier and must NOT change — that's how the system pairs
        // existing placed widgets with the extension after an update.
        // Only the user-facing display name was renamed in v0.21.22
        // (voice 4002 / MBP-CC bridge msg-65036391).
        .configurationDisplayName("Stats Widget from Website")
        .description("Shows a saved tracker/widget configuration from the main app.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        // v0.21.41 — only the small family. Voice 4206 quote:
        //   "The fucking large size widget and the medium size widget,
        //    etcetera, don't actually seem to work. Maybe we should just
        //    remove them from the app, simplify the app because I don't
        //    need them and I don't even wanna test it. So just have the
        //    small size widget."
        //
        // Confirmed Ethan's currently placed widgets are all small (each
        // selectedTrackers=1 in the timeline diagnostics log), so flipping
        // supportedFamilies has zero visible impact on his desktop.
        // macOS auto-removes any placed widgets whose family is no longer
        // supported by the extension on next reload — but since none of
        // his placed widgets use medium/large/extra-large, no orphan
        // cleanup is required.
        [.systemSmall]
    }
}

extension View {
    /// Apply the gradient `foregroundStyle` for the hero number text in
    /// every multi-tracker template. Prefers the `LinearGradient` over a
    /// solid `Color` so the hue survives the macOS desktop widget vibrancy
    /// material — solid colors get desaturated to gray-white behind the
    /// vibrancy compositor, but LinearGradient is rendered onto the widget
    /// canvas with its hue intact. Falls back to `.primary` when the
    /// tracker has gradient disabled, has no numeric reading, or is in
    /// snapshot mode.
    @ViewBuilder
    func trackerGradientStyle(_ item: WidgetTrackerItem) -> some View {
        if let gradient = item.gradientStyle {
            self.foregroundStyle(gradient)
        } else {
            self.foregroundStyle(.primary)
        }
    }

    /// Optional-item overload used by single-tracker templates that store
    /// the item as `WidgetTrackerItem?`. nil item → `.primary` fallback.
    @ViewBuilder
    func trackerGradientStyle(_ item: WidgetTrackerItem?) -> some View {
        if let item, let gradient = item.gradientStyle {
            self.foregroundStyle(gradient)
        } else {
            self.foregroundStyle(.primary)
        }
    }
}

struct WidgetTrackerItem: Identifiable {
    let tracker: Tracker
    let reading: TrackerReading?
    /// v0.21.9: ordered list of secondary `TrackerElement.id`s the user
    /// picked for the slot this item is rendering at. The widget
    /// composition layer (StatsWidgetEntryView) reads the active
    /// WidgetConfiguration's per-slot bindings and passes them in here.
    /// Empty list = render no secondary text (the historical behavior
    /// every existing widget gets).
    var secondaryElementIDs: [UUID] = []
    /// v0.21.13: which WidgetKit family is currently rendering this item.
    /// Threaded down from `StatsWidgetEntryView.family` via the item
    /// factories below so `title` can pick a family-appropriate label
    /// (forcing the canonical tracker name on `.systemSmall`, see the
    /// `title` doc-comment).
    ///
    /// Defaulted to `nil` so call sites that don't know/care (e.g. test
    /// fixtures, the `firstAttentionItem` overlay helper which is family-
    /// agnostic) keep working unchanged — `nil` falls back to the pre-
    /// v0.21.13 behavior (`tracker.label ?? tracker.name`).
    var family: WidgetFamily? = nil

    var id: UUID {
        tracker.id
    }

    /// User-facing title for the widget body. Family-aware as of v0.21.13:
    ///
    /// - `.systemSmall` → ALWAYS the canonical `tracker.name`.
    /// - everything else → the user's `tracker.label` when set, otherwise
    ///   `tracker.name` (the historical behavior).
    ///
    /// Why force `tracker.name` on `.systemSmall` (Ethan voice 3983,
    /// 2026-05-24): the system-small widget has a single top-leading
    /// title slot and no chip (`visibleConfigurationName` already
    /// short-circuits to `nil` on small per the v0.21.11 fix at
    /// commit `a3ad150`). When `tracker.label` is set to a short context
    /// hint like "5h session" / "Session" — e.g. on multi-element-array
    /// trackers introduced in v0.21.9 where the label describes the
    /// secondary-stat slot rather than the tracker itself — the small
    /// widget then displays a label that doesn't identify the tracker
    /// at all. Ethan's report: "Why is the ChatGPT title now just says
    /// '5h session' and the Claude session just says 'Session'? That's
    /// not the name of my trackers." The v0.21.11 a3ad150 fix
    /// suppressed the WRONG element (the config-name chip) — the actual
    /// regression was the label-vs-name precedence at the title slot
    /// itself. Forcing `tracker.name` on small ensures the title
    /// always reads as "ChatGPT session usage" / "Claude session usage"
    /// / "claude weekly usij" — i.e. the user-recognizable tracker name
    /// they typed when they first created it. Larger families keep the
    /// historical label-override because they have room for both the
    /// label AND the config-name chip without colliding, and a custom
    /// `tracker.label` there is intentional disambiguation when many
    /// trackers fit on the same widget canvas (dashboard, list, etc.).
    var title: String {
        if family == .systemSmall {
            // Force the canonical tracker name on small widgets — see
            // the doc-comment above. Falling back to the label here
            // would re-introduce the v0.21.9 regression that voice
            // 3983 flagged.
            return tracker.name
        }
        return tracker.label?.isEmpty == false ? tracker.label! : tracker.name
    }

    /// v0.21.9: ordered display strings for every selected secondary
    /// element. Pulls each value from `reading.secondaryValues` and falls
    /// back to "—" when the element scraped but had no text yet. Returns
    /// [] for trackers/widgets that don't use secondary elements (the
    /// common case), so existing templates render unchanged.
    var secondaryTexts: [String] {
        guard !secondaryElementIDs.isEmpty else { return [] }
        let secondaryByID = reading?.secondaryValues ?? [:]
        return secondaryElementIDs.compactMap { elementID in
            guard tracker.secondaryElements.contains(where: { $0.id == elementID }) else {
                return nil
            }
            return secondaryByID[elementID.uuidString]?.value
        }
        .filter { !$0.isEmpty }
    }

    /// v0.21.9: joined " · "-separated string of secondary values, or
    /// nil when there are none. Templates that want to render secondary
    /// text inline pick this; templates that want one-per-line iterate
    /// `secondaryTexts` directly.
    var secondaryTextJoined: String? {
        let texts = secondaryTexts
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: " · ")
    }

    var value: String {
        if let displayValue = tracker.displayValue(for: reading) {
            return displayValue
        }

        switch reading?.status {
        case .broken:
            // Avoid the bare "?" placeholder; surface a short status hint instead.
            // The widget overlay also renders an attention badge for broken trackers.
            return "—"
        default:
            return "—"
        }
    }

    /// Numeric reading after applying `tracker.valueTransform`. Used by both
    /// the display layer (so the big-number text reflects the transform) and
    /// the gradient layer (so the color interpolation is consistent with
    /// what the user is reading). `currentNumeric` stays raw on disk; the
    /// transform is presentation-only.
    var numeric: Double? {
        tracker.displayNumeric(for: reading)
    }

    var sparkline: [Double] {
        let raw = reading?.sparkline ?? []
        switch tracker.valueTransform {
        case .none:
            return raw
        case .invertFromHundred:
            // Codex review (2026-05-14): the big-number text and gradient
            // already apply `100 - x`, so leaving the sparkline raw would
            // visually reverse the trend (e.g. "99% remaining" while the
            // sparkline trends as the underlying "% used" curve). Apply the
            // same presentation transform to history-derived values so the
            // chart matches the displayed value.
            return raw.map { max(0.0, min(100.0, 100.0 - $0)) }
        }
    }

    var status: TrackerStatus {
        reading?.status ?? .stale
    }

    var needsAttention: Bool {
        status == .broken
    }

    var accessibilityDescription: String {
        let statusText = needsAttention ? "needs attention" : status.rawValue
        return "\(title), \(value), \(statusText), updated \(updatedText)"
    }

    var deepLinkURL: URL? {
        URL(string: "macos-widgets-stats-from-website://tracker/\(tracker.id.uuidString)")
    }

    var updatedText: String {
        guard let date = reading?.lastUpdatedAt else {
            return "not updated"
        }

        // Widget timeline entries are static — RelativeDateTimeFormatter
        // would freeze "5 sec ago" at render time and never tick because
        // WidgetKit can't re-render between timeline entries. Show the
        // ABSOLUTE time instead: same-day renders as "20:09", older
        // renders as "11 May 20:09" so the user can always tell exactly
        // when the value was fetched.
        let now = Date()
        let isToday = Calendar.current.isDate(date, inSameDayAs: now)
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        if isToday {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.setLocalizedDateFormatFromTemplate("d MMM HH:mm")
        }
        return formatter.string(from: date)
    }

    var accent: Color {
        Color(hexString: tracker.accentColorHex) ?? .accentColor
    }

    /// Optional gradient-based color for the big numeric value, computed
    /// from `tracker.gradientMode` and the parsed `currentNumeric`. Returns
    /// nil when the tracker has gradient disabled, has no numeric reading,
    /// or is in snapshot mode (snapshot templates render bitmaps, not text).
    /// Templates fall back to their existing default text color when nil.
    ///
    /// NOTE: On macOS desktop widgets the vibrancy material desaturates
    /// solid `Color` foregroundStyles even when
    /// `.widgetAccentedRenderingMode(.fullColor)` is in play. Prefer
    /// `gradientStyle` (a LinearGradient) on the big-number text so the
    /// hue survives the vibrancy pass. This accessor remains for places
    /// that genuinely want a solid `Color` (chip backgrounds, etc.).
    var gradientColor: Color? {
        guard tracker.renderMode == .text else {
            return nil
        }
        return GradientColor.color(numeric: numeric, mode: tracker.gradientMode)
    }

    /// LinearGradient variant for use as the `foregroundStyle` on the
    /// big-number Text view. macOS desktop widgets desaturate solid colors
    /// behind the vibrancy material — a LinearGradient (even a degenerate
    /// 2-stop) stays vivid. Templates pass this to `.foregroundStyle(...)`
    /// when present and fall back to the default `.primary` color when nil
    /// (gradient disabled / no numeric / snapshot mode).
    var gradientStyle: LinearGradient? {
        guard tracker.renderMode == .text else {
            return nil
        }
        return GradientColor.gradient(numeric: numeric, mode: tracker.gradientMode)
    }

    var snapshotImage: NSImage? {
        guard tracker.renderMode == .snapshot,
              let data = SnapshotSharedCache.shared.data(for: tracker.id) else {
            return nil
        }

        return NSImage(data: data)
    }
}

enum NumberAnimation {
    static func spring(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82)
    }
}

/// Small refresh button surfaced inside each widget template. Tapping it
/// invokes `RefreshTrackerIntent`, which writes one pending-scrape
/// request file per tracker the main app's BackgroundScheduler picks up
/// via a file watcher. Designed to be unobtrusive — semi-transparent
/// foreground, hierarchical rendering, ~14pt icon — so the scraped
/// number stays the focus.
///
/// `trackerIDs` is a list because multi-tracker templates
/// (Dashboard3Up, StatsListWatchlist, MegaDashboardGrid, DualStatCompare)
/// want one button to refresh every visible tracker. Empty array →
/// EmptyView so placeholder / gallery previews don't render a stray
/// button.
@available(macOSApplicationExtension 14.0, *)
struct WidgetRefreshButton: View {
    let trackerIDs: [UUID]

    var body: some View {
        if !trackerIDs.isEmpty {
            Button(intent: RefreshTrackerIntent(trackerIDs: trackerIDs)) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Refresh tracker now"))
        } else {
            EmptyView()
        }
    }
}

/// Convenience modifier so templates can opt into the refresh button
/// with a single line. Anchored to bottom-trailing across the board so
/// the affordance lives in a consistent place no matter which template
/// is active and so it doesn't collide with the top-leading
/// configuration-name chip or the top-trailing error badge.
extension View {
    @ViewBuilder
    func widgetRefreshOverlay(trackerIDs: [UUID]) -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            self.overlay(alignment: .bottomTrailing) {
                WidgetRefreshButton(trackerIDs: trackerIDs)
                    .padding(6)
            }
        } else {
            self
        }
    }

    /// Single-tracker convenience overload used by all the
    /// one-tracker-per-template flavours.
    @ViewBuilder
    func widgetRefreshOverlay(trackerID: UUID?) -> some View {
        widgetRefreshOverlay(trackerIDs: trackerID.map { [$0] } ?? [])
    }
}

struct ErrorStateBadge: View {
    let item: WidgetTrackerItem

    var body: some View {
        Group {
            if let url = item.deepLinkURL {
                Link(destination: url) {
                    content
                }
            } else {
                content
            }
        }
        .accessibilityLabel(Text("\(item.title) needs attention"))
    }

    private var content: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            Text("needs attention")
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
    }
}

struct EmptyWidgetView: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("No tracker")
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("Open the app to add one.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(8)
    }
}

// v0.21.41 — All the in-file `private struct ___WidgetView` types were
// deleted: SingleBigNumberWidgetView, NumberSparklineWidgetView,
// LiveSnapshotTileWidgetView, LiveSnapshotHeroWidgetView,
// SnapshotPlusStatWidgetView, GaugeRingWidgetView,
// HeadlineSparklineWidgetView, Dashboard3UpWidgetView. They were all
// dead — never referenced from anywhere — leftover from an earlier
// abandoned rendering approach. The actual templates live in the
// `Templates/` directory and (post-v0.21.41) only SingleBigNumber.swift
// remains.
//
// The dependent infrastructure types (SnapshotImageView, SnapshotOverlay,
// SparklineView, SparklineShape) are also deleted because their sole
// callers were the dead structs above; nothing in the surviving
// SingleBigNumberTemplate uses sparklines or snapshot rendering.

extension View {
    @ViewBuilder
    func numericValueTransition() -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }

    @ViewBuilder
    func widgetCompatibleBackground() -> some View {
        if #available(macOSApplicationExtension 14.0, *) {
            containerBackground(.background, for: .widget)
        } else {
            background(Color(nsColor: .windowBackgroundColor))
        }
    }
}

private extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let hex = Int(value, radix: 16) else {
            return nil
        }

        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
