//
//  WidgetConfiguration.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Widget composition configuration persisted with trackers.
//

import Foundation

struct WidgetConfiguration: Codable, Identifiable {
    var id: UUID
    var name: String
    var templateID: WidgetTemplate
    var size: WidgetConfigurationSize
    var layout: WidgetConfigurationLayout
    var trackerIDs: [UUID]
    var showSparklines: Bool
    var showLabels: Bool
    /// Per-slot secondary-element bindings (v0.21.9, Ethan voice 3797).
    /// Maps a slot index (as a string for JSON friendliness) to an ordered
    /// list of secondary `TrackerElement.id`s on the tracker bound to that
    /// slot. The widget renders these as "secondary text" beside the main
    /// value — e.g. for "claude weekly usage 73%" the user can bind the
    /// "resets in 4d" secondary element to slot 0 and see both at once.
    /// Default empty for every existing widget config; new widgets get an
    /// empty map and only populate it when the user explicitly picks a
    /// secondary element in the editor. Backcompat-critical: missing key
    /// or empty list = no secondary text rendered, identical to pre-v0.21.9.
    var secondaryElementIDsBySlot: [String: [UUID]]

    init(
        id: UUID = UUID(),
        name: String,
        templateID: WidgetTemplate,
        size: WidgetConfigurationSize = .small,
        layout: WidgetConfigurationLayout = .single,
        trackerIDs: [UUID] = [],
        showSparklines: Bool = true,
        showLabels: Bool = true,
        secondaryElementIDsBySlot: [String: [UUID]] = [:]
    ) {
        self.id = id
        self.name = name
        self.templateID = templateID
        self.size = size
        self.layout = layout
        self.trackerIDs = trackerIDs
        self.showSparklines = showSparklines
        self.showLabels = showLabels
        self.secondaryElementIDsBySlot = secondaryElementIDsBySlot
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        templateID = try container.decodeIfPresent(WidgetTemplate.self, forKey: .templateID) ?? .singleBigNumber
        size = try container.decodeIfPresent(WidgetConfigurationSize.self, forKey: .size) ?? .small
        layout = try container.decodeIfPresent(WidgetConfigurationLayout.self, forKey: .layout) ?? .single
        trackerIDs = try container.decodeIfPresent([UUID].self, forKey: .trackerIDs) ?? []
        showSparklines = try container.decodeIfPresent(Bool.self, forKey: .showSparklines) ?? true
        showLabels = try container.decodeIfPresent(Bool.self, forKey: .showLabels) ?? true
        // secondaryElementIDsBySlot added in 0.21.9 — default empty.
        secondaryElementIDsBySlot = try container.decodeIfPresent([String: [UUID]].self, forKey: .secondaryElementIDsBySlot) ?? [:]
    }

    /// Convenience: secondary element IDs for a slot, or [] if none bound.
    func secondaryElementIDs(forSlot slotIndex: Int) -> [UUID] {
        secondaryElementIDsBySlot[String(slotIndex)] ?? []
    }
}

enum WidgetConfigurationSize: String, Codable, CaseIterable {
    case small
    case medium
    case large
    case extraLarge
}

enum WidgetConfigurationLayout: String, Codable, CaseIterable {
    case grid
    case stack
    case single
}
