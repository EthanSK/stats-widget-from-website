//
//  TrackerResult.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Last-known tracker reading persisted in App Group readings.json.
//

import Foundation

enum TrackerStatus: String, Codable, Equatable {
    case ok
    case stale
    case broken
}

/// Classifies a tracker's last failure into a small set of user-actionable
/// buckets so the trackers-list UI can surface a concrete next step instead
/// of just a generic warning icon. Derived from `lastError` text so we don't
/// have to break the on-disk schema by piping a Swift error enum through
/// the JSON file — `lastError` already contains the LocalizedError
/// description string from each scrape failure path.
enum TrackerFailureKind {
    case loginRequired
    case selectorNotFound
    case pageTimeout
    case staleSuccess
    case other(String)

    /// Short noun phrase used as the per-row status label.
    var headline: String {
        switch self {
        case .loginRequired:
            return "Login required"
        case .selectorNotFound:
            return "Element not found"
        case .pageTimeout:
            return "Page timeout"
        case .staleSuccess:
            return "Stale"
        case .other:
            return "Error"
        }
    }

    /// Optional tappable hint shown next to the headline. Returning a
    /// non-nil string is the cue for the trackers-list row to treat the
    /// status block as interactive ("tap to re-identify"). Login-required
    /// is the only failure that's reliably user-fixable in one click, so
    /// it's the only kind that gets a tap-action hint by default.
    var actionHint: String? {
        switch self {
        case .loginRequired:
            return "Tap to re-identify"
        case .selectorNotFound:
            return "Tap to re-identify"
        case .pageTimeout, .staleSuccess, .other:
            return nil
        }
    }

    /// True when this kind benefits from re-running the Identify Element
    /// flow — i.e. the user needs to either log in inside the bundled
    /// Chromium and re-capture the selector, or pick a fresh selector.
    var benefitsFromReIdentify: Bool {
        switch self {
        case .loginRequired, .selectorNotFound:
            return true
        case .pageTimeout, .staleSuccess, .other:
            return false
        }
    }

    /// Best-effort classifier. Looks at `lastError` text for known
    /// scraper-error fingerprints (the LocalizedError descriptions in
    /// SelectorExtractionError + ScraperError) and falls back to
    /// `.staleSuccess` when the reading is stale but has no error
    /// message — i.e. the LaunchAgent never even got a chance to scrape.
    static func classify(reading: TrackerReading) -> TrackerFailureKind? {
        // OK readings never have a failure kind. The list row stays clean.
        if reading.status == .ok {
            return nil
        }

        if let message = reading.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            let lowered = message.lowercased()
            // SelectorExtractionError.loginRequired.errorDescription
            // matches "Login appears to be required …".
            if lowered.contains("login") || lowered.contains("sign in") || lowered.contains("password") {
                return .loginRequired
            }
            // SelectorExtractionError.selectorDidNotMatch / .invalidSelector
            if lowered.contains("selector did not match") || lowered.contains("selector is invalid") {
                return .selectorNotFound
            }
            // ScraperError.selectedElementHasNoText / .selectedElementHasNoVisibleRect
            if lowered.contains("selected element has no") {
                return .selectorNotFound
            }
            // ScraperError.navigationFailed("Timed out loading …")
            if lowered.contains("timed out") || lowered.contains("timeout") {
                return .pageTimeout
            }
            return .other(message)
        }

        // No lastError but status != ok ⇒ stale because the LaunchAgent
        // hasn't refreshed in time but the last reading was actually fine.
        return .staleSuccess
    }
}

struct TrackerReading: Codable, Equatable {
    var currentValue: String?
    var currentNumeric: Double?
    var snapshotPath: String?
    var snapshotCacheKey: String?
    var snapshotCapturedAt: Date?
    var lastUpdatedAt: Date?
    /// Timestamp of the most recent scrape ATTEMPT, regardless of success or
    /// failure. `lastUpdatedAt` only advances on a successful read; we need a
    /// separate field so the LaunchAgent-driven scraper (v0.19.0+) can
    /// rate-limit retries on broken trackers — without it, a tracker whose
    /// site is down would be hammered on every LaunchAgent tick.
    /// Optional for backward compatibility with older readings.json files.
    var lastAttemptedAt: Date?
    var status: TrackerStatus
    var sparkline: [Double]
    var lastError: String?
    var consecutiveFailureCount: Int?
    /// Per-secondary-element scrape results (v0.21.9+, Ethan voice 3797).
    /// Keyed by `TrackerElement.id.uuidString`. Captures the SAME scrape
    /// cycle as `currentValue` — the scraper queries every secondary
    /// element against the SAME loaded DOM, so all values share the same
    /// timestamp. Empty for trackers with no secondary elements (default
    /// for every pre-v0.21.9 tracker; no impact on existing readings).
    /// Optional for backward compatibility with older readings.json files
    /// — decoded as [:] when absent.
    var secondaryValues: [String: TrackerSecondaryValue]

