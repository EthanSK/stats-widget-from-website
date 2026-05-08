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
        return Text(values.isEmpty ? "macOS Widgets Stats from Website, no trackers configured" : values)
    }
}

private enum StatsWidgetEntryFactory {
    static func placeholder(family: WidgetFamily = .systemSmall) -> StatsWidgetEntry {
        galleryPreview(family: family)
    }

    static func galleryPreview(family: WidgetFamily) -> StatsWidgetEntry {
        let trackers = previewTrackers
        let templateID: WidgetTemplate
        let trackerLimit: Int

        switch family {
        case .systemMedium:
            templateID = .dashboard3Up
            trackerLimit = 3
        case .systemLarge:
            templateID = .statsListWatchlist
            trackerLimit = 4
        case .systemExtraLarge:
            templateID = .megaDashboardGrid
            trackerLimit = 6
        default:
            templateID = .singleBigNumber
            trackerLimit = 1
        }

        let selectedTrackers = Array(trackers.prefix(trackerLimit))
        let configuration = WidgetConfiguration(
            name: "AI Spend Dashboard",
            templateID: templateID,
            size: templateID.size,
            layout: templateID.defaultLayout,
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
        var trackers = trackerIDs.compactMap { id in
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
        let nextDate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        return Timeline(entries: [entry], policy: .after(nextDate))
    }

    func recommendations() -> [AppIntentRecommendation<StatsWidgetConfigurationIntent>] {
        WidgetConfigurationQuery.allEntities().map { entity in
            let intent = StatsWidgetConfigurationIntent(configuration: entity)
            return AppIntentRecommendation(intent: intent, description: entity.recommendationDescription)
        }
    }
}

struct StatsWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Stats Widget Configuration"
    static var description = IntentDescription("Choose which saved widget configuration this widget should show.")

    @Parameter(title: "Configuration")
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
            if let item = firstAttentionItem {
                ErrorStateBadge(item: item)
                    .padding(8)
            }
        }
        .animation(NumberAnimation.spring(reduceMotion: reduceMotion), value: entry.valueFingerprint)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.accessibilitySummary)
    }

    @ViewBuilder
    private var templateView: some View {
        switch entry.configuration?.templateID ?? defaultTemplate {
        case .singleBigNumber:
            SingleBigNumberTemplate(item: item(at: 0))
        case .numberPlusSparkline:
            NumberPlusSparklineTemplate(item: item(at: 0))
        case .gaugeRing:
            GaugeRingTemplate(item: item(at: 0))
        case .liveSnapshotTile:
            LiveSnapshotTileTemplate(item: item(at: 0))
        case .headlineSparkline:
            HeadlineSparklineTemplate(item: item(at: 0))
        case .dualStatCompare:
            DualStatCompareTemplate(items: items(limit: 2))
        case .dashboard3Up:
            Dashboard3UpTemplate(items: items(limit: 3))
        case .snapshotPlusStat:
            SnapshotPlusStatTemplate(snapshotItem: snapshotItem(), textItem: textItem(excluding: snapshotItem()?.id))
        case .statsListWatchlist:
            StatsListWatchlistTemplate(items: items(limit: 6))
        case .heroPlusDetail:
            HeroPlusDetailTemplate(item: item(at: 0))
        case .liveSnapshotHero:
            LiveSnapshotHeroTemplate(item: item(at: 0))
        case .megaDashboardGrid:
            MegaDashboardGridTemplate(items: items(limit: 8))
        }
    }

    @ViewBuilder
    private var fallbackView: some View {
        if item(at: 0)?.tracker.renderMode == .snapshot {
            switch family {
            case .systemLarge:
                LiveSnapshotHeroTemplate(item: item(at: 0))
            default:
                LiveSnapshotTileTemplate(item: item(at: 0))
            }
        } else if #available(macOSApplicationExtension 14.0, *), family == .systemExtraLarge {
            MegaDashboardGridTemplate(items: items(limit: 8))
        } else {
            switch family {
            case .systemMedium:
                Dashboard3UpTemplate(items: items(limit: 3))
            case .systemLarge:
                StatsListWatchlistTemplate(items: items(limit: 6))
            default:
                SingleBigNumberTemplate(item: item(at: 0))
            }
        }
    }

    private var defaultTemplate: WidgetTemplate {
        if #available(macOSApplicationExtension 14.0, *), family == .systemExtraLarge {
            return .megaDashboardGrid
        }

        switch family {
        case .systemMedium:
            return .dashboard3Up
        case .systemLarge:
            return .statsListWatchlist
        default:
            return .singleBigNumber
        }
    }

    private func item(at index: Int) -> WidgetTrackerItem? {
        guard entry.trackers.indices.contains(index) else {
            return nil
        }

        let tracker = entry.trackers[index]
        return WidgetTrackerItem(tracker: tracker, reading: entry.readings[tracker.id])
    }

    private func items(limit: Int) -> [WidgetTrackerItem] {
        entry.trackers.prefix(limit).map { tracker in
            WidgetTrackerItem(tracker: tracker, reading: entry.readings[tracker.id])
        }
    }

    private func snapshotItem() -> WidgetTrackerItem? {
        entry.trackers
            .map { WidgetTrackerItem(tracker: $0, reading: entry.readings[$0.id]) }
            .first { $0.tracker.renderMode == .snapshot }
    }

    private func textItem(excluding excludedID: UUID?) -> WidgetTrackerItem? {
        entry.trackers
            .filter { $0.id != excludedID }
            .map { WidgetTrackerItem(tracker: $0, reading: entry.readings[$0.id]) }
            .first { $0.tracker.renderMode == .text }
    }

    private var firstAttentionItem: WidgetTrackerItem? {
        entry.trackers
            .map { WidgetTrackerItem(tracker: $0, reading: entry.readings[$0.id]) }
            .first { $0.needsAttention }
    }
}

