//
//  MegaDashboardGrid.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Extra Large mixed dashboard template.
//

import SwiftUI

struct MegaDashboardGridTemplate: View {
    let items: [WidgetTrackerItem]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(items.prefix(8)) { item in
                if item.tracker.renderMode == .snapshot {
                    LiveSnapshotTileTemplate(item: item)
                        .frame(height: 138)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(item.accent)
                                .frame(width: 7, height: 7)
                            Text(item.title)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(item.value)
                            .font(.system(size: 28, weight: .semibold, design: .rounded))
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
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(12)
        .widgetRefreshOverlay(trackerIDs: items.prefix(8).map(\.tracker.id))
        .accessibilityElement(children: .contain)
    }
}