    init(
        currentValue: String? = nil,
        currentNumeric: Double? = nil,
        snapshotPath: String? = nil,
        snapshotCacheKey: String? = nil,
        snapshotCapturedAt: Date? = nil,
        lastUpdatedAt: Date? = Date(),
        lastAttemptedAt: Date? = nil,
        status: TrackerStatus = .ok,
        sparkline: [Double] = [],
        lastError: String? = nil,
        consecutiveFailureCount: Int? = 0,
        secondaryValues: [String: TrackerSecondaryValue] = [:]
    ) {
        self.currentValue = currentValue
        self.currentNumeric = currentNumeric
        self.snapshotPath = snapshotPath
        self.snapshotCacheKey = snapshotCacheKey
        self.snapshotCapturedAt = snapshotCapturedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.lastAttemptedAt = lastAttemptedAt
        self.status = status
        self.sparkline = sparkline
        self.lastError = lastError
        self.consecutiveFailureCount = consecutiveFailureCount
        self.secondaryValues = secondaryValues
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentValue = try container.decodeIfPresent(String.self, forKey: .currentValue)
        currentNumeric = try container.decodeIfPresent(Double.self, forKey: .currentNumeric)
        snapshotPath = try container.decodeIfPresent(String.self, forKey: .snapshotPath)
        snapshotCacheKey = try container.decodeIfPresent(String.self, forKey: .snapshotCacheKey)
        snapshotCapturedAt = try container.decodeIfPresent(Date.self, forKey: .snapshotCapturedAt)
        lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        lastAttemptedAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptedAt)
        status = try container.decodeIfPresent(TrackerStatus.self, forKey: .status) ?? .ok
        sparkline = try container.decodeIfPresent([Double].self, forKey: .sparkline) ?? []
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        consecutiveFailureCount = try container.decodeIfPresent(Int.self, forKey: .consecutiveFailureCount)
        // secondaryValues was added in 0.21.9. Pre-0.21.9 readings.json files
        // predate the key so default to []. Backcompat-critical.
        secondaryValues = try container.decodeIfPresent([String: TrackerSecondaryValue].self, forKey: .secondaryValues) ?? [:]
    }
}

/// One secondary element's scrape result (v0.21.9+). Stored on TrackerReading
/// in a dictionary keyed by the element's UUID stringified, so existing
/// `[String: TrackerReading]` JSON encoding survives unchanged.
struct TrackerSecondaryValue: Codable, Equatable {
    var value: String?
    var numeric: Double?
    /// Failure message specific to THIS secondary element. The primary
    /// element's failure goes on the parent `TrackerReading.lastError`
    /// (and bumps the parent's status to .broken). A secondary element
    /// failing does NOT mark the whole tracker broken — secondaries are
    /// best-effort: if the "resets in" widget can't be parsed this cycle,
    /// the primary "73% used" still renders.
    var lastError: String?

    init(value: String? = nil, numeric: Double? = nil, lastError: String? = nil) {
        self.value = value
        self.numeric = numeric
        self.lastError = lastError
    }
}

struct TrackerReadingsFile: Codable, Equatable {
    var schemaVersion: Int
    var readings: [String: TrackerReading]

    static var empty: TrackerReadingsFile {
        TrackerReadingsFile(schemaVersion: currentSchemaVersion, readings: [:])
    }
}

extension ValueParser {
    func parseNumeric(from value: String) -> Double? {
        switch type {
        case .raw:
            return nil
        case .currencyOrNumber:
            var candidate = value
            stripChars.forEach { candidate = candidate.replacingOccurrences(of: $0, with: "") }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = Double(trimmed) {
                return direct
            }
            // Fallback: extract the leading numeric token. Handles values like
            // "81% used", "$42.50/mo", "1,234 visitors / 5,000", "83%" when the
            // stripChars list doesn't cover trailing units / suffixes.
            return Self.extractLeadingNumber(from: value)
        case .percent:
            let candidate = value
                .replacingOccurrences(of: "%", with: "")
                .replacingOccurrences(of: ",", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let direct = Double(candidate) {
                return direct
            }
            // Fallback: extract the leading numeric token. Handles "81% used",
            // "~83% of quota", "approx. 42% remaining" etc.
            return Self.extractLeadingNumber(from: value)
        }
    }

    /// Extracts the first numeric run from a string (optional sign, digits,
    /// optional decimal point). Strips commas so "1,234.5" parses as 1234.5.
    /// Returns nil if no numeric run is found.
    static func extractLeadingNumber(from value: String) -> Double? {
        // Remove thousands-separator commas, then scan for the first numeric token.
        let cleaned = value.replacingOccurrences(of: ",", with: "")
        let pattern = "[+-]?[0-9]+(?:\\.[0-9]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, range: range),
              let swiftRange = Range(match.range, in: cleaned) else {
            return nil
        }
        return Double(cleaned[swiftRange])
    }
}
