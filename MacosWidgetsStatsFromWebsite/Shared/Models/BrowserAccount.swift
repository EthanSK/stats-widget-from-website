//
//  BrowserAccount.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Persistent, user-facing browser-account definitions.
//

import Foundation

struct BrowserAccount: Codable, Identifiable, Equatable, Hashable {
    /// Stable storage identifier used by Tracker.browserProfile, Chromium's
    /// user-data directory, and the profile-specific CDP port. This must never
    /// change when the user renames the account.
    var id: String
    var name: String
    var colorHex: String

    static let palette: [String] = [
        "#4C8DFF", // signal blue
        "#8B5CF6", // account violet
        "#14B8A6", // session teal
        "#F59E0B", // identity amber
        "#F43F5E"  // profile rose
    ]

    static let defaultAccount = BrowserAccount(
        id: Tracker.defaultBrowserProfile,
        name: "Default",
        colorHex: palette[0]
    )

    var isDefault: Bool {
        id == Tracker.defaultBrowserProfile
    }

    var initials: String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap(\.first)
        let value = String(words).uppercased()
        return value.isEmpty ? "?" : value
    }

    static func fallbackName(for profileID: String) -> String {
        if profileID == Tracker.defaultBrowserProfile {
            return defaultAccount.name
        }

        let words = profileID
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return "Browser Account"
        }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

enum BrowserAccountCatalogError: LocalizedError, Equatable {
    case emptyName
    case duplicateName(String)
    case invalidColor(String)
    case accountNotFound(String)
    case cannotDeleteDefault
    case accountInUse(name: String, trackerCount: Int)
    case portAllocationExhausted

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Enter a name for the browser account."
        case .duplicateName(let name):
            return "A browser account named \"\(name)\" already exists."
        case .invalidColor(let value):
            return "\"\(value)\" is not a six-digit hex colour such as #4C8DFF."
        case .accountNotFound:
            return "That browser account no longer exists."
        case .cannotDeleteDefault:
            return "The Default browser account cannot be removed."
        case .accountInUse(let name, let trackerCount):
            let noun = trackerCount == 1 ? "tracker uses" : "trackers use"
            return "\(trackerCount) \(noun) \"\(name)\". Move those trackers to another browser account before removing it."
        case .portAllocationExhausted:
            return "Could not allocate a separate browser connection for this account. Try again."
        }
    }
}

enum BrowserAccountCatalog {
    static let baseCDPPort = 18_880

    static func normalized(
        _ accounts: [BrowserAccount],
        referencedProfileIDs: [String]
    ) -> [BrowserAccount] {
        var result: [BrowserAccount] = []
        var seenIDs = Set<String>()

        func append(_ candidate: BrowserAccount) {
            let profileID = normalizedProfileID(candidate.id)
            guard seenIDs.insert(profileID).inserted else { return }

            let trimmedName = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let color = normalizedColorHex(candidate.colorHex) ?? colorHex(for: profileID)
            result.append(BrowserAccount(
                id: profileID,
                name: trimmedName.isEmpty ? BrowserAccount.fallbackName(for: profileID) : trimmedName,
                colorHex: color
            ))
        }

        if let existingDefault = accounts.first(where: { normalizedProfileID($0.id) == Tracker.defaultBrowserProfile }) {
            append(existingDefault)
        } else {
            append(.defaultAccount)
        }

        for account in accounts where normalizedProfileID(account.id) != Tracker.defaultBrowserProfile {
            append(account)
        }

        for rawProfileID in referencedProfileIDs {
            let profileID = normalizedProfileID(rawProfileID)
            guard !seenIDs.contains(profileID) else { continue }
            append(BrowserAccount(
                id: profileID,
                name: BrowserAccount.fallbackName(for: profileID),
                colorHex: colorHex(for: profileID)
            ))
        }

        return result
    }

    static func makeAccount(named rawName: String, existing: [BrowserAccount]) throws -> BrowserAccount {
        let name = try validatedName(rawName, excludingID: nil, existing: existing)
        let usedPorts = Set(existing.map { derivedCDPPort(for: $0.id) })

        // UUID-backed identifiers make collisions extremely unlikely, but CDP
        // ports intentionally live in a bounded range. Generate until both the
        // storage ID and derived port are unique so simultaneous accounts can
        // never attach to the wrong Chromium instance.
        for _ in 0..<100 {
            let profileID = "browser-account-\(UUID().uuidString.lowercased())"
            guard !existing.contains(where: { $0.id == profileID }),
                  !usedPorts.contains(derivedCDPPort(for: profileID)) else {
                continue
            }
            return BrowserAccount(
                id: profileID,
                name: name,
                colorHex: nextPaletteColor(existing: existing)
            )
        }

        // Reaching this would require 100 consecutive collisions in a
        // 1,000-port space. Surface a deterministic failure rather than ever
        // returning an account that could cross-wire sessions.
        throw BrowserAccountCatalogError.portAllocationExhausted
    }

    static func validatedName(
        _ rawName: String,
        excludingID: String?,
        existing: [BrowserAccount]
    ) throws -> String {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw BrowserAccountCatalogError.emptyName
        }
        let duplicate = existing.contains {
            $0.id != excludingID && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        guard !duplicate else {
            throw BrowserAccountCatalogError.duplicateName(name)
        }
        return name
    }

    static func normalizedProfileID(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Tracker.defaultBrowserProfile : trimmed
    }

    static func safeStorageIdentifier(_ rawValue: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = normalizedProfileID(rawValue).unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let safe = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return safe.isEmpty ? "browser-account" : safe
    }

    static func derivedCDPPort(for profileID: String) -> Int {
        let safeProfileID = safeStorageIdentifier(profileID)
        var hash: UInt32 = 2_166_136_261
        for scalar in safeProfileID.unicodeScalars {
            hash ^= UInt32(scalar.value)
            hash = hash &* 16_777_619
        }
        return baseCDPPort + Int(hash % 1_000)
    }

    static func colorHex(for profileID: String) -> String {
        let safeProfileID = safeStorageIdentifier(profileID)
        var hash: UInt32 = 2_166_136_261
        for scalar in safeProfileID.unicodeScalars {
            hash ^= UInt32(scalar.value)
            hash = hash &* 16_777_619
        }
        return BrowserAccount.palette[Int(hash % UInt32(BrowserAccount.palette.count))]
    }

    static func normalizedColorHex(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        let asciiHexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard hex.unicodeScalars.count == 6,
              hex.unicodeScalars.allSatisfy(asciiHexDigits.contains) else {
            return nil
        }
        return "#\(hex.uppercased())"
    }

    static func isValidColorHex(_ value: String) -> Bool {
        normalizedColorHex(value) != nil
    }

    private static func nextPaletteColor(existing: [BrowserAccount]) -> String {
        let used = Set(existing.map { $0.colorHex.uppercased() })
        return BrowserAccount.palette.first(where: { !used.contains($0.uppercased()) })
            ?? BrowserAccount.palette[existing.count % BrowserAccount.palette.count]
    }
}
