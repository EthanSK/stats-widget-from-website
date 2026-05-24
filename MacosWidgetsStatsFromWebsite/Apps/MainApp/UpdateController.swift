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
import Sparkle

final class UpdateController: NSObject {
    static let shared = UpdateController()

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    /// Most recent appcast item Sparkle has found via the
    /// `updater(_:didFindValidUpdate:)` delegate hook. Stored so the
    /// MCP `check_for_updates` tool can report `latestAppcastVersion`
    /// + `installPending` without re-running the network check or
    /// reaching into Sparkle's private state. Reset to nil when
    /// Sparkle reports "no update found" so the bridge doesn't lie
    /// about a stale pending update after the user has installed
    /// out-of-band.
    private var lastFoundUpdate: SUAppcastItem?

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
    }

    @objc func checkForUpdates(_ sender: Any? = nil) {
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
        lastFoundUpdate = item
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        NSLog("Sparkle did not find an update: %@", error.localizedDescription)
        // Drop any cached pending update — the latest probe says there
        // is none, so the MCP bridge should not report one.
        lastFoundUpdate = nil
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        NSLog("Sparkle update check failed: %@", error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            NSLog("Sparkle update cycle finished with error: %@", error.localizedDescription)
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
    func checkForUpdates(completion: @escaping (MCPUpdateCheckResult) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                completion(Self.snapshot(currentItem: nil))
                return
            }

            // If a check session is already in progress, return the
            // cached state immediately — re-triggering would race
            // Sparkle's internal scheduler. `sessionInProgress` covers
            // appcast download, update download, and any showing of
            // update UI; we don't want to interfere with any of those.
            if !self.updater.sessionInProgress && self.updater.canCheckForUpdates {
                self.updater.checkForUpdateInformation()
            }

            // Wait one runloop tick so the delegate hook
            // (`didFindValidUpdate` / `updaterDidNotFindUpdate`) has a
            // chance to fire before we read `lastFoundUpdate`. The
            // network round-trip itself is async and may take longer
            // than a single tick — in that case we return the cached
            // state from the PREVIOUS check, which is the documented
            // behaviour ("may be null if not yet checked"). Future
            // calls will pick up the fresher state once the network
            // result lands.
            DispatchQueue.main.async {
                completion(Self.snapshot(currentItem: self.lastFoundUpdate))
            }
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
    private static func snapshot(currentItem: SUAppcastItem?) -> MCPUpdateCheckResult {
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        return MCPUpdateCheckResult(
            currentVersion: current,
            latestAppcastVersion: currentItem?.displayVersionString,
            installPending: currentItem != nil
        )
    }
}
