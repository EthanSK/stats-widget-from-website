# Stats Widget from Website — Plan

> Living design document. **Current implementation state: v0.21.83.** The app now
> uses persistent, isolated Chrome/Chromium Browser Accounts controlled through CDP for setup,
> identify, authentication, scraping, and snapshots. The old embedded-browser
> implementation has been removed from source. Widget instance configuration is
> AppIntent-backed and requires macOS 14+; the main app and CLI still build for
> macOS 13 where supported. MCP remains the only local agent surface.

---

## 1. Vision & problem statement

I keep refreshing analytics dashboards, billing pages, storefront stats, and a
couple of other "what's my number right now" pages. Each one
is a tab, a cookie, a sign-in, and twenty seconds of friction. The numbers
themselves are tiny — one to four digits — but the act of fetching them
breaks flow several times a day.

A widget on the desktop is the right surface for this:

- **App** is overkill. I don't want to launch anything; I want the number to
  already be there when I glance at it.
- **Menu-bar status item** is too cramped for multiple trackers and doesn't
  compose well visually.
- **Browser extension** doesn't show on my desktop and dies when the browser
  is closed.
- **Widget** is the native macOS surface for "passive value on screen", with
  WidgetKit's timeline + Intents API and SwiftUI rendering (gauges,
  sparklines, cropped element images).

The product is therefore: **a macOS WidgetKit widget app that displays
scraped content from any logged-in web page** — text values *or* live element
snapshots — **configured once via a click-to-pick element flow, refreshing on
a per-tracker schedule, with clear stale/broken status and a re-identify flow
when sites change their layout**.

LLM-spend pages are the canonical example use case. The product itself is
**not coupled** to LLM spend, money, or AI usage: any text node, number,
percentage, status badge, or visual region on any web page you can sign into
is fair game. **"Tracker"** is the term we use throughout — a tracker is one
`(URL, selector, render mode)` triple plus its display config.

It is a personal tool first and a public open-source project (MIT) second.
The **App Store** is the v1.0 distribution path for the app + widget; the
**Homebrew** tap is the optional power-user adjunct for the standalone CLI.

## 2. Architecture overview

Three components share a single App Group, plus an embedded MCP server that
exposes the data plane to local AI agents:

| Component | Type | Responsibility | Ships via |
|---|---|---|---|
| **Main app** | `.app` (AppKit shell + SwiftUI) | Preferences UI, Chrome/CDP browser, element-capture flow, login persistence, **scheduled scraping via NSBackgroundActivityScheduler**, **embedded MCP server**, manual scrape trigger | Mac App Store |
| **Widget extension** | WidgetKit extension inside the `.app` | Reads tracker readings from App Group on each timeline tick, renders Text or Snapshot mode | Mac App Store (bundled) |
| **CLI scraper** (optional) | Standalone executable | Power-user adjunct: custom schedules, headless server use, automation, scriptable bulk operations. Connects to the main app's MCP server. | Homebrew tap |

```
   ┌──────────────────────────────────────────────────────────┐
   │  Main App (sandbox)                                      │
   │  - Preferences UI                                        │
   │  - Chrome/Chromium CDP Browser Accounts                 │
   │  - Element-capture flow (Identify Element overlay)       │
   │  - Background scrape (NSBackgroundActivityScheduler)     │
   │  - Chrome/CDP snapshot sessions (Chrome/CDP scraper)     │
   │  - Embedded MCP server (stdio + UNIX socket)             │
   │  - Manual "scrape now"                                   │
   └────────────┬─────────────────────────────┬───────────────┘
                │                             │
                │ reads & writes              │ exposes via MCP
                │                             │
                ▼                             ▼
        ┌────────────────────────┐    ┌──────────────────────────┐
        │  App Group container   │    │  External AI agents       │
        │  ~/Library/Group       │    │  (local MCP clients,      │
        │  Containers/<group-id>/│    │   optional Homebrew CLI,  │
        │  ├─ trackers.json      │    │   anything MCP-speaking)  │
        │  ├─ readings.json      │    │                            │
        │  ├─ snapshots/<id>.png │    └──────────────────────────┘
        │  ├─ widget-configs.json│
        │  └─ schema-version     │
        └────────┬───────────────┘
                 │  reads only
                 ▼
       ┌────────────────────────┐
       │  Widget Extension      │
       │  - Text / Snapshot     │
       │  - Sparkline           │
       │  - Multi-tracker grid  │
       └────────────────────────┘
```

**Data flow.** The main app owns *config*, *readings*, and *scheduling*. The
widget only *reads*. External AI agents talk to the app via the embedded MCP
server — they don't touch the file store directly. The optional CLI is a
second surface that connects through the **same MCP server**, never bypassing
it. There is one source of truth.

**Process boundaries (App Store sandbox implications):**

- The widget extension is sandboxed and has *no* network entitlement. It
  reads local files in the App Group container only. Critical for App Store
  acceptance.
- The main app has the network-client entitlement (Chrome/CDP browser, headless
  scraping, webhook POSTs, MCP socket) but **never spawns external CLIs**.
  AI involvement, if any, happens outside the app: the user's own local MCP
  client session connects to MCP and calls ordinary tracker/config tools.
  The app never invokes any AI binary itself.
- The main app's *scheduled scraping* runs through
  `NSBackgroundActivityScheduler` — sandbox-safe, the canonical Apple-blessed
  surface for "rerun this every N minutes while the app is alive (or wake
  it)". This guarantees standalone functionality: the app + widget refresh on
  their own without any external CLI installed.
- The optional Homebrew CLI is a regular macOS executable, unsandboxed,
  Homebrew-shipped. It does not write into the App Group container directly;
  it talks to the main app via the MCP socket so there is exactly one writer.

## 3. Tech stack & rationale

- **Swift 5.9+**. The main app and CLI still target macOS 13 where supported;
  the WidgetKit extension targets macOS 14+ for desktop widgets.
- **SwiftUI** for Preferences UI and the widget itself. **AppKit** shell for
  the main app window where SwiftUI is still weak (hidden-when-closed dock
  icon, window restoration, menu-bar niceties).
- **WidgetKit** with `StaticConfiguration`; the placed widget reads the app's saved widget configuration from the App Group store instead of requiring a separate per-widget edit sheet.
- **NSBackgroundActivityScheduler** for in-app scheduled scraping.
  Sandbox-safe; runs while the app is alive or wakes it from suspended state.
  No LaunchAgent required for the standalone path; the optional CLI keeps a
  LaunchAgent for headless / power-user setups.
- **Chrome/Chromium controlled through CDP** as the scraping engine for setup,
  manual re-identify, scheduled text scrapes, and snapshot captures. Reasons:
  - Auth reliability: OAuth, passkeys, Google consent, and dashboard sessions
    behave like they do in a real browser.
  - One session model: setup, identify, MCP identify, and scraping all use the
    same app-owned Chrome/Chromium user-data directory.
  - Clear fallback: use installed Chrome/Chromium or managed Chrome for Testing
    where distribution policy allows it.
- **Chrome/Chromium user-data directory for the app profile** — a single named
  persistent profile shared between setup and scraping. Cookies, IndexedDB,
  localStorage, and service worker registrations persist across launches, so a
  site stays logged in after the user signs in once.
- **Keychain Services API** — stores the MCP launch/shared token; page auth state
  lives in the app-owned Chrome/Chromium profile, not app-managed passwords.
- **App Group** over UserDefaults / iCloud / Keychain for the data plane:
  - UserDefaults: scoped to a single bundle ID by default; cross-process
    sharing requires `suiteName`, but we want JSON + PNG too.
  - iCloud: latency, conflict resolution, and offline behaviour are wrong for
    a refresh-every-30-min widget.
  - Keychain: only for credentials, not for readings.
- **xcodegen** (`project.yml`) keeps project settings regeneratable and reduces
  hand-edited `.xcodeproj` drift.
- **Embedded MCP server in the main app** — see §13. Stdio transport when
  invoked as a child process by an MCP client; UNIX domain socket at
  `~/Library/Group Containers/<group-id>/mcp.sock` for the always-on case.
  Sandbox-safe in both modes.
- **launchd LaunchAgent** (Homebrew CLI only, optional) for headless
  scheduling. The standalone app+widget never needs a LaunchAgent.

