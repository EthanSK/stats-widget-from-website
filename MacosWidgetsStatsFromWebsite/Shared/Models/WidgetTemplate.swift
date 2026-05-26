//
//  WidgetTemplate.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  v0.1 stub — see PLAN.md §9 for the full design.
//

// v0.21.41 — Drastic simplification per Ethan voice 4206.
//
// Before v0.21.41 this enum had 12 template variants (sparkline, gauge,
// dashboard, snapshot tile, mega-grid, etc.). Voice 4206 quote:
//   "for the templates, the widget templates, I feel like a bunch of
//    them can go like the trend lines. Most of them can go. Let's just
//    keep the number. Actually, just get rid of templates entirely.
//    There's literally no no need at all."
//
// We collapsed the model to ONE template: `.singleBigNumber`. We keep
// the enum + raw value so existing trackers.json files that previously
// stored "number-plus-sparkline", "gauge-ring", etc. continue to decode
// without crashing — but the decoder coerces every value to
// `.singleBigNumber` (see `init(from:)` below). This is the safest
// backcompat path: no user re-configuration required, no orphaned
// widget configurations.
//
// IMPORTANT: WidgetKit `kind:` ID ("MacosWidgetsStatsFromWebsite") is
// UNCHANGED so existing placed widgets re-pair with the extension after
// the update. See StatsWidget.swift `kind` definition + the v0.21.22
// notes in project.yml for the broader "never break the kind ID" rule.
enum WidgetTemplate: String, CaseIterable, Codable {
    case singleBigNumber = "single-big-number"

    /// Custom Decodable: any legacy template raw value from a pre-v0.21.41
    /// trackers.json file (e.g. "gauge-ring", "dashboard-3-up") silently
    /// coerces to `.singleBigNumber`. Without this override the default
    /// synthesized decoder would `throw DecodingError.dataCorrupted` on the
    /// first unknown raw value and the whole WidgetConfiguration would fail
    /// to load — orphaning every existing widget. Backcompat-critical.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        // Map any known/unknown legacy value to the only surviving case.
        self = WidgetTemplate(rawValue: raw) ?? .singleBigNumber
    }
}

extension WidgetTemplate {
    var displayName: String {
        // Single template — but keep the property for any UI/MCP consumer
        // that still references it. Always reads "Single Big Number".
        switch self {
        case .singleBigNumber:
            return "Single Big Number"
        }
    }

    /// Always `.small` post-v0.21.41 — we only ship the small widget family.
    /// Medium / large / extraLarge sizes were dropped per voice 4206.
    var size: WidgetConfigurationSize {
        switch self {
        case .singleBigNumber:
            return .small
        }
    }

    /// Single tracker slot. Multi-slot templates (dashboard, watchlist,
    /// dual-compare) were removed in v0.21.41 — the single-big-number
    /// template only renders one tracker at a time.
    var slotCount: ClosedRange<Int> {
        switch self {
        case .singleBigNumber:
            return 1...1
        }
    }

    /// `.single` layout — only one slot, no grid/stack arrangement needed.
    var defaultLayout: WidgetConfigurationLayout {
        switch self {
        case .singleBigNumber:
            return .single
        }
    }
}

extension WidgetConfigurationSize {
    var displayName: String {
        switch self {
        case .small:
            return "Small"
        case .medium:
            return "Medium"
        case .large:
            return "Large"
        case .extraLarge:
            return "Extra Large"
        }
    }
}

extension WidgetConfigurationLayout {
    var displayName: String {
        switch self {
        case .grid:
            return "Grid"
        case .stack:
            return "Stack"
        case .single:
            return "Single"
        }
    }
}
