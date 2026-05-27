//
//  TCCPrewarmer.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  v0.21.53 — collapses the post-reboot "would like to access data from
//  other apps" TCC dialog cascade into a SINGLE prompt per boot.
//
//  ============================================================================
//  THE BUG THIS FIXES (voice 4274, 2026-05-27)
//  ============================================================================
//  Symptom: after every macOS reboot Ethan sees TWO consecutive
//  "Stats Widget from Website would like to access data from other apps"
//  TCC dialogs, both requiring an "Allow" click, before the host can
//  function.
//
//  Root cause: on macOS Sonoma+ the TCC service
//  `kTCCServiceSystemPolicyAppData` (which gates access to
//  `~/Library/Group Containers/<id>/`) binds its grant to the
//  CURRENT BOOT UUID rather than persisting permanently. Verified empirically
//  by inspecting `~/Library/Application Support/com.apple.TCC/TCC.db`:
//
//    sqlite> SELECT service, client, auth_value, boot_uuid FROM access
//            WHERE client LIKE '%macos-widgets%';
//    kTCCServiceSystemPolicyAppData|com.ethansk.macos-widgets-stats-from-website|5|EA30FFBA-...
//
//  `auth_value=5` = "Authorized for current boot session only". The
//  `boot_uuid` column matches `sysctl kern.bootsessionuuid`. On every
//  reboot the boot_uuid changes → TCC treats the grant as invalid and
//  re-prompts.
//
//  Why TWO dialogs (not one): the host's `App.init()` issues MULTIPLE
//  distinct file operations against the Group Container in rapid
//  succession before the user can dismiss the first dialog:
//
//    1. `ActivityLogger.log("app", "launch")`
//         → writes Logs/activity.log under the Group Container
//    2. `AppGroupStore.migrateLegacyAppGroupContainerIfNeeded()`
//         → reads + maybe writes within the Group Container
//    3. `AppGroupStore.backfillDefaultHookScaffoldIfNeeded()`
//         → writes trackers.json under the Group Container
//    4. `AppGroupStore()` init
//         → reads trackers.json
//
//  macOS does NOT coalesce these into one prompt because each access uses
//  a different file descriptor / open intent. The first access prompts,
//  the user hasn't clicked yet, but the next access fires its own prompt
//  before the first resolves → TWO stacked dialogs in the queue.
//
//  Why the host has no `application-groups` entitlement (=Apple's intended
//  fix): adding that entitlement re-introduces the AMFI -413 SIGKILL
//  documented in v0.21.31 — `com.apple.security.application-groups` is an
//  AMFI-restricted entitlement on Sonoma+ and requires an embedded Developer
//  ID Direct Distribution provisioning profile to validate. The Sparkle
//  release flow ships profile-free. So we cannot use the architecturally
//  correct fix without rebuilding the entire CI signing pipeline.
//
//  ============================================================================
//  THE FIX
//  ============================================================================
//  Perform ONE deliberate, synchronous Group Container access at the very
//  TOP of `App.init()`, before any other code path can touch the directory.
//  This issues exactly ONE TCC prompt. `App.init()` blocks (single thread)
//  until the file write returns, which on macOS happens AFTER the user
//  clicks "Allow" on the dialog. Once the boot-session grant exists in
//  TCC.db (auth_value=5 with current boot_uuid), all subsequent accesses
//  in this boot session reuse it silently — no further dialogs.
//
//  Net effect: ONE dialog per boot instead of TWO.
//
//  Caveats:
//   - This does NOT eliminate the dialog entirely. Eliminating it requires
//     re-adding the App Group entitlement + embedding a Direct Distribution
//     provisioning profile in the bundle. That's the v0.22 architectural
//     fix tracked separately.
//   - If the user clicks "Don't Allow", subsequent file ops will all fail.
//     We log a clear warning so the activity log captures it; users in
//     that state need to re-grant via System Settings → Privacy & Security
//     → "Files and Folders" → Stats Widget from Website.
//   - The prewarm file (`.tcc-prewarm-sentinel`) is intentionally separate
//     from any user-data file so the SAME write path is hit every boot
//     (a missing/created file doesn't change the TCC-relevant code path).
//

