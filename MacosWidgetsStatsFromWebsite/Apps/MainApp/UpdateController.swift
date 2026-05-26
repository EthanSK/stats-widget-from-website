//
//  UpdateController.swift
//  MacosWidgetsStatsFromWebsite
//
//  Sparkle 2 updater integration.
//
//  v0.21.15+ (Ethan voice 3991, 2026-05-24): also acts as the bridge
//  back-end for the MCP update tools (`check_for_updates`,
//  `install_pending_update`, `get_version`) — see MCPUpdateBridge.swift
//  for the rationale + protocol shape. This wiring lets the agent
//  end-to-end-verify a Sparkle release (push tag → CI builds + signs →
//  appcast updates → running app sees newer version → agent triggers
//  install) without a human clicking through Sparkle's UI dialog.
//

import AppKit
import Combine
import Sparkle

// v0.21.39 — switched from NSObject to a class also conforming to
// ObservableObject so SwiftUI views (AboutPrefsView's "Last checked"
// row) can re-render when Sparkle's lastUpdateCheckDate changes. Sparkle
// drops the timestamp on `SPUUpdater.lastUpdateCheckDate` after every
// terminal cycle, but that property is NOT KVO-observable in a way that
// plays nicely with SwiftUI — we publish a snapshot ourselves from the
// `didFinishUpdateCycleFor` delegate hook.
final class UpdateController: NSObject, ObservableObject {
    static let shared = UpdateController()

    /// Snapshot of the last time Sparkle ran a check cycle (any terminal
    /// state — found update, no update, aborted). Published so the About
    /// section can show "Last checked X ago". Nil until the first cycle
    /// completes.
    @Published private(set) var lastCheckDate: Date?

    /// Convenience flag the About section reads to disable the button while
    /// Sparkle is running a probe — prevents double-clicks from queueing
    /// extra cycles. Mirrors `probeInFlight` but exposed as `@Published`.
    @Published private(set) var isCheckingForUpdates: Bool = false

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    /// Most recent appcast item Sparkle has found via the
    /// `updater(_:didFindValidUpdate:)` delegate hook. Stored so the
    /// MCP `check_for_updates` tool can report `latestAppcastVersion`
    /// + `installPending` without re-running the network check or
    /// reaching into Sparkle's private state.
    ///
    /// HIGH 3 (Codex xhigh review, voice 3991): when Sparkle reports
    /// "no update found" it may STILL include the latest appcast item
    /// in `error.userInfo[SPULatestAppcastItemFoundKey]` (current == latest
    /// case). The old code blindly nil-ed this on `updaterDidNotFindUpdate`,
    /// which made `latestAppcastVersion` null on the "I'm up-to-date"
    /// branch — caller could not confirm "I'm on the newest" without
    /// inferring from nulls. New behaviour: preserve the appcast item
    /// from userInfo when present, only nil it if Sparkle truly returned
    /// nothing. See `updaterDidNotFindUpdate(_:error:)` below.
    private var lastFoundUpdate: SUAppcastItem?

    // MARK: - HIGH 2 — wait-for-probe-completion plumbing
    //
    // Codex xhigh review (voice 3991): the previous MCP `check_for_updates`
    // implementation called `updater.checkForUpdateInformation()` and then
    // returned the cached state after a single runloop tick. That tick
    // is FAR shorter than the network round-trip to fetch the appcast,
    // so the first MCP call always returned stale data (or null, on
    // first run). New behaviour:
    //
    //   1. MCP handler asks UpdateController to perform a probe.
    //   2. UpdateController queues the caller's completion handler and
    //      kicks off Sparkle's check.
    //   3. When Sparkle fires `updater(_:didFinishUpdateCycleFor:error:)`
    //      we flush all queued completions with the post-probe snapshot.
    //   4. MCP handler waits with a 30s timeout (Codex spec) — if Sparkle's
    //      network call dies, we still return rather than hanging the MCP
    //      session. Cached state is the fallback.
    //
    // Serialisation: only ONE Sparkle probe runs at a time. Subsequent
    // concurrent MCP callers attach their completion to the same in-flight
    // probe and all fire together when it finishes. This avoids hammering
    // Sparkle's scheduler with overlapping `checkForUpdateInformation()`
    // calls (which can confuse its internal session state).

    /// Queue of completion handlers waiting for the in-flight probe to
    /// finish. Accessed only on the main queue (Sparkle is main-thread-only,
    /// so we use that same queue as the synchronisation point — no extra
    /// lock needed). When non-empty, a probe is in flight.
    private var pendingProbeCompletions: [(MCPUpdateCheckResult) -> Void] = []