struct StatsWidget: Widget {
    static let kind = "MacosWidgetsStatsFromWebsite"

    var body: some SwiftUI.WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: StatsWidgetConfigurationIntent.self, provider: StatsWidgetProvider()) { entry in
            StatsWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("macOS Widgets Stats from Website")
        .description("Shows a saved tracker/widget configuration from the main app.")
        .supportedFamilies(supportedFamilies)
    }

    private var supportedFamilies: [WidgetFamily] {
        [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    }
}

struct WidgetTrackerItem: Identifiable {
    let tracker: Tracker
    let reading: TrackerReading?

    var id: UUID {
        tracker.id
    }

    var title: String {
        tracker.label?.isEmpty == false ? tracker.label! : tracker.name
    }

    var value: String {
        if let currentValue = reading?.currentValue, !currentValue.isEmpty {
            return currentValue
        }

        switch reading?.status {
        case .broken:
            return "?"
        default:
            return "--"
        }
    }

    var numeric: Double? {
        reading?.currentNumeric
    }

    var sparkline: [Double] {
        reading?.sparkline ?? []
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

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var accent: Color {
        Color(hexString: tracker.accentColorHex) ?? .accentColor
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
        VStack(spacing: 6) {
            Text("Click to configure tracker")
                .font(.headline)
            Text("Choose a tracker in widget configuration.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct SingleBigNumberWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.title ?? "Tracker")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(item?.value ?? "--")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .numericValueTransition()
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: item?.status == .ok ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                Text(item?.updatedText ?? "not updated")
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var statusColor: Color {
        switch item?.status {
        case .broken:
            return .red
        case .stale, nil:
            return .secondary
        case .ok:
            return .primary
        }
    }

    private var accessibilityLabel: Text {
        Text("\(item?.title ?? "Tracker"), \(item?.value ?? "no value"), updated \(item?.updatedText ?? "never")")
    }
}

private struct NumberSparklineWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.title ?? "Tracker")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item?.value ?? "--")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .numericValueTransition()
            SparklineView(values: item?.sparkline ?? [], tint: item?.accent ?? .accentColor)
                .frame(height: 34)
            Text(item?.updatedText ?? "not updated")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}

private struct LiveSnapshotTileWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        SnapshotImageView(item: item, cornerRadius: 4)
            .overlay(alignment: .bottomLeading) {
                SnapshotOverlay(item: item)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(item?.title ?? "Snapshot tracker"), updated \(item?.updatedText ?? "never")"))
    }
}

