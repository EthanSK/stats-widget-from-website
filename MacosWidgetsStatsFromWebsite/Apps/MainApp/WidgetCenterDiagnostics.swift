//
//  WidgetCenterDiagnostics.swift
//  MacosWidgetsStatsFromWebsite
//
//  Logs WidgetKit reload context before calling WidgetCenter so duplicate
//  same-bundle app processes are visible in activity.log.
//

import AppKit
import Foundation
import WidgetKit

enum WidgetCenterDiagnostics {
    static let widgetKind = "MacosWidgetsStatsFromWebsite"

    static func reloadTimelines(ofKind kind: String = widgetKind, reason: String) {
        guard !AppGroupPaths.isUsingTestContainerOverride else {
            log("skipped WidgetCenter.reloadTimelines for isolated test container", reason: reason, kind: kind)
            return
        }

        log("WidgetCenter.reloadTimelines", reason: reason, kind: kind)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func reloadAllTimelines(reason: String) {
        guard !AppGroupPaths.isUsingTestContainerOverride else {
            log("skipped WidgetCenter.reloadAllTimelines for isolated test container", reason: reason, kind: "all")
            return
        }

        log("WidgetCenter.reloadAllTimelines", reason: reason, kind: "all")
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func log(_ message: String, reason: String, kind: String) {
        let bundle = Bundle.main
        let bundleIdentifier = bundle.bundleIdentifier ?? AppDelegate.mainBundleIdentifier
        let sameBundleApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        let runningPaths = sameBundleApps
            .map { app in
                "\(app.processIdentifier):\(app.bundleURL?.path ?? "<unknown>")"
            }
            .joined(separator: "|")

        ActivityLogger.log("widget-reload", message, metadata: [
            "reason": reason,
            "kind": kind,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "bundleID": bundleIdentifier,
            "bundlePath": bundle.bundleURL.path,
            "version": (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "build": (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown",
            "sameBundleRunningApps": runningPaths
        ])
    }
}
