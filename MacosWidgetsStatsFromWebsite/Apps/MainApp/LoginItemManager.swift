//
//  LoginItemManager.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.21.0 — wraps macOS 13+ ServiceManagement SMAppService.mainApp so
//  the user can opt the app into auto-start at login from the menu-bar
//  dropdown. Replaces the implicit "LaunchAgent fires regardless of
//  whether the user wants it" model in 0.19–0.20.
//
//  ServiceManagement notes:
//    - SMAppService.mainApp registers the .app bundle itself (not a
//      helper) as a login item. macOS surfaces it under System Settings
//      > General > Login Items, where the user has the final say.
//    - First-time `register()` calls can throw if the user has denied
//      the app's Login Items entry. The thrown error is surfaced to the
//      caller; the menu-bar UI logs it and leaves the toggle off.
//    - `status` returns `.requiresApproval` when the user has not yet
//      acknowledged the prompt. We treat that as "not enabled" for the
//      menu toggle since macOS hasn't actually wired it up yet.
//

import Foundation
import ServiceManagement

enum LoginItemManager {
    /// Returns whether the main app is currently registered as a login
    /// item AND has been approved by the user. `.requiresApproval` is
    /// counted as NOT-enabled so the menu toggle doesn't lie about
    /// activation state.
    static func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns whether the user has been prompted but not yet decided.
    /// Surfaces to the menu UI so we can show "(needs approval)" text.
    static func requiresApproval() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// Enables or disables login-at-startup. Throws if SMAppService
    /// rejects the change (e.g. user has the entry disabled in System
    /// Settings).
    static func setEnabled(_ enabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw LoginItemError.unsupportedOSVersion
        }
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    enum LoginItemError: LocalizedError {
        case unsupportedOSVersion

        var errorDescription: String? {
            switch self {
            case .unsupportedOSVersion:
                return "Launch at login requires macOS 13 (Ventura) or newer."
            }
        }
    }
}
