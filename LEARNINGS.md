# Learnings

Per-repo institutional memory for fixes. Every entry below is a real bug we hit + how we solved it. Check this file BEFORE attempting a same-looking fix.

Maintained by the `learnings` skill — see `~/.claude/skills/learnings/skill.md`.

## Format

Each entry looks like:

```
---
**Date:** YYYY-MM-DDTHH:MM:SSZ
**Trigger:** <voice N / message snippet / null>
**Symptom:** <what was visible>
**Root cause:** <what we actually found>
**Fix:** <file:line + short prose + commit SHA>
**Guard:** <test / lint / watchdog / comment that prevents regression — or 'none'>
---
```

## Entries

(newest first)

---
**Date:** 2026-05-26T15:06:32Z
**Trigger:** voice 4189 + 4188 (2026-05-26)
**Symptom:** Widget picker (Finder → Edit Widgets → search) showed legacy 'macOS Widget Stats from Website' / 'MacosWidgetsStatsFromWebsite' as the section header even after the v0.21.22 user-facing rename. CFBundleDisplayName was already 'Stats Widget from Website' but the picker ignored it.
**Root cause:** Both main app + widget extension Info.plists set 'CFBundleName: $(PRODUCT_NAME)'. $(PRODUCT_NAME) expands to the internal Swift product name ('MacosWidgetsStatsFromWebsite' / 'MacosWidgetsStatsFromWebsiteWidget'). macOS widget picker reads CFBundleName for app grouping and only falls back to CFBundleDisplayName when CFBundleName is absent — so the legacy identifier surfaced despite the display name override.
**Fix:** Set CFBundleName explicitly to 'Stats Widget from Website' / 'Stats Widget from Website Widget' in both project.yml info.properties blocks AND both raw Info.plists (project.yml is the merged source of truth, raw files kept in sync for direct-Xcode builds). PRODUCT_NAME / target name / scheme name / kind ID deliberately unchanged — they're internal Sparkle / app-group / placed-widget contracts and renaming would invalidate Sparkle updates + existing user-placed widgets. v0.21.36, commit b2b0cff.
**Commit:** b2b0cff
**Guard:** /usr/libexec/PlistBuddy -c 'Print :CFBundleName' on the installed bundle's Info.plist must return the user-facing string, not '$(PRODUCT_NAME)' or 'MacosWidgetsStatsFromWebsite'. Inline comment block in both Info.plists names the bug + the picker behaviour + the reason PRODUCT_NAME wasn't flipped.
---

---
**Date:** 2026-05-26T15:06:20Z
**Trigger:** voice 4189 + 4188 (2026-05-26) + readings.json diag showing exit 127 across all 4 trackers
**Symptom:** Every tracker's onFailure hook logs '/bin/bash: /Applications/Stats: No such file or directory' (exit 127) in trackers.json lastRun.detail after the v0.21.22 .app wrapper rename. Auto-repair never runs.
**Root cause:** HookExecutor's .runShellCommand path passes the substituted AUTO_REPAIR_SCRIPT path UNQUOTED into 'bash -lc "<path>"'. After v0.21.22 the bundled script path is '/Applications/Stats Widget from Website.app/Contents/Resources/Scripts/auto-repair-tracker.sh' (two spaces). Bash tokenises on whitespace and tries to exec '/Applications/Stats' as a command.
**Fix:** HookExecutor.swift .runShellCommand split into two codepaths: exact-token payloads (the built-in scaffold) exec the script directly with no shell at all (process.launchPath = scriptPath, no '-lc'). User-authored payloads still go through bash but with the substituted path single-quoted via new shellQuote() helper. v0.21.36, commit b2b0cff.
**Commit:** b2b0cff
**Guard:** New unit test HookProcessIntegrationTests.testShellQuoteSurvivesSpacesInPath pins the shell-quote contract. After v0.21.36 installs, trackers.json hooks.onFailure[0].lastRun.detail should never contain 'No such file or directory' for the script path. Inline comment block in HookExecutor.swift names the bug + symptom + fix path.
---

