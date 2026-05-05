# Chrome/CDP browser path

_Last assessed on 2026-05-05 from the MacBook implementation state._

## Decision

Use a real Chrome/Chromium profile controlled over the Chrome DevTools Protocol
as the app's user-facing browser path for setup, re-identify, MCP-driven
`identify_element`, and app-owned scraping.

The former embedded-browser sign-in and element-picking flows are no longer part
of the product UX. OAuth, passkeys, Google sign-in, and modern dashboard auth are
more reliable in a real browser profile, and keeping one browser path avoids the
old mismatch where setup used one cookie store and scraping used another.

## Current implementation inventory

- `ChromeBrowserProfile` launches a persistent Chrome/Chromium profile with a
  local CDP port and per-profile user-data directory.
- `ChromeCDPScraper` performs app-owned scraping through that profile.
- The first-launch wizard, tracker editor, and MCP identify requests open the
  same Chrome/CDP picker directly.
- `ChromeCDPClient` intentionally avoids `Runtime.enable` and uses bounded
  `Runtime.evaluate` calls for selector extraction, matching the safer
  Google-login-compatible control style.
- `InspectOverlayJS` works through Chrome/CDP by storing successful picks on
  `window.__statsWidgetPicked` and errors on
  `window.__statsWidgetInspectError`; the CDP coordinator polls those globals,
  validates the selector, and returns the same preview/save payload.

## User flow

1. Paste the target page URL.
2. Click **Open Chrome and Identify Element** / **Identify in Chrome**.
3. Sign in or navigate in the app's Chrome profile if needed.
4. Hover and click the value or page region.
5. Confirm the preview; the tracker stores the selector, bounding box, render
   mode, and Chrome profile name.

## Notes

- Vendor-specific shortcuts are intentionally absent. To track any signed-in
  dashboard, paste that service's URL manually.
- Chrome for Testing / installed Chrome / Chromium resolution remains handled by
  `ChromeBrowserProfile`; distribution policy is documented separately in the
  release notes.
- The legacy embedded-browser implementation has been deleted; Chrome/CDP is the
  only setup, authentication, identify, and scraping path.
