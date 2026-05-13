//
//  NumberPlusSparkline.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Small Text template with one value and compact history.
//

import SwiftUI

struct NumberPlusSparklineTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item?.title ?? "Tracker")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item?.value ?? "--")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .numericValueTransition()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(item?.gradientColor ?? .primary)
            SparklineView(values: item?.sparkline ?? [], tint: item?.accent ?? .accentColor)
                .frame(height: 34)
            Text(item?.updatedText ?? "not updated")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .widgetRefreshOverlay(trackerID: item?.tracker.id)
        .accessibilityElement(children: .combine)
    }
}
