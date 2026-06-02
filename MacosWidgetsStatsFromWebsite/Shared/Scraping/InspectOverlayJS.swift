//
//  InspectOverlayJS.swift
//  MacosWidgetsStatsFromWebsite
//
//  JavaScript injected into the visible browser for element picking.
//

enum InspectOverlayJS {
    static func inspectOverlayJS(contextLabel: String? = nil) -> String {
        // Two banner-text variants for the two overlay states. Both are
        // JSON-encoded so they're safe to inline as JS string literals
        // even when the tracker label contains quotes / backslashes /
        // newlines. See IdentifyOverlayBanner for the prose itself.
        let prepareBannerLiteral = IdentifyOverlayBanner.javaScriptStringLiteral(
            IdentifyOverlayBanner.prepareBannerText(contextLabel: contextLabel)
        )
        let activeBannerLiteral = IdentifyOverlayBanner.javaScriptStringLiteral(
            IdentifyOverlayBanner.bannerText(contextLabel: contextLabel)
        )

        return #"""
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

    // ─── Hover-highlight outline ─────────────────────────────────────
    // Visual indicator (blue rectangle) that follows the user's pointer
    // once inspection is ACTIVE. Always created on inject (the poll
    // script `IdentifyOverlayPollJS.pollScript` looks for the
    // `data-stats-widget-inspect-outline` marker to decide the picker
    // is "active"; if we skipped creating it pre-Start the poll would
    // wrongly report inactive and trigger recoverOverlayAfterNavigation
    // → re-inject loop). It stays `display:none` until the user hovers
    // an element AFTER pressing Start. pointer-events:none always so it
    // never intercepts clicks itself.
    const outline = document.createElement('div');
    outline.setAttribute('data-stats-widget-inspect-outline', 'true');
    outline.style.cssText = 'position:fixed;border:2px solid #2997ff;box-sizing:border-box;pointer-events:none;z-index:2147483647;display:none;';
    root.appendChild(outline);

    // ─── Top-of-viewport banner ──────────────────────────────────────
    // v0.21.48 added a visible banner so users knew the picker was live
    // even before they moved their mouse. v0.21.77 expands the banner
    // with a "Start" button — see the long comment below.
    //
    // Layout choices (unchanged from v0.21.48):
    //   • position:fixed at top — survives page scroll, always in view
    //   • full-width — unmissable, no horizontal-scroll edge case
    //   • z-index 2147483647 (max int32) — sits above any site UI
    //   • distinctive color (Apple blue #2997ff) — matches outline
    //   • inline-styled — no risk of site CSS stripping classes
    //
    // CRITICAL DIFFERENCE FROM v0.21.48:
    //   v0.21.48 set the banner itself to `pointer-events:none` so the
    //   banner could never block clicks on the page beneath it. That
    //   was correct WHEN inspection auto-armed at inject time, because
    //   the document-level click handler captured picks anyway, and
    //   pointer-events:auto on the banner would have made the banner
    //   text "eat" picks on tall pages where it overlapped the target.
    //
    //   v0.21.77 changes the model: inspection is GATED behind the
    //   Start button on this banner. The button itself MUST be
    //   clickable, so the banner needs `pointer-events:auto`. But we
    //   ONLY want the BUTTON to receive clicks — the rest of the
    //   banner surface should still pass clicks through to the page
    //   beneath so users can interact with anything that happens to be
    //   under the banner (e.g. a login form at the very top of the
    //   viewport). We get this by:
    //     • Banner container: pointer-events:none  ← clicks pass through
    //     • Start button (child):  pointer-events:auto  ← clicks land
    //   That isolates the click target to the button alone.
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
      // pointer-events:none so banner SURFACE passes clicks through to
      // the page. The Start button (added below) re-enables
      // pointer-events on ITSELF so it's the sole clickable region.
      'pointer-events:none',
      'z-index:2147483647',
      'user-select:none',
      '-webkit-user-select:none',
      'display:flex',
      'align-items:center',
      'justify-content:center',
      'gap:12px',
      'flex-wrap:wrap'
    ].join(';');

    // Banner prose — held in a SPAN so we can swap textContent on Start
    // without disturbing the button child node.
    const bannerLabel = document.createElement('span');
    bannerLabel.setAttribute('data-stats-widget-inspect-banner-label', 'true');
    bannerLabel.textContent = \#(prepareBannerLiteral);
    banner.appendChild(bannerLabel);

