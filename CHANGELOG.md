# Changelog

Release-by-release notes for the Stats Widget from Website project.

Format: each entry is dated, lists the user-visible changes first, then the
under-the-hood / signing / packaging changes. Newest first.

## v0.21.80 — 2026-07-06

### The "last updated" time is now a trustworthy "last successful refresh" signal

- **Tapping the reload button on a tracker row no longer makes the "last
  updated" time look like it jumped instantly.** While a scrape is in
  flight the row now shows an explicit **"Refreshing…"** label in place of
  the relative timestamp; the real time only (re)appears once the scrape
  has actually finished. On success it shows the new time; on failure it
  returns to the previous successful time — so the timestamp only ever
  advances when a scrape genuinely worked.
- Previously the only in-flight cue was the tiny button spinner, so a fast
  (warm-tab) success made the freshly-advanced time look like it updated
  "before the refresh finished". The displayed value was already bound to
  `lastUpdatedAt` (which the scrape layer only stamps on a real success,
  and which failures leave untouched), so this is purely a
  clarity/affordance fix — the timestamp's meaning is now unambiguous.

## v0.21.78 — 2026-06-08

### Under-the-hood — MCP can finally WRITE secondary elements + slot bindings (voice 4501)

- **`update_tracker` now accepts a `secondaryElements` array.** Previously
  the MCP read payloads emitted `secondaryElements` (on trackers) and
  `secondaryElementIDsBySlot` (on widget configs) so they *looked*
  settable, but the update handlers parsed neither — they were output-only.
  An agent could read a secondary element but had no way to add one, edit
  one, or change its parser via MCP; the only write path was the SwiftUI
  editor. Now:
  - Omit `id` → **add** a new secondary element (a UUID is generated).
  - Include a known `id` → **edit** it (field-level merge — only the keys
    you send change; everything else is left alone).
  - Include `id` + `_delete: true` → **remove** it.
  - Send `[]` → clear all secondary elements.
  - `valueParser.type` accepts `raw` | `currencyOrNumber` | `percent`.
    Use `raw` for verbatim text passthrough (e.g. a "Resets Friday" line
    that should NOT be coerced to a number).
  The input mirrors the read-payload shape exactly, so a read → tweak →
  write round-trip works.
- **`update_widget_configuration` now accepts `secondaryElementIDsBySlot`.**
  A map of slot-index string → array of the bound tracker's
  secondary-element UUID strings. Replace semantics (send the full map;
  `{}` clears all bindings). This is what binds a secondary element into a
  widget slot as secondary text under the main number.
- Both tool input schemas + descriptions were updated to document the new
  fields. Changes go through the same `notifyConfigurationChanged()` path
  as every other update_* handler, so placed widgets reload their timelines.
- New pure parser `Shared/Models/SecondaryElementMCPParser` holds the JSON→
  model logic. It lives in `Shared/Models/` (not `Shared/MCP/`, which the
  unit-test target excludes) so the parsing is unit-testable; new tests in
  `SecondaryElementsCodableTests` cover edit-parser-in-place, add, remove,
  clear, unknown-id error, bad-parser-type error, all three parser types,
  and slot-binding decode/normalisation/validation.

## v0.21.54 — 2026-05-27

### User-facing — Identify-in-Chrome flow actually works now (voice 4277)

