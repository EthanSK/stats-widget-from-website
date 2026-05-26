//
//  AppDelegate.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.1 stub — see PLAN.md §4 for the full design.
//

import AppKit
import UserNotifications
import WidgetKit

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Bundle identifier of the main app. Hardcoded here so the
    /// single-instance enforcement runs even before `Bundle.main` is fully
    /// resolved (it is, but keeping this as a constant makes the intent
    /// explicit and avoids a force-unwrap on `Bundle.main.bundleIdentifier`
    /// during very-early startup).
    static let mainBundleIdentifier = "com.ethansk.macos-widgets-stats-from-website"

    /// Terminate any other running copies of this app that share our bundle
    /// identifier but have a different PID from ourselves.
    ///
    /// Why: when iterating in Xcode (or via `./scripts/build.sh`), each build
    /// produces a fresh `.app` bundle at a *different* on-disk path. Launching
    /// the freshly built bundle does NOT cause AppKit's normal reopen flow
    /// (`applicationShouldHandleReopen`) to fire on the prior instance —
    /// macOS treats them as two separate apps that just happen to share a
    /// bundle ID, and you end up with two copies of the app fighting over the
    /// shared App Group container, MCP socket, dock icon, menu bar, etc.
    ///
    /// This helper enumerates `NSRunningApplication` instances matching the
    /// main bundle ID, filters out our own PID, and asks each one to
    /// terminate gracefully (falling back to `forceTerminate()` if a stuck
    /// instance is still alive after a short grace period).
    ///
    /// This is intentionally called from `App.init()` (before the
    /// `AppGroupStore` is constructed) so the new instance has uncontended
    /// access to the App Group container by the time it reads from disk.
    /// `applicationShouldHandleReopen` is still kept for the
    /// same-bundle-relaunch case where a single-window focus is the right
    /// behaviour.
    static func terminatePriorInstancesIfNeeded() {
        let myPID = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: mainBundleIdentifier)
            .filter { $0.processIdentifier != myPID && !$0.isTerminated }

        guard !others.isEmpty else { return }

        for other in others {
            let warning = "[startup] WARN: another instance of \(mainBundleIdentifier) detected at \(other.bundleURL?.path ?? "<unknown>")"
            NSLog("%@ PID=%d", warning, other.processIdentifier)
            ActivityLogger.log("startup", warning, metadata: [
                "pid": "\(other.processIdentifier)"
            ])
            NSLog(
                "[startup] terminating prior MacosWidgetsStatsFromWebsite instance PID=%d (bundleURL=%@)",
                other.processIdentifier,
                other.bundleURL?.path ?? "<unknown>"
            )
            // Graceful first; macOS sends an AppleEvent quit which lets the
            // old instance run `applicationWillTerminate` (which closes the
            // MCP socket and tears down browsers cleanly).
            _ = other.terminate()
        }

        // Wait briefly for them to die so the App Group container and
        // MCP socket are unencumbered before we proceed. Cap at ~2s so a
        // wedged prior instance never blocks the new launch indefinitely;
        // anything still alive after the grace period gets force-killed.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let stillAlive = others.contains { !$0.isTerminated }
            if !stillAlive { break }
            Thread.sleep(forTimeInterval: 0.1)
        }

        for other in others where !other.isTerminated {
            NSLog(
                "[startup] force-terminating stuck prior instance PID=%d",
                other.processIdentifier
            )
            _ = other.forceTerminate()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        TrackerAttentionNotifier.shared.configure()
        UpdateController.shared.start()
        MCPServer.shared.startSocketServer()

        // v0.21.44 — POST-SPARKLE-INSTALL WIDGET EXTENSION REFRESH.
        //
        // Problem this guards against:
        //   When Sparkle's `quitAndInstall` replaces the .app on disk and
        //   relaunches the host process, macOS `chronod` (the WidgetKit
        //   extension host daemon) KEEPS the old widget extension binary
        //   loaded in memory. Result: the host runs the new version but
        //   the widget extension keeps serving stale cached values from
        //   the OLD .appex binary. v0.21.43 → v0.21.44 incident
        //   (2026-05-26): host upgraded but widget extension stayed pinned
        //   to v0.21.36 for 30+ min, rendering stale numbers (80%/97%) and
        //   a blank widget where chronod hadn't called TimelineProvider
        //   since the install. Manual `killall -9 chronod` was the only
        //   way to recover.
        //
        // The fix runs ONLY on the first launch after the host build
        // number changes — i.e. exactly the situation where chronod's
        // cached widget-extension binary might be stale. Normal launches
        // (relaunch after Quit, login auto-start, re-foreground) skip
        // this entirely so we don't churn chronod's cache for no reason.
        //
        // See `refreshWidgetExtensionsIfHostJustUpdated()` below for the
        // actual mechanism + escalation chain.
        refreshWidgetExtensionsIfHostJustUpdated()

        // v0.21.35 — SWITCH FROM LaunchAgent TO SMAppService FOR LOGIN ITEM.
        //
        // Background (the failure mode this fixes):
        //   v0.21.0–0.21.34 used a per-user LaunchAgent
        //   (`~/Library/LaunchAgents/com.ethansk.macos-widgets-stats-from-website.plist`)
        //   whose `ProgramArguments` directly exec'd the host binary at login.
        //   macOS registers a binary launched this way as an `osservice`
        //   under launchd, NOT as a regular foreground app via LaunchServices.
        //   Consequence: when the user later double-clicks `Stats Widget from
        //   Website.app` in Finder, LaunchServices sees the bundle ID is
        //   already running (as the osservice), refuses to spawn a second
        //   foreground instance, and the existing osservice can't receive
        //   the open event because it has NO LaunchServices identity. The
        //   user sees `open` return -600 / "Application isn't running" and
        //   the Dock icon never appears. Verified by bootout-test on
        //   2026-05-26: bootout the LaunchAgent → Finder double-click works,
        //   Trackers window appears, Dock icon visible.
        //
        // Fix: use `SMAppService.mainApp` (macOS 13+) to register the .app
        // itself as a login item. macOS then launches the .app via
        // LaunchServices at login — registered as a normal foreground app —
        // so Finder double-clicks coexist correctly. The legacy LaunchAgent
        // is removed by `LaunchAgentManager.removeLegacyHostLaunchAgent()`
        // (one-shot migration; idempotent).
        let startupLine = "[startup] pid=\(getpid()) bundle=\(Bundle.main.bundlePath)"
        NSLog("%@", startupLine)
        ActivityLogger.log("startup", startupLine)

        // One-shot: tear down the legacy host LaunchAgent installed by
        // v0.21.0–0.21.34. The migration is idempotent — if no plist is
        // present (fresh install) it logs and returns. After this lands,
        // the LaunchAgent file is gone from disk and `launchctl print
        // gui/$UID/com.ethansk.macos-widgets-stats-from-website` returns
        // "Could not find service" — which the stats-widget-host-watchdog
        // already handles as "host_plist_missing app_likely_uninstalled"
        // (no-op). The watchdog will be deprecated in a follow-up.
        LaunchAgentManager.removeLegacyHostLaunchAgent()

        // Register the .app as a macOS login item via SMAppService.
        // Quiet-fails if the user has it disabled in System Settings >
        // General > Login Items — the host still runs (we're running NOW),
        // we just won't auto-launch at next login. The user can re-enable
        // from the menu-bar dropdown if they want auto-start.
        //
        // SMAppService.mainApp is the modern macOS 13+ replacement for the
        // LSBackgroundOnly + LaunchAgent pattern. macOS handles the actual
        // launch path via LaunchServices, so the resulting process has a
        // proper foreground identity (Dock icon, Cmd-Tab presence,
        // double-click coexistence with the running process).
        do {
            try LoginItemManager.setEnabled(true)
            ActivityLogger.log("startup", "SMAppService login item registered (or already enabled)")
        } catch {
            // Non-fatal — user can re-enable via menu-bar "Launch at Login"
            // toggle, or via System Settings if they revoked the entry.
            ActivityLogger.log("startup", "SMAppService register failed (non-fatal)", metadata: [
                "error": error.localizedDescription
            ])
        }

        // v0.21.0 — long-running-host architecture (UPDATED v0.21.32:
        // now a hybrid Dock-visible app rather than a pure menu-bar
        // agent — see activation-policy block below).
        //
        // Previously (v0.19/0.20) we relied on a per-user LaunchAgent
        // firing the bundled CLI every 5 min to keep `readings.json`
        // fresh. That hit two WidgetKit problems:
        //   1. macOS only honours `WidgetCenter.reloadTimelines(ofKind:)`
        //      from the host app's process identity, so the CLI's call
        //      was a no-op; we had to relaunch the GUI binary headlessly
        //      every tick to wake the widget — fragile + chronod-noisy.
        //   2. WidgetKit budgets non-foreground apps to ~40–70 timeline
        //      reloads/day. A 5-min cadence = 288/day; we routinely
        //      blew the budget and chronod started silently throttling
        //      us on macOS 26.
        //
        // The model since v0.21.0: the app itself is the one persistent
        // process. BackgroundScheduler's in-process timers handle
        // scraping (default 30 min cadence per tracker), and the host
        // calls `WidgetCenter.reloadTimelines(ofKind:)` from its own
        // (correct) identity. No CLI re-launch, no LaunchAgent timer,
        // no chronod-state mismatch.
        //
        // v0.21.32 clarification: the chronod budget benefit is from
        // (a) process longevity (host stays alive long-term via the
        // host-watchdog LaunchAgent) + (b) the 30-min cadence. It is
        // NOT from `LSUIElement=true`. So we now ship with LSUIElement
        // false (Dock icon visible) without losing widget budget. See
        // LEARNINGS.md v0.21.32 entry.
        //
        // Migration: tear down any legacy LaunchAgent from prior
        // installs so we don't end up with both schedulers fighting.
        let migrated = LegacyLaunchAgentMigrator.migrateIfNeeded()

        // Install menu-bar status item. Wires up "Open Preferences",
        // "Scrape Trackers Now", "Launch at Login", "Quit", etc.
        if let store = appStoreForWiring, let scheduler = appSchedulerForWiring {
            MainPreferencesWindowController.shared.configure(
                store: store,
                backgroundScheduler: scheduler
            )
            MenuBarController.shared.install(
                store: store,
                backgroundScheduler: scheduler
            )
        }

        // v0.21.32 — hybrid UX. Activation policy is `.regular` so the
        // app has a normal Dock icon you can click, and Cmd-Tab finds
        // it the way you'd expect a normal Mac app. The menu-bar
        // status item installed above still appears alongside — same
        // pattern as Bartender / Time Out / iStat Menus.
        //
        // We deliberately do NOT call `setActivationPolicy(.accessory)`
        // here any more. Prior versions (v0.21.0–0.21.31) ran the
        // process as a pure menu-bar agent (LSUIElement=true +
        // activationPolicy=.accessory). Ethan opened v0.21.31 from
        // Finder, saw nothing happen, and the implicit-launch UX was
        // confusing. v0.21.32 reverts to a Dock-visible app.
        //
        // Activation-policy is also re-asserted to `.regular` from
        // `MainPreferencesWindowController.showWindow` (no-op when
        // already regular). The previous `windowWillClose` handler
        // dropped back to `.accessory`; that's been removed (see
        // MainPreferencesWindowController.swift) so closing the prefs
        // window leaves the Dock icon in place — the user can click it
        // again to reopen the window (handled by
        // `applicationShouldHandleReopen` below).
        NSApp.setActivationPolicy(.regular)

        if migrated {
            presentMigrationAlertOnNextRunLoop()
        }

        // v0.21.32 — auto-open the preferences window on every launch
        // (not just first-launch). Double-clicking the .app in Finder
        // or hitting "Open" from LaunchPad should bring the prefs UI
        // to the foreground, the way a normal Mac app does. If the
        // user then closes the window, the host stays alive (per
        // `applicationShouldTerminateAfterLastWindowClosed` returning
        // false below) so the menu-bar status item + BackgroundScheduler
        // continue to run and feed the widgets — and the Dock icon
        // remains a way to reopen the window.
        //
        // 1.0s delay matches the original first-launch path: lets
        // AppKit settle the activation-policy promotion + ContentView
        // wire up its @StateObject subscriptions before we present.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainPreferencesWindowController.shared.showWindow()
        }

        // v0.21.6 — agent-startup orphan tab sweep. Old installs (pre
        // v0.17.x Page.close cleanup, pre-v0.21.6 identify-tab cleanup)
        // can have accumulated dozens of about:blank / newtab / orphan
        // pages inside the bundled Chromium user-data-dir. Sweep them on
        // startup so a fresh launch returns the browser to a sane state.
        // Conservative: keeps tabs whose URL matches a tracker URL, +
        // up to 8 unknown-but-non-blank tabs (so the user's logged-in
        // pages survive).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            self.sweepOrphanBrowserTabsOnStartup()
        }
    }

    /// Scans the bundled Chromium's CDP /json/list and closes any
    /// disposable orphan tabs (about:blank, chrome://newtab, etc.)
    /// without touching tabs the user has actively signed into. Runs
    /// only if there are trackers configured AND the headless instance
    /// is already running (we don't want to *cold-start* Chromium just
    /// to sweep tabs — that'd undo the menu-bar agent's reduced-cost
    /// model). Best-effort; failures are logged.
    private func sweepOrphanBrowserTabsOnStartup() {
        guard let store = AppDelegate.pendingStore, !store.trackers.isEmpty else {
            return
        }

        // Use a transient background-use ticket so we don't hold the
        // browser open just for the sweep. The endBackgroundUse counter
        // ensures Chromium gets torn down again if no scrape happens to
        // be in flight.
        let configuration = ChromeBrowserProfile.shared.beginBackgroundUse()
        let trackerURLs = Set(store.trackers.compactMap { tracker -> String? in
            let trimmed = tracker.url.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })

        // Soft-launch path: only sweep if CDP is already reachable. If
        // it's not, the menu-bar agent hasn't scraped yet anyway so
        // there's nothing to clean up.
        ChromeBrowserProfile.shared.pageTargetCount(configuration: configuration) { count in
            guard let count, count > 0 else {
                ActivityLogger.log("startup", "skipped orphan tab sweep — Chromium not running yet or empty")
                ChromeBrowserProfile.shared.endBackgroundUse(configuration: configuration)
                return
            }

            ActivityLogger.log("startup", "running orphan tab sweep at agent startup", metadata: [
                "tabCount": "\(count)",
                "trackerURLCount": "\(trackerURLs.count)"
            ])

            // v0.21.12 race fix: pin in-flight scrape targets so the
            // startup sweep cannot accidentally close a scraper's live
            // tab. By the time this runs, BackgroundScheduler may already
            // have fired a scrape on the same headless Chromium.
            // activeScrapeTargetIDs requires the main queue.
            DispatchQueue.main.async {
                let pinnedIDs = ChromeCDPScraper.activeScrapeTargetIDs()
                ChromeBrowserProfile.shared.closeOrphanPageTargets(
                    configuration: configuration,
                    keepURLs: trackerURLs,
                    keepTargetIDs: pinnedIDs,
                    maxKeep: 8
                ) { _ in
                    ChromeBrowserProfile.shared.endBackgroundUse(configuration: configuration)
                }
            }
        }
    }

    // MARK: - Post-Sparkle-install widget extension refresh
    //
    // v0.21.44 — see comment block at the call site in
    // `applicationDidFinishLaunching` for background. The short story:
    // when Sparkle replaces the .app, macOS chronod can keep the OLD
    // widget extension binary live in-memory. The host needs to kick
    // chronod to drop the cached binding so the NEW .appex is loaded.

    /// UserDefaults key that stores the CFBundleVersion (build number) of
    /// the host process the LAST time this code path ran cleanly. On every
    /// launch we compare this against the current build; a mismatch means
    /// "first launch after install" (whether the install was Sparkle,
    /// Mac App Store update, manual drag-replace, or fresh install on a
    /// machine where the user had a different prior build).
    private static let lastSeenHostBuildKey = "lastSeenHostBuildAfterStartup"

    /// Detect first-launch-after-build-change and, if so, force-refresh
    /// the WidgetKit widget extension so chronod doesn't keep serving
    /// stale values from the old .appex binary still cached in memory.
    ///
    /// Escalation chain (cheapest → nuclear):
    ///   (1) `WidgetCenter.shared.reloadAllTimelines()` — costs nothing,
    ///       always worth trying. Sometimes enough on its own when
    ///       chronod's cache was already cold.
    ///   (2) After a 5-second settle window, schedule a recheck: re-fire
    ///       reloadAllTimelines + a check on whether the activity log
    ///       has seen a widget-extension query in the new version yet.
    ///       If chronod still appears to be serving old code, escalate.
    ///   (3) Last resort: `killall -9 chronod`. This is the only thing
    ///       that reliably forced chronod to re-load the new .appex
    ///       binary during the v0.21.36 → v0.21.43 incident on
    ///       2026-05-26. Destructive in the sense that it kills ALL
    ///       widget extensions on the system briefly — but chronod is
    ///       respawned by launchd within ~1 second, and other widgets
    ///       are simply reloaded by their respective hosts shortly
    ///       after. The user impact is a 1–2s blip in all widgets, not
    ///       a permanent state. We only do this on actual host-build
    ///       changes, NOT on every launch, so the blip happens at most
    ///       once per host upgrade.
    ///
    /// Apple does not expose a public API to invalidate a specific
    /// extension binding inside chronod. We audited the
    /// ChronoCore/WidgetKit headers + private symbol space for things
    /// like `dropExtensionBindings(_:)` or a darwin notification on
    /// `com.apple.chrono.invalidate-binding` — nothing public, nothing
    /// reliably callable from a sandboxed-or-not host. WidgetCenter's
    /// public surface (reloadTimelines/reloadAllTimelines) does NOT
    /// invalidate the loaded extension binary; it only invalidates the
    /// timeline cache, which is a SEPARATE layer that sits on top of
    /// whatever code chronod has currently mapped into its extension
    /// host process. So `killall chronod` is the cleanest available
    /// option for the cache-drop case, and we accept it.
    private func refreshWidgetExtensionsIfHostJustUpdated() {
        let bundle = Bundle.main
        // CFBundleVersion is what we compare on — it's a monotonic build
        // counter, unlike CFBundleShortVersionString which can have build
        // suffixes / pre-release tags. v0.21.43 -> v0.21.44 here means
        // 129700091 -> 129700092.
        let currentBuild = (bundle.infoDictionary?["CFBundleVersion"] as? String) ?? "unknown"
        let currentMarketing = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"

        // Use UserDefaults.standard which, for an unsandboxed host (see
        // v0.21.31 entitlements rework), is rooted at
        // ~/Library/Preferences/<bundle-id>.plist — survives across
        // Sparkle installs because Sparkle keeps that prefs file in
        // place when replacing the .app bundle.
        let defaults = UserDefaults.standard
        let lastSeenBuild = defaults.string(forKey: AppDelegate.lastSeenHostBuildKey)

        // No drift → normal launch. Record current build (handles the
        // very-first launch on a fresh install) and exit. The next time
        // Sparkle replaces the .app, lastSeenBuild WILL differ.
        guard lastSeenBuild != currentBuild else {
            ActivityLogger.log("widget-refresh", "host-build unchanged — no widget refresh needed", metadata: [
                "build": currentBuild,
                "version": currentMarketing
            ])
            return
        }

        // Drift detected. Could be: Sparkle install, MAS update, fresh
        // install (lastSeenBuild == nil), or a developer doing a manual
        // drag-replace. All paths benefit from the same refresh ritual.
        ActivityLogger.log("widget-refresh", "host build changed — starting widget extension refresh ritual", metadata: [
            "previousBuild": lastSeenBuild ?? "<none>",
            "currentBuild": currentBuild,
            "version": currentMarketing
        ])

        // Record the new build IMMEDIATELY so a crash during the refresh
        // ritual doesn't make us re-run the (potentially noisy) escalation
        // chain on the next launch. If the refresh fails, the host's next
        // run will see no drift and skip — chronod will eventually catch
        // up on its own anyway (it does eventually, just slowly).
        defaults.set(currentBuild, forKey: AppDelegate.lastSeenHostBuildKey)
        defaults.synchronize()

        // Tier (1): cheap, always-on. Fire reloadAllTimelines immediately
        // via the diagnostics wrapper so the call shows up in activity.log
        // alongside the chronod queries we're trying to influence.
        WidgetCenterDiagnostics.reloadAllTimelines(reason: "post-install-host-build-change")

        // Tier (2)+(3): give chronod a chance to act on tier (1), then
        // verify + escalate. We run the verify pass after 5 seconds (long
        // enough for chronod to wake the extension and start serving the
        // new timeline, short enough that the user doesn't sit on stale
        // widgets for long). The verify reads the activity log tail and
        // looks for a widget-extension query stamped with the NEW build —
        // see WidgetExtension's TimelineProvider, which already logs
        // pid+version on every query (that's how we caught this bug).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) { [currentBuild, currentMarketing] in
            let widgetExtensionRanWithNewBuild = AppDelegate.widgetExtensionHasQueriedSinceBuildChange(currentBuild: currentBuild)
            if widgetExtensionRanWithNewBuild {
                ActivityLogger.log("widget-refresh", "verify-OK: widget extension already serving new build — done", metadata: [
                    "build": currentBuild,
                    "version": currentMarketing
                ])
                return
            }

            // Tier (2): re-fire reloadAllTimelines once more in case the
            // first attempt landed before chronod fully booted its extension
            // host. Then wait another 5 seconds and recheck.
            ActivityLogger.log("widget-refresh", "verify-MISS: widget extension still stale after 5s — escalating (reload+wait)", metadata: [
                "build": currentBuild
            ])
            DispatchQueue.main.async {
                WidgetCenterDiagnostics.reloadAllTimelines(reason: "post-install-reload-retry")
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) { [currentBuild, currentMarketing] in
                let stillStale = !AppDelegate.widgetExtensionHasQueriedSinceBuildChange(currentBuild: currentBuild)
                if !stillStale {
                    ActivityLogger.log("widget-refresh", "verify-OK after retry: widget extension serving new build", metadata: [
                        "build": currentBuild,
                        "version": currentMarketing
                    ])
                    return
                }

                // Tier (3): nuclear. Kill chronod. launchd respawns it
                // within ~1 second; the next widget query then has to
                // load the new .appex binary from disk because the
                // cached binding is gone. Confirmed working on
                // 2026-05-26 — `killall -9 chronod` immediately moved
                // the activity log from `version=0.21.36` to
                // `version=0.21.43` across all 4 configIDs.
                ActivityLogger.log("widget-refresh", "still stale after retry — escalating to chronod kill", metadata: [
                    "build": currentBuild,
                    "version": currentMarketing
                ])
                AppDelegate.killChronodToForceWidgetExtensionReload()

                // Give chronod a beat to respawn, then nudge once more
                // so it actually queries the fresh extension binary.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    WidgetCenterDiagnostics.reloadAllTimelines(reason: "post-chronod-kill")
                }
            }
        }
    }

    /// Scan the tail of the shared activity log looking for a recent
    /// widget-extension query line stamped with the current build. The
    /// widget extension's TimelineProvider logs every getTimeline /
    /// getSnapshot call with `pid=<n> version=<marketing> build=<n>`
    /// metadata (see WidgetExtension.swift). If we see at least one
    /// such line with `build=<currentBuild>` written AFTER our refresh
    /// kick, chronod has loaded the new .appex and we're done.
    ///
    /// Conservative: any failure to parse / read the log returns false
    /// so we ALWAYS escalate rather than declare success on a parse
    /// error. False negatives (escalating unnecessarily) are cheap; a
    /// false positive would leave the user with stale widgets.
    private static func widgetExtensionHasQueriedSinceBuildChange(currentBuild: String) -> Bool {
        let recentLines = ActivityLogger.recentLogText(lineLimit: 200)
        guard !recentLines.isEmpty else { return false }

        // The widget extension's log lines look like:
        //   2026-...Z [widget] TimelineProvider.getTimeline build=129700092 pid=4353 ...
        // The category is exactly "[widget]" (see StatsWidget.swift's
        // ActivityLogger.log call sites). We need ANY line that has
        // both "[widget]" and a build= token matching the current
        // build. Any other host-side log lines with build= metadata
        // (the host log lines from refreshWidgetExtensionsIfHostJust...
        // above, for example) use a DIFFERENT category, so the
        // "[widget]" check correctly excludes those — we only count
        // lines originating from the appex process.
        for line in recentLines.split(separator: "\n").reversed() {
            // Cheap substring match. We're scanning ~200 lines max so a
            // proper regex would be overkill.
            if line.contains("build=\(currentBuild)") && line.contains("[widget]") {
                return true
            }
        }
        return false
    }

    /// Shell out to `killall -9 chronod`. This is the only path we have
    /// found that reliably forces macOS to drop chronod's cached
    /// widget-extension binary mapping. launchd respawns chronod
    /// immediately (it's a system-managed daemon), so the only user-
    /// visible side effect is a ~1-second blip across ALL widgets on
    /// the system. Documented in the v0.21.44 fix incident notes.
    ///
    /// Best-effort: if for any reason the launch fails (TCC, sandbox,
    /// codesign), we just log the failure and let chronod's own slow
    /// background refresh catch up over the following ~minutes. We do
    /// NOT propagate the error to the user.
    ///
    /// NB: We deliberately do NOT request a confirmation dialog for
    /// this. The whole point of v0.21.44 is to make the post-install
    /// refresh invisible to the user; popping a dialog would defeat
    /// that. The action is bounded (one process kill, one daemon
    /// respawn) and non-destructive to user data.
    private static func killChronodToForceWidgetExtensionReload() {
        // Use /usr/bin/killall — it accepts the process name and walks
        // proc list itself. No PID lookup needed on our side.
        let task = Process()
        task.launchPath = "/usr/bin/killall"
        task.arguments = ["-9", "chronod"]

        // Pipe stderr to a buffer so we can log any failure detail
        // (e.g. "No matching processes belonging to you" if chronod
        // isn't running under our UID, which means there's nothing to
        // kill anyway → also success-ish).
        let errPipe = Pipe()
        task.standardError = errPipe
        task.standardOutput = Pipe() // discard stdout

        do {
            try task.run()
            task.waitUntilExit()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8) ?? ""
            ActivityLogger.log("widget-refresh", "killall chronod completed", metadata: [
                "exitCode": "\(task.terminationStatus)",
                "stderr": errText.trimmingCharacters(in: .whitespacesAndNewlines)
            ])
        } catch {
            ActivityLogger.log("widget-refresh", "killall chronod failed (non-fatal)", metadata: [
                "error": error.localizedDescription
            ])
        }
    }

    /// Set by `MacosWidgetsStatsFromWebsiteApp.init()` after the
    /// `AppGroupStore` and `BackgroundScheduler` have been created so
    /// `applicationDidFinishLaunching` can hand them to the menu-bar /
    /// window controllers. Static rather than instance state so
    /// `App.init()` can write to it before `AppDelegate` is invoked.
    static var pendingStore: AppGroupStore?
    static var pendingScheduler: BackgroundScheduler?
    static var shouldShowFirstLaunchFlow: Bool = false

    private var appStoreForWiring: AppGroupStore? { AppDelegate.pendingStore }
    private var appSchedulerForWiring: BackgroundScheduler? { AppDelegate.pendingScheduler }

    private func presentMigrationAlertOnNextRunLoop() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let alert = NSAlert()
            alert.messageText = "Stats Widget now runs in the menu bar"
            alert.informativeText = """
                The app now lives in your menu bar (look for the chart icon at the top of your screen). Click it to open Preferences, trigger a manual scrape, or quit.

                The previous background-refresh job (a LaunchAgent) has been disabled — the menu-bar app handles refreshing on its own now.
                """
            alert.addButton(withTitle: "Got it")
            alert.alertStyle = .informational
            alert.runModal()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
        MCPServer.shared.stopSocketServer()
    }

    /// Hybrid-app behaviour: when the user clicks the Dock icon (or
    /// re-opens the app from Finder/LaunchPad/Spotlight while the
    /// process is already running) and there are no visible windows,
    /// materialize the preferences window. This is the standard "click
    /// Dock icon to bring app forward" UX that normal Mac apps have.
    ///
    /// `flag == true` means the system can find at least one visible
    /// window already; AppKit will handle activation itself, we don't
    /// need to do anything special. Returning `true` either way tells
    /// AppKit we've handled the reopen request.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            MainPreferencesWindowController.shared.showWindow()
        }
        return true
    }

    /// v0.21.32 — KEEP THE HOST ALIVE WHEN THE PREFS WINDOW CLOSES.
    ///
    /// Returning `false` is what lets us behave like a normal Mac app
    /// (Dock icon you can click) AND keep the in-process
    /// BackgroundScheduler ticking to feed widget refreshes. Without
    /// this, closing the prefs window (red dot / Cmd-W) would terminate
    /// the host process, the BackgroundScheduler would stop, and the
    /// widget would go stale within the next scrape interval.
    ///
    /// The Dock icon stays visible after close — clicking it triggers
    /// `applicationShouldHandleReopen` above which re-opens the window.
    /// The menu-bar status item also stays as a redundant access point.
    ///
    /// SwiftUI's default for AppKit apps with no `WindowGroup` is also
    /// "don't terminate on last window close", so this method is
    /// arguably redundant — but stating it explicitly here makes the
    /// intent obvious to future readers and guards against a SwiftUI
    /// SDK change flipping the default.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "macos-widgets-stats-from-website" {
                openDeepLink(url)
            } else if url.pathExtension.lowercased() == SelectorPack.fileExtension {
                do {
                    _ = try SelectorPackImportCoordinator.importSelectorPack(at: url)
                } catch {
                    MCPInvocationLoggerProxy.logImportFailure(error)
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let trackerIDString = response.notification.request.content.userInfo["trackerID"] as? String,
           let trackerID = UUID(uuidString: trackerIDString) {
            MainPreferencesWindowController.shared.showWindow(section: .trackers)
            AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
        }

        completionHandler()
    }

    private func openDeepLink(_ url: URL) {
        // `macos-widgets-stats-from-website://refresh` is the widget
        // fallback path: the widget extension's RefreshTrackerIntent
        // writes a pending-request file AND (if the main app was off)
        // nudges via this URL so LaunchServices brings the app forward.
        // The actual scrape is dispatched by BackgroundScheduler when it
        // drains the pending-request directory on foreground / launch, so
        // we don't need to do anything extra here other than make sure
        // the app is foregrounded.
        if url.host == "refresh" {
            // v0.21.0 — menu-bar agent never needs to foreground for a
            // refresh deep link. The scheduler watches the pending-
            // request directory and dispatches scrapes from background.
            NotificationCenter.default.post(
                name: AppNavigationEvents.drainPendingScrapeRequestsNotification,
                object: nil
            )
            return
        }

        guard url.host == "tracker",
              let trackerIDString = url.pathComponents.dropFirst().first,
              let trackerID = UUID(uuidString: trackerIDString) else {
            return
        }

        // Open the preferences window so AppNavigationEvents can route
        // to the trackers section. Without a visible window the
        // notification would land but never be acted on.
        MainPreferencesWindowController.shared.showWindow(section: .trackers)
        AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
    }

    // v0.21.32 — hybrid app: auto-opens prefs window on launch (see
    // `applicationDidFinishLaunching` above) AND keeps the menu-bar
    // status item. Originally launch-silent in v0.21.0 (menu-bar only,
    // no auto-window) — reverted here because that UX confused users
    // double-clicking the .app and seeing nothing happen.
}

private enum MCPInvocationLoggerProxy {
    static func logImportFailure(_ error: Error) {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macOS Widgets Stats from Website", isDirectory: true)
        let url = directory.appendingPathComponent("selector-pack-import.log", isDirectory: false)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(error.localizedDescription)\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {}
    }
}
