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

          // v0.21.8 instrumentation-only additions: readyState, url, title.
          // Read once into locals so the diagnostics never affect the
          // existing payload shape (count, text, bbox, loginLikely).
          const readyState = (() => {
            try { return String(document.readyState || ''); } catch (_) { return ''; }
          })();
          const currentURL = (() => {
            try { return String(window.location && window.location.href || ''); } catch (_) { return ''; }
          })();
          const docTitle = (() => {
            try { return String(document.title || '').slice(0, 200); } catch (_) { return ''; }
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
              loginLikely: loginLikely,
              readyState: readyState,
              url: currentURL,
              title: docTitle
            };
          } catch (error) {
            return {
              count: -1,
              error: String(error && error.message ? error.message : error),
              loginLikely: loginLikely,
              readyState: readyState,
              url: currentURL,
              title: docTitle
            };
          }
        })()
        """
    }

    static func contentFallbackScript(trackerName: String, hint: String?) -> String {
        let trackerNameLiteral = javaScriptStringLiteral(trackerName)
        let hintLiteral = javaScriptStringLiteral(hint ?? "")
        return """
        (() => {
          const trackerName = \(trackerNameLiteral);
          const explicitHint = \(hintLiteral);
          const percentPattern = /(\\d+(?:\\.\\d+)?\\s*%\\s*(?:used|remaining)?)/i;
          const genericTerms = new Set([
            'usage', 'used', 'percent', 'percentage', 'quota', 'limit',
            'remaining', 'tracker', 'stats', 'widget', 'value'
          ]);

          function normalizeText(value) {
            return String(value || '').replace(/\\s+/g, ' ').trim();
          }

          function terms(value, dropGeneric) {
            const matches = normalizeText(value).toLowerCase().match(/[a-z0-9]+/g) || [];
            const seen = new Set();
            const result = [];
            for (const term of matches) {
              if (term.length < 2 || seen.has(term)) continue;
              if (dropGeneric && genericTerms.has(term)) continue;
              seen.add(term);
              result.push(term);
            }
            return result;
          }

          function isVisible(element) {
            try {
              const style = window.getComputedStyle(element);
              if (!style || style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity || 1) === 0) {
                return false;
              }
              const rect = element.getBoundingClientRect();
              return rect.width > 0 && rect.height > 0;
            } catch (_) {
              return false;
            }
          }

          function surroundingText(element) {
            const chunks = [];
            let current = element;
            for (let depth = 0; current && depth < 4; depth += 1) {
              chunks.push(normalizeText(current.innerText || current.textContent).slice(0, 320));
              const parent = current.parentElement;
              if (parent) {
                for (const sibling of Array.from(parent.children || [])) {
                  if (sibling === current) continue;
                  const text = normalizeText(sibling.innerText || sibling.textContent);
                  if (text && text.length <= 320) chunks.push(text);
                }
              }
              current = parent;
            }
            return normalizeText(chunks.join(' '));
          }

          const explicitTerms = terms(explicitHint, false);
          const nameTerms = terms(trackerName, true);
          const candidates = [];
          const nodes = document.body ? Array.from(document.body.querySelectorAll('*')) : [];

          nodes.forEach((element, index) => {
            const tagName = String(element.tagName || '').toLowerCase();
            if (['script', 'style', 'noscript', 'svg', 'path'].includes(tagName)) return;
            if (!isVisible(element)) return;

            const text = normalizeText(element.innerText || element.textContent);
            if (!text || text.length > 180) return;
            const match = text.match(percentPattern);
            if (!match) return;

            const context = surroundingText(element);
            const lowerText = text.toLowerCase();
            const lowerContext = context.toLowerCase();
            const rect = element.getBoundingClientRect();
            let score = 0;
            const matchedTerms = [];

            for (const term of explicitTerms) {
              if (lowerText.includes(term)) {
                score += 24;
                matchedTerms.push(term);
              } else if (lowerContext.includes(term)) {
                score += 18;
                matchedTerms.push(term);
              }
            }

            for (const term of nameTerms) {
              if (lowerText.includes(term)) {
                score += 8;
                matchedTerms.push(term);
              } else if (lowerContext.includes(term)) {
                score += 5;
                matchedTerms.push(term);
              }
            }

            if (text.length <= 40) score += 4;
            if (/^\\s*\\d+(?:\\.\\d+)?\\s*%\\s*(?:used|remaining)?\\s*$/i.test(text)) score += 5;
            score -= index / 10000;
            score -= Math.min(text.length, 180) / 1000;

            candidates.push({
              text: match[1].trim(),
              fullText: text,
              context,
              score,
              matchedTerms,
              index,
              tagName,
              bbox: {
                x: Math.max(0, rect.left + window.scrollX),
                y: Math.max(0, rect.top + window.scrollY),
                width: rect.width,
                height: rect.height,
                viewportWidth: window.innerWidth,
                viewportHeight: window.innerHeight,
                devicePixelRatio: window.devicePixelRatio || 1
              }
            });
          });

          if (!candidates.length) {
            return {
              count: 0,
              candidates: 0,
              text: '',
              hint: explicitHint,
              trackerName
            };
          }

          candidates.sort((left, right) => {
            if (right.score !== left.score) return right.score - left.score;
            return left.index - right.index;
          });

          const selected = candidates[0];
          return {
            count: 1,
            candidates: candidates.length,
            text: selected.text,
            fullText: selected.fullText,
            context: selected.context.slice(0, 240),
            hint: explicitHint,
            trackerName,
            score: selected.score,
            matchedTerms: selected.matchedTerms,
            tagName: selected.tagName,
            bbox: selected.bbox,
            fallback: true
          };
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
