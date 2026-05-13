//
//  SingleBigNumber.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Small Text template with one hero value.
//

import SwiftUI

struct SingleBigNumberTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tracker names like "claude weekly usage" don't fit in one line of
            // .caption2 in a systemSmall widget, so we allow up to 2 lines with
            // a modest minimumScaleFactor as a final fallback for very long
            // labels. Single-line names still render identically.
            Text(item?.title ?? "Tracker")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)

            Text(item?.value ?? "--")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .numericValueTransition()
                .minimumScaleFactor(0.45)
                .lineLimit(1)
                .foregroundStyle(statusColor)
                .frame(maxWidth: .infinity, alignment: .center)

            Spacer(minLength: 0)

            HStack(spacing: 4) {
                Image(systemName: item?.status == .ok ? "arrow.clockwise" : "exclamationmark.triangle.fill")
                Text(footerText)
                    .lineLimit(1)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .widgetRefreshOverlay(trackerID: item?.tracker.id)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(item?.title ?? "Tracker"), \(item?.value ?? "no value"), updated \(item?.updatedText ?? "never")"))
    }

    private var statusColor: Color {
        // Broken/stale states take precedence — surfacing a green or red
        // gradient color on a broken tracker would lie about its health.
        switch item?.status {
        case .broken:
            return .red
        case .stale, nil:
            return .secondary
        case .ok:
            // gradientColor is nil when the tracker has `.none` or no numeric
            // reading, in which case we fall back to the default primary
            // text color — preserving existing behavior for older trackers.
            return item?.gradientColor ?? .primary
        }
    }

    private var footerText: String {
        // Surface a short, actionable hint when the tracker is broken so users
        // know to re-identify the element rather than wondering why the value
        // is missing. Falls back to the relative-update timestamp otherwise.
        if item?.status == .broken {
            return "Selector needs re-identifying"
        }
        return item?.updatedText ?? "not updated"
    }
}
