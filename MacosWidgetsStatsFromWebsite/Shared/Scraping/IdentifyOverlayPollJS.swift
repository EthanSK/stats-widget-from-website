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
    // v0.21.77 — banner now has TWO states, gated by a "Start" button.
    //
    // Why: pre-v0.21.77 the overlay armed click-to-pick the instant it
    // injected. That broke any flow where the user needed to log in,
    // dismiss a cookie banner, scroll, or otherwise navigate first —
    // their FIRST click on the page was eaten as the element pick,
    // typically capturing a login form / cookie button / wrong page.
    //
    // The fix gates inspection behind an explicit "Start" button on the
    // banner. Pre-Start the overlay is PASSIVE (banner visible + Start
    // button clickable, but the page itself receives all hover / click
    // / scroll events normally). Post-Start the existing behavior kicks
    // in (hover-highlight outline + click-to-pick + Esc-to-cancel).
    //
    // `bannerText` is now the POST-Start text (the existing prompt).
    // `prepareBannerText` is the new PRE-Start text shown until the user
    // clicks Start. Two-step copy lets us be explicit at each stage
    // without overloading either message.
    //
    // Both strings are rendered into the inject-JS via
    // `javaScriptStringLiteral` (JSON-encoded so quotes / backslashes
    // are safe inside the source-level JS literal).

    /// PRE-Start banner copy: tells the user to log in / navigate first,
    /// then press the Start button on the banner to begin picking.
    static func prepareBannerText(contextLabel: String?) -> String {
        let label = trimmedLabel(from: contextLabel)
        // Keep the line compact — Telegram-style: caveman-compressed,
        // every word earns its place. The Start button on the banner is
        // the visual call-to-action; the prose just gives context.
        if label.isEmpty {
            return "Log in or navigate to the right page, then press Start to pick the element."
        }
        return "Log in or navigate, then press Start to identify \"\(label)\"."
    }

    /// POST-Start banner copy: same prompt we've shipped since v0.21.48,
    /// but the contextLabel-less variant drops the leading "Identify
    /// Element —" prefix because the banner already established context
    /// pre-Start and the user has already pressed Start (i.e. they know
    /// what mode they're in). For the labelled variant we keep the
    /// existing exact string because IdentifyElementRegressionTests
    /// pins it (see `testInspectOverlayBannerIncludesTrackerName`).
    static func bannerText(contextLabel: String?) -> String {
        let label = trimmedLabel(from: contextLabel)
        guard !label.isEmpty else {
            return "Identify Element — hover the value you want, click to capture, or press Esc to cancel."
        }

        return "Identify Element for \"\(label)\" — hover the value you want, click to capture, or press Esc to cancel."
    }

    /// Shared label-normaliser: strips whitespace / newlines and
    /// collapses runs of internal whitespace to a single space. Used by
    /// both bannerText variants so a tracker named "  chatgpt\n " gives
    /// the same output in both pre- and post-Start copy.
    private static func trimmedLabel(from contextLabel: String?) -> String {
        contextLabel?
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func javaScriptStringLiteral(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }

        return "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