- **Click Identify in Chrome — one window, one tab, on the right
  page, picker banner visible from the moment the page loads.**
  v0.21.47 tried to fix this with `/json/activate/<id>` +
  `Page.bringToFront` but Ethan still saw four tabs (one per tracker),
  the wrong tab activated, no overlay UI, and a yellow Chromium banner
  about "use-fake-ui-for-media-stream". Voice 4277 (2026-05-27):
  *"the one I'm trying to identify is not the last one is not the
  one the tab that's activated. Also there's literally no UI."*

  Root causes (3, all fixed in v0.21.54):
  1. **Background scrapers race-piled tabs into the foreground
     Chromium.** When the user clicked Identify, the headless
     Chromium was torn down + a headed one was launched. Background
     scrapers' `NSBackgroundActivityScheduler` windows continued
     firing during the launch, each one hit the
     `joined in-flight Chrome launch` coalescing path inside the
     same pending-launch slot, and ALL of them called `openTab(...)`
     the moment the headed Chromium booted — opening 3-4 extra
     tracker tabs in the user's window. The Identify-target tab
     got buried under the noise. **Fix:** new
     `identifyInProgressPorts` lock blocks scraper kickoffs for the
     duration of the Identify flow. Scrapes queue locally and drain
     when Identify finishes.
  2. **`about:blank` placeholder tab from the launch arg.** The
     spawn-headed code path always passed `["about:blank"]` as the
     trailing launch arg, then called `openTab` for the actual
     target URL. End-state: 1 placeholder tab + 1 target tab,
     placeholder foregrounded. **Fix:** new `initialURL` parameter
     on `ensureLaunched` makes Chromium boot DIRECTLY with the
     target page as its first/active tab. No more `about:blank`
     placeholder, no more `openTab` round-trip.
  3. **No visible overlay UI.** The inspect overlay was just a 2px
     blue hover-outline that only rendered AFTER the user moved
     their mouse over an element. If the user landed on the page
     and didn't move the mouse first, the flow looked like nothing
     happened. **Fix:** a top-of-viewport banner ("Identify Element
     — hover the value you want, click to capture, or press Esc to
     cancel.") renders the moment the overlay JS is injected, with
     `pointer-events: none` so it never blocks the underlying click
     target.

- **Yellow Chromium banner about "use-fake-ui-for-media-stream" is
  gone.** Voice 4277: *"it says using an unsupported command line
  flag, use fake UI for media stream, and security will suffer."*
  The flag was added in v0.21.45 as defense-in-depth against
  getUserMedia auto-prompts. It was always redundant with the
  consolidated `--disable-features=MediaCapture,WebAudio,...`
  bundle (which kills the entire AV-capture init path BEFORE any
  prompt fires). **Fix:** removed the flag from the launch-args
  list. `--use-fake-device-for-media-stream` (which does NOT
  trigger the banner) is kept as belt-and-suspenders.

- **Secondary-elements UX hidden behind a feature flag.** Voice
  4277: *"get rid of the whole secondary elements thing. Just put
  it behind the feature flag and comment it out or whatever."*
  **Fix:** new `ChromeBrowserProfile.enableSecondaryElements`
  static flag (default `false`). When false, the "Secondary
  elements" section + "+ Add secondary element" button no longer
  render in the tracker editor. The decoded model
  (`Tracker.secondaryElements`) still loads + saves as before, so
  existing trackers with stored secondary elements aren't broken
  — they're just not editable until the flag is flipped.

### Under-the-hood

- **Identify-in-Chrome flow rewrites `ensureLaunched(foreground:)`
  to ALWAYS tear down + spawn fresh.** Previous v0.21.47 behavior
  was "tear down if existing instance was headless, REUSE if it
  was already headed". The "reuse if headed" branch was a major
  source of stale-tab and wrong-tab-activated bugs: when persistent
  Chromium mode (v0.21.46+) keeps the browser alive across scrapes,
  the SAME Chromium can accumulate 4-6 tabs from background
  scrapes that Identify then inherited verbatim. Now: every
  Identify click → SIGTERM the Chromium → spawn a brand-new
  Chromium with the target URL as the only initial tab → known
  clean single-tab state.

- **Headed Chromium is torn down when Identify completes.**
  Previously the identify-spawned headed Chromium would linger
  until a scraper hit it on the next cycle. New
  `terminateHeadedIdentifyInstance` is called from the coordinator's
  terminal paths so the user-visible window vanishes cleanly. The
  next scrape spawns a fresh HEADLESS Chromium (which is the right
  default state for the background scrape loop).

- **Launch-time tab discovery via `findLaunchedIdentifyTarget`
  polls `/json/list` for up to 4s** to find the tab created by the
  trailing-URL launch arg. Falls back to `openTab` as a defensive
  backstop if some future Chromium version stops honoring trailing
  URL args.

## v0.21.53 — 2026-05-27

### User-facing — single TCC dialog per reboot (not two)

- **The "Stats Widget would like to access data from other apps"
  dialog now appears only ONCE per reboot, not twice.** Pre-v0.21.53
  the host fired 3–4 distinct file operations against the App Group
  container during `App.init()` (activity-log write, legacy-container
  migration, hook-scaffold backfill, store init) in rapid succession.
  macOS Sonoma+ does not coalesce these into a single TCC prompt — it
  queues one prompt per access, so the user saw TWO stacked dialogs
  per reboot. Per voice 4274 (2026-05-27): *"After restarting my
  computer, I always get stats widget. Would like to access data TCC
  dialogue, and there's two of them, and I have to click allow every
  time."*

  v0.21.53 adds a `TCCPrewarmer` that synchronously writes a tiny
  sentinel file to the Group Container as the absolute first line of
  `App.init()`, before any other code path can touch the directory.
  This issues exactly ONE TCC prompt; the calling thread blocks until
  the user clicks Allow. From that point on in the boot session, all
  subsequent accesses reuse the boot-bound TCC grant and prompt
  nothing further.

  The architecturally correct fix is to re-add the App Group
  entitlement to the host. That path is blocked by AMFI -413
  (restricted entitlements require an embedded Developer ID Direct
  Distribution provisioning profile, which the Sparkle release flow
  ships profile-free per v0.21.31). Embedding a profile is a larger
  CI change tracked for v0.22 — v0.21.53 ships the per-reboot
  single-dialog improvement now while the long-term fix is scoped.

## v0.21.50 — 2026-05-27

### User-facing — drag-and-drop reorder for widgets list

- **You can now drag-and-drop widget configurations in the Widgets pane**
  to reorder them. Mirrors the existing drag-and-drop on the Trackers list
  (shipped in v0.2). Order persists across app restarts via `trackers.json`.
  Pure organisation — no scrape impact, no widget rebinding (placed
  widgets keep their binding by configuration id, not list index). Per
  voice 4275 (2026-05-27): *"make it so I can drag and drop the widgets
  and the trackers around in the window the app window in the list of
  items. It's just organization."*

### Under the hood

- New `AppGroupStore.moveWidgetConfigurations(fromOffsets:toOffset:)`
  mirrors the existing `moveTrackers` method — same SwiftUI `.onMove`
  destination-adjustment math, persists via the same `persist()` path.
- WidgetConfigsView's `ForEach` over `store.widgetConfigurations` now has
  `.onMove(perform: store.moveWidgetConfigurations)`. SwiftUI handles the
  hover-revealed drag handles natively on macOS 13+ — no edit-mode
  toggle, no NSTableView wrapping.

## v0.21.46 — 2026-05-27

### User-facing — third-wave Chromium crash fix (Tahoe 26)

- **Two-pronged attack on the remaining browser-init SIGTRAPs.** v0.21.45
  dropped crash frequency but did not kill it — ~13 crashes were still
  landing per ~3 hours, all clustered at imageOffset 0x6816xxx (the same
  256-byte Chromium 150 browser-init code region). v0.21.46 ships both
  prongs of the planned fix:
  - **Prong A — more aggressive `--disable-features` + extra individual
    flags.** Disabled GlobalMediaControls, SystemNotifications, WebOTP,
    SmsReceiver, BackgroundFetch, BackgroundSync, PaymentRequest,
    PictureInPicture, ScreenCapture, AccessibilityService, PermissionsAPI,
    PresentationAPI, FaceTimeCalling, AmbientLight, ScreenAI, FedCm,
    AttributionReportingAPI, and many more Tahoe-touched Chromium
    features. Added `--disable-3d-apis`, `--disable-webgl`,
    `--disable-webgl2`, `--disable-vulkan`, `--no-experiments`,
    `--disable-back-forward-cache`,
    `--disable-component-extensions-with-background-pages`, and others.
    None of these subsystems are exercised by the DOM-only scraper, so
    disabling them is free.
  - **Prong B — persistent Chromium between scrapes.** Previously the
    host launched a FRESH Chromium per scrape; the terminate-after-scrape
    path is what re-exposes every scrape to the browser-init crash zone.
    The host now KEEPS Chromium alive between scrapes — only the tab
    lifecycle is per-scrape. Init-crash exposure drops from ~once per
    scrape (one crash every ~12-15 min on a 4-tracker config) to roughly
    once per app session (i.e. once per Mac boot / once per app
    relaunch). Recovery is unchanged: if Chromium dies for any reason,
    the next scrape detects the dead CDP port and spawns fresh.
    App-exit still tears Chromium down cleanly — no leaked processes.

### Under the hood

- `ChromeBrowserProfile.persistentBrowserMode` static toggle (default
  `true`). When on, `endBackgroundUse` short-circuits before the
  terminate block. Bookkeeping (`backgroundLaunchedProcesses` /
  `backgroundLaunchedApplications`) is left intact so
  `terminateAppOwnedBrowsersOnAppExit` still cleans up on quit, and
  `isExistingInstanceHeadless` can still vouch for app-ownership of the
  long-running process. Flip to `false` to revert to the v0.21.45
  per-scrape lifecycle.
- Consolidated `--disable-features` comma-list grew from 27 → 56
  feature names. Chromium dedupes feature names internally so order
  doesn't matter; the constraint is that it must remain ONE flag (the
  last `--disable-features` value wins; multiple would silently drop
  earlier ones).

