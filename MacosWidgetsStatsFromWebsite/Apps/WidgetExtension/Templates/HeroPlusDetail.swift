//
//  HeroPlusDetail.swift
//  MacosWidgetsStatsFromWebsiteWidget
//
//  Large Text template with hero value, chart, and summary stats.
//

import SwiftUI

struct HeroPlusDetailTemplate: View {
    let item: WidgetTrackerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item?.title ?? "Tracker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(item?.value ?? "--")
                    .font(.system(size: 70, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                    .numericValueTransition()
                    .trackerGradientStyle(item)
                // v0.21.9: secondary text(s) bound to slot 0 (this template
                // is single-slot). Hidden when nothing is bound.
                if let secondary = item?.secondaryTextJoined {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            SparklineView(values: item?.sparkline ?? [], tint: item?.accent ?? .accentColor)
                .frame(height: 92)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                DetailCell(title: "Low", value: formatted(minValue))
                DetailCell(title: "High", value: formatted(maxValue))
                DetailCell(title: "Avg", value: formatted(averageValue))
                DetailCell(title: "Now", value: item?.value ?? "--")
            }
        }
        .padding(16)
        .widgetRefreshOverlay(trackerID: item?.tracker.id)
        .accessibilityElement(children: .contain)
    }

    private var values: [Double] {
        item?.sparkline ?? []
    }

    private var minValue: Double? {
        values.min()
    }

    private var maxValue: Double? {
        values.max()
    }

    private var averageValue: Double? {
        guard !values.isEmpty else {
            return nil
        }

        return values.reduce(0, +) / Double(values.count)
    }

    private func formatted(_ value: Double?) -> String {
        guard let value else {
            return "--"
        }

        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}

private struct DetailCell: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .numericValueTransition()
        }
        .frame(maxWidth: .infinity)
    }
}
