//
//  RenderMode.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Text or snapshot tracker rendering mode.
//

enum RenderMode: String, CaseIterable, Codable, Identifiable {
    case text
    case snapshot

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .text:
            return "Text"
        case .snapshot:
            return "Snapshot"
        }
    }

    var defaultRefreshIntervalSec: Int {
        switch self {
        case .text:
            // v0.21.0 — bumped default from 5 min → 30 min to stay
            // under WidgetKit's ~40-70 reload/day budget for non-
            // foreground apps. The previous 5-min default = 288
            // reloads/day, well over budget; chronod started silently
            // throttling timeline reloads on macOS 26. Users who want
            // a faster cadence can still set a custom interval in the
            // tracker editor, but the floor on widget repaints is
            // chosen by WidgetKit, not us.
            return 1800
        case .snapshot:
            return 2
        }
    }
}
