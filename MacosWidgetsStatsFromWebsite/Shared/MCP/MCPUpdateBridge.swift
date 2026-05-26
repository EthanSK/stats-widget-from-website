//
//  MCPUpdateBridge.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Thin static bridge that lets MCP update tools (check_for_updates,
//  install_pending_update) talk to Sparkle WITHOUT MCPServer.swift —
//  which lives in Shared/ — having to `import Sparkle`.
//
//  Why this lives in Shared/ but does not import Sparkle:
//    - MCPServer.swift is compiled into BOTH MainApp (where Sparkle IS
//      linked via the SPM package) AND the CLI tool (where Sparkle is
//      NOT linked — Sparkle would bloat the headless CLI binary and
//      isn't useful there: a one-shot CLI process can't run an updater
//      session anyway). See project.yml for the two target dependency
//      blocks.
//    - The widget extension excludes Shared/MCP entirely, so it never
//      sees this file.
//
//  How the wiring works:
//    1. UpdateController.start() in MainApp registers itself as the
//       handler via `MCPUpdateBridge.handler = self`.
//    2. MCPServer's update tools read `MCPUpdateBridge.handler` and
//       dispatch through the protocol. If handler is nil (CLI stdio
//       transport, or MainApp before UpdateController has been booted),
//       the tools throw a clear "update tools unavailable in this
//       transport" error — same pattern as identify_element guarding
//       against the stdio-only path.
//    3. Sparkle types (SUAppcastItem, SPUUpdater) never leak across
//       this boundary — the protocol uses primitive Swift types so
//       both sides compile cleanly regardless of Sparkle's link state.
//
//  Context: Ethan voice 3991 (2026-05-24) — stats-widget is moving from
//  Xcode-driven releases to a Sparkle-only pipeline, and the agent needs
//  programmatic ways to (a) check whether the just-shipped appcast has
//  a newer version than the running binary and (b) trigger install on
//  the verifier machine without a human clicking through a dialog. The
//  bundle.id / version readout from `get_version` doubles as the "what
//  am I running right now" probe that the bump-and-tag script (Sub B)
//  uses to confirm a release has propagated.
//

import Foundation

/// Result returned from a programmatic `check_for_updates` invocation.
///
/// All fields are kept as primitive Swift types so this header is
/// Sparkle-agnostic — the MainApp-side implementer (`UpdateController`)
/// translates SUAppcastItem into a plain version string before returning.
struct MCPUpdateCheckResult {
    /// `CFBundleShortVersionString` of the currently running binary.
    let currentVersion: String

    /// Most recent appcast version Sparkle has fetched and cached via
    /// the `updater(_:didFindValidUpdate:)` delegate hook. `nil` until
    /// at least one check has completed against the feed.
    let latestAppcastVersion: String?

    /// True iff Sparkle has found a valid update that hasn't been
    /// installed yet (i.e. a pending update is queued for install).
    let installPending: Bool
}

/// Result returned from a programmatic `install_pending_update` invocation.
struct MCPUpdateInstallResult {
    /// True iff the call successfully scheduled an install (i.e. Sparkle
    /// found a pending update and either dispatched the install or
    /// surfaced the standard installer UI). False means no update was
    /// available to install.
    let scheduled: Bool

    /// The version string that will be installed if `scheduled == true`.
    /// `nil` when nothing is pending.
    let pendingVersion: String?
}

/// Result returned from `upgrade_to_latest` — the autonomous orchestrator
/// added in v0.21.43 (Ethan voice 4212, 2026-05-26). One-shot probe + install
/// dispatch wrapping the existing checkForUpdates → installPendingUpdate
/// dance so an agent doesn't have to chain two MCP calls.
///
/// IMPORTANT — silent-install caveat: Sparkle's `SPUStandardUserDriver`
/// (which we use for the menu-bar app) does NOT expose a fully-headless
/// install path. When `scheduled == true`, Sparkle will display a small
/// "install on quit / install and relaunch" prompt that the user must
/// dismiss. The flag `automaticUpdatesEnabled` here means we've toggled
/// `SPUUpdater.automaticallyDownloadsUpdates = YES` so subsequent app
/// launches will silently install pending updates via Sparkle's
/// scheduled-update path — i.e. the "next time you quit + relaunch the
/// menu-bar app, the update applies without any UI". The marketing-version
/// switch is therefore deferred to the next app launch on the user's
/// machine; we cannot force a foreground relaunch over MCP without
/// implementing a custom `SPUUserDriver` (out of scope for v0.21.43).
struct MCPUpgradeResult {
    /// True iff a newer appcast version was found vs the running binary.
    let upgraded: Bool