---
**Date:** 2026-05-26T15:30:00Z
**Trigger:** MBP-CC ship task — root-cause of "Finder double-click does nothing after auto-start" diagnosed; switch from LaunchAgent to SMAppService.
**Symptom:** v0.21.0–v0.21.34: after the per-user LaunchAgent (`~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.plist`) auto-started the host at login, double-clicking `Stats Widget from Website.app` in Finder returned `-600 / "Application isn't running"`. No Dock icon bounce, no window. `bootout` the LaunchAgent → Finder double-click immediately works, Trackers window opens, Dock icon visible. Verified empirically.
**Root cause:** LaunchAgent plist's `ProgramArguments` directly exec'd the host binary. macOS registers a binary started this way as an `osservice` under launchd, NOT as a foreground app via LaunchServices. When the user then double-clicks the .app in Finder, LaunchServices sees the bundle ID is already running (as the osservice), refuses to spawn a second foreground instance (single-instance policy), and the existing osservice can't receive the open event because it has NO LaunchServices identity. Net result: `-600` to the user. The osservice / LaunchServices duality is the load-bearing fact — `LSUIElement` flipping, Dock-icon-visibility, and activation-policy work were ALL irrelevant to this bug.
**Fix:** v0.21.35 — switch to `SMAppService.mainApp` for login-item registration. (1) `AppDelegate.applicationDidFinishLaunching`: removed `LaunchAgentManager.ensureInstalledAndBootstrapped()` call; added one-shot `LaunchAgentManager.removeLegacyHostLaunchAgent()` (bootouts the legacy plist + deletes it from disk); added `try LoginItemManager.setEnabled(true)` to register the .app as a login item via the modern macOS 13+ ServiceManagement API. (2) `LaunchAgentManager.swift`: gutted to just the one-shot migrator — `removeLegacyHostLaunchAgent()` + supporting helpers. All install/bootstrap/write-plist code removed (not just commented out). (3) `LoginItemManager.swift`: unchanged — was already in place since v0.21.0, just hadn't been wired in.
**Commit:** <pending — see git log for v0.21.35>
**Guard:** (a) `LaunchAgentManager.swift` top-of-file doc-comment block explains WHY this file is now migration-only and links to this LEARNINGS entry. (b) `AppDelegate` SMAppService block has an explicit comment naming the `-600` symptom + the osservice/LaunchServices duality. (c) Verification after install: `ls ~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.plist` should return "No such file or directory" after one launch of v0.21.35+; `sfltool dumpbtm | grep -A 3 macos-widgets-stats-from-website` should show it as an SMAppService login item. If a future agent considers re-introducing a direct-binary-spawn LaunchAgent for ANY reason, re-read this entry first — that pattern is what caused the bug. The host-watchdog at `~/.claude/scripts/stats-widget-host-watchdog.sh` (line 262) already gracefully no-ops when the plist is absent, so the migration is safe; the watchdog itself should be deprecated in a follow-up since it's chasing a failure mode that can no longer occur.
---

---
**Date:** 2026-05-26T14:07:50Z
**Trigger:** voice 4178 (2026-05-26): 'I didn't told you in the first place to do it like producer player. So why didn't you?'
**Symptom:** Release pipeline diverged from Producer Player (tag-only instead of push+tag)
**Root cause:** Agent (MBP-CC) unilaterally switched release.yml to tag-only on 2026-05-24 (commit ebc9198), attributed change to 'voice 3991' which was actually about Xcode, not release triggers. Self-rubber-stamped via agent-bridge msg-3db7c68a with no Ethan instruction.
**Fix:** Restored push: branches [main, master] alongside tags: ['v*'] in release.yml. prepare_release_metadata.py already supports both flows (see 'Producer Player-style branch releases' comment ~line 100). check-tag-race guard handles bump-and-tag.sh's branch-then-tag double-fire.
**Commit:** 4e3604a
**Guard:** RETRO-release-trigger-2026-05-26.md committed as institutional memory; comment block in release.yml now references the retro instead of the fabricated voice 3991 attribution
---

