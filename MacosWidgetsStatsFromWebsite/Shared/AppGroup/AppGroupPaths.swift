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

    // v0.21.31 (post-AMFI fix): the HOST app no longer carries the
    // `com.apple.security.application-groups` entitlement at runtime. AMFI
    // treats `application-groups` as a restricted entitlement on macOS
    // Sonoma+ and requires an embedded Developer ID provisioning profile to
    // validate it; Developer-ID distribution channels (Sparkle) historically
    // ship profile-free, which left v0.21.30 in a state where amfid emitted
    //   "Restricted entitlements not validated, bailing out. Error: Code=-413"
    //   "Disallowing com.ethansk.macos-widgets-stats-from-website because no
    //    eligible provisioning profiles found"
    // and SIGKILL'd every launch attempt on systems that hadn't already
    // cached an older signed copy.
    //
    // Mitigation chosen (smallest blast radius): remove the restricted
    // entitlements from the HOST .app entitlements file and resolve the
    // shared-container path manually here. The host is unsandboxed in
    // Release (see MacosWidgetsStatsFromWebsite.entitlements:
    // `com.apple.security.app-sandbox = false`), so it has direct
    // filesystem access to `~/Library/Group Containers/<id>/` — the same
    // directory the SANDBOXED widget extension reaches via the
    // `forSecurityApplicationGroupIdentifier` API. The widget keeps its
    // entitlement (its sandbox MUST go through the API), so writes from
    // both sides land in the same directory and the data still shares.
    //
    // Order of preference:
    //   1. Test override (`MACOS_WIDGETS_STATS_TEST_CONTAINER` env var).
    //   2. Genuine container vended by the security API — works whenever
    //      the running process DOES have the entitlement (i.e. the widget
    //      appex). Returns nil for the host.
    //   3. Manual `~/Library/Group Containers/<identifier>/` reconstruction,
    //      with `mkdir -p` so the host's first launch doesn't crash on the
    //      missing directory. This branch is what the host hits in v0.21.31+
    //      and is also a safety net if the widget ever loses its entitlement
    //      for any reason.
    static func sharedContainerURL() -> URL? {
        if let testContainerURL = testContainerURL() {
            return testContainerURL
        }
        if let entitledContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) {
            return entitledContainerURL
        }
        // Manual fallback: build the well-known Group Containers path. On
        // macOS this is `~/Library/Group Containers/<team-id>.group.<bundle>/`.
        // The unsandboxed host can read+write this directory directly even
        // without the entitlement, and the (sandboxed) widget extension
        // reaches the same physical path through the security API.
        let manualURL = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
        // Ensure the directory exists so callers that immediately write
        // (e.g. activity.log, readings.json) don't fail on first launch.
        // mkdir -p semantics — failure here is non-fatal; the caller will
        // surface a more specific error if/when its write fails.
        try? FileManager.default.createDirectory(
            at: manualURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        return manualURL
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