    /// Reason short-string when `upgraded == false`. One of:
    ///   `"already_latest"`  — current binary == appcast latest, nothing to do.
    ///   `"no_appcast"`      — Sparkle probe didn't return an appcast item (network error, feed empty).
    ///   `"updater_unavailable"` — bridge handler missing (e.g. stdio without proxy fallback).
    /// `nil` when `upgraded == true`.
    let reason: String?

    /// Currently-running binary `CFBundleShortVersionString` BEFORE the install dispatch.
    /// Always populated, even on the no-op path.
    let fromVersion: String

    /// Latest appcast `displayVersionString` AFTER the probe.
    /// On `upgraded == true` this is the version Sparkle will install.
    /// On `upgraded == false, reason == "already_latest"` this equals
    /// `fromVersion`. On `reason == "no_appcast"` this is `nil`.
    let toVersion: String?

    /// True iff we successfully toggled `SPUUpdater.automaticallyDownloadsUpdates`
    /// on for the running app. The flag persists in `NSUserDefaults` under
    /// `SUAutomaticallyUpdate` so subsequent app launches will silently
    /// download + install pending updates without an install dialog. This
    /// is our compromise for "auto-install without user-interaction Sparkle
    /// dialog" given `SPUStandardUserDriver`'s API surface — see
    /// MCPUpgradeResult documentation block above for the full caveat.
    let automaticUpdatesEnabled: Bool

    /// Total wall-clock duration of the orchestrator in milliseconds, from
    /// MCP request arrival to result completion. Helps the agent reason
    /// about whether to wait for the install dialog to surface or move on.
    let elapsedMs: Int
}

/// Protocol implemented by the MainApp's `UpdateController` so the
/// MCP server in Shared/ can drive Sparkle without importing it.
///
/// All methods must be safe to call from a non-main thread — the
/// implementer is responsible for hopping to the main queue before
/// touching Sparkle (Sparkle's `SPUUpdater` is `NS_SWIFT_UI_ACTOR`).
protocol MCPUpdateBridgeHandler: AnyObject {
    /// Fire a programmatic update check against the configured appcast.
    /// Should NOT show any UI (Sparkle's `checkForUpdateInformation`
    /// "probing" path). The completion fires with the latest known
    /// state after the check completes (or immediately with the
    /// cached state on error — never blocks indefinitely).
    func checkForUpdates(completion: @escaping (MCPUpdateCheckResult) -> Void)

    /// Trigger install of the pending update if one is queued. May
    /// surface Sparkle's standard installer UI on the running app —
    /// Sparkle's `SPUUpdater` API does not expose a fully-headless
    /// install path on the standard user driver, so showing the
    /// dialog is the trade-off here.
    func installPendingUpdate(completion: @escaping (MCPUpdateInstallResult) -> Void)

    /// Autonomous probe + install orchestrator (v0.21.43, Ethan voice 4212,
    /// 2026-05-26). One MCP call: probe Sparkle, if an update is pending
    /// toggle `SPUUpdater.automaticallyDownloadsUpdates = YES` so future
    /// launches install silently, then dispatch Sparkle's install path.
    /// Completion fires once the probe has settled + the install dispatch
    /// has been requested (NOT once Sparkle actually completes the
    /// install + relaunch — that requires a process restart we can't
    /// observe in-band).
    ///
    /// Implementer must:
    ///   1. Wait for the Sparkle probe to terminate (didFinishUpdateCycleFor)
    ///   2. If probe found a newer version, set automaticallyDownloadsUpdates
    ///      and call updater.checkForUpdates() to dispatch install
    ///   3. Hop to main queue for all SPUUpdater touches (Sparkle is
    ///      `NS_SWIFT_UI_ACTOR`)
    func upgradeToLatest(completion: @escaping (MCPUpgradeResult) -> Void)
}

/// Static singleton accessor for the MCP server to read.
///
/// Set once from `UpdateController.start()` on the MainApp side. Read
/// by `MCPToolDispatcher` when the agent invokes a Sparkle MCP tool.
/// Stays `nil` in CLI/stdio builds and any path that hasn't booted
/// UpdateController yet (e.g. a socket request that arrives before
/// `applicationDidFinishLaunching`).
enum MCPUpdateBridge {
    /// The currently-registered handler. Use a serial-access pattern —
    /// in practice this is written exactly once at MainApp startup and
    /// read on the MCP dispatch threads, so a plain mutable static is
    /// fine without locking.
    static weak var handler: MCPUpdateBridgeHandler?
}