---
**Date:** 2026-05-26T14:00:00Z
**Trigger:** Ethan opened v0.21.31 from Finder, nothing happened (no Dock icon, no window). Asked for the app to behave like a normal Mac app — Dock icon + auto-open prefs on launch — while keeping menu-bar agent benefits for widget refresh.
**Symptom:** v0.21.0–v0.21.31 ran as `LSUIElement=true` + `NSApp.setActivationPolicy(.accessory)`. Double-clicking the .app in Finder produced NO visible feedback: no Dock icon bounce, no window, no menu-bar flash visible to a user who wasn't already looking at their menu bar. The host process was running fine and the menu-bar status item was present, but the launch UX read as "the app is broken / didn't open" to a normal user.
**Root cause:** The v0.21.0 commit comment block treated `LSUIElement=true` as load-bearing for the widget-refresh budget / chronod cadence. That was wrong. The chronod widget budget (~40-70 timeline reloads/day for non-foreground apps) is governed by TWO things: (a) host-process longevity — kept alive via the host-watchdog LaunchAgent + KeepAlive — and (b) reload cadence — `BackgroundScheduler` defaults to 30 min per tracker, well under budget. `LSUIElement` does not factor into either. Background-window apps (Dock-visible, no foregrounded window) and pure LSUIElement agents fall into the same chronod bucket. So flipping LSUIElement off costs us nothing on widget refresh — but gives us a Dock icon, auto-open-on-launch, Cmd-Tab discoverability, and reopen-on-Dock-click.
**Fix:** v0.21.32 — hybrid UX. (1) `Info.plist`: `LSUIElement` true → false. (2) `AppDelegate.applicationDidFinishLaunching`: removed `setActivationPolicy(.accessory)`, replaced with `setActivationPolicy(.regular)`; added an unconditional `MainPreferencesWindowController.shared.showWindow()` 1s after launch (was previously gated on `shouldShowFirstLaunchFlow`). (3) `AppDelegate`: added `applicationShouldTerminateAfterLastWindowClosed` → false so the host stays alive when prefs window closes (BackgroundScheduler continues running for widget refresh). The existing `applicationShouldHandleReopen` already handled Dock-click-to-reopen. (4) `MainPreferencesWindowController.windowWillClose`: removed the `setActivationPolicy(.accessory)` revert — Dock icon now stays visible after window close. (5) `MenuBarController` kept as redundant access point (same hybrid pattern as Bartender / Time Out / iStat Menus). Commit: `<pending — see git log>`.
**Guard:** Inline comment block on the `LSUIElement` key in `MacosWidgetsStatsFromWebsite/Apps/MainApp/Info.plist` AND `project.yml` (targets.MacosWidgetsStatsFromWebsite.info.properties.LSUIElement — this is the merged source of truth that xcodegen produces and ships) explicitly documents WHY this is false. **GOTCHA — v0.21.32 first attempt:** flipped only the source Info.plist's LSUIElement to false but missed `project.yml`'s `info.properties.LSUIElement: true` directive, which xcodegen merges INTO the built Info.plist and overrides the raw source. Result: shipped v0.21.32 had LSUIElement=true in the built bundle. Fixed in v0.21.33 by also flipping the project.yml directive. ALWAYS check `/usr/libexec/PlistBuddy -c "Print :LSUIElement" "Contents/Info.plist"` on the built app to verify, not the raw source. After install, `Stats Widget from Website.app` should show in the Dock with a clickable icon, and double-clicking it from Finder should bring its prefs window to the foreground. If the Dock icon doesn't appear, LSUIElement is still true somewhere — check `project.yml` first.
---

---
**Date:** 2026-05-26T00:00:00Z
**Trigger:** Voice 4166 (2026-05-26): "Feel free to try and get the mini to use Codec's computer use. Invoke it from the command line or something to get it working if needed and see it through." + MBP fresh install of v0.21.30 SIGKILL'd by kernel.
**Symptom:** Stats Widget from Website v0.21.30 (and any earlier version) refuses to launch on a clean install via `launchctl bootstrap` or direct exec — process exits with code 137 (SIGKILL) before main() runs. `/usr/bin/log show --predicate 'process == "amfid"'` shows: `amfid: Restricted entitlements not validated, bailing out. Error: Code=-413 "No matching profile found"` followed by `taskgated-helper: Disallowing com.ethansk.macos-widgets-stats-from-website because no eligible provisioning profiles found`. Existing installs that were running before this never tripped because AMFI cached the original grant; only fresh installs surface it.
**Root cause:** The host .app's entitlements include `com.apple.security.application-groups` and `keychain-access-groups`, both AMFI-restricted on macOS Sonoma+. Restricted entitlements require an embedded Developer ID provisioning profile (`Contents/embedded.provisionprofile`) for AMFI to validate them at exec time. The Sparkle / `method=developer-id` distribution flow in `.github/workflows/release.yml` ships PROFILE-FREE by design (see `scripts/ExportOptions.plist` comment). Result: signed bundle with restricted entitlements + no embedded profile → AMFI -413 → kernel SIGKILL. The widget appex has the same entitlement but launches under chronod / Plugin Kit which evaluates extensions under the parent's already-validated identity, so the widget itself didn't trip the same path.
**Fix:** v0.21.31 — removed `com.apple.security.application-groups` and `keychain-access-groups` from `MacosWidgetsStatsFromWebsite/Apps/MainApp/MacosWidgetsStatsFromWebsite.entitlements` (host only — widget keeps the entitlement because the appex IS sandboxed and MUST go through the security API). Updated `MacosWidgetsStatsFromWebsite/Shared/AppGroup/AppGroupPaths.swift` `sharedContainerURL()` to fall back to manually building `~/Library/Group Containers/<identifier>/` when `containerURL(forSecurityApplicationGroupIdentifier:)` returns nil — the unsandboxed host can read+write this path directly without the entitlement, and the widget reaches the same physical directory through the security API, so shared data still flows. Updated `scripts/build.sh` to only require app-groups entitlements + profile on the widget appex, not the host. Keychain sharing still works because `KeychainHelper.swift` already falls back from access-group to default-group on each candidate. Commit: `<pending>`.
**Guard:** v0.21.31 ships and `find "/Applications/Stats Widget from Website.app" -name "embedded.provisionprofile"` MUST still show no host-level profile, AND `codesign -d --entitlements - .../Contents/MacOS/MacosWidgetsStatsFromWebsite | grep application-groups` MUST return nothing on the host (presence on the widget appex is correct + required). Adding either entitlement back to host without embedding a Developer ID Direct Distribution profile WILL reproduce the AMFI -413 SIGKILL — the entitlements file has an inline comment block warning future agents off doing so.
---

