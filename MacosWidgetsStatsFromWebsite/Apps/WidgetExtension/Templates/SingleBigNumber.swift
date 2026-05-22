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

            heroValueText
                .frame(maxWidth: .infinity, alignment: .center)

            // v0.21.9: secondary text(s) from any TrackerElement the user
            // bound to this slot in the widget config UI. Hidden when none
            // are selected, so single-element trackers + widgets render
            // exactly as they did pre-v0.21.9 (no extra vertical space,
            // no visual change).
            if let secondary = item?.secondaryTextJoined {
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

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

    /// Big-number text with the right foregroundStyle for the current
    /// status. We branch at the view level (instead of computing a single
    /// `ShapeStyle`) because `LinearGradient` and `Color` don't share a
    /// concrete type — we'd otherwise have to erase to `AnyShapeStyle`
    /// which still leaks vibrancy desaturation on solid colors. Branching
    /// in @ViewBuilder land keeps each branch with its native style type.
    @ViewBuilder
    private var heroValueText: some View {
        let base = Text(item?.value ?? "--")
            .font(.system(size: 48, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .numericValueTransition()
            .minimumScaleFactor(0.45)
            .lineLimit(1)

        switch item?.status {
        case .broken:
            base.foregroundStyle(Color.red)
        case .stale, nil:
            base.foregroundStyle(Color.secondary)
        case .ok:
            // Prefer the LinearGradient variant: macOS desktop widgets
            // desaturate solid Color foregroundStyles behind the vibrancy
            // material, but LinearGradient survives. Falls back to .primary
            // when the tracker has gradient disabled / no numeric reading.
            if let gradient = item?.gradientStyle {
                base.foregroundStyle(gradient)
            } else {
                base.foregroundStyle(.primary)
            }
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
