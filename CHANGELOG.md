# Changelog

Release-by-release notes for the Stats Widget from Website project.

Format: each entry is dated, lists the user-visible changes first, then the
under-the-hood / signing / packaging changes. Newest first.

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
