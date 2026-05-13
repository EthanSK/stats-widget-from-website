//
//  HeadlineSparkline.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Medium Text template with a wide trend chart.
//

import SwiftUI

struct HeadlineSparklineTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item?.title ?? "Tracker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item?.value ?? "--")
                    .font(.system(size: 50, weight: .semibold, design: .rounded))
                    .numericValueTransition()
                    .minimumScaleFactor(0.45)
                    .lineLimit(1)
                    .foregroundStyle(item?.gradientColor ?? .primary)
                Text(item?.updatedText ?? "not updated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SparklineView(values: item?.sparkline ?? [], tint: item?.accent ?? .accentColor)
                .frame(width: 130, height: 90)
        }
        .padding(14)
        .widgetRefreshOverlay(trackerID: item?.tracker.id)
        .accessibilityElement(children: .combine)
    }
}
