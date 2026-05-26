# Changelog

Release-by-release notes for the Stats Widget from Website project.

Format: each entry is dated, lists the user-visible changes first, then the
under-the-hood / signing / packaging changes. Newest first.

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