## 4. Module structure

```
MacosWidgetsStatsFromWebsite/
  Apps/
    MainApp/
      MacosWidgetsStatsFromWebsiteApp.swift       — app entry, scene wiring
      AppDelegate.swift               — menu bar / dock icon control
      PreferencesWindow.swift         — main preferences container
      TrackersListView.swift          — list of configured trackers
      TrackerEditorView.swift         — add/edit tracker form
      WidgetConfigsView.swift         — list of widget configurations
      WidgetConfigEditorView.swift    — add/edit a widget composition
      WidgetTemplatesGalleryView.swift— curated template gallery (12 cards)
      ChromeIdentifyElementCoordinator.swift — Chrome/CDP Identify Element flow
      InspectOverlayJS.swift          — JS string for hover/click overlay
      FirstLaunchWizardView.swift     — first-launch flow (URL → identify → widget)
      SignInPrefsView.swift           — Chrome profile controls
      MCPPrefsView.swift              — socket path, token reveal/copy, MCP notes
      SelectorPackImportView.swift    — drag-drop / open-with handler
      BackgroundScheduler.swift       — NSBackgroundActivityScheduler wrapper
    WidgetExtension/
      MacosWidgetsStatsFromWebsiteBundle.swift    — registers all widget kinds
      StatsWidget.swift               — TimelineProvider + entry view
      Templates/
        SingleBigNumber.swift         — small / Text
        NumberPlusSparkline.swift     — small / Text
        GaugeRing.swift               — small / Text
        LiveSnapshotTile.swift        — small / Snapshot
        HeadlineSparkline.swift       — medium / Text
        DualStatCompare.swift         — medium / Text
        Dashboard3Up.swift            — medium / Text
        SnapshotPlusStat.swift        — medium / Mixed
        StatsListWatchlist.swift      — large / Text
        HeroPlusDetail.swift          — large / Text
        LiveSnapshotHero.swift        — large / Snapshot
        MegaDashboardGrid.swift       — extraLarge / Mixed
      SparklineView.swift             — last-N reading sparkline
      StatsWidget.swift               — AppIntent configuration picker + widget UI
    CLI/                              — optional Homebrew adjunct
      main.swift                      — argument parsing
      MCPClient.swift                 — connects to main app's MCP server
      ScrapeCommand.swift             — `scrape` subcommand → trigger_scrape
      LaunchdInstaller.swift          — install/remove LaunchAgent plist
    MCPServer/
      MCPServer.swift                 — entry point, transport selection
      StdioTransport.swift            — JSON-RPC over stdin / stdout
      SocketTransport.swift           — JSON-RPC over UNIX domain socket
      Tools/
        ListTrackersTool.swift
        GetTrackerTool.swift
        AddTrackerTool.swift
        UpdateTrackerTool.swift
        DeleteTrackerTool.swift
        TriggerScrapeTool.swift
        IdentifyElementTool.swift
        ListWidgetConfigsTool.swift
        GetWidgetConfigTool.swift
        UpdateWidgetConfigTool.swift
        DeleteWidgetConfigTool.swift
        ExportSelectorPackTool.swift
        ImportSelectorPackTool.swift
        AttachWebhookTool.swift
      Auth/
        SocketAuth.swift              — UNIX-perm + Keychain shared-secret check
  Shared/
    Models/
      Tracker.swift                   — Tracker struct (config row)
      BrowserAccount.swift            — stable IDs, names, badge colours, CDP-port allocation
      TrackerResult.swift             — last reading + sparkline history
      RenderMode.swift                — .text | .snapshot
      TrackerStatus.swift             — .ok | .stale | .broken
      WidgetConfiguration.swift       — name, size, [trackerID], layout, templateID
      WidgetTemplate.swift            — id, name, size, supportedModes, slot count
      SelectorPack.swift              — exportable JSON shape
    AppGroup/
      AppGroupPaths.swift             — typed paths into the container
      AppGroupStore.swift             — atomic JSON read/write helpers
      SchemaVersion.swift             — current version + migrators
    Scraping/
      ChromeBrowserProfile.swift      — app-owned, per-account Chrome/Chromium launcher
      ChromeCDPClient.swift           — bounded Chrome DevTools Protocol client
      ChromeCDPScraper.swift          — Chrome/CDP text + snapshot scraper
      SelectorExtraction.swift        — selector validation JS and parsing helpers
    Notifications/
      TrackerAttentionNotifier.swift  — macOS native notification when a tracker breaks
      UNUserNotificationCenterClient.swift — macOS native notifications
      WebhookClient.swift             — generic webhook POST (Slack/Discord/etc.)
  Tests/
    SharedTests/                      — unit tests for pure types
    ScrapingTests/                    — fixture-HTML based selector tests
    MCPServerTests/                   — JSON-RPC tool dispatch tests
  scripts/
    bootstrap.sh                      — one-shot dev setup
    package-cli.sh                    — produces a Homebrew-ready tarball
  project.yml                         — xcodegen project definition
```

One-line responsibility per file is the discipline we keep — if a file
needs more than one line to describe, it's doing too much and we split it.

## 5. Configuration schema

Stored at `~/Library/Application Support/Stats Widget from Website/trackers.json`
(the **canonical config** — the App Group container holds a *copy* the
widget reads, written atomically by the main app):

```jsonc
{
  "schemaVersion": 6,
  "browserAccounts": [
    {
      "id": "macos-widgets-stats-from-website", // stable; also used by legacy trackers
      "name": "Default",                        // user-facing and renameable
      "colorHex": "#4C8DFF"
    },
    {
      "id": "browser-account-550e8400-…",       // immutable storage identity
      "name": "Work",
      "colorHex": "#8B5CF6"
    }
  ],
  "trackers": [
    {
      "id": "8c1b2e6e-…",                 // UUID, immutable — the tracker ID
      "name": "Codex weekly spend",
      "url": "https://platform.openai.com/usage",
      "browserProfile": "browser-account-550e8400-…", // Browser Account stable ID
      "renderMode": "text",               // "text" | "snapshot"
      "selector": "div[data-testid=\"weekly-cost\"] span",
      "elementBoundingBox": {              // captured at Identify Element time
        "x": 480, "y": 312, "width": 96, "height": 28,
        "viewportWidth": 1280, "viewportHeight": 800,
        "devicePixelRatio": 2
      },
      "refreshIntervalSec": 1800,         // text default 1800 (30 min); snapshot default 2
      "label": "Codex",                   // display label override
      "icon": "dollarsign.circle.fill",    // SF Symbol name
      "accentColorHex": "#10a37f",
      "valueParser": {                     // text mode only
        "type": "currencyOrNumber",       // "currencyOrNumber" | "percent" | "raw"
        "stripChars": ["$", ",", " "]
      },
      "history": {
        "retentionPolicy": "days",        // "count" | "days"
        "retentionValue": 7,               // 7 days default; max 30 days
        "displayWindow": 24                // sparkline shows last 24 readings
      },
      "hideElements": [                    // snapshot mode: CSS selectors hidden before capture
        ".cookie-banner",
        "#trial-prompt"
      ]
    }
  ],
  "widgetConfigurations": [
    {
      "id": "9d2f1a8b-…",
      "name": "AI Spend Dashboard",
      "templateID": "stats-list-watchlist",   // one of the 12 curated templates (§9)
      "size": "large",                        // small | medium | large | extraLarge
      "layout": "grid",                       // grid | stack | single (template-dependent)
      "trackerIDs": [
        "8c1b2e6e-…",
        "f4a3c2d1-…",
        "b1e8d7f5-…",
        "5c3a9b2e-…"
      ],
      "showSparklines": true,
      "showLabels": true
    },
    {
      "id": "1a4c6b9e-…",
      "name": "Primary KPI",
      "templateID": "single-big-number",
      "size": "small",
      "layout": "single",
      "trackerIDs": ["8c1b2e6e-…"],
      "showSparklines": true,
      "showLabels": true
    }
  ],
  "preferences": {
    "notificationChannels": {
      "macosNative": true,
      "webhook": null                         // optional URL string
    },
    "snapshotConcurrencyCap": 8                // long-lived sessions; LRU recycled past this
  }
}
```

Readings live in a separate file (App Group only, never in user docs):