    /// Tracks whether a Sparkle probe is currently in flight. Set true
    /// when we kick off `checkForUpdateInformation()` and cleared in
    /// `didFinishUpdateCycleFor`. Distinct from `pendingProbeCompletions`
    /// non-empty because we want to know "is Sparkle currently running a
    /// cycle" independent of whether anyone is waiting on the result.
    private var probeInFlight = false

    var updater: SPUUpdater {
        updaterController.updater
    }

    func start() {
        updaterController.startUpdater()
        // Register with the Shared/MCP bridge so MCP tool dispatch can
        // reach Sparkle without Shared/ importing Sparkle. Set after
        // `startUpdater` so `updater.canCheckForUpdates` is meaningful
        // by the time the first MCP request arrives over the socket.
        MCPUpdateBridge.handler = self
        // Prime the last-check timestamp from Sparkle's own bookkeeping
        // so the About section shows a real value even if no cycle has
        // run during THIS session. Sparkle keeps the timestamp in
        // SUUpdaterLastUpdateCheckDate in NSUserDefaults.
        if let stored = updaterController.updater.lastUpdateCheckDate {
            lastCheckDate = stored
        }
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
        // The standard updater's checkForUpdates() shows the user-driver
        // UI. Flip the in-flight flag so views can disable the button
        // until didFinishUpdateCycleFor flushes us back to idle. We don't
        // try to be perfectly precise here — the worst case is the button
        // stays disabled an extra moment if the user cancels Sparkle's
        // dialog, which is harmless.
        isCheckingForUpdates = true
        updaterController.checkForUpdates(sender)
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // The app is always safe to update-check; keep this delegate hook for future gating.
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        NSLog("Sparkle found update %@", item.displayVersionString)
        // Cache the appcast item so the MCP bridge can answer
        // `latestAppcastVersion` / `installPending` without re-checking.
        // The `didFinishUpdateCycleFor` hook (below) is what actually
        // flushes the MCP completions — this just primes lastFoundUpdate
        // so the snapshot it reads is fresh.
        lastFoundUpdate = item
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("Sparkle did not find an update: %@", error.localizedDescription)
        // HIGH 3 (Codex xhigh review, voice 3991): when Sparkle reports
        // "no update found" the error.userInfo MAY include the latest
        // appcast item via SPULatestAppcastItemFoundKey (Sparkle 2.x
        // constant — confirmed against sparkle-project.org docs:
        // https://sparkle-project.org/documentation/publishing/).
        // Common case: current == latest. The old code blindly nil-ed
        // lastFoundUpdate here, which collapsed the "you are on the
        // newest" branch to null and forced callers to infer "up-to-date"
        // from missing fields. New behaviour: if Sparkle handed us the
        // appcast item we just compared against, KEEP it so the MCP
        // bridge can answer `latestAppcastVersion` truthfully even when
        // installPending is false.
        let userInfo = (error as NSError).userInfo
        if let latestItem = userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            // Preserve the item — current binary IS the latest, but we
            // still know the appcast's latest version. installPending will
            // be derived from currentVersion != latestVersion in the
            // bridge snapshot, NOT from lastFoundUpdate being non-nil
            // (which would otherwise lie about a pending install).
            lastFoundUpdate = latestItem
            NSLog(
                "Sparkle no-update path preserved appcast item %@ from userInfo",
                latestItem.displayVersionString
            )
        } else {
            // Truly no information about the appcast — clear the cache
            // so the bridge doesn't lie with stale data.
            lastFoundUpdate = nil
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Sparkle update check failed: %@", error.localizedDescription)
        // HIGH 2: an aborted cycle still needs to flush the waiters so
        // they don't sit on the semaphore until timeout. `didFinishUpdateCycleFor`
        // (below) is the canonical "cycle is over" hook in Sparkle 2.x —
        // didAbortWithError is paired with it, so we rely on that single
        // flush point rather than calling flushPendingProbeCompletions
        // here too (would double-flush).
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            NSLog("Sparkle update cycle finished with error: %@", error.localizedDescription)
        }
        // HIGH 2 (Codex xhigh review, voice 3991): THIS is the canonical
        // hook for "Sparkle's check cycle is over" — fires for every
        // terminal state (found update, didn't find, aborted with error,
        // user cancelled). All MCP callers waiting on a probe get
        // released here with the post-cycle snapshot.
        flushPendingProbeCompletions()
    }

    /// Drain every queued MCP probe completion handler with the current
    /// snapshot. Runs on the main queue (Sparkle's delegate hooks all
    /// fire on the main queue). Called exclusively from
    /// `didFinishUpdateCycleFor` — do NOT call from `didFindValidUpdate`
    /// / `updaterDidNotFindUpdate` directly, as those fire BEFORE the
    /// cycle completes and the snapshot could miss any final state Sparkle
    /// applies post-delegate.
    private func flushPendingProbeCompletions() {
        // Snapshot the appcast item we have, then build the result once
        // and hand the same one to every waiter. Avoids racing with a
        // hypothetical second probe scheduling itself in the gap between
        // calls (defence-in-depth — serialisation already blocks that).
        let snapshot = Self.snapshot(currentItem: lastFoundUpdate)
        let waiters = pendingProbeCompletions
        pendingProbeCompletions.removeAll(keepingCapacity: false)
        probeInFlight = false
        // v0.21.39 — publish the cycle-completion timestamp so the
        // About section's "Last checked" line refreshes. Prefer the
        // updater's own bookkeeping (more accurate — Sparkle records
        // this after the network exchange finishes) and fall back to
        // now() if Sparkle hasn't set it yet. Also clear the
        // user-driven "is checking" flag — the cycle is over either way.
        lastCheckDate = updaterController.updater.lastUpdateCheckDate ?? Date()
        isCheckingForUpdates = false
        for completion in waiters {
            completion(snapshot)
        }
    }
}

