//
//  SchemaVersion.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Current configuration schema version.
//

// v5 (0.21.9): added Tracker.secondaryElements + TrackerReading.secondaryValues
// + WidgetConfiguration.secondaryElementIDsBySlot. All three are backcompat-
// safe (decode missing keys as empty), so v4 files migrate transparently —
// the version bump just signals the schema landed at decode time, and lets
// future migrations branch on the version.
let currentSchemaVersion = 5
