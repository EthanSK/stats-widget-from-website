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

struct TrackerReading: Codable, Equatable {
    var currentValue: String?
    var currentNumeric: Double?
    var snapshotPath: String?
    var snapshotCacheKey: String?
    var snapshotCapturedAt: Date?
    var lastUpdatedAt: Date?
    var status: TrackerStatus
    var sparkline: [Double]
    var lastError: String?
    var consecutiveFailureCount: Int?

    init(
        currentValue: String? = nil,
        currentNumeric: Double? = nil,
        snapshotPath: String? = nil,
        snapshotCacheKey: String? = nil,
        snapshotCapturedAt: Date? = nil,
        lastUpdatedAt: Date? = Date(),
        status: TrackerStatus = .ok,
        sparkline: [Double] = [],
        lastError: String? = nil,
        consecutiveFailureCount: Int? = 0
    ) {
        self.currentValue = currentValue
        self.currentNumeric = currentNumeric
        self.snapshotPath = snapshotPath
        self.snapshotCacheKey = snapshotCacheKey
        self.snapshotCapturedAt = snapshotCapturedAt
        self.lastUpdatedAt = lastUpdatedAt
        self.status = status
        self.sparkline = sparkline
        self.lastError = lastError
        self.consecutiveFailureCount = consecutiveFailureCount
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