## v0.21.45 — 2026-05-26

### User-facing — second-wave Chromium crash fix (Tahoe 26)

- **Stop the new browser-init SIGTRAP on macOS 26 Tahoe.** v0.21.40
  patched the original CrBrowserMain crash at imageOffset 0x6816010 by
  disabling the Web Speech API + audio output + notifications. Two new
  crashes on 2026-05-26 (18:15 + 18:48 BST) landed at imageOffset
  **0x6816050** — a sibling Chromium-150 browser-init code path 448
  bytes beyond the original. Unified system log captured a flurry of
  macOS API probes seconds before each SIGTRAP: CoreLocation
  (`CLLocationManager` init + authorization check), LocalAuthentication
  (5× `LAContext canEvaluatePolicy` calls, the Touch-ID / WebAuthn
  platform-authenticator probe), and TCC requests for
  `kTCCServiceMicrophone` + `kTCCServiceCamera` (`getUserMedia` /
  `MediaDevices.enumerateDevices` probe). We now disable ALL of these
  Chromium subsystems at launch — Geolocation, WebAuthn, MediaCapture,
  WebMIDI, WebUSB, WebBluetooth, WebHID, WebSerial, WebNFC, MediaSession,
  HardwareMediaKeyHandling, IdleDetection, ContactsAPI — none of which
  are ever used by the DOM-only scraper.