private struct LiveSnapshotHeroWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        SnapshotImageView(item: item, cornerRadius: 0)
            .overlay(alignment: .topLeading) {
                SnapshotOverlay(item: item)
                    .padding(10)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("\(item?.title ?? "Snapshot tracker"), updated \(item?.updatedText ?? "never")"))
    }
}

private struct SnapshotPlusStatWidgetView: View {
    let snapshotItem: WidgetTrackerItem?
    let textItem: WidgetTrackerItem?

    var body: some View {
        HStack(spacing: 12) {
            LiveSnapshotTileWidgetView(item: snapshotItem)
                .frame(width: 142)

            SingleBigNumberWidgetView(item: textItem)
                .padding(.vertical, -8)
        }
        .padding(8)
    }
}

struct SnapshotImageView: View {
    let item: WidgetTrackerItem?
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let image = item?.snapshotImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text("No snapshot")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct SnapshotOverlay: View {
    let item: WidgetTrackerItem?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(item?.status == .broken ? Color.red : (item?.status == .ok ? Color.green : Color.orange))
                .frame(width: 6, height: 6)
            Text(item?.title ?? "Snapshot")
                .lineLimit(1)
            Text(item?.updatedText ?? "")
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .padding(6)
    }
}

private struct GaugeRingWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(spacing: 8) {
            Gauge(value: gaugeValue, in: 0...1) {
                Text(item?.title ?? "Tracker")
            } currentValueLabel: {
                Text(item?.value ?? "--")
                    .font(.caption.weight(.semibold))
                    .minimumScaleFactor(0.5)
                    .numericValueTransition()
            }
            .gaugeStyle(.accessoryCircular)
            .tint(gaugeTint)
            .frame(width: 92, height: 92)

            Text(item?.title ?? "Tracker")
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    }

    private var gaugeValue: Double {
        guard let numeric = item?.numeric else {
            return 0
        }

        return min(max(numeric / 100, 0), 1)
    }

    private var gaugeTint: Color {
        switch gaugeValue {
        case ..<0.7:
            return .green
        case ..<0.9:
            return .orange
        default:
            return .red
        }
    }
}

private struct HeadlineSparklineWidgetView: View {
    let item: WidgetTrackerItem?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item?.title ?? "Tracker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item?.value ?? "--")
                    .font(.system(size: 50, weight: .semibold, design: .rounded))
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .numericValueTransition()
                Text(item?.updatedText ?? "not updated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SparklineView(values: item?.sparkline ?? [], tint: item?.accent ?? .accentColor)
                .frame(width: 130, height: 90)
        }
        .padding(14)
    }
}

private struct Dashboard3UpWidgetView: View {
    let items: [WidgetTrackerItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .numericValueTransition()
                    SparklineView(values: item.sparkline, tint: item.accent)
                        .frame(height: 24)
                    Text(item.updatedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if index < items.count - 1 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 14)
    }
}

struct SparklineView: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        SparklineShape(values: values)
            .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .background(
                SparklineShape(values: values)
                    .fill(tint.opacity(0.12))
            )
    }
}

private struct SparklineShape: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        guard values.count > 1,
              let minValue = values.min(),
              let maxValue = values.max(),
              minValue != maxValue else {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }

        let spread = maxValue - minValue
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1)
            let y = rect.maxY - rect.height * CGFloat((value - minValue) / spread)
            let point = CGPoint(x: x, y: y)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

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
