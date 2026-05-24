//
//  AppGroupPaths.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Typed paths for canonical and App Group configuration files.
//

import Foundation

enum AppGroupPaths {
    static let identifier = "T34G959ZG8.group.com.ethansk.macos-widgets-stats-from-website"
    // Application Support directory name — DELIBERATELY UNCHANGED in
    // v0.21.22 even though the user-facing .app wrapper was renamed to
    // "Stats Widget from Website.app". Reason: this directory holds
    // EXISTING user data (trackers.json, readings.json, activity.log,
    // selector packs, MCP sockets, logs, etc.) that must remain readable
    // after the rename ceremony — renaming the directory would orphan
    // every existing install's data and look like silent data loss. The
    // App Group identifier (`group.com.ethansk.macos-widgets-stats-from-website`)
    // and the legacy `~/Library/Application Support/macOS Widgets Stats
    // from Website/` directory are internal stability identifiers; only
    // the .app wrapper directory name + UX strings + WidgetKit display
    // name were changed. See voice 4002 / MBP-CC bridge msg-65036391.
    //
    // If a future major version wants to migrate this directory, a
    // dedicated AppGroupPaths migrator would need to:
    //   1. Detect the legacy directory exists.
    //   2. Copy contents to the new directory.
    //   3. Persist a "migrated" sentinel.
    //   4. Optionally leave the legacy directory as a fallback for
    //      sibling tools that still read from it (e.g. CLI helpers).
    // Don't do that lightly — v0.21.22 is intentionally a UX-only rename.
    static let applicationSupportDirectoryName = "macOS Widgets Stats from Website"
    static let trackersFileName = "trackers.json"
    static let readingsFileName = "readings.json"
    static let activityLogFileName = "activity.log"
    static let mcpSocketFileName = "mcp.sock"
    private static let testContainerEnvironmentKey = "MACOS_WIDGETS_STATS_TEST_CONTAINER"

    private static func testContainerURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment[testContainerEnvironmentKey],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func sharedContainerURL() -> URL? {
        testContainerURL() ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func canonicalApplicationSupportURL() -> URL {
        if let testContainerURL = testContainerURL() {
            return testContainerURL
        }

        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func canonicalTrackersURL() -> URL {
        canonicalApplicationSupportURL().appendingPathComponent(trackersFileName, isDirectory: false)
    }

    static func appGroupTrackersURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(trackersFileName, isDirectory: false)
    }

    static func appGroupReadingsURL() -> URL? {
        sharedContainerURL()?.appendingPathComponent(readingsFileName, isDirectory: false)
    }

    static func logsDirectoryURL() -> URL {
        if let sharedContainerURL = sharedContainerURL() {
            return sharedContainerURL.appendingPathComponent("Logs", isDirectory: true)
        }

        let baseURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return baseURL
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    static func activityLogURL() -> URL {
        logsDirectoryURL().appendingPathComponent(activityLogFileName, isDirectory: false)
    }


    static func mcpApplicationSupportURL() -> URL {
        if let sharedContainerURL = sharedContainerURL() {
            return sharedContainerURL
        }

        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("MacosWidgetsStatsFromWebsite", isDirectory: true)
    }

    static func mcpSocketURL() -> URL {
        mcpApplicationSupportURL().appendingPathComponent(mcpSocketFileName, isDirectory: false)
    }
}
