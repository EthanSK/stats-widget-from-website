//
//  Dashboard3Up.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Medium Text template with three equal columns.
//

import SwiftUI

struct Dashboard3UpTemplate: View {
    let items: [WidgetTrackerItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(item.value)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .numericValueTransition()
                        .foregroundStyle(item.gradientColor ?? .primary)
                    SparklineView(values: item.sparkline, tint: item.accent)
                        .frame(height: 24)
                    Text(item.updatedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if index < min(items.count, 3) - 1 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 14)
        .widgetRefreshOverlay(trackerIDs: items.prefix(3).map(\.tracker.id))
        .accessibilityElement(children: .contain)
    }
}