// MARK: - MCPUpdateBridgeHandler
//
// Implementation of the Shared/MCP bridge protocol. All work hops to
// the main queue because Sparkle's SPUUpdater is annotated
// `NS_SWIFT_UI_ACTOR` (main-thread only) — MCP requests arrive on
// arbitrary GCD queues so we cannot touch the updater inline.
//
// The completion closures are dispatched from the main queue back to
// the caller. The MCP dispatcher in MCPServer.swift uses a semaphore
// to bridge the async result back to its synchronous tool return.

extension UpdateController: MCPUpdateBridgeHandler {
    /// Programmatic (no-UI) update check. Uses
    /// `SPUUpdater.checkForUpdateInformation()` which fires the
    /// delegate hooks (`didFindValidUpdate` / `updaterDidNotFindUpdate`)
    /// without offering the user the standard install dialog —
    /// matches the task brief "Don't trigger UI; programmatic-only path."
    ///
    /// HIGH 2 (Codex xhigh review, voice 3991): waits for Sparkle's
    /// actual probe completion (`didFinishUpdateCycleFor`) before
    /// invoking the caller's completion. The old implementation only
    /// waited one runloop tick — far shorter than the network round-trip
    /// — so callers got stale/null cache on the first invocation. This
    /// version:
    ///
    ///   1. Enqueues the caller's completion onto `pendingProbeCompletions`.
    ///   2. Kicks off `checkForUpdateInformation()` IFF no probe is
    ///      already in flight (serialisation — concurrent MCP calls share
    ///      one Sparkle probe and all flush together when it finishes).
    ///   3. The actual flush happens in the `didFinishUpdateCycleFor`
    ///      delegate hook (see `flushPendingProbeCompletions`).
    ///   4. The MCP server side (`MCPServer.swift`) holds a semaphore
    ///      with a 30s timeout — if Sparkle's network call hangs we
    ///      still return rather than pinning the MCP session.
    func checkForUpdates(completion: @escaping (MCPUpdateCheckResult) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(Self.snapshot(currentItem: nil))
                return
            }

            // Sparkle's session-in-progress covers appcast download,
            // update download, and any UI showing. If a *user-driven*
            // session is up we cannot programmatically join it — return
            // the current cached state immediately so the agent isn't
            // blocked waiting for a human to dismiss a dialog. The
            // serialisation queue (probeInFlight) handles concurrent
            // MCP probes; sessionInProgress handles concurrent user UI.
            if self.updater.sessionInProgress && !self.probeInFlight {
                completion(Self.snapshot(currentItem: self.lastFoundUpdate))
                return
            }

            // Queue the caller. If a probe is already in flight, just
            // attach — the in-flight probe's didFinishUpdateCycleFor
            // will flush us along with everyone else.
            self.pendingProbeCompletions.append(completion)
            if self.probeInFlight {
                return
            }

