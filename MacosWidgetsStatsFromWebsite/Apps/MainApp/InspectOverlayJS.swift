//
//  InspectOverlayJS.swift
//  MacosWidgetsStatsFromWebsite
//
//  JavaScript injected into the visible browser for element picking.
//

enum InspectOverlayJS {
    static let inspectOverlayJS = #"""
(() => {
  try {
    if (window.__statsWidgetInspectCleanup) {
      window.__statsWidgetInspectCleanup();
    }

    window.__statsWidgetPicked = null;
    window.__statsWidgetInspectError = null;
    window.__statsWidgetInspectCanceled = false;

    const root = document.body || document.documentElement;
    if (!root) {
      throw new Error('No document root is available.');
    }

    const outline = document.createElement('div');
    outline.setAttribute('data-stats-widget-inspect-outline', 'true');
    outline.style.cssText = 'position:fixed;border:2px solid #2997ff;box-sizing:border-box;pointer-events:none;z-index:2147483647;display:none;';
    root.appendChild(outline);

    // v0.21.48 — VISIBLE banner so the user knows the picker is armed.
    // Voice 4277: "I don't see the overlay being added either." The old
    // overlay was just a 2px blue hover-outline — only rendered ONCE the
    // user moves the mouse over an element. If the user landed on the
    // page and DIDN'T move the mouse first, the flow looked like nothing
    // happened. Adding a top-of-viewport banner makes it obvious the
    // picker is live BEFORE any hover, and gives the user the keyboard
    // shortcuts at-a-glance.
    //
    // Layout choices:
    //   • position: fixed at top — survives page scroll, always in view
    //   • full-width — unmissable, no horizontal-scroll edge case
    //   • z-index 2147483647 (max int32) — sits above every site's UI
    //     including modal overlays
    //   • pointer-events: none — never blocks clicks on the underlying
    //     element the user is trying to capture
    //   • distinctive color (Apple blue #2997ff) — matches the hover
    //     outline so the visual language is consistent
    //   • inline-styled — no risk of the page's CSS stripping classes
    //
    // The banner CAN be dismissed via Esc (same as the whole picker),
    // and the cleanup() function removes it alongside the outline.
    const banner = document.createElement('div');
    banner.setAttribute('data-stats-widget-inspect-banner', 'true');
    banner.style.cssText = [
      'position:fixed',
      'top:0',
      'left:0',
      'right:0',
      'padding:10px 16px',
      'background:#2997ff',
      'color:#ffffff',
      'font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif',
      'font-size:13px',
      'font-weight:600',
      'line-height:1.4',
      'text-align:center',
      'letter-spacing:0.2px',
      'box-shadow:0 2px 8px rgba(0,0,0,0.25)',
      'box-sizing:border-box',
      'pointer-events:none',
      'z-index:2147483647',
      'user-select:none',
      '-webkit-user-select:none'
    ].join(';');
    banner.textContent = 'Identify Element — hover the value you want, click to capture, or press Esc to cancel.';
    root.appendChild(banner);

    let hoverElement = null;
    window.__statsWidgetHover = null;

    function postError(error) {
      const message = String(error && error.message ? error.message : error);
      if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectError) {
        webkit.messageHandlers.inspectError.postMessage({ message });
      } else {
        window.__statsWidgetInspectError = { message };
        console.error(message);
      }
    }

    function postCanceled() {
      if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectCanceled) {
        webkit.messageHandlers.inspectCanceled.postMessage({});
      }
      window.__statsWidgetInspectCanceled = true;
    }

    function isElement(value) {
      return value && value.nodeType === Node.ELEMENT_NODE;
    }

    function tagName(element) {
      return element.tagName.toLowerCase();
    }

    function escapeAttributeValue(value) {
      return String(value)
        .replace(/\\/g, '\\\\')
        .replace(/"/g, '\\"')
        .replace(/\n/g, '\\A ')
        .replace(/\r/g, '\\A ');
    }

    function queryCount(selector) {
      try {
        return document.querySelectorAll(selector).length;
      } catch (_) {
        return 0;
      }
    }

    function attributeSelector(element, attributes) {
      for (const attribute of attributes) {
        const value = element.getAttribute(attribute);
        if (!value) {
          continue;
        }

        const selector = '[' + attribute + '="' + escapeAttributeValue(value) + '"]';
        if (queryCount(selector) === 1) {
          return selector;
        }

        const taggedSelector = tagName(element) + selector;
        if (queryCount(taggedSelector) === 1) {
          return taggedSelector;
        }
      }

      return null;
    }

    function nthChildSegment(element) {
      let index = 1;
      let sibling = element;
      while ((sibling = sibling.previousElementSibling)) {
        index += 1;
      }
      return tagName(element) + ':nth-child(' + index + ')';
    }

    function synthesiseSelector(element) {
      const direct = attributeSelector(element, ['data-testid', 'id', 'aria-label', 'name']);
      if (direct) {
        return direct;
      }

      const segments = [];
      let node = element;
      while (isElement(node)) {
        const anchor = node === element ? null : attributeSelector(node, ['data-testid', 'id']);
        if (anchor) {
          segments.unshift(anchor);
          const anchoredSelector = segments.join(' > ');
          if (queryCount(anchoredSelector) === 1) {
            return anchoredSelector;
          }
        }

        segments.unshift(nthChildSegment(node));
        const selector = segments.join(' > ');
        if (queryCount(selector) === 1) {
          return selector;
        }

        node = node.parentElement;
      }

      const fallback = segments.join(' > ');
      if (fallback) {
        return fallback;
      }

      throw new Error('Could not build a selector for the selected element.');
    }

    function elementText(element) {
      return String(element.innerText || element.textContent || '').trim();
    }

    function updateOutline(element) {
      const rect = element.getBoundingClientRect();
      Object.assign(outline.style, {
        display: 'block',
        left: rect.left + 'px',
        top: rect.top + 'px',
        width: rect.width + 'px',
        height: rect.height + 'px'
      });
    }

    function cleanup() {
      document.removeEventListener('mousemove', onMove, true);
      document.removeEventListener('click', onClick, true);
      document.removeEventListener('keydown', onKeyDown, true);
      if (outline.parentNode) {
        outline.parentNode.removeChild(outline);
      }
      // v0.21.48 — also remove the visible banner so post-cleanup the
      // page goes back to a normal state. The DOM has no other artifacts
      // of the picker — outline + banner are the entire surface.
      if (banner.parentNode) {
        banner.parentNode.removeChild(banner);
      }
      window.__statsWidgetHover = null;
      window.__statsWidgetInspectCleanup = null;
    }

    function onMove(event) {
      if (!isElement(event.target)) {
        return;
      }

      hoverElement = event.target;
      window.__statsWidgetHover = hoverElement;
      updateOutline(hoverElement);
    }

    function onClick(event) {
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      try {
        const element = hoverElement || event.target;
        if (!isElement(element)) {
          throw new Error('No element is currently under the pointer.');
        }

        const rect = element.getBoundingClientRect();
        const selector = synthesiseSelector(element);
        const payload = {
          selector,
          text: elementText(element),
          bbox: {
            x: rect.left,
            y: rect.top,
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio || 1
          }
        };

        if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.elementPicked) {
          webkit.messageHandlers.elementPicked.postMessage(payload);
        } else {
          window.__statsWidgetPicked = payload;
        }
        cleanup();
      } catch (error) {
        postError(error);
        cleanup();
      }
    }

    function onKeyDown(event) {
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        cleanup();
        postCanceled();
      }
    }

    window.__statsWidgetInspectCleanup = cleanup;
    document.addEventListener('mousemove', onMove, true);
    document.addEventListener('click', onClick, true);
    document.addEventListener('keydown', onKeyDown, true);
  } catch (error) {
    const message = String(error && error.message ? error.message : error);
    if (window.webkit && webkit.messageHandlers && webkit.messageHandlers.inspectError) {
      webkit.messageHandlers.inspectError.postMessage({ message });
    } else {
      window.__statsWidgetInspectError = { message };
      console.error(message);
    }
  }
})();
"""#
}
