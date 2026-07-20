# Chrome/CDP browser path

_Last assessed on 2026-05-05 from the MacBook implementation state._

## Decision

Use real, isolated Chrome/Chromium Browser Accounts controlled over the Chrome DevTools Protocol
as the app's user-facing browser path for setup, re-identify, MCP-driven
`identify_element`, and app-owned scraping.

The former embedded-browser sign-in and element-picking flows are no longer part
of the product UX. OAuth, passkeys, Google sign-in, and modern dashboard auth are
more reliable in a real browser, and keeping one browser implementation avoids the
old mismatch where setup used one cookie store and scraping used another.

## Current implementation inventory

- `BrowserAccount` gives each login a stable storage ID plus a renameable name
  and colour badge.
- `ChromeBrowserProfile` launches a persistent Chrome/Chromium instance with a
  distinct local CDP port and user-data directory for each Browser Account.
- `ChromeCDPScraper` performs app-owned scraping through the account assigned to
  each tracker; the same URL and selector can therefore return different values
  for different logins.
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
3. Sign in or navigate in the selected Browser Account if needed.
4. Hover and click the value or page region.
5. Confirm the preview; the tracker stores the selector, bounding box, render
   mode, and stable Browser Account ID.

## Notes

- Vendor-specific shortcuts are intentionally absent. To track any signed-in
  dashboard, paste that service's URL manually.
- Create and sign into accounts in **Preferences → Browser Accounts**. Renaming
  an account never moves its data; removing one is blocked while a tracker uses
  it, and reset/removal moves data to the Trash.
- Chrome for Testing / installed Chrome / Chromium resolution remains handled by
  `ChromeBrowserProfile`; distribution policy is documented separately in the
  release notes.
- The legacy embedded-browser implementation has been deleted; Chrome/CDP is the
  only setup, authentication, identify, and scraping path.
