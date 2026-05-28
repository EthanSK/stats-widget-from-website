//
//  TrackerURLValidator.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Shared URL validation for tracker capture/scrape entry points.
//

import Foundation

enum TrackerURLValidator {
    static func httpOrHTTPSURL(
        from rawValue: String,
        defaultScheme: String? = "https",
        allowHTTPOnlyForLocalhost: Bool = false
    ) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let normalized: String
        if trimmed.contains("://") {
            normalized = trimmed
        } else if let defaultScheme {
            normalized = "\(defaultScheme)://\(trimmed)"
        } else {
            return nil
        }

        guard hasSingleSchemeMarkerBeforeQueryOrFragment(normalized),
              let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              let url = components.url else {
            return nil
        }

        if allowHTTPOnlyForLocalhost,
           scheme == "http",
           !isLocalhost(host) {
            return nil
        }

        return url
    }

    private static func hasSingleSchemeMarkerBeforeQueryOrFragment(_ value: String) -> Bool {
        let head = value.prefix { character in
            character != "?" && character != "#"
        }
        return String(head).components(separatedBy: "://").count == 2
    }

    private static func isLocalhost(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
