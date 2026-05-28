//
//  IdentifyOverlayPollJS.swift
//  MacosWidgetsStatsFromWebsite
//
//  JavaScript used by the Identify-in-Chromium coordinator to read picker state.
//

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