### Under the hood

- Added a single consolidated `--disable-features=...` comma-list in
  `ChromeBrowserProfile.swift::buildChromeLaunchArguments` (Chromium
  only honors one `--disable-features` flag — the last one wins, so
  the earlier `Translate,MediaRouter` gate was MERGED into the new
  list). Also added `--use-fake-ui-for-media-stream` +
  `--use-fake-device-for-media-stream` as belt-and-suspenders to
  prevent any AVCaptureDevice enumeration in case the feature flags
  miss a code path. Heavily commented at the launch-args site with
  the exact crash imageOffsets + the unified-log signals each flag
  is mitigating.

## v0.21.44 — 2026-05-26

### User-facing — no more stale widgets after a Sparkle install

- **Auto-refresh the widget extension on first launch after an update.**
  Before this fix, when Sparkle replaced the host app and restarted it,
  macOS `chronod` (the WidgetKit extension host daemon) would keep the
  OLD widget extension binary loaded in memory. Result: the host ran the
  new version but widgets kept showing stale values from the previous
  build — for as long as 30+ minutes — until something else forced
  chronod to drop its cache. We now detect "first launch after a host
  build change" and walk an escalation chain: (1) immediate
  `WidgetCenter.reloadAllTimelines()`, (2) after 5s, retry if widgets
  still serving old build, (3) after another 5s, `killall chronod` —
  the only path that reliably forces chronod to reload the new .appex
  binary. launchd respawns chronod within ~1s, so the user-visible
  blip is minimal and only happens once per update.

### Under the hood

- New code path: `AppDelegate.refreshWidgetExtensionsIfHostJustUpdated()`
  + helpers (`widgetExtensionHasQueriedSinceBuildChange`,
  `killChronodToForceWidgetExtensionReload`). UserDefaults key
  `lastSeenHostBuildAfterStartup` tracks the last-seen CFBundleVersion;
  Sparkle preserves UserDefaults across installs so the comparison
  survives the app replacement. Audited Apple's ChronoCore /
  WidgetKit headers for a public extension-binding invalidation API —
  none exists. `killall chronod` is the only known-working path and
  is well-commented as such in `AppDelegate.swift`.
- Logs every step under category `[widget-refresh]` in `activity.log`
  so the escalation chain is traceable. Verify success by checking
  for `[widget] ... build=<new-build>` lines after a Sparkle install.

## v0.21.43 — 2026-05-26

### User-facing — autonomous one-shot upgrade (Ethan voice 4212)

