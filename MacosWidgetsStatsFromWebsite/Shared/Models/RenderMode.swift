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
            // Default 5 min so newly-added trackers feel responsive
            // (per Ethan 2026-05-11). Background scheduler floor is 60s.
            return 300
        case .snapshot:
            return 2
        }
    }
}