    // ─── Start button ────────────────────────────────────────────────
    // The Start button is the gate between the PASSIVE state (banner
    // visible, page interactive) and the ACTIVE state (hover-highlight +
    // click-to-pick installed). pointer-events:auto so it's clickable
    // even though the parent banner is pointer-events:none. Styled
    // distinct (white pill on the blue banner) so it reads as a CTA.
    const startButton = document.createElement('button');
    startButton.setAttribute('type', 'button');
    startButton.setAttribute('id', 'stats-widget-inspect-start');
    startButton.setAttribute('data-stats-widget-inspect-start', 'true');
    startButton.textContent = 'Start';
    startButton.style.cssText = [
      // Re-enable click reception on the button (banner is pointer-
      // events:none; without this the button would be inert).
      'pointer-events:auto',
      'cursor:pointer',
      'background:#ffffff',
      'color:#2997ff',
      'border:none',
      'border-radius:14px',
      'padding:5px 14px',
      'font-family:inherit',
      'font-size:13px',
      'font-weight:700',
      'letter-spacing:0.3px',
      'box-shadow:0 1px 3px rgba(0,0,0,0.15)',
      // user-select:none so dragging the cursor across the button
      // doesn't accidentally select its text (would also block click).
      'user-select:none',
      '-webkit-user-select:none'
    ].join(';');
    banner.appendChild(startButton);

    root.appendChild(banner);

    // ─── State machine ───────────────────────────────────────────────
    // inspectionActive gates the hover-highlight + click-to-pick
    // listeners. Starts false; flips to true when the user clicks the
    // Start button. Esc-to-cancel works in BOTH states (so users who
    // pressed Start by mistake, or want to abort during prep, can bail
    // cleanly). The mousemove + click document-level listeners are NOT
    // installed until inspectionActive flips true — that way pre-Start
    // the page is untouched and the user's clicks pass straight through
    // to whatever's beneath the (pointer-events:none) banner.
    let inspectionActive = false;
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
      // Always attempt to remove BOTH listeners regardless of whether
      // they were installed — removeEventListener with a never-added
      // handler is a safe no-op. This keeps cleanup idempotent even if
      // it's called before Start (e.g. Esc-during-prep) and even after
      // re-inject scenarios.
      document.removeEventListener('mousemove', onMove, true);
      document.removeEventListener('click', onClick, true);
      document.removeEventListener('keydown', onKeyDown, true);
      startButton.removeEventListener('click', onStartClicked, true);
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
      inspectionActive = false;
    }

    function onMove(event) {
      // Defensive: should be unreachable when inspectionActive=false
      // because we don't install this listener until Start. Kept as a
      // belt-and-suspenders guard in case a future caller installs it
      // earlier without flipping the flag.
      if (!inspectionActive) {
        return;
      }
      if (!isElement(event.target)) {
        return;
      }

      hoverElement = event.target;
      window.__statsWidgetHover = hoverElement;
      updateOutline(hoverElement);
    }

    function onClick(event) {
      // Same defensive guard as onMove — if anything ever invokes this
      // before Start was pressed, we early-return WITHOUT preventing
      // default / stopping propagation, so the click continues through
      // to the page as if the overlay weren't installed.
      if (!inspectionActive) {
        return;
      }

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
      // Esc dismisses in BOTH states. Pre-Start: user changed their mind
      // about identifying. Post-Start: user wants to abort the pick. The
      // poll loop watches `__statsWidgetInspectCanceled` either way.
      if (event.key === 'Escape') {
        event.preventDefault();
        event.stopPropagation();
        cleanup();
        postCanceled();
      }
    }

    // ─── Start-button handler ────────────────────────────────────────
    // Flips the state machine from PASSIVE → ACTIVE:
    //   1. Set inspectionActive = true so the guards in onMove/onClick
    //      stop short-circuiting.
    //   2. Swap the banner label to the post-Start copy so the user
    //      knows what to do next ("hover, click, Esc to cancel").
    //   3. Hide the Start button so the user can't double-Start (the
    //      button has done its job — banner copy now reflects the new
    //      mode, button would be redundant noise).
    //   4. Install the document-level mousemove + click listeners that
    //      drive hover-highlight + pick capture. These were NOT
    //      installed pre-Start; that's how clicks passed through to the
    //      page (the document had no listener intercepting them).
    function onStartClicked(event) {
      // Important: stop the click from leaking into the page beneath.
      // The user clicked the BUTTON, not whatever happens to be
      // underneath the banner — preventDefault/stop propagation keeps
      // that intent clean.
      event.preventDefault();
      event.stopPropagation();
      event.stopImmediatePropagation();

      if (inspectionActive) {
        // Idempotent: if Start is somehow clicked twice, ignore the
        // second one rather than double-installing listeners.
        return;
      }
      inspectionActive = true;

      bannerLabel.textContent = \#(activeBannerLiteral);
      startButton.style.display = 'none';

      document.addEventListener('mousemove', onMove, true);
      document.addEventListener('click', onClick, true);
    }

    // Esc + Start are wired up at inject time so the user can dismiss
    // (Esc) or activate (Start) from the moment the overlay appears.
    // The mousemove + click document listeners are deliberately NOT
    // wired up until Start is pressed — see onStartClicked.
    window.__statsWidgetInspectCleanup = cleanup;
    document.addEventListener('keydown', onKeyDown, true);
    startButton.addEventListener('click', onStartClicked, true);
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
}