            // First caller — kick off the actual Sparkle probe.
            guard self.updater.canCheckForUpdates else {
                // Cannot check (e.g. updater not started, or disabled
                // by policy). Flush ourselves with the cached state so
                // the caller doesn't sit on the semaphore.
                self.flushPendingProbeCompletions()
                return
            }
            self.probeInFlight = true
            self.updater.checkForUpdateInformation()
            // The didFinishUpdateCycleFor delegate (and its
            // flushPendingProbeCompletions call) will fire when Sparkle
            // completes the cycle — either with a found update, no
            // update, or an abort. The MCP semaphore on the other side
            // bounds the wait at 30s in case Sparkle hangs.
        }
    }

    /// Trigger Sparkle's install path. Note Sparkle's `SPUStandardUserDriver`
    /// surfaces an "install now / later" dialog on the running app —
    /// there is no fully-headless install API exposed by the standard
    /// updater. For an agent-driven verification flow this is the best
    /// we can do without writing a custom user driver. If `lastFoundUpdate`
    /// is nil (no pending update cached) we don't trigger Sparkle at
    /// all — return `scheduled: false`.
    func installPendingUpdate(completion: @escaping (MCPUpdateInstallResult) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(MCPUpdateInstallResult(scheduled: false, pendingVersion: nil))
                return
            }

            guard let pending = self.lastFoundUpdate else {
                completion(MCPUpdateInstallResult(scheduled: false, pendingVersion: nil))
                return
            }

            // `checkForUpdates()` on SPUUpdater (not the controller's
            // IBAction wrapper) re-uses the cached found update if a
            // session is still alive, or re-runs the probe + offers
            // install via the standard user driver if not. This is the
            // closest analogue to "install if available" available on
            // the standard user driver.
            if self.updater.canCheckForUpdates {
                self.updater.checkForUpdates()
            }

            completion(MCPUpdateInstallResult(
                scheduled: true,
                pendingVersion: pending.displayVersionString
            ))
        }
    }

    /// Build the bridge-typed snapshot from the running-binary Bundle
    /// info dict + the cached appcast item. Kept as a static helper so
    /// the early-return paths in `checkForUpdates` share one source of
    /// truth for the shape.
    ///
    /// HIGH 3 (Codex xhigh review, voice 3991): the appcast version is
    /// preserved even when current == latest. Old behaviour: any cached
    /// appcast item implied "install pending"; we now compute pending-ness
    /// from a version comparison so callers can confirm "I'm on the newest"
    /// via currentVersion == latestAppcastVersion && installPending=false.
    ///
    /// FINDING 1 follow-up (Codex re-review of 09ee493, voice 3991):
    /// `installPending` MUST be computed using Sparkle's
    /// `SUAppcastItem.versionString` (which corresponds to CFBundleVersion
    /// — the monotonic build number) against the running binary's
    /// `CFBundleVersion`, NOT against `displayVersionString` /
    /// `CFBundleShortVersionString`. This repo intentionally ships
    /// `v<version>-build.<run_number>` releases that keep the marketing
    /// version stable while bumping the build number (see
    /// prepare_release_metadata.py line ~94). Comparing display strings
    /// would mark a legitimate higher-build update as "not pending".
    /// Sparkle's documentation is explicit: "versionString is what Sparkle
    /// uses to compare update items" (= CFBundleVersion).
    /// `latestAppcastVersion` in the JSON response stays as the
    /// human-readable `displayVersionString` because that is what agents
    /// quote in user-facing release notes.
    private static func snapshot(currentItem: SUAppcastItem?) -> MCPUpdateCheckResult {
        let info = Bundle.main.infoDictionary
        // displayVersion = CFBundleShortVersionString (e.g. "0.21.16") —
        // for human-facing display only.
        let displayVersion = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        // buildVersion = CFBundleVersion (e.g. "1273") — the monotonic
        // build number Sparkle ACTUALLY compares against versionString.
        // Cast as String since CFBundleVersion is stored as a string in
        // the plist even though it's numeric in practice.
        let currentBuild = (info?["CFBundleVersion"] as? String) ?? ""
        let latestDisplay = currentItem?.displayVersionString
        let latestBuild = currentItem?.versionString
        // installPending iff Sparkle's appcast build version differs
        // from our running build number. This correctly catches both
        // marketing-version bumps (which always bump build too) AND
        // build-only "vX.Y.Z-build.N" releases where the marketing
        // version stays put.
        //
        // We compare strings, not parsed ints, because Sparkle
        // tolerates non-numeric build identifiers (e.g. "1273.beta").
        // A pure string comparison may classify a legitimate downgrade
        // appcast as "pending" — that's acceptable because Sparkle's
        // own install path will refuse a downgrade unless explicitly
        // allowed. The MCP "pending" flag is an availability signal,
        // not a "Sparkle will definitely apply this" guarantee.
        let pending: Bool
        if let latestBuild, !currentBuild.isEmpty, latestBuild != currentBuild {
            pending = true
        } else {
            pending = false
        }
        return MCPUpdateCheckResult(
            currentVersion: displayVersion,
            latestAppcastVersion: latestDisplay,
            installPending: pending
        )
    }
}