import Foundation

/// Single-purpose helper that collapses the multi-dialog post-reboot
/// TCC prompt cascade into a single prompt by issuing one deliberate,
/// synchronous Group Container access ahead of all other startup work.
///
/// Called from `MacosWidgetsStatsFromWebsiteApp.init()` as the VERY
/// FIRST statement, before `ActivityLogger.log`, before any
/// `AppGroupStore` interaction, before any other Group Container path
/// resolution. The single access here triggers the boot-session TCC
/// grant; every subsequent access in this boot session piggybacks on
/// that grant without a fresh prompt.
///
/// Idempotent within a single process — only the FIRST call does work;
/// subsequent calls are no-ops (guarded by `hasPrewarmed`).
enum TCCPrewarmer {
    /// In-process flag — once we've issued the prewarm write in this
    /// process, don't repeat. The TCC grant is already cached at the
    /// kernel level by this point so a repeat call would be a no-op
    /// anyway, but skipping the file-system round-trip saves a few ms
    /// on hot reload paths (e.g. SwiftUI preview refresh).
    private static var hasPrewarmed = false

    /// Filename of the sentinel written during the prewarm. Lives at the
    /// root of the Group Container (NOT in a subdirectory) so we hit the
    /// minimum possible filesystem traversal — every directory boundary
    /// crossed is another TCC checkpoint that macOS could potentially
    /// turn into its own prompt under future tightening.
    ///
    /// Leading dot so it's hidden in Finder if Ethan ever pokes at the
    /// Group Container directly. The file's CONTENTS don't matter — only
    /// the act of writing-to-the-Group-Container is what triggers TCC.
    private static let sentinelFileName = ".tcc-prewarm-sentinel"

