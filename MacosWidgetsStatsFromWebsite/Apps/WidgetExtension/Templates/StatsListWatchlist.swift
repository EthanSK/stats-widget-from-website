//
//  StatsListWatchlist.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Large Text watchlist template.
//

import SwiftUI

struct StatsListWatchlistTemplate: View {
    let items: [WidgetTrackerItem]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.prefix(6).enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(item.accent)
                        .frame(width: 5, height: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(item.updatedText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    SparklineView(values: item.sparkline, tint: item.accent)
                        .frame(width: 42, height: 18)
                    Text(item.value)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .numericValueTransition()
                        .foregroundStyle(item.gradientColor ?? .primary)
                        .frame(width: 86, alignment: .trailing)
                }
                .frame(height: 50)

                if index < min(items.count, 6) - 1 {
                    Divider()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .widgetRefreshOverlay(trackerIDs: items.prefix(6).map(\.tracker.id))
        .accessibilityElement(children: .contain)
    }
}