```jsonc
// readings.json
{
  "schemaVersion": 4,
  "readings": {
    "<tracker-id>": {
      "currentValue": "$42.18",          // text mode: extracted innerText
      "currentNumeric": 42.18,           // text mode: parsed value (for sparkline)
      "snapshotPath": "snapshots/8c1b2e6e.png", // snapshot mode: latest PNG path
      "snapshotCapturedAt": "2026-04-28T14:02:13Z",
      "lastUpdatedAt": "2026-04-28T14:02:13Z",
      "status": "ok",
      "sparkline": [38.4, 39.1, 40.0, 42.0, 42.18],
      "lastError": null
    }
  }
}
```

**Versioning strategy.** `schemaVersion` is a monotonic integer.

- `schemaVersion = 1` (v0.0.1 baseline) — single `metrics` array, no widget
  configurations, no MCP, "number" / "screenshot" mode names.
- `schemaVersion = 2` migration: rename `metrics` → `trackers`,
  `mode` → `renderMode`, `"number"` → `"text"`, `"screenshot"` → `"snapshot"`.
  Pure key rename, no data loss.
- `schemaVersion = 3` migration: add `widgetConfigurations`, `preferences`,
  per-tracker `history` block; collapse legacy `cropRegion` into
  `elementBoundingBox`.
- `schemaVersion = 4` (this plan, v0.0.4): add `templateID` to each
  widget configuration; add `snapshotConcurrencyCap` to preferences; remove
  earlier dev-build AI-CLI preference fields (those features were dropped —
  the app no longer detects or invokes AI CLIs).
- `schemaVersion = 5` (v0.21.9): add secondary elements, per-reading
  secondary values, and per-widget-slot secondary-element bindings.
- `schemaVersion = 6` (v0.21.83): add the `browserAccounts` catalog. Existing
  trackers keep their `browserProfile` identifiers; the legacy identifier is
  represented by the built-in Default account, and any other pre-existing IDs
  receive synthesized catalog entries without moving their browser data.

On app launch we read both files, compare against `currentSchemaVersion`,
and run forward migrators (`Migrator_1_to_2`, `Migrator_2_to_3`,
`Migrator_3_to_4`). Migrators are pure functions. We never delete fields; we
add an optional `deprecated` flag and stop reading them. Backward migration
is not supported — once upgraded, downgrade requires restoring the prior
`trackers.json` from the last `trackers.json.bak`. The app keeps three
rotating backups.

## 6. Element-capture UX flow

```
[Preferences]
   ├─ user clicks "+ Add tracker"
   ▼
[New Tracker — Step 1: Browse]
   ├─ embedded Chrome/CDP, full chrome (back/forward/reload/url-bar)
   ├─ user signs in (cookies persisted via Chrome/Chromium profile storage identifier
   │  "macos-widgets-stats-from-website"; passkey path used when site supports it)
   ├─ user navigates to the page that has the value/region they want
   ▼
[New Tracker — Step 2: Identify Element]
   ├─ user clicks "Identify Element" toolbar button
   ├─ JS injects an InspectOverlay (mouseover outline, click trap)
   ├─ user hovers — element under cursor gets 2px solid outline
   ├─ user clicks — element selected, inspect mode exits
   ▼
[New Tracker — Step 3: Choose Render Mode]
   ├─ shows extracted innerText + element snapshot side-by-side
   ├─ user picks "Text mode" (extract innerText) or "Snapshot mode"
   │   (capture the element's bounding rect as an image)
   ├─ if Snapshot, user can optionally tick CSS selectors to hide
   │   from the captured frame (cookie banners, trial prompts)
   ▼
[New Tracker — Step 4: Polish]
   ├─ user names the tracker, picks SF Symbol + accent colour
   ├─ user picks refresh interval (slider; defaults: 30 min Text / 2 sec Snapshot)
   ├─ user picks which widget configuration(s) the tracker belongs to
   │   (or chooses "Create new widget configuration")
   ▼
[Save] → writes trackers.json, schedules background scrape, reload widget timeline
```

**Sign-in persistence UX (Preferences → Browser Accounts).** A dedicated panel lets
the user manage logged-in state without going back to the Identify Element
flow:

```
┌─ Browser Accounts ───────────────────────────────────────────┐
│  Default          2 trackers  │  Default                     │
│  Work             1 tracker   │  [ Open Default ]            │
│  Client           1 tracker   │  [ Open URL ]                 │
│  [+]                          │  [ Reset Sign-In Data… ]      │
│                               │                               │
│  Each row has a stable colour │  ID, CDP endpoint, and local  │
│  + initials badge.            │  user-data path are visible.  │
└──────────────────────────────────────────────────────────────┘
```

Names and badge colours are editable, but IDs, user-data directories, and CDP
ports remain stable. Removal is blocked until all trackers move elsewhere;
reset/removal closes only that account's Chromium process and moves its data to
the Trash.

`Reset browser data` is destructive — it wipes the entire profile and forces
re-login on every tracked site. Confirmation dialog. The button exists so
users can recover from "I logged into the wrong account once and now
everything is wrong" without nuking the whole app.

**JS injection for inspect overlay** — sketch:

```js
(() => {
  const outline = document.createElement('div');
  outline.style.cssText = 'position:fixed;border:2px solid #2997ff;' +
    'pointer-events:none;z-index:2147483647;';
  document.body.appendChild(outline);
  const onMove = e => {
    const el = e.target;
    const r = el.getBoundingClientRect();
    Object.assign(outline.style,
      { left: r.left+'px', top: r.top+'px',
        width: r.width+'px', height: r.height+'px' });
    window.__statsWidgetHover = el;
  };
  const onClick = e => {
    e.preventDefault(); e.stopPropagation();
    const el = window.__statsWidgetHover;
    const r = el.getBoundingClientRect();
    const sel = synthesiseSelector(el); // attribute > class > nth-child fallback
    webkit.messageHandlers.elementPicked.postMessage({
      selector: sel, text: el.innerText.trim(),
      bbox: { x:r.left, y:r.top, width:r.width, height:r.height,
              viewportWidth: innerWidth, viewportHeight: innerHeight,
              devicePixelRatio: devicePixelRatio }
    });
    cleanup();
  };
  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('click', onClick, true);
  function cleanup() { /* remove listeners + outline */ }
})();
```

The Swift side receives the message, validates the selector against the
current DOM (does it return *exactly one* match? for Text mode, is the text
non-empty? for Snapshot mode, is the bounding rect non-zero?), then commits.
**Render mode is a render-time choice; the captured selector is the same in
both modes.**

## 7. Scraping strategy

Two render modes, two scrape strategies — same captured selector either way.

### 7.1 Text mode

- **Chrome/CDP scrape per tracker.** Open page, wait for `selector` to
  match, run `document.querySelector(selector)?.innerText`, write result,
  tear down.
- **Schedule.** Per-tracker `refreshIntervalSec`. Default **30 min**, min 5
  min (anything under that is asking for a 429), max 24 hours.
- **Driven by NSBackgroundActivityScheduler** in the main app for the
  standalone case, or by the optional Homebrew CLI's launchd agent for
  power-user setups.

### 7.2 Snapshot mode (long-lived session)

Snapshot mode is designed for **live-updating visual elements** — spinners,
animated bars, multi-line dashboards. Default polling cadence is **every 2
seconds**.

The naive approach — reload the page from scratch every 2 s — is hostile to
the target site (hammers their CDN, racks up 429s, looks like a bot) and
slower than the polling interval. Instead:

- **Long-lived page session.** When a snapshot tracker is added, the scrape
  engine opens the URL in a hidden Chrome/CDP and *keeps it open*. The page
  stays loaded; cookies, JS state, and auth tokens stay live.
- **Re-snapshot only.** Every 2 s the scheduler calls
  `webView.takeSnapshot(of: cachedRect, into: …)`, where `cachedRect` is the
  element bounding rect we captured at Identify time (re-resolved each tick
  if the element has moved).
- **In-memory only.** The PNG is written to
  `App Group/snapshots/<tracker-id>.png` (same fixed path, atomic replace).
  Older PNGs are not retained — old in-memory snapshots are discarded as the
  new one overwrites. **No file persistence for snapshot history.**
