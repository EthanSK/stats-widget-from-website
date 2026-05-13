//
//  GradientColor.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Smooth green → yellow → red color interpolation for text-style widget
//  numeric values, gated by `Tracker.gradientMode`. Lives in Shared/Models
//  so both the main app (preview / list-row colored chip) and the widget
//  extension (the actual hero number) compute identical colors.
//

import SwiftUI

enum GradientColor {
    /// HSL-space interpolation between three reference stops:
    ///   0   = green  (#22c55e)
    ///   50  = yellow (#facc15)
    ///   100 = red    (#ef4444)
    ///
    /// We interpolate hue directly (green ≈ 142°, yellow ≈ 50°, red ≈ 0°)
    /// and use fixed saturation + lightness pulled from the Tailwind 500
    /// shades for visual consistency with the rest of macOS-style UIs.
    /// Direct HSL hue interpolation gives a perceptually smoother sweep
    /// than RGB lerp (RGB would muddy through brown around the midpoint).
    ///
    /// - Parameters:
    ///   - numeric: Parsed reading value. Clamped 0..100 before mapping.
    ///   - mode: GradientMode from the tracker config. `.none` returns nil.
    /// - Returns: SwiftUI Color to apply via `.foregroundStyle(...)`, or nil
    ///   for the caller to fall back to the existing default text color.
    static func color(numeric: Double?, mode: GradientMode) -> Color? {
        guard mode != .none, let raw = numeric else {
            return nil
        }

        // Clamp negative + >100 readings so e.g. "150% capacity" still maps
        // to fully-red rather than wrapping past red into purple territory.
        let clamped = max(0.0, min(100.0, raw))

        // For `.highIsGood` we invert the position on the gradient so high
        // values land on the green end instead of red. Single mapping
        // function keeps the math + hue stops in one place.
        let position: Double
        switch mode {
        case .highIsBad:
            position = clamped / 100.0
        case .highIsGood:
            position = 1.0 - (clamped / 100.0)
        case .none:
            return nil
        }

        return interpolate(position: position)
    }

    /// Three-stop hue interpolation, `position` in [0, 1]:
    ///   0.0 → green (hue 142°)
    ///   0.5 → yellow (hue 50°)
    ///   1.0 → red (hue 0°)
    /// Saturation + brightness are constant so the gradient reads as a pure
    /// hue sweep rather than darkening/lightening as it crosses midpoint.
    private static func interpolate(position: Double) -> Color {
        // Hue endpoints (degrees) — pulled from Tailwind-500 swatches so they
        // sit at "vivid but not retina-burning" intensity.
        let greenHue: Double = 142.0
        let yellowHue: Double = 50.0
        let redHue: Double = 0.0

        let hue: Double
        if position < 0.5 {
            let t = position / 0.5
            hue = greenHue + (yellowHue - greenHue) * t
        } else {
            let t = (position - 0.5) / 0.5
            hue = yellowHue + (redHue - yellowHue) * t
        }

        // SwiftUI Color takes hue 0..1, not degrees.
        return Color(hue: hue / 360.0, saturation: 0.72, brightness: 0.85)
    }
}
