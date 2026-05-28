//
//  IdentifyOverlayPollJS.swift
//  MacosWidgetsStatsFromWebsite
//
//  JavaScript used by the Identify-in-Chromium coordinator to read picker state.
//

import Foundation

enum IdentifyOverlayPollJS {
    static let pollScript = """
    (() => ({
      picked: window.__statsWidgetPicked || null,
      error: window.__statsWidgetInspectError || null,
      canceled: !!window.__statsWidgetInspectCanceled,
      active: !!window.__statsWidgetInspectCleanup
        && !!document.querySelector('[data-stats-widget-inspect-banner]')
        && !!document.querySelector('[data-stats-widget-inspect-outline]')
    }))()
    """
}

enum IdentifyOverlayBanner {
    static func bannerText(contextLabel: String?) -> String {
        let trimmedLabel = contextLabel?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !trimmedLabel.isEmpty else {
            return "Identify Element — hover the value you want, click to capture, or press Esc to cancel."
        }

        return "Identify Element for \"\(trimmedLabel)\" — hover the value you want, click to capture, or press Esc to cancel."
    }

    static func javaScriptStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }

        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