- **Wake-from-sleep handling.** When the app suspends, the long-lived
  session pauses. On wake, we run one `webView.reload()` to pick up
  whatever has changed since the last frame, then resume snapshotting.
- **Reload heartbeat.** Every 30 min the long-lived session does a
  background `webView.reload()` so we don't drift on long-running pages and
  cookies stay fresh.
- **Cap on concurrent snapshot trackers.** Each open page costs ~50 MB of
  memory. The app caps simultaneous snapshot sessions at **8**; beyond
  that, trackers cycle (active → suspended) on a least-recently-rendered
  basis.

### 7.3 Shared knobs

- **Browser profile.** `Chrome/CDPConfiguration` with
  `websiteDataStore = Chrome/Chromium user-data directory for the app profile`.
  Same identifier in app and headless scraper. Cookies, IndexedDB,
  localStorage, service worker registrations, passkey state — all
  persistent.
- **Throttle + jitter (text mode only).** ±20% jitter on every scheduled run,
  smeared across the interval window. Single in-flight scrape at any time
  across the whole app process. 30-second minimum gap between scrapes, even
  if two trackers are due at the same second. Snapshot mode is exempt —
  each tracker has its own long-lived session.
- **Backoff.** Exponential on HTTP 429 / 503: 5 min → 15 → 45 → 2h, cap at
  2h. Reset on next success.
- **Login flow.** User signs in via the Chrome/CDP browser; we never touch
  credentials directly. Cookies persist via
  `the app Chrome/Chromium profile directory`. Where the site offers passkeys we
  use `ASWebAuthenticationSession`.

## 8. Tracker failure and re-identify flow

When a site changes layout, the cached selector can stop matching. The app does
not try to auto-repair selectors or guess replacement values. It records the
failure, keeps the previous successful reading where available, and gives the
user a direct path back to Identify Element.

**Trigger conditions:**

- Selector returns `null` / empty.
- Selector matches but text doesn't parse per the tracker's `valueParser`
  (text mode only).
- Snapshot mode: the cached element node has disappeared from the DOM, or
  the captured rect resolves to 0×0.

**Failure handling:**

1. Each failed scrape writes `status = .stale`, `lastError`, and an incremented
   `consecutiveFailureCount` to `readings.json`.
2. Three consecutive failures mark the tracker `.broken`.
3. The widget renders the broken state clearly instead of inventing a value.
4. The app sends a macOS native notification: "<tracker> needs attention.
   Open the app to re-identify the element."
5. The notification/deep link opens the tracker in the normal Identify Element
   flow. Saving writes the new selector and bounding box like any other edit.

External agents use the same MCP surface as every other automation: call
`get_tracker`/`list_trackers` to inspect status, `update_tracker` if they know
a valid replacement selector, or `identify_element` over the running app socket
to ask the user to pick a new element in the visible browser.

**Notification payload.** macOS native notification by default, plus an
optional generic webhook (POST `{title, body, severity, trackerId}` to any
URL). The webhook payload is intentionally generic — it works with Slack,
Discord, Pushover, ntfy, n8n, or any custom endpoint. **No
Telegram-specific code anywhere in the app.**

## 9. Widget UI

The widget extension renders at four sizes and supports two render modes
(Text / Snapshot) with one mixed mode (Snapshot + Text on the same canvas).
A user typically combines a couple of multi-tracker dashboards with several
single-tracker widgets for the most-checked stats.

### 9.1 Verified widget dimensions

macOS WidgetKit uses the same point-based `WidgetFamily` cases as iOS, but
the macOS canvas dimensions differ from iPhone. Verified working dimensions
(Apple WidgetFamily docs + simonbs/ios-widget-sizes + forum 671621):

| Family | Points (W × H) | Use |
|---|---|---|
| `.systemSmall` | **155 × 155** | One glanceable primary value. |
| `.systemMedium` | **329 × 155** | Headline + secondary, or 2-column. |
| `.systemLarge` | **329 × 345** | Multi-row dashboard. |
| `.systemExtraLarge` | **690 × 318** | macOS-only. Dashboard-grade. |

Some Xcode reference templates show ±2–3pt (158 / 338 / 354) — design to
the smaller numbers as **minimum drawable area** plus default
`.containerBackground`. Margins follow the HIG: **16pt** for text-heavy,
**11pt** for graphics-dominated, opt out via `.contentMarginsDisabled()`
only for full-bleed snapshots.

### 9.2 Refresh model — macOS has no widget reload budget

This is the load-bearing fact for our scheduling design.

