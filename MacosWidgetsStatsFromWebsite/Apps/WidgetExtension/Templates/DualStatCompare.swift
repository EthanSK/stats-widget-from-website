//
//  DualStatCompare.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Medium Text template for two trackers.
//

import SwiftUI

struct DualStatCompareTemplate: View {
    let items: [WidgetTrackerItem]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.prefix(2).enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.accent)
                            .frame(width: 7, height: 7)
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(item.value)
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .numericValueTransition()
                        .foregroundStyle(item.gradientColor ?? .primary)
                    SparklineView(values: item.sparkline, tint: item.accent)
                        .frame(height: 28)
                    Text(item.updatedText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

                if index == 0 {
                    Divider()
                }
            }
        }
        .padding(.vertical, 12)
        .widgetRefreshOverlay(trackerIDs: items.prefix(2).map(\.tracker.id))
        .accessibilityElement(children: .contain)
    }
}
