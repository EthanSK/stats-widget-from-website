//
//  SelectorExtraction.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Shared CSS-selector extraction helpers for Chrome/CDP scraping.
//

import CoreGraphics
import Foundation

enum ScraperError: LocalizedError {
    case invalidURL
    case navigationFailed(String)
    case selectedElementHasNoText
    case selectedElementHasNoVisibleRect
    case snapshotEncodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Tracker URL is not a valid http or https URL."
        case .navigationFailed(let message):
            return message
        case .selectedElementHasNoText:
            return "Selected element has no text."
        case .selectedElementHasNoVisibleRect:
            return "Selected element has no visible rect."
        case .snapshotEncodingFailed:
            return "Snapshot image could not be encoded as PNG."
        }
    }
}

enum SelectorExtractionError: LocalizedError {
    case selectorDidNotMatch
    case loginRequired
    case invalidSelector(String)
    case invalidEvaluationResult

    var errorDescription: String? {
        switch self {
        case .selectorDidNotMatch:
            return "Selector did not match any element."
        case .loginRequired:
            return "Login appears to be required in the app's Chrome profile before this selector can be scraped."
        case .invalidSelector(let message):
            return "Selector is invalid: \(message)"
        case .invalidEvaluationResult:
            return "Selector evaluation returned an unreadable result."
        }
    }
}

enum SelectorExtractionJS {
    static func validationScript(for selector: String) -> String {
        let selectorLiteral = javaScriptStringLiteral(selector)
        return """
        (() => {
          const selector = \(selectorLiteral);
          const loginLikely = (() => {
            try {
              const inputs = Array.from(document.querySelectorAll('input'));
              const passwordInput = inputs.some(input => String(input.type || '').toLowerCase() === 'password');
              const currentURL = String(window.location && window.location.href || '').toLowerCase();
              const title = String(document.title || '').toLowerCase();
              const formText = String(document.body && document.body.innerText || '').toLowerCase();
              return passwordInput ||
                /(^|[/.])(login|signin|sign-in|accounts|auth)([/.:-]|$)/.test(currentURL) ||
                /sign in|log in|login|password/.test(title) ||
                /sign in|log in|enter your password|continue to/.test(formText.slice(0, 4000));
            } catch (_) {
              return false;
            }
          })();

          try {
            const matches = document.querySelectorAll(selector);
            const element = matches[0] || null;
            const rect = element ? element.getBoundingClientRect() : null;
            return {
              count: matches.length,
              text: element ? String(element.innerText || element.textContent || '').trim() : '',
              bbox: rect ? {
                x: rect.left,
                y: rect.top,
                width: rect.width,
                height: rect.height,
                viewportWidth: window.innerWidth,
                viewportHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio || 1
              } : null,
              loginLikely: loginLikely
            };
          } catch (error) {
            return {
              count: -1,
              error: String(error && error.message ? error.message : error),
              loginLikely: loginLikely
            };
          }
        })()
        """
    }

    static func snapshotRectScript(for selector: String, hideElements: [String]) -> String {
        let selectorLiteral = javaScriptStringLiteral(selector)
        let hideElementsLiteral = javaScriptArrayLiteral(hideElements)
        return """
        (() => {
          for (const selector of \(hideElementsLiteral)) {
            try {
              document.querySelectorAll(selector).forEach(element => {
                element.setAttribute('data-stats-widget-hidden', 'true');
                element.style.visibility = 'hidden';
              });
            } catch (_) {}
          }

          const element = document.querySelector(\(selectorLiteral));
          if (!element) {
            return null;
          }

          try {
            element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'auto' });
          } catch (_) {
            try { element.scrollIntoView(false); } catch (_) {}
          }

          const rect = element.getBoundingClientRect();
          return {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio || 1
          };
        })()
        """
    }

    static func dictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }

        return value as? NSDictionary as? [String: Any]
    }

    static func rect(from value: Any?) -> CGRect? {
        guard let dictionary = dictionary(from: value),
              let x = doubleValue(dictionary["x"]),
              let y = doubleValue(dictionary["y"]),
              let width = doubleValue(dictionary["width"]),
              let height = doubleValue(dictionary["height"]) else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func elementBoundingBox(from value: Any?) -> ElementBoundingBox? {
        guard let dictionary = dictionary(from: value),
              let x = doubleValue(dictionary["x"]),
              let y = doubleValue(dictionary["y"]),
              let width = doubleValue(dictionary["width"]),
              let height = doubleValue(dictionary["height"]),
              let viewportWidth = doubleValue(dictionary["viewportWidth"]),
              let viewportHeight = doubleValue(dictionary["viewportHeight"]) else {
            return nil
        }

        return ElementBoundingBox(
            x: x,
            y: y,
            width: width,
            height: height,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            devicePixelRatio: doubleValue(dictionary["devicePixelRatio"]) ?? 1
        )
    }

    static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    static func intValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            return (value as NSString).boolValue
        }
        return nil
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return literal
    }

    private static func javaScriptArrayLiteral(_ value: [String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return literal
    }
}