> **macOS WidgetKit imposes no daily timeline-reload budget.** Confirmed by
> an Apple Frameworks Engineer in the public dev-forum thread
> [711091](https://developer.apple.com/forums/thread/711091): *"On Mac,
> Widgets do not [have a budget]. On iOS the limit is 72 manual refreshes
> per day."*

Practical consequences:

- A `TimelineReloadPolicy.atEnd` with 5-minute entries on macOS is fine —
  that's 288 reloads/day and it'll be honoured. (On hypothetical iOS, the
  same policy would be throttled around reload 50.)
- The 5-minute minimum spacing between timeline entries is a separate,
  conservative HIG recommendation, not a hard cap.
- The architecture decouples *scrape cadence* from *widget reload cadence*.
  The scraper writes to the App Group at whatever interval the tracker
  needs (2 s for snapshot, 30 min for text). The widget's
  `TimelineProvider` reads the file on each tick, and the app calls
  `WidgetCenter.shared.reloadTimelines(ofKind:)` when a new reading
  meaningfully changes. macOS happily accepts forced reloads at high
  frequency.

If the project ever ships an iOS port, the per-instance ~40–72/day
budget would re-enter the picture **for iOS only** and would inform a
different reload policy there. macOS is not constrained.

### 9.3 The 12-template catalog

The widget extension ships **twelve curated templates**. Users compose a
*widget configuration* by picking a template and binding it to one or more
trackers.

**Small (4 templates — fit in 155 × 155):**

1. **Single Big Number** — Text · 1 tracker.
   Title (caption2, top-left, 11pt secondary) + hero number (centred,
   48–56pt rounded semibold) + footer (relative time + reset glyph).
   *Top-3 default. Use case: "I just want my Codex weekly spend, that's
   it."*
2. **Number + Sparkline** — Text · 1 tracker (with history).
   Title top, hero number mid-left (40pt), sparkline bottom-right
   (60×30pt) showing last 24 reads.
3. **Gauge Ring** — Text · 1 tracker (with min/max).
   Circular `Gauge` (`.accessoryCircular`-style ring), 90×90pt centred,
   current value in the centre, label below, threshold tinting (green
   < 70% / amber 70–90% / red > 90%).
4. **Live Snapshot Tile** — Snapshot · 1 tracker.
   Edge-to-edge cropped image of the page region, 4pt-radius rounded
   rect, 12pt overlay strip at bottom with name + timestamp.
   `.contentMarginsDisabled()` for full-bleed.

**Medium (4 templates — 329 × 155):**

5. **Headline + Sparkline** — Text · 1 tracker (with history).
   Left half: title + hero number (60pt+). Right half: larger sparkline
   (140×100pt) with subtle area fill + min/max labels.
6. **Dual Stat Compare** — Text · 2 trackers.
   Vertical divider, each side gets title + value (32pt) + delta arrow +
   tiny sparkline. Each side tinted with its own accent.
7. **Dashboard 3-Up** — Text · 3 trackers.
   Three equal columns. Each: 11pt title (top), 24pt value (mid),
   8pt delta + reset-time (bottom). Subtle 1pt vertical separators.
   *Top-3 default.*
8. **Snapshot + Stat** — Mixed (Snapshot + Text) · 1 snapshot tracker + 1
   text tracker. Left half (~155×155) cropped page screenshot tile,
   right half title + hero number (40pt) + footer.

**Large (3 templates — 329 × 345):**

9. **Stats List (Watchlist Style)** — Text · 4–6 trackers.
   Vertical list of ~50pt rows (6 fit). Each row: leading 16pt color chip,
   title (15pt), trailing right-aligned value (20pt mono digits), tiny
   sparkline (40×16pt), delta arrow.
   *Top-3 default. The "iOS Stocks watchlist" pattern adapted to spend
   trackers.*
10. **Hero + Detail** (single-tracker large) — Text · 1 tracker.
    Top third: title + hero number (72pt rounded bold).
    Middle third: full-width sparkline (320×100pt) with min/max/avg axis.
    Bottom third: 4-up secondary stats grid (today / week / month / cap).
11. **Live Snapshot Hero** — Snapshot · 1 tracker.
    Edge-to-edge full snapshot of the chosen page region (full-bleed,
    `.contentMarginsDisabled()`); top-left chip overlay with title +
    timestamp on a glass blur background.

**Extra Large (1 template — 690 × 318, macOS only):**

12. **Mega Dashboard Grid** — Mixed · 6–8 trackers.
    4×2 grid of stat tiles. Each tile: title + value (28pt) + tiny
    sparkline. One tile slot is replaceable with a snapshot.

The three **top-3 defaults** (Single Big Number, Dashboard 3-Up, Stats List
Watchlist Style) are the headline templates featured in App Store
screenshots and the first-launch flow's "drop a widget" suggestion.

### 9.4 Design lineage

The catalog draws from four well-tested patterns in the LLM-usage tracker
cohort and the macOS desktop-stats world:

- **CodexBar** ([github.com/steipete/CodexBar](https://github.com/steipete/CodexBar))
  — stacked **2-bar meter** (5h session window over weekly window) and
  **Merge Icons Mode** that combines providers into one icon. Informs Dual
  Stat Compare (#6) and the per-row chip language in Stats List (#9).
- **MeterBar** ([meterbar.app](https://meterbar.app/)) — **tiered
  disclosure** (menu-bar → notification widget → full dashboard) and
  **traffic-light status**. Informs the threshold tinting on Gauge Ring
  (#3) and the per-tile health colours on Mega Dashboard Grid (#12).
- **iStat Menus** ([bjango.com/mac/istatmenus](https://bjango.com/mac/istatmenus/))
  — the gold-standard **sparkline + threshold indicator** pattern for
  "many tiny numbers in a small canvas". Informs every template that pairs
  a number with a tiny indicator.
- **TokenTracker** ([github.com/mm7894215/TokenTracker](https://github.com/mm7894215/TokenTracker))
  — **a curated set of 4–10 desktop widgets, not infinite customization**,
  is the right product shape for this cohort. Validates our 12-template
  approach over a generic free-form canvas like Widgy.

Apple's own **Stocks** (watchlist + single-ticker), **Calendar**
(density-by-size), **Battery** (mini-ring multi-up), and **Weather**
(same-data-different-rows) are the system-app reference points each
template aligns with.

### 9.5 Composition + widget gallery UX

**Surface 1 — Built-in template gallery in the main app's Preferences.**

```
┌─ Widgets ────────────────────────────────────────────────────────┐
│  Filter: [Small] [Medium] [Large] [XL] · [Text] [Snapshot] [Mix] │
│                                                                   │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                │
│  │ Single Big  │  │ Number +    │  │ Gauge Ring  │   …            │
│  │ Number      │  │ Sparkline   │  │             │                │
│  │  $42.30     │  │  $231 ╱╲    │  │  ◜─◝ 62%    │                │
│  └─────────────┘  └─────────────┘  └─────────────┘                │
│                                                                   │
│  + Create configuration from a template                           │
└──────────────────────────────────────────────────────────────────┘
```

User picks a template card → the editor opens with slot-mapping dropdowns
populated from the user's tracker library. Save writes a row into
`widgetConfigurations` (template ID + tracker bindings + per-tracker accent
overrides).

**Surface 2 — macOS widget gallery / placed widget.**

The widget extension now uses `StaticConfiguration` and reads the first saved
`widgetConfigurations` row from the App Group store. macOS only needs to place
the widget from Edit Widgets; the app remains the configuration UI. This avoids
depending on a per-widget Edit sheet, which is not consistently exposed in the
macOS desktop widget menu during development. For the widget gallery itself,
`getSnapshot(in:)` checks `context.isPreview` and returns fast sample data per
widget family, matching Apple’s WidgetKit guidance that gallery previews should
use sample data when live app data is not immediately available.

This split — **rich configuration in the app, automatic rendering in the widget gallery/desktop widget** —
mirrors simple stock/weather-style widgets: the widget is already set up when
it is placed, and edits happen in the app.

### 9.6 Empty state (first run)

When no trackers exist, every widget renders an empty state:

```
   "Stats Widget from Website"
   "No trackers configured"
   [Open App ➜]
```

Tapping the deep-link button opens the main app's first-launch flow (§14).
**No silent default scrape.** The user is always in control of what data
the app pulls.

### 9.7 Accents, status states, and accessibility

Each tracker carries an SF Symbol name, a hex accent colour, and a label
override. The widget reads these from `trackers.json`.

Status states:
- `.ok` — black/white text per appearance, accent on icon only.
- `.stale` — value rendered with 50% opacity + "stale" tag.
- `.broken` — red label, "?" icon, last-known value crossed out.

Accessibility:
- VoiceOver: `"<tracker name>, <current value>, <delta>, updated <relative time>"`,
  `.accessibilityElement(children: .combine)` per stat block.
- Dynamic Type: text styles + `.minimumScaleFactor(0.5)` on hero numbers.
- Color-blind: pair threshold colours with directional glyphs (↑ ↓ →).
- Reduce Motion / Transparency: skip sparkline anim, fall back to
  `.regularMaterial`.
- Localisation: `Text(value, format: .currency(code: ...))`, never
  hard-coded "$".

## 10. App Store path & entitlements

| Entitlement | Value | Why |
|---|---|---|
| `com.apple.security.app-sandbox` | `true` | Required for App Store. |
| `com.apple.security.network.client` | `true` | Chrome/CDP browser, headless scraper, MCP socket, webhook POSTs all need outbound. |
| `com.apple.security.files.user-selected.read-write` | `true` | Export / import selector packs from a Finder picker. |
| `com.apple.security.application-groups` | `group.com.ethansk.macos-widgets-stats-from-website` | Shared container with widget extension. |
| `com.apple.security.network.server` | *unset* | The MCP server uses stdio or a UNIX socket — neither needs the server entitlement. |
| `com.apple.security.device.audio-input` etc. | *unset* | We touch no AV devices. |

The widget extension's entitlements are a **subset**: only `app-sandbox` and
`application-groups`. No network. No file access outside the App Group.

**Review risks (and mitigations):**

1. *Chrome/CDP browser scraping third-party sites.* App Store has accepted this
   pattern for password managers, Read Later apps, archive tools, and so on.
   Framing: "the widget acts on your behalf, with your credentials, on
   pages you can already see in your own browser."
2. *Persistent third-party cookies via `Chrome/Chromium profile storage`.* Standard API,
   well-precedented. No extra disclosure beyond a privacy-policy line.
3. *Embedded MCP server.* Uses stdio (no network listener) or a UNIX socket
   inside the App Group container (sandbox-permitted). No
   `network.server` entitlement required. The MCP surface is local to the
   user's machine — explained in the privacy disclosure.
4. *No private APIs in the widget extension.* Verified by automated lint
   pre-submission.
5. *No CLI in the App Store build.* The optional CLI is a **separate
   target** excluded from the App Store archive. Homebrew tap publishes
   the CLI artefact (separate repo: `homebrew-macos-widgets-stats-from-website`).
6. *No external-process spawning from the sandboxed app.* The app does not
   invoke `codex` / `claude` / any binary; AI involvement only happens via
   the MCP server, initiated by the user's own agent session out-of-process.
   (This was an earlier risk; the v0.0.4 design eliminates it entirely.)

The App Store submission is the *app + widget extension only* and is
**fully functional standalone**: it scrapes via
`NSBackgroundActivityScheduler`, exposes its MCP server, and ships the
12-template catalog. The optional Homebrew CLI is a power-user adjunct
(custom schedules, headless server use, scriptable bulk ops). Users who never
install the CLI get a complete product.

## 11. Phased rollout

| Version | Deliverable |
|---|---|
| **v0.0.x** | Scaffold (PLAN.md, README, LICENSE, .gitignore). v0.0.4 = canonical pre-implementation state. No code. |
| **v0.1** | `project.yml` → xcodegen → Xcode project → empty app + empty widget extension + empty CLI all build green. CI smoke. |
| **v0.2** | Main app with Preferences UI; trackers list, add/edit form, no scraping yet. Local persistence to `trackers.json`. |
| **v0.3** | Element-capture flow working in the Chrome/CDP browser. JS overlay, selector synthesis, preview pane, save round-trip. Sign-in / Re-sign-in / Reset Browser panel. |
| **v0.4** | App-internal scraping: `NSBackgroundActivityScheduler` firing per-tracker scrapes; Text mode write-out. App Group `readings.json` round-trip. |
| **v0.5** | Widget reads from App Group; Text mode renders with sparkline; configurable per-instance via Intent. First few of the 12 templates implemented. |
| **v0.6** | Snapshot mode rendering on all sizes. Long-lived session pattern, 2 s polling, `takeSnapshot(of:rect)`. Cropper validated against fixture pages. |
| **v0.7** | Widget configurations editor + the full 12-template catalog. Layouts: grid / stack / single. Built-in template gallery in Preferences. |
| **v0.8** | Broken-tracker status + user-driven re-identify path. macOS native notification + generic webhook. |
| **v0.9** | Embedded MCP server (§13). Full tool set + auth + transport selection. Local diagnostic logging. |
| **v0.10** | Selector packs: JSON export / import, Open-With + drag-drop into the main app. |
| **v0.11** | First-launch flow (§14): sign-in → Identify Element → first widget. **No CLI detection step.** |
| **v0.12** | Polish: error states, fail-safe, `.broken` status, re-Identify flow refinements, Homebrew CLI installer + LaunchAgent. |
| **v1.0** | Polish, screenshots, GitHub Pages site, README setup walkthrough filled in. Mac App Store submission (app + widget extension only). |
| **v1.1** | Homebrew tap published (`homebrew-macos-widgets-stats-from-website`). |
| **v1.2** | Public selector pack gallery (community contributions, separate public repo). |
| **v2.x** | Cross-browser support: Chrome via CDP, Firefox via Marionette. Same selector / capture flow, different transport. Optional, only if Chrome/CDP proves limiting. |

Each minor version is a working, demoable build. We ship dogfood builds
between every two minors.

## 12. Resolved decisions

The seven open questions in v0.0.1, the follow-up requirements raised in
the v0.0.2 / v0.0.3 voice notes, and the canonical-state clarifications
folded into v0.0.4 are recorded here. Each entry: question / requirement →
resolution → one-line reasoning.

### 12.1 Notification path
*Question:* Telegram via dot-claude bot, or dedicated bot, or something else?
*Resolution:* macOS native (`UNUserNotificationCenter`) by default, *plus* an
optional generic webhook (POST `{title, body, severity, trackerId}` to any
URL — Slack, Discord, Pushover, ntfy, n8n). **No Telegram-specific code
anywhere.**
*Reason:* Native notifications are zero-config and work for 90% of users; the
generic webhook covers the other 10% without locking us to a single chat
platform.

### 12.2 Widget refresh budget
*Question:* Share WidgetKit's reload budget across trackers, or one widget per
tracker?
*Resolution:* **macOS has no widget reload budget** (Apple forum 711091; the
~40–72/day cap is iOS-only). Decouple anyway: scrape schedule is owned by the
main app's `NSBackgroundActivityScheduler`; widget timeline reload governs
*visual* refresh only. Multi-tracker dashboard widgets *and* single-tracker
widgets are both first-class.
*Reason:* The two concerns have different cadences. Even on iOS (if we ever
port), the budget is per widget instance, not per tracker. On macOS it's a
non-issue.

### 12.3 Broken-selector recovery strategy
*Question:* Should the app guess repairs, call an AI CLI, or keep recovery
manual?
*Resolution:* Keep recovery explicit. The app records stale/broken status and
opens the normal re-identify flow. Agents can inspect status via MCP, write a
known selector with `update_tracker`, or call `identify_element` over the app
socket to ask the user to pick the element in the visible browser. There is no
automatic value guessing and no dedicated selector-repair feature.
*Reason:* Guessing values is worse than showing a broken state, and spawning
external binaries from a sandboxed app is brittle and review-risky. MCP remains
the clean automation surface without making selector repair a separate product
feature.

### 12.4 Sparkline retention
*Question:* Last 24, last 7 days, last 30 days?
*Resolution:* Display last 24 readings in widget UI. Retain **7 days
default** (336 points at 30-min cadence), **30 days max**. Per-tracker
configurable.
*Reason:* Display window stays small for visual clarity; retention is
generous-but-bounded so power users can scroll a longer history without
ballooning the App Group file size.

### 12.5 First-run experience
*Question:* Empty-state CTA, or silent default scrape?
*Resolution:* **Layered.** Widget empty-state CTA (deep-links into main app)
+ first-launch flow with custom URL → render/config choice → Identify Element
→ explicit Save Tracker → first widget. **No silent default scrape and no
AI-spend-specific starter defaults.** The first setup path always starts from
a URL the user enters.
*Reason:* Privacy-respecting, user-in-control, with a generic fast path so the
first tracker takes <60 s without implying the product is only for LLM spend.
Silent scrape is the dark-pattern surface we want to avoid.

### 12.6 App Store + Homebrew
*Question:* Is App Store-only acceptable without the CLI?
*Resolution:* **Yes.** Main `.app` does its own scheduled scraping via
sandbox-safe `NSBackgroundActivityScheduler`. App + widget standalone fully
functional. CLI is the optional power-user adjunct (custom schedules,
headless server use, scriptable bulk ops, automation).
*Reason:* `NSBackgroundActivityScheduler` is the right Apple-blessed surface
for "rerun this every N minutes" inside a sandboxed app. The CLI is never a
hard dependency.

### 12.7 Selector packs
*Question:* Shareable JSON export?
*Resolution:* Yes — at v1.0. Format:
`{schemaVersion, name, url, mode, selector, cropRegion, label, icon,
hideElements}`. **Strictly no scripts** in the JSON. Open-With + drag-drop
into the main app. Export from each tracker's settings. v1.2+ adds a public
selector-pack gallery in a separate repo.
*Reason:* Users want to share configs; forcing every user to repeat
Identify Element for the same site is silly. No-scripts policy guards
against import-as-attack.

### 12.8 Terminology cleanup
*Requirement:* The product is **not specifically about metrics** — it tracks
any text or visual region on a webpage. LLM usage is just the canonical
example.
*Resolution:* "metric" / "metrics" → **"tracker" / "trackers"** throughout
PLAN.md, schema, variable names, README. "Metric ID" → "tracker ID".
"Metric history" → "tracker history". "Metric mode" → "render mode".
*Reason:* Naming the product around its narrow first use case constrains
everyone's mental model later. "Tracker" is generic and honest.

### 12.9 Render mode terminology
*Requirement:* Drop "Number mode" / "Screenshot mode" framing.
*Resolution:* Use **"Text mode"** (extracts `element.innerText` via JS,
renders as SwiftUI Gauge / Text in widget) and **"Snapshot mode"** (captures
the element's bounding rect via `Chrome/CDP.takeSnapshot(of:rect)`, renders
as `Image()` in widget). Both modes use the **same captured selector** —
mode is render-time behaviour, not capture-time behaviour.
*Reason:* "Number" was a lie because text-mode handles non-numeric text
too. "Screenshot" implied a full-page capture, but we only ever capture the
element rect.

### 12.10 Snapshot polling cadence
*Requirement:* Snapshot mode = **every 2 seconds** for live updates.
*Resolution:* Default 2 s for Snapshot mode; mechanism is a long-lived
Chrome/CDP page session that keeps the page loaded and only re-snapshots the
element rect each tick. Old snapshots overwritten in memory; **no file
persistence** for snapshot history. 30-min reload heartbeat keeps the
session fresh. 8-tracker concurrency cap, LRU recycle past that. Text mode
default stays 30 min.
*Reason:* 2-s reload-from-scratch would be hostile to target sites and
slower than the polling interval. Long-lived session is cheap (~50 MB per
tracker, capped) and gives near-real-time visuals.

### 12.11 Sign-in persistence APIs
*Requirement:* Use the proper macOS APIs for session persistence.
*Resolution:*
- `Chrome/Chromium user-data directory for the app profile` for the named
  persistent cookie / IndexedDB / localStorage profile.
- **Keychain Services API** for any user-entered credentials (rare, since
  most tracked sites are OAuth/SSO).
- **Passkey APIs** (`AuthenticationServices` framework,
  `ASWebAuthenticationSession`) where the site supports passkeys.
- Preferences panel: "Sign in / Re-sign in / Reset Browser" — clear cookies,
  switch profile, re-login any tracked site.
*Reason:* Apple has correct primitives for each layer; we use them rather
than rolling our own.

### 12.12 Multiple widget configurations
*Requirement:* A user can define widget compositions in the app and have the
macOS widget show the current saved composition without extra setup.
*Resolution:* `widgetConfigurations` array in `trackers.json` with shape
`{id, name, templateID, size, [trackerIDs], layout, showSparklines,
showLabels}`. The WidgetKit extension uses `StaticConfiguration` and picks the
first saved configuration, falling back to the first tracker if no explicit
widget configuration exists.
*Reason:* During desktop-widget testing, macOS did not expose a reliable
per-widget Edit sheet for this development build. The app is now the source of
truth: configure in the app, then the widget gallery/desktop widget is already
set up when placed.

### 12.13 Embedded MCP server (kept and expanded)
*Requirement:* The main `.app` exposes an MCP server that **fully controls
the app and does everything** — every app feature is reachable as a tool.
External clients (user's MCP client, local MCP client, optional Homebrew CLI,
anything else that speaks MCP) connect via the same server. This is the
**single agent surface**.
*Resolution:* §13 specifies the full tool set (CRUD, scrape, identify,
selector packs, widget configs), transport choice (stdio for headless local
operations, UNIX socket for always-on app control), auth model (socket file
permissions + Keychain shared secret), and security (human-in-loop on
`identify_element`, rate limits on destructive ops, URL validation, local
diagnostic logging).
*Reason:* The whole product becomes much more useful when the user's agents
manage it without clicking through Preferences. This is the natural
endpoint for "tracker as a generic concept" plus "user's already-paid-for
agent does the heavy lifting".

### 12.14 Notifications stay generic (Telegram explicitly out)
*Requirement:* No Telegram-specific code in the app.
*Resolution:* macOS native (UNUserNotificationCenter) + optional generic
webhook (POST `{title, body, severity, trackerId}` to any URL). The webhook
is a single string — Slack, Discord, Pushover, ntfy, n8n, Telegram-via-Bot
(if the *user* sets up a webhook bridge), or anything else.
*Reason:* Locking the app to a single chat platform is wrong product
design. The user's notification preferences are personal.

### 12.15 No agent chat panel UI
*Requirement:* Confirm there is **no in-app chat surface** for talking to an
AI agent.
*Resolution:* Confirmed. The MCP server (§13) is the agent surface; the
agent runs in the user's existing CLI session (local MCP clients /
anything else MCP-speaking), not inside our app. We render no chat UI.
*Reason:* Building a chat surface is a huge product decision and well
outside the "quiet number on the desktop" scope. The MCP integration covers
the same intent without us shipping a chat client.

### 12.16 First-launch flow has no CLI-detection step (DROPPED)
*Requirement (canonical state):* The first-launch flow must not auto-detect
or recommend installing AI CLIs. The product works fully without any
external CLI; agents that want to talk to it connect via MCP separately.
*Resolution:* §14 specifies a three-step flow: custom URL → render/config +
Identify Element → first widget. The previously-planned "Detect AI CLIs" step
is deleted.
*Reason:* Detecting specific agent binaries would couple the app to one
agent ecosystem, suggest the app *needs* one, and leak the user's installed
agents into our preferences file. The MCP server is opt-in plumbing, not a
first-launch concern.

### 12.17 Quick-Setup Skill installer (DROPPED)
*Requirement (canonical state):* No buttons in Preferences that write agent
skills, prompts, or global instructions into user dotfiles.
*Resolution:* The Quick-Setup pane and its agent-specific skill installers are
removed entirely. Documentation explaining how to wire an external local MCP
client session into our MCP server lives in the README and project website only
— never as an in-app installer.
*Reason:* Writing into the user's home directory from a sandboxed App Store
app is a review risk and a trust risk. A README pointer plus a Keychain
secret the user can copy by hand is the right level of help.

### 12.18 No internal AI CLI invocation (DROPPED)
*Requirement (canonical state):* The app must never spawn `codex` /
`claude` / any AI binary itself.
*Resolution:* `AICLIInvoker.swift` and the bundled-CLI repair path are gone.
If the user wants an AI agent involved, it runs *out of process* and talks to
the ordinary MCP tools from the user's own agent session. The no-AI baseline is
clear stale/broken status plus the re-identify flow.
*Reason:* Spawning external binaries from a sandboxed app is brittle and a
review risk. Out-of-process via MCP is the clean separation.

### 12.19 Widget catalog: 12 curated templates
*Requirement:* Replace the prior "small / medium / large layouts" sketch
with a concrete catalog of curated, shippable widget templates.
*Resolution:* §9.3 enumerates 12 templates spanning Small/Medium/Large/XL
and Text/Snapshot/Mixed modes, with Single Big Number, Dashboard 3-Up, and
Stats List Watchlist Style as the **top-3 defaults**. §9.4 documents the
design lineage (CodexBar / MeterBar / iStat Menus / TokenTracker plus
Stocks / Calendar / Battery / Weather).
*Reason:* The TokenTracker / CodexBar evidence shows curated catalogs win
in this cohort. A free-form canvas (Widgy) is a v2 concern at best.

### 12.20 Verified WidgetKit dimensions and refresh model
*Requirement:* Replace the rough "small / medium / large" point hints with
verified dimensions; correct any references implying macOS has a widget
reload budget.
*Resolution:* §9.1 lists 155×155 / 329×155 / 329×345 / 690×318 as verified
working dimensions. §9.2 documents that **macOS WidgetKit has no daily
reload budget** (Apple forum 711091); the ~40–72/day figure applies to iOS
only. The architecture decouples scrape cadence from widget reload
cadence.
*Reason:* Earlier drafts treated the iOS budget as a macOS constraint. It
isn't. Designing around a non-existent constraint would have over-throttled
us.

## 13. MCP Server

The main `.app` ships an embedded MCP server. **It is the only agent
surface.** External MCP clients (the user's MCP client, local MCP client, the
optional Homebrew CLI, anything else that speaks MCP) connect to it and
operate the tracker fleet. The server "fully controls the app" — every
user-facing feature is reachable as a tool.

### 13.1 Transport

Two transports, picked at startup based on caller context:

- **Stdio.** When invoked as a child process by an MCP client (the agent's
  MCP config points at the app executable with `--mcp-stdio`, or to the
  standalone CLI with `mcp-stdio`). JSON-RPC 2.0 over stdin / stdout using
  standard MCP `Content-Length` framing; newline-delimited JSON is also kept for
  local smoke clients. **App Store-safe** — no socket, no listener, no network
  server entitlement.
- **UNIX domain socket.** When the main app is already running, it binds a
  socket inside the App Group container (Preferences → MCP shows the exact
  path, normally `~/Library/Group Containers/group.com.ethansk.macos-widgets-stats-from-website/mcp.sock`)
  and serves the same JSON-RPC. Clients can connect without re-launching the
  app. Sandbox permits sockets inside the App Group container.

The agent picks one — **stdio** is suitable for headless tracker/configuration
operations, while **socket** is required for tools that need the live app UI
(such as opening the visible browser for Identify Element).

### 13.2 Tool catalog

The MCP server exposes the entire app feature set as tools. Initial set:

| Tool | Signature | Description |
|---|---|---|
| `get_status` | `() → Status` | Server status, Browser Accounts, transport, data counts, tracker health counts/IDs, and available tool names. |
| `list_browser_accounts` | `() → [BrowserAccount]` | List account IDs, names, colours, tracker counts, CDP endpoints, and local data directories. |
| `add_browser_account` | `(name, colorHex?) → BrowserAccount` | Create a new isolated Browser Account; the user signs in through Preferences. |
| `update_browser_account` | `(id, name?, colorHex?) → BrowserAccount` | Rename or recolour an account without changing its login/session identity. |
| `list_trackers` | `() → [Tracker]` | Return all trackers with current values, status, last-updated. |
| `get_tracker` | `(id) → Tracker & {history}` | Current value + sparkline + full config. |
| `add_tracker` | `(name, url, browserProfile?, renderMode, selector, …) → {id}` | Add a tracker assigned to a Browser Account. Selector required if known; if absent, agent should call `identify_element` instead. |
| `update_tracker` | `(id, fields…) → Tracker` | Modify the Browser Account, name, URL, selector, element bounds, label, icon, refresh interval, etc. |
| `delete_tracker` | `(id) → {ok}` | Remove a tracker (also unlinks from any `widgetConfigurations`). |
| `trigger_scrape` | `(id) → TrackerResult` | Force-refresh one tracker now. |
| `reset_tracker_failure_state` | `(id, reason?) → Tracker` | Clear stale/broken failure metadata after a manual repair and mark the tracker stale until the next scrape proves it works. |
| `identify_element` | `(trackerId?, url?, browserProfile?) → {trackerId, status: "awaiting_user"}` | **Human-in-the-loop.** Socket-only. Open the selected Browser Account, prompt the user for sign-in + Identify Element, then update the existing or pending tracker. |
| `list_widget_configurations` | `() → [WidgetConfiguration]` | All widget compositions. |
| `get_widget_configuration` | `(id) → WidgetConfiguration` | One widget composition. |
| `update_widget_configuration` | `(id, fields…) → WidgetConfiguration` | Rename, change template, change size, reorder trackers, change layout. |
| `delete_widget_configuration` | `(id) → {ok}` | Delete a widget composition. |
| `export_selector_pack` | `(trackerId) → SelectorPackJSON` | Serialize one tracker as a sharable selector pack. |
| `import_selector_pack` | `(json) → {trackerId}` | Add a tracker from a selector pack. |
| `attach_webhook` | `(url \| null) → {ok}` | Set / clear the generic notification webhook. |

Future tools (post-v1, listed for visibility): `pause_tracker`,
`resume_tracker`, `bulk_export`, `bulk_import`, `list_widget_templates`.

### 13.3 Authentication

- **Stdio** transport requires no extra auth — the parent process spawned
  us, file-system permissions are already enforced.
- **UNIX socket** transport uses two layers:
  1. **File permissions.** The socket is created mode `0600` owned by the
     user. Only the user's own processes can connect.
  2. **Shared-secret handshake.** On `initialize`, the client must send a
     token stored in Keychain under `mcp-secret/macos-widgets-stats-from-website`. The
     token is regenerated on each app launch. The user retrieves the
     current token from Preferences → MCP → "Reveal token" (or via `mcp-token`
     in the companion CLI) and passes it either as an `X-Auth: <token>` header
     line before the first JSON-RPC request or as `initialize.params.token`.

### 13.4 Security

- `identify_element` always requires a **human in the loop** and the live app
  socket transport — the user must complete the capture flow in the visible
  browser. This prevents an agent (compromised or otherwise) from quietly
  tracking new pages.
- `add_browser_account`, `update_browser_account`, `add_tracker`, `update_tracker`, `delete_tracker`, `update_widget_configuration`,
  `delete_widget_configuration`, `import_selector_pack`, `attach_webhook`, and
  `reset_tracker_failure_state` are state-changing; the app rate-limits them
  (max 10 destructive/state-changing operations per minute per session) and
  reloads the UI from disk after MCP configuration changes.
- All scrape URLs are validated as `https://` only (or `http://localhost`
  for testing). No `file://`, no `javascript:`.
- The MCP server writes a local diagnostic log to
  `~/Library/Logs/Stats Widget from Website/mcp.log` with timestamp, tool name,
  and argument-key fingerprint (no sensitive values). Logging is for support and
  troubleshooting; there is no in-app audit-log UI.
- Per-tool rate limits on top of the destructive-op cap above; full table
  ships with the v0.9 implementation tag.

### 13.5 How users connect their agent

This is documentation, not code, and lives in the README and project site —
**not** as in-app installer buttons. Sketch:

```
# local MCP client (~/.claude/skills/your-name-here/SKILL.md)
This MCP server is at /Applications/Stats Widget from Website.app/Contents/MacOS/MacosWidgetsStatsFromWebsite --mcp-stdio
Socket path/token: see Preferences → MCP in the running app

# Codex CLI (~/.codex/AGENTS.md or whatever the user uses)
Same idea — point your agent's MCP config at the binary or socket.
```

The exact text for each agent ecosystem is left to the agent's docs;
shipping a one-button installer that writes into the user's dotfiles is a
trust / sandbox / review risk we explicitly avoid (see §12.17).

## 14. First-Launch Flow

Three steps, on first app launch. Each is skippable; skipping degrades the
experience but never blocks the install. **There is no CLI-detection step**
— the app does not know or care which AI CLIs the user has installed.

### Step 1 — Enter the first URL

```
┌─ Start with any website ───────────────────────────────────────┐
│  Paste the page you want to track:                              │
│                                                                 │
│   [ https://example.com/dashboard                         ]     │
│                                                                 │
│  You can sign in and move around inside the Chrome/CDP browser      │
│  before choosing the exact value or region.                     │
│                                                                 │
│              [ Skip ]                         [ Continue ]       │
└─────────────────────────────────────────────────────────────────┘
```

There are no vendor-specific or AI-spend starters in the first-run path. The
user enters any http/https URL (scheme may be omitted for normal domains).
We never store credentials; cookies persist via the app-owned Chrome/Chromium
profile, including passkey-capable browser flows.

### Step 2 — Configure and Identify Element

The standard capture flow from §6, walked through with inline guidance:
"In the browser, sign in if needed, click Identify Element, hover the value
or region, then click to preview and use it." User names the tracker, picks
render mode (Text / Snapshot), picks the first widget template, sets SF
Symbol + accent, captures the element, then explicitly clicks **Save Tracker**
to commit to `trackers.json`.

### Step 3 — Add a widget

```
┌─ Drop a widget on your desktop ────────────────────────────────┐
│  We just made your first widget configuration:                  │
│                                                                 │
│   "example.com Tracker Widget" — Single Big Number — Small      │
│                                                                 │
│  How to add it:                                                 │
│   1. Right-click the desktop ➜ Edit Widgets                     │
│   2. Search "Stats Widget from Website"                  │
│   3. Drag the matching size onto your desktop                   │
│   4. Widget uses the app's saved configuration automatically    │
│                                                                 │
│              [ I'll do this later ]    [ Done ]                  │
└─────────────────────────────────────────────────────────────────┘
```

The first configuration is built from the template the user chose in Step 2
and bound to the tracker they just saved. The flow ends. Re-open any time
from Help → "Show First-Launch Flow".

## 15. Pre-implementation TODO

Before tagging v0.1 and writing the first line of Swift, run this PLAN.md
through Codex review:

```
codex review PLAN.md
```

…or use any repo-review agent workflow against the staged plan diff. The review
should flag ambiguities, missing-piece risks, and contradictions; the maintainer
then applies fixes / clarifications and loops until LGTM.

If the review surfaces material changes — new sections, schema bumps, flow
rewrites — bump the tag (v0.0.5, v0.0.6, …) before implementation starts.

Specific things to validate in that review:

- Are the schema migrations (1 → 2 → 3 → 4) actually safe / lossless?
- Is `NSBackgroundActivityScheduler` the right surface, or should we also
  consider `BGAppRefreshTask`-style alternatives on macOS 14+?
- Does Chrome/CDP snapshot capture stay reliable across logged-in dashboards,
  page reloads, and repeated scheduled scrapes?
- Are the MCP tool signatures stable enough to not break agents on v1.0?
- Is the MCP shared-secret rotation good UX, or a footgun? (Acceptable
  alternative: a launchd-survivable token, or "trust this client" toggle
  pinning the token until manually invalidated.)
- Is "App Store + Homebrew" framing legally clean (no implication that the
  App Store version *requires* Homebrew)?
- Are the 12 templates each implementable with the data we already capture
  (selector + bbox + render mode + sparkline history)?

Post-review, this section gets either ticked off or replaced with a
"Codex review highlights" sub-section before we cut v0.1.

> See [`docs/ux-research-v0.0.3.md`](docs/ux-research-v0.0.3.md) for the
> full WidgetKit research dossier (verified dimensions, refresh model,
> third-party tracker survey, 12-template catalog rationale, accessibility
> notes) that underpins §9 of this plan.