- **New MCP tool `upgrade_to_latest`.** One call probes Sparkle, dispatches
  the install if a newer version is available, AND flips Sparkle's
  silent-auto-update flag on so subsequent updates apply with no dialog
  on next launch. Returns `{ upgraded, reason, fromVersion, toVersion,
  automaticUpdatesEnabled, elapsedMs }`. Voice 4212: *"Is there an MCP
  hook in the app to go to the latest version so I can just tell you
  to upgrade stats... you should be able to see it through as well... clicking
  through all the things without any user intervention."* The first invocation
  on a fresh install still surfaces Sparkle's standard "install and relaunch"
  dialog because `SPUStandardUserDriver` doesn't expose a fully-headless
  first-install API — but every invocation AFTER the auto-update flag is
  set will install silently on quit. Result: terminal CC can now upgrade
  the stats widget host on demand without Ethan touching the menu bar.
- **Stdio-to-socket proxy fallback.** The three Sparkle MCP tools
  (`check_for_updates`, `install_pending_update`, `upgrade_to_latest`)
  were socket-only previously (Sparkle isn't linked into the `--mcp-stdio`
  CLI binary). v0.21.43 adds an automatic stdio→socket forwarder so
  terminal CC sessions (which talk to the host over stdio per
  `~/.claude/.mcp.json`) can now call these tools too — the stdio
  process reads the shared keychain token and forwards the JSON-RPC
  request to the running menu-bar host's Unix socket, then unwraps the
  response. Transparent to callers.

### Bug fixes — sparkle:version drift (Ethan voice 4212)

- **Build-suffix releases no longer publish to the Sparkle appcast.**
  Pre-v0.21.43 build-suffix releases (e.g. `v0.21.41-build.90`) encoded
  `sparkle:version` as `base_build * 100000 + run_number`, producing
  mega-numbers (e.g. 129700090) that interleaved with the small monotonic
  base_build values from tag releases (e.g. 1296 for v0.21.40). The
  next clean tag release would have a LOWER `sparkle:version` than the
  installed build-suffix release, and Sparkle (which uses CFBundleVersion
  numerically) would refuse to offer the tag update. Fix: the `Update
  gh-pages appcast` + `Commit appcast` steps in release.yml are now
  gated on `RELEASE_CHANNEL == 'tag'` (canonical tag pushes only).
  Build-suffix releases still produce a GitHub Release as a testing
  artifact, but they don't pollute the appcast.
- **`prepare_release_metadata.py` dropped the `base_build * 100000 +
  run_number` encoding** for build-suffix tags. Going forward,
  CFBundleVersion always equals `CURRENT_PROJECT_VERSION` (the
  source-of-truth value in `project.yml`), regardless of whether the
  release is a canonical tag or a build-suffix tag.
- **`CURRENT_PROJECT_VERSION` jump-leap to 129700091.** One-time bump
  past the highest historical mega-number (129700090, from
  `v0.21.41-build.90`) so v0.21.43 is guaranteed offerable as an update
  to every installed prior release — canonical tag installs (low
  build numbers, 1287–1297) AND build-suffix installs (mega-numbers up
  to 129700090). Future releases increment by 1 from here
  (`bump-and-tag.sh` default).

## v0.21.41 — 2026-05-26

### User-facing — major UX simplification (Ethan voice 4206)

- **Only the small widget remains.** Medium / large / extra-large widget
  sizes were dropped. Voice 4206: *"The fucking large size widget and the
  medium size widget, etcetera, don't actually seem to work. Maybe we
  should just remove them from the app, simplify the app because I don't
  need them and I don't even wanna test it. So just have the small size
  widget."* All currently-placed widgets are small, so this change has no
  visible impact on the desktop.
- **Widget templates are gone.** Previously the app offered 12 layouts
  (single big number, sparkline, gauge, dashboard 3-up, watchlist, mega
  dashboard, etc.). Voice 4206: *"just get rid of templates entirely.
  There's literally no need at all."* Every widget now renders the
  single-big-number layout. Existing widget configurations that
  referenced removed templates (gauge, dashboard, etc.) silently coerce
  to single-big-number on next load — no user re-configuration needed.
- **Template picker UI removed** from the widget configuration editor.
  Only one template ships, so the picker had nothing to choose between.
- **SF Symbol icon picker removed.** Voice 4206: *"What's the s f symbol?
  I don't see that being used anywhere in the widget. Can we get rid of
  that?"* Confirmed unused on the widget face itself; the field stayed
  only as a cosmetic UI knob in preferences. The stored
  `tracker.icon` value is preserved on disk (no data migration) — only
  the editor UI is gone. The trackers-list view still shows the icon as
  a cosmetic identifier.
- **Visual / gradient controls removed**, accent color stays. Voice
  4206: *"the visual stuff as well at the bottom, that configuration
  can go ... The color is the color stuff is useful, so keep that."*
  Gradient-mode picker dropped from the per-widget Visuals card.