---
**Date:** 2026-05-24T22:50:00Z
**Trigger:** Voices 4019 + 4020 (2026-05-24): "Can you increase the timeout then? So let it have longer time to load. Also, maybe set the chat GPT ones to happen every ten minutes anyway, twenty minutes. What would Cloudflare not start rate limiting me on?" + "Also, can we only show the error message if, after three consecutive failed attempts, the error notification?"
**Symptom:** ChatGPT-domain trackers were timing out at the 30s outer scrape deadline (selectorPoll deadline at ~24-25s elapsed) AND occasionally getting Cloudflare-challenged on every scrape because the 30 min default cadence sat at the edge of Cloudflare's per-IP rate-limit window. Auto-repair agent + macOS notification then fired on EVERY single transient failure, even when the next scrape recovered cleanly.
**Root cause:** (1) Cloudflare JS-challenge on chatgpt.com / *.openai.com pages can hold the metric element offscreen for 10-20s, clipping the 25s inner selector-poll deadline. Claude pages don't have this issue. (2) Hammering ChatGPT URLs every 30 min trips Cloudflare's rate heuristic; 15 min cadence stays under the threshold. (3) HookExecutor's .onFailure trigger fired immediately on first failure with no consecutive-failure gate, even though TrackerAttentionNotifier already had a `>= 3` gate for the system notification — so the two layers were inconsistent.
**Fix:** v0.21.29: added `Tracker.isChatGPTDomain(url:)`, `Tracker.scrapeTimeoutSec` (60s for ChatGPT, 30s otherwise), `Tracker.effectiveRefreshIntervalSec` (floors ChatGPT at 900s). ChromeCDPScraper armTimeout + inner selectorPoll deadline both derive from `tracker.scrapeTimeoutSec`. BackgroundScheduler.fireScrapeLifecycleHooks now suppresses .onFailure hooks when `consecutiveFailureCount < 3` AND logs the suppression. auto-repair-tracker.sh duplicates the gate defensively (in case a user-authored hook bypasses the Swift gate). Scheduler "rescheduled" log gains `configuredIntervalSec` + `domainCadenceFloor` so post-hoc you can tell whether the override fired.
**Commit:** <pending — see git log>
**Guard:** Activity-log gate: "rescheduled" log lines for ChatGPT trackers should show `intervalSec=900 domainCadenceFloor=chatgpt-15min`; "started scrape" log lines for ChatGPT trackers should show `timeoutSec=60`. Auto-repair / TrackerAttentionNotifier should both fire at the same moment (failure #3), never on failure #1.
---

---
**Date:** 2026-05-24T02:58:22Z
**Trigger:** Voice 3988 (2026-05-24): 'Again, I see selector needs something. What the fuck? Investigate the logs. ... Should we slow slow it down a bit, combine them, stagger them better? Maybe it needs to be staggered better.'
**Symptom:** Stats Widget showing random warning icons (⚠) instead of tracker values + frequent 'CDP websocket disconnected' / 'Timed out loading' scrape failures across all 4 trackers (Claude session, Claude weekly, ChatGPT session, ChatGPT codex). Pre-v0.21.14 log was a continuous storm of disconnects.
**Root cause:** Parallel scrapes against the same Chromium browser profile shared a single CDP websocket. When two trackers' scrapes fired within ~1s of each other (which BackgroundScheduler did every cycle), the first to finish would call Page.close, which dropped the shared websocket — and the second scrape's selector-poll loop then hit 'The CDP websocket disconnected' for ~30s of retries before timing out. Surfaces to the user as warning icon + stale data.
**Fix:** v0.21.14: introduced 15s per-profile scrape-start stagger via new lastScrapeStartedAt watermark in ChromeBrowserProfile + reserveScrapeStart() called from ChromeCDPScraper.scrape() BEFORE any DispatchQueue.main.async. Watermark stores PROJECTED start time inside queue.sync so 4 simultaneous reserves stagger to 0s/15s/30s/45s instead of all racing. Also v0.21.12: pin in-flight scrape tabs against orphan sweep so a sweep can't close a tab a sibling scrape is using.
**Commit:** fbd1fe1
**Guard:** Activity-log gate: zero 'CDP websocket disconnected' lines over 10 consecutive scrape cycles post-install. The [scheduler] staggering scrape log line ALSO fires whenever stagger applies, so it can be greped for to confirm the watermark code is actually executing.
---