    /// Synchronously trigger exactly one TCC access against the Group
    /// Container so the post-reboot prompt cascade collapses to a single
    /// dialog. Safe to call from any thread (the underlying FileManager
    /// write is thread-safe), but in practice called only from
    /// `App.init()` on the main thread.
    ///
    /// Failure modes (all non-fatal):
    ///   - "Don't Allow" clicked: write fails with EACCES. Logged via NSLog
    ///     (cannot use ActivityLogger here — that writes to the same
    ///     directory and would recurse). Subsequent app behaviour will
    ///     show the same dialog over and over for each access; user must
    ///     re-grant via System Settings.
    ///   - Directory doesn't exist: caller of `sharedContainerURL()`
    ///     handles `mkdir -p` semantics, so this is rare. If it happens
    ///     we log + return without crashing.
    ///   - URL is nil: extremely unlikely (the manual-path fallback in
    ///     `AppGroupPaths.sharedContainerURL()` always returns
    ///     non-nil), but defensively handled.
    static func prewarmGroupContainerAccess() {
        // In-process short-circuit — only do work once per process.
        // The TCC grant is kernel-side cached after the first access in
        // this boot session, so further file ops won't prompt anyway,
        // but skipping the syscall is still a couple ms cheaper.
        guard !hasPrewarmed else {
            return
        }
        hasPrewarmed = true

        // Resolve the Group Container URL via the same path the rest of
        // the app uses. This is critical: TCC prompts are issued PER
        // TARGET DIRECTORY, so we have to hit the EXACT directory all
        // subsequent code paths will hit — otherwise we'd just add a
        // third dialog instead of collapsing two into one.
        //
        // `sharedContainerURL()` returns the same URL regardless of
        // entitlement state because the host is unsandboxed and the
        // implementation falls back to manual `~/Library/Group Containers/<id>/`
        // when the security API returns nil (see AppGroupPaths.swift
        // for the full rationale).
        guard let containerURL = AppGroupPaths.sharedContainerURL() else {
            // Defensive — manual fallback in AppGroupPaths makes this
            // effectively unreachable, but we don't want a nil-crash
            // either if a future refactor returns nil for any reason.
            NSLog("[tcc-prewarm] WARN: AppGroupPaths.sharedContainerURL() returned nil — skipping prewarm")
            return
        }

        // The sentinel file path. We write the current ISO timestamp +
        // boot_uuid (best-effort) so if Ethan ever looks at the file
        // he can see when it was last touched, but the content is not
        // load-bearing — TCC only cares that we wrote SOMETHING to a
        // directory inside the Group Container.
        let sentinelURL = containerURL.appendingPathComponent(sentinelFileName, isDirectory: false)

        // Build the payload — ISO timestamp + (best-effort) boot session
        // UUID via sysctl. Useful for forensic inspection of the file
        // contents but not strictly required for the TCC mechanism.
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let timestamp = isoFormatter.string(from: Date())
        let bootUUID = currentBootSessionUUID() ?? "unknown"
        let payload = "tcc-prewarm version=v0.21.53 ts=\(timestamp) boot=\(bootUUID)\n"
        // ASCII-only payload — ensures we never trip a path-encoding
        // weirdness from Unicode normalization. (Defensive — UTF8
        // encoding to data would handle anything, but this keeps the
        // file inspectable from `cat` without surprise.)
        guard let payloadData = payload.data(using: .utf8) else {
            NSLog("[tcc-prewarm] WARN: failed to encode payload — skipping prewarm")
            return
        }

        // The write. THIS is what triggers the TCC dialog. The call
        // blocks the calling thread (the main thread, since this runs
        // from `App.init()`) until macOS finishes prompting the user
        // AND the user clicks "Allow" or "Don't Allow". With "Allow",
        // the write succeeds. With "Don't Allow", it fails with EACCES
        // and we log + continue.
        //
        // Wall-clock blocking note: this is intentional. The whole
        // purpose of this code is to FORCE serial dialog handling
        // BEFORE the rest of `App.init()` runs more file ops that
        // would queue MORE dialogs. The user sees ONE dialog, clicks
        // Allow, and the rest of startup proceeds silently. Acceptable
        // UX trade-off vs the pre-v0.21.53 behaviour of stacked
        // dialogs.
        do {
            try payloadData.write(to: sentinelURL, options: [.atomic])
            NSLog("[tcc-prewarm] Group Container TCC prewarmed via %@", sentinelURL.path)
        } catch {
            // "Don't Allow" path — log clearly so post-mortem can see
            // it. Cannot use ActivityLogger.log here because that
            // writes to the SAME directory (Logs/activity.log inside
            // the Group Container) and would just fail too,
            // potentially spinning if the logger has retry logic.
            // NSLog goes to the unified system log, accessible via
            // `log show --process MacosWidgetsStatsFromWebsite`.
            NSLog(
                "[tcc-prewarm] ERROR: failed to prewarm Group Container TCC — write threw %@. User likely clicked \"Don't Allow\" on the macOS dialog. App functionality will be degraded until they re-grant via System Settings → Privacy & Security → Files and Folders → Stats Widget from Website.",
                error.localizedDescription
            )
        }
    }

    /// Read the current boot session UUID via sysctl
    /// (`kern.bootsessionuuid`). Best-effort — returns nil if the sysctl
    /// is missing or fails. Used only for diagnostic content inside the
    /// sentinel file; never load-bearing.
    ///
    /// Why we don't just use `Host.current().name` or a UUID() literal:
    /// the boot UUID is the SAME value TCC.db's `boot_uuid` column
    /// uses to bind grants to a boot session. Including it in the
    /// sentinel file makes it possible to correlate "prewarm fired"
    /// with "TCC grant created" if Ethan ever needs to debug a
    /// regression. See `kern.bootsessionuuid` in /usr/include/sys/sysctl.h.
    private static func currentBootSessionUUID() -> String? {
        // sysctl returns a NULL-terminated C string. Allocate 64 bytes
        // (UUIDs are 36 chars plus null) and read it via sysctlbyname.
        var size: size_t = 64
        var buffer = [CChar](repeating: 0, count: 64)
        let result = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        guard result == 0 else {
            return nil
        }
        return String(cString: buffer)
    }
}