- **Widget shows live values during refresh (was: blank/demo numbers).**
  After tapping the refresh button on a placed widget, the widget could
  briefly show a "—" or stale render while WidgetKit rebuilt the
  timeline (voice 4206: *"I just clicked refresh on one of the widget
  buttons and after a minute, it's now showing nothing, but the other
  two widgets are fine."*). The `TimelineProvider.placeholder` path
  used to return gallery-style fake numbers (`$42.18`, `$157`) during
  the reload window. Now `placeholder` calls the same live-data factory
  as the real timeline entry, so the most-recent reading shows
  continuously through the refresh — no flicker, no fake demo numbers.

### Under-the-hood

- `WidgetTemplate` enum collapsed from 12 cases to 1 (`.singleBigNumber`).
  Custom `init(from:)` coerces any legacy raw value
  ("dashboard-3-up", "gauge-ring", etc.) to `.singleBigNumber`, so
  existing `trackers.json` files keep decoding without crashing.
- Deleted template files:
  `Dashboard3Up.swift`, `DualStatCompare.swift`, `GaugeRing.swift`,
  `HeadlineSparkline.swift`, `HeroPlusDetail.swift`,
  `LiveSnapshotHero.swift`, `LiveSnapshotTile.swift`,
  `MegaDashboardGrid.swift`, `NumberPlusSparkline.swift`,
  `SnapshotPlusStat.swift`, `StatsListWatchlist.swift`. Only
  `SingleBigNumber.swift` remains.
- `StatsWidget.supportedFamilies` reduced to `[.systemSmall]`.
- Dead in-file `private struct ___WidgetView` types removed from
  `StatsWidget.swift` along with `SparklineView`, `SparklineShape`,
  `SnapshotImageView`, `SnapshotOverlay`.
- `WidgetTemplatesInfoView` + `TemplateIllustration` + Mock*
  illustration helpers removed from `WidgetConfigsView.swift`.
- `FirstLaunchWizardView.swift`: SF Symbol picker removed, "First
  widget layout" picker removed (single-option lists were meaningless);
  `availableWidgetTemplates(for:)` collapsed to `[.singleBigNumber]`.
- `AppGroupStore.inferredWidgetTemplate` collapsed — every input
  returns `.singleBigNumber`.
- WidgetKit `kind` ID (`MacosWidgetsStatsFromWebsite`) UNCHANGED so
  existing placed widgets re-pair after the update. Per voice 4192
  Ethan will "shit the bed" if we orphan his placed widgets — every
  identifier on the wire stays put.

## v0.21.40 — 2026-05-26

### Under-the-hood
- **Defensive Chromium flags for macOS 26 (Tahoe) browser-main crashes.** Over
  26 Chromium browser-main crashes today on the MBP (`CrBrowserMain` thread,
  `EXC_BREAKPOINT` / `SIGTRAP`, identical stack offset across crashes,
  6-9 seconds after launch). Three of those happened on v0.21.37+, AFTER the
  helper-entitlements fix — meaning the v0.21.37 fix correctly addressed the
  renderer JIT crashes but a SECOND distinct crash signature remained in the
  browser process. Unified system log right before each crash shows
  Chromium 150 probing macOS speech-synthesis voice catalog
  (`SiriTTSService #FactoryInstall`, `AssistantServices AFLocalization
  outputVoiceDescriptorForOutputLanguageCode "No descriptor found"` x10),
  CoreAudio HAL proxy errors, SafariServices SFUniversalLink errors,
  and a burst of 45+ TCC requests — strong evidence that Web Speech API
  init is the trigger on Tahoe.
- **Fix:** added five defensive Chromium launch flags in
  `ChromeBrowserProfile.swift`'s `buildChromeLaunchArguments`:
  `--disable-speech-api`, `--disable-speech-synthesis-api`, `--mute-audio`,
  `--disable-audio-output`, `--disable-notifications`. The scraper does
  pure DOM reads — none of these subsystems are needed. Belt-and-suspenders.
- **No user-facing change.** Widgets refresh as normal. The expected outcome
  is fewer "Chromium quit unexpectedly" macOS notifications + zero impact
  on scrape reliability (which already auto-recovered from these crashes).

## v0.21.39 — 2026-05-26

### User-facing
- **"Check for Updates…" is now everywhere it should be.** It was already in
  the menu-bar status item, but Ethan didn't realise that was the only place.
  v0.21.39 also adds it to the **About** preferences section (with a "Last
  checked X ago" relative timestamp + a subtle note that updates are installed
  automatically) and to the standard **App menu** right after the system
  "About" entry, matching every other Mac app's conventions. All three
  entry points call the same Sparkle path — behaviour is identical.

### Under-the-hood
- **MCP Unix-domain socket fix — `socket_path_too_long` since v0.21.0.**
  The embedded MCP server's socket path lived under the Group Container
  (`~/Library/Group Containers/T34G959ZG8.group.com.ethansk.macos-widgets-stats-from-website/mcp.sock`),
  which is 122 bytes — well over macOS's `sun_path` cap of 104 bytes. Every
  host launch since v0.21.0 has been failing the `bind(2)` call and silently
  logging `socket_path_too_long` to `~/Library/Logs/macOS Widgets Stats from
  Website/mcp.log`. The host's external-MCP-over-socket path has therefore
  been broken for months. Stdio (`--mcp-stdio`) was unaffected because it
  skips the bind entirely, which is why `.mcp.json`-based external CC access
  kept working.
- **Fix:** socket moved to `NSTemporaryDirectory()/mcp.sock` (~57 bytes per-user
  under `/var/folders/<XX>/<YY>/T/`). Group Container holds user data and is
  intentionally not touched — only the ephemeral socket relocates. Hook
  scripts pick the new location up automatically via the
  `MCP_SOCKET_PATH` env var `HookExecutor` already injects.
- **`UpdateController` is now `ObservableObject`** so the new About-section
  "Last checked" row re-renders when Sparkle's `lastUpdateCheckDate` changes.
  Published fields: `lastCheckDate` (Date?) + `isCheckingForUpdates` (Bool).

## v0.21.36 — 2026-05-26

### User-facing
- **Auto-repair hook no longer fails with `/bin/bash: /Applications/Stats: No such
  file or directory`.** The built-in auto-repair scaffold now spawns the bundled
  script directly instead of through `bash -lc`, so spaces in the install path
  (`/Applications/Stats Widget from Website.app/...`) survive correctly. User-
  authored shell hooks that reference `${AUTO_REPAIR_SCRIPT}` now get a shell-
  quoted path substitution, so multi-arg invocations like
  `${AUTO_REPAIR_SCRIPT} --dry-run` also work despite the spaces.
- **Widget picker now reads "Stats Widget from Website"** instead of the legacy
  internal identifier `MacosWidgetsStatsFromWebsite`. Set `CFBundleName`
  explicitly in both the main app and widget extension Info.plists (was
  `$(PRODUCT_NAME)` which expanded to the legacy Swift product name).
- **User-facing copy refresh.** Identify / Sign-In / Chromium-install / reinstall
  prompts that still read "Reinstall macOS Widgets Stats from Website…" now read
  "Reinstall Stats Widget from Website…" — completing the v0.21.22 rename pass
  for the remaining user-visible Text() strings.

### Under-the-hood
- `HookExecutor` adds a POSIX-safe `shellQuote()` helper and splits
  `.runShellCommand` into two codepaths: exact-token payloads (the built-in
  scaffold) exec the script directly with no shell at all; user-authored
  payloads still go through bash with the substituted path single-quoted.
- New unit test `HookProcessIntegrationTests.testShellQuoteSurvivesSpacesInPath`
  guards the shell-quote contract so a future agent can't accidentally regress
  it.
- Internal Swift product name (`PRODUCT_NAME`, target name, scheme name) is
  unchanged — still `MacosWidgetsStatsFromWebsite{Widget}` — so the Sparkle
  update channel, App Group identifier, bundle ID, and existing widget kind ID
  (`MacosWidgetsStatsFromWebsite`) all keep working. Only the user-facing
  CFBundleName and the four Text() strings flipped.

## v0.21.35 — 2026-05-26

### User-facing
- **Finder double-click now works again.** Previously, after the app had
  auto-started at login, double-clicking `Stats Widget from Website.app`
  in Finder would silently fail (LaunchServices returned -600
  "Application isn't running"). The Dock icon never appeared and no
  window opened. v0.21.35 fixes this — the .app coexists correctly with
  itself and Finder double-clicks bring the prefs window forward.

### Under-the-hood
- **LaunchAgent → SMAppService.** v0.21.0–0.21.34 used a per-user
  LaunchAgent that directly `exec`'d the host binary at login. macOS
  registered the resulting process as an `osservice` rather than a
  LaunchServices foreground app, which is what broke Finder
  double-clicks (single-instance policy + missing LaunchServices
  identity). v0.21.35 switches to `SMAppService.mainApp` — macOS launches
  the .app at login via LaunchServices, so it has a proper foreground
  identity and Finder coexists.
- One-shot migration on first launch: bootouts the legacy LaunchAgent
  and removes `~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.plist`.
  Idempotent — safe on repeated launches.
- `LaunchAgentManager.swift` reduced to the migration helper only; the
  install/bootstrap codepath is gone.

## v0.21.22 — 2026-05-24

### User-facing
- **Product renamed** to "Stats Widget from Website" — the .app wrapper that
  lives in `/Applications/` is now `Stats Widget from Website.app` (was
  `MacosWidgetsStatsFromWebsite.app`). The Sparkle update ZIP basename and the
  GitHub release asset filename match: `Stats-Widget-from-Website-v0.21.22.zip`
  (URL-safe hyphens, since spaces would percent-encode in the Sparkle enclosure
  URL and break a couple of download clients).
- The widget picker entry, About panel, first-launch wizard header, and
  error messages now read "Stats Widget from Website".
- First-launch widget empty-state copy softened from
  "macOS Widgets Stats from Website, no trackers configured" to
  "Stats Widget from Website — no trackers configured yet" (em dash, "yet" —
  reads as guidance, not an error).
- Follow-up: the app icon design is still placeholder-feeling — Ethan plans
  to revisit it in a later release.

### Under-the-hood
- **Signing flipped to manual Developer ID.** v0.21.21's CI run failed because
  Xcode's auto-signing fallback inside the CI keychain tried to resolve a
  "Mac Development" cert for the widget extension that doesn't exist on a
  Developer-ID-only signing keychain. `project.yml` now sets
  `CODE_SIGN_STYLE: Manual` + `CODE_SIGN_IDENTITY: "Developer ID Application"`
  on the Release config of both the main app and the widget extension targets.
  Debug stays Automatic so local Xcode runs work without a CI keychain.
  `scripts/ExportOptions.plist` flipped from `signingStyle: automatic` to
  `manual` with explicit `signingCertificate: Developer ID Application`. No
  provisioning profile is involved — Developer ID distribution is profile-free.
- **LaunchAgent migration on first launch.** If an existing user has a
  pre-v0.21.22 LaunchAgent plist on disk that references
  `/Applications/MacosWidgetsStatsFromWebsite.app/...`, the new
  `migrateLegacyProgramArgumentsIfNeeded()` step rewrites
  `ProgramArguments[0]` to the new wrapper path and runs
  `launchctl bootout`+`bootstrap` so launchd loads the corrected
  arguments. Idempotent — runs every launch but only does work when there
  is drift to fix. Fresh installs skip it (no legacy plist exists);
  Sparkle in-place updates that preserve the legacy wrapper directory
  name also skip it (the new wrapper path won't exist on disk yet).
- **CLI fallback resolver.** `ChromeBrowserProfile.swift`'s
  `chromiumBundleCandidates()` now probes BOTH wrapper names — "Stats
  Widget from Website.app" first (canonical), then
  "MacosWidgetsStatsFromWebsite.app" (legacy, for Sparkle-updated users
  whose outer directory name didn't change). The first existing path
  wins, so the new name is preferred when both are present.
- **Application Support directory preserved.** The internal data
  directory at `~/Library/Application Support/macOS Widgets Stats from
  Website/` keeps its name intentionally — renaming it would orphan
  every existing install's trackers, readings, logs, and selector packs.
  See the doc comment in `AppGroupPaths.swift:12` for the full
  rationale.
- **Internal executable name unchanged.** The executable inside
  `Contents/MacOS/` stays `MacosWidgetsStatsFromWebsite`. The
  `CFBundleIdentifier`, App Group identifier, LaunchAgent label, and
  WidgetKit `kind` are also all unchanged — only the .app wrapper
  directory's filename and the user-facing display strings changed.
- README, `docs/release.md`, and the gh-pages `index.html` were updated to
  reference the new ZIP filename so `validate_release_metadata.py`'s
  `check_site` / `check_repo` validations pass.

### References
- Voice 4002 / MBP-CC bridge msg-65036391 (combined signing-fix + .app
  rename + UX strings + LaunchAgent migration + CLI fallback decision).
- Predecessor: v0.21.21 — first signing-rename attempt; the Mac Development
  cert error on the widget extension is what motivated the Option A pivot
  to manual Developer ID signing.
