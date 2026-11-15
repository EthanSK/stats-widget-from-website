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

    static var isUsingTestContainerOverride: Bool {
        testContainerURL() != nil
    }

    // v0.21.89 restores the host's membership of this TEAM-ID-prefixed
    // macOS group, matching the widget and Debug host. Apple permits this
    // naming scheme without a provisioning profile; the old v0.21.31
    // experiment removed app groups AND Keychain Access Groups together.
    // Removing only the latter avoids its AMFI profile requirement.
    // Native membership also satisfies macOS 15+ app-data protection,
    // which applies even though the host is unsandboxed. A hand-built
    // path alone cannot grant access to that protected folder.
    // Keep the manual path fallback for existing migration/dev callers;
    // it preserves the location but cannot replace native authorization.
    // https://developer.apple.com/documentation/xcode/accessing-app-group-containers
    static func sharedContainerURL() -> URL? {
        if let testContainerURL = testContainerURL() {
            return testContainerURL
        }
        if let entitledContainerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) {
            return entitledContainerURL
        }
        // Compatibility fallback: preserve the established directory when
        // native resolution is unavailable. App-data protection still
        // applies; this does not bypass missing group membership.
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

    // v0.21.39 — MCP socket path moved out of the Group Container.
    //
    // BUG (silent since v0.21.0): the previous socket location lived under
    //   ~/Library/Group Containers/T34G959ZG8.group.com.ethansk.macos-widgets-stats-from-website/mcp.sock
    // which is 122 bytes — well over the macOS Unix-domain `sun_path` cap
    // of 104 bytes (sys/un.h: `char sun_path[104]`). Every host launch since
    // v0.21.0 was hitting `socket_path_too_long` in MCPServer.runSocketServer()
    // and silently failing to bind. The MCP log under
    //   ~/Library/Logs/macOS Widgets Stats from Website/mcp.log
    // has been logging this error continuously for months (every host
    // launch + every reload). Result: ALL external MCP-over-socket access
    // has been broken since v0.21.0. Stdio mode (`--mcp-stdio`) still works
    // because it bypasses the bind entirely. See LEARNINGS.md for the full
    // arc.
    //
    // Fix: route the socket through NSTemporaryDirectory() which on macOS
    // resolves to the per-user darwin-userspace tmp dir
    //   /var/folders/<XX>/<YY>/T/
    // i.e. ~49 bytes. Adding `mcp.sock` (8 bytes) lands at ~57 bytes total —
    // well under the 104 cap with headroom for unusually-long user UUIDs.
    // The dir is per-user and inherits the same posix permissions as the
    // current process (effectively 0700 for the user), so an unprivileged
    // attacker on the same machine still can't pre-create a spoofed socket.
    //
    // We DELIBERATELY do NOT relocate the App Group Container itself — that
    // dir holds user data (trackers.json, readings.json, logs) and renaming
    // it would orphan every install's state. Only the socket — which is
    // ephemeral, recreated on every launch, and not user-visible — moves.
    static func mcpSocketURL() -> URL {
        if let testContainerURL = testContainerURL() {
            return testContainerURL.appendingPathComponent(mcpSocketFileName, isDirectory: false)
        }

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return tmpDir.appendingPathComponent(mcpSocketFileName, isDirectory: false)
    }
}
