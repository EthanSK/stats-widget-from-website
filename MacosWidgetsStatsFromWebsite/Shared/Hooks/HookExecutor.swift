//
//  HookExecutor.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Detached executor for per-tracker scrape lifecycle hooks (v0.18.0+).
//
//  Design contract:
//    - Hook execution NEVER blocks scrape recording. We invoke
//      `fire(...)` from the BackgroundScheduler's post-record path and
//      return immediately. The actual Process spawn happens on a
//      dedicated utility queue.
//    - Hook failures NEVER block the scheduler. An exception thrown
//      inside the hook script is caught, stamped on the hook's
//      lastRun.detail, and logged to ActivityLogger. The next scrape
//      proceeds unaffected.
//    - 60s wall-clock timeout per hook. Exceeding it sends SIGTERM,
//      then SIGKILL 1s later if the child is still alive.
//    - Env-var contract is the public-stable API surface for hook
//      authors. See `makeEnvironment(...)` below for the full list.
//    - Hook execution can be mocked at the top of fire() via the
//      `processLauncher` static — tests inject a fake to avoid actually
//      spawning Terminal windows during the suite.
//

import Foundation

#if !WIDGET_EXTENSION

enum HookExecutor {
    static let defaultTimeoutSeconds: TimeInterval = 60.0

    /// Maximum bytes of stderr captured back into `HookLastRun.detail`.
    /// Anything beyond this is truncated so a chatty hook can't bloat
    /// trackers.json.
    static let maxCapturedDetailBytes = 1024

    /// Mockable launcher seam. Tests replace this with a fake that
    /// records invocations without spawning real processes.
    static var processLauncher: HookProcessLauncher = SystemHookProcessLauncher()

    /// Replace the launcher and return the prior value so tests can
    /// reset cleanly in tearDown.
    @discardableResult
    static func setLauncher(_ launcher: HookProcessLauncher) -> HookProcessLauncher {
        let prior = processLauncher
        processLauncher = launcher
        return prior
    }

    /// Async-fires every enabled hook for `trigger` on the given tracker.
    /// Returns immediately. Any per-hook telemetry update flows through
    /// the optional `recordTelemetry` callback so the caller (typically
    /// BackgroundScheduler) can persist the lastRun stamp back into the
    /// tracker config without HookExecutor needing to know about
    /// AppGroupStore.
    static func fire(
        trigger: HookTrigger,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        recordTelemetry: ((UUID, HookLastRun) -> Void)? = nil
    ) {
        let hooks = tracker.hooks.enabledHooks(for: trigger)
        guard !hooks.isEmpty else {
            return
        }

        let launcher = processLauncher

        ActivityLogger.log("hook", "firing", metadata: [
            "trigger": trigger.rawValue,
            "trackerID": tracker.id.uuidString,
            "count": "\(hooks.count)"
        ])

        for hook in hooks {
            let startedAt = Date()
            let initialTelemetry = HookLastRun(
                startedAt: startedAt,
                finishedAt: nil,
                status: .ok,
                exitCode: nil,
                detail: nil
            )
            recordTelemetry?(hook.id, initialTelemetry)

            launcher.launch(
                hook: hook,
                tracker: tracker,
                scrapeContext: scrapeContext,
                timeout: defaultTimeoutSeconds
            ) { outcome in
                let telemetry = HookLastRun(
                    startedAt: startedAt,
                    finishedAt: Date(),
                    status: outcome.status,
                    exitCode: outcome.exitCode,
                    detail: truncateDetail(outcome.detail)
                )

                ActivityLogger.log("hook", "finished", metadata: [
                    "trigger": trigger.rawValue,
                    "trackerID": tracker.id.uuidString,
                    "hookID": hook.id.uuidString,
                    "hookName": hook.name,
                    "status": outcome.status.rawValue,
                    "exitCode": outcome.exitCode.map { "\($0)" } ?? "-",
                    "elapsedSec": String(format: "%.2f", telemetry.finishedAt!.timeIntervalSince(startedAt))
                ])

                recordTelemetry?(hook.id, telemetry)
            }
        }
    }

    /// Build the env-var bag every hook sees. The naming is **stable
    /// public API** — third parties writing custom hooks rely on these
    /// names. Rename = breaking change.
    static func makeEnvironment(
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        bundleAutoRepairScript: Bool = true
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment

        env["TRACKER_ID"] = tracker.id.uuidString
        env["TRACKER_NAME"] = tracker.name
        env["TRACKER_URL"] = tracker.url
        env["TRACKER_SELECTOR"] = tracker.selector
        env["TRACKER_RENDER_MODE"] = tracker.renderMode.rawValue
        env["TRACKER_BROWSER_PROFILE"] = tracker.browserProfile

        env["HOOK_TRIGGER"] = scrapeContext.trigger.rawValue
        env["HOOK_FIRED_AT"] = ISO8601DateFormatter().string(from: scrapeContext.firedAt)

        if let value = scrapeContext.scrapedValue {
            env["SCRAPE_VALUE"] = value
        }
        if let numeric = scrapeContext.scrapedNumeric {
            env["SCRAPE_NUMERIC"] = "\(numeric)"
        }
        if let errorKind = scrapeContext.errorKind {
            env["ERROR_KIND"] = errorKind
        }
        if let errorMessage = scrapeContext.errorMessage {
            env["ERROR_MESSAGE"] = errorMessage
        }
        if let consecutiveFailureCount = scrapeContext.consecutiveFailureCount {
            env["CONSECUTIVE_FAILURE_COUNT"] = "\(consecutiveFailureCount)"
        }

        env["APP_GROUP_IDENTIFIER"] = AppGroupPaths.identifier
        env["MCP_SOCKET_PATH"] = AppGroupPaths.mcpSocketURL().path

        if bundleAutoRepairScript {
            env["AUTO_REPAIR_SCRIPT"] = HookScriptPaths.autoRepairScriptURL().path
        }

        return env
    }

    /// POSIX-safe shell-quoting for a path that will be spliced into a
    /// `/bin/bash -lc "..."` invocation. Wraps the string in single
    /// quotes and escapes any embedded single-quote as `'\''`.
    ///
    /// We need this because the auto-repair bundle path after the
    /// v0.21.22 rename contains spaces (`Stats Widget from Website.app`),
    /// and unquoted spaces tokenise the bash command line — see comment
    /// in the .runShellCommand case above. Single-quote wrapping is the
    /// least error-prone approach: it disables ALL bash interpretation
    /// inside the quoted region, so `$`, backticks, backslash, etc. all
    /// survive verbatim. The only character that needs special handling
    /// is the single-quote itself.
    ///
    /// Established 2026-05-26 (voice 4189 / v0.21.36 fix).
    static func shellQuote(_ rawPath: String) -> String {
        // Replace each embedded `'` with `'\''` (close-quote,
        // escaped-quote, reopen-quote). Then wrap the whole thing in
        // single quotes.
        let escaped = rawPath.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private static func truncateDetail(_ detail: String?) -> String? {
        guard var trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.utf8.count > maxCapturedDetailBytes {
            let end = trimmed.index(trimmed.startIndex, offsetBy: maxCapturedDetailBytes, limitedBy: trimmed.endIndex) ?? trimmed.endIndex
            trimmed = String(trimmed[..<end]) + "…"
        }
        return trimmed
    }
}

/// Snapshot of the scrape attempt that produced the hook firing. Passed
/// through to the executor as env vars and surfaced to test mocks.
struct HookScrapeContext: Equatable {
    var trigger: HookTrigger
    var firedAt: Date
    var scrapedValue: String?
    var scrapedNumeric: Double?
    var errorKind: String?
    var errorMessage: String?
    var consecutiveFailureCount: Int?
}

/// Result of a single hook process invocation.
struct HookOutcome: Equatable {
    var status: HookLastRun.Status
    var exitCode: Int32?
    var detail: String?
}

/// Pluggable seam — tests swap in a fake launcher that doesn't actually
/// fork/exec.
protocol HookProcessLauncher {
    func launch(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval,
        completion: @escaping (HookOutcome) -> Void
    )
}

/// Production launcher. Spawns a Process per hook, captures stderr,
/// applies a hard wall-clock timeout, and reports back via completion.
final class SystemHookProcessLauncher: HookProcessLauncher {
    static let workQueue = DispatchQueue(
        label: "com.ethansk.macos-widgets-stats-from-website.hook-executor",
        qos: .utility,
        attributes: .concurrent
    )

    func launch(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval,
        completion: @escaping (HookOutcome) -> Void
    ) {
        Self.workQueue.async {
            let outcome = self.runSynchronously(
                hook: hook,
                tracker: tracker,
                scrapeContext: scrapeContext,
                timeout: timeout
            )
            completion(outcome)
        }
    }

    private func runSynchronously(
        hook: TrackerHook,
        tracker: Tracker,
        scrapeContext: HookScrapeContext,
        timeout: TimeInterval
    ) -> HookOutcome {
        let process = Process()
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()

        switch hook.actionKind {
        case .runShellCommand:
            // v0.21.36 — shell-quote the substituted script path before
            // splicing it into the bash command line.
            //
            // Bug history (voice 4189 + 4188 + readings.json diag,
            // 2026-05-26): the auto-repair scaffold ships with
            // `actionPayload = "${AUTO_REPAIR_SCRIPT}"` (literal,
            // unquoted in the template). v0.21.22+ renamed the .app
            // wrapper from `MacosWidgetsStatsFromWebsite.app` to
            // `Stats Widget from Website.app`. Once installed, the
            // bundled hook script path expands to e.g.
            //   `/Applications/Stats Widget from Website.app/Contents/Resources/Scripts/auto-repair-tracker.sh`
            // — a path with TWO spaces. Splicing that into
            // `bash -lc "<path>"` made bash tokenise on whitespace and
            // try to exec `/Applications/Stats` as a command, yielding
            // exit code 127 and the iconic detail string
            //   "/bin/bash: /Applications/Stats: No such file or directory"
            // visible in trackers.json `lastRun.detail` for every
            // tracker that hit a failure under v0.21.34 / .35.
            //
            // Fix: when the actionPayload IS exactly the auto-repair
            // token, bypass shell entirely and exec the script directly
            // — no quoting risk, no shell at all. The env vars set
            // below (TRACKER_*, HOOK_*, AUTO_REPAIR_SCRIPT itself) are
            // already inherited by the child, which is the entire
            // public-stable hook API. For user-authored shell payloads
            // we still apply shell-quoting to the substituted path so
            // arbitrary user shell snippets like
            //   `${AUTO_REPAIR_SCRIPT} --dry-run`
            // continue to work even when the bundle path contains
            // spaces.
            let scriptPath = HookScriptPaths.autoRepairScriptURL().path
            let isExactAutoRepairInvocation = hook.actionPayload
                .trimmingCharacters(in: .whitespacesAndNewlines) ==
                HookScriptPaths.autoRepairCommandToken
            if isExactAutoRepairInvocation {
                // Direct exec — no shell tokenisation at all. Safest
                // path for the built-in scaffold.
                process.launchPath = scriptPath
                process.arguments = []
            } else {
                // User-authored shell payload: shell-quote the
                // substituted path so spaces survive bash parsing.
                let resolvedPayload = hook.actionPayload
                    .replacingOccurrences(
                        of: HookScriptPaths.autoRepairCommandToken,
                        with: HookExecutor.shellQuote(scriptPath)
                    )
                process.launchPath = "/bin/bash"
                process.arguments = ["-lc", resolvedPayload]
            }
        case .runAppleScript:
            process.launchPath = "/usr/bin/osascript"
            process.arguments = ["-e", hook.actionPayload]
        }

        process.environment = HookExecutor.makeEnvironment(
            tracker: tracker,
            scrapeContext: scrapeContext
        )
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe

        // v0.21.74 — PIPE-BUFFER DEADLOCK FIX (voice-reported: auto-repair
        // agent + other verbose hooks silently SIGKILLed at the 60s timeout).
        //
        // Bug: the previous code attached both pipes, ran the process, polled
        // `process.isRunning` in a sleep loop, and only called
        // `readDataToEndOfFile()` AFTER the process exited. A pipe has a fixed
        // OS kernel buffer (~16–64 KB on macOS). A child that writes more than
        // that to stdout/stderr fills the buffer and BLOCKS on `write(2)`
        // waiting for someone to drain the read end. But nobody was reading
        // until after exit — and the child could not exit because it was
        // blocked mid-write. Classic producer/consumer deadlock: the child
        // hangs forever, our poll loop hits the 60s deadline, and we
        // terminate/SIGKILL a hook that was perfectly healthy — it just had a
        // lot to say. The auto-repair agent (which streams verbose Claude
        // output) is exactly such a hook, so it kept getting killed.
        //
        // Fix: install `readabilityHandler` on BOTH pipe read-ends BEFORE
        // `process.run()`. The handlers fire on a background queue as data
        // becomes available, continuously draining the kernel buffers so the
        // child never blocks on write. We accumulate into `stdoutData` /
        // `stderrData`, guarded by `outputLock` because the two handlers run
        // concurrently and the timeout/exit path on this thread also reads
        // them. After this change the 60s timeout only ever fires for a
        // genuinely-stuck hook, not for a chatty one.
        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Drain stdout as it arrives. An empty `availableData` signals EOF
        // (the write end closed when the child exited / we closed it on
        // teardown) — clear the handler then so the reader thread can wind
        // down and we don't spin on repeated zero-length reads.
        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outputLock.lock()
            stdoutData.append(chunk)
            outputLock.unlock()
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            outputLock.lock()
            stderrData.append(chunk)
            outputLock.unlock()
        }

        do {
            try process.run()
        } catch {
            // Launch failed before any reader work mattered — tear the
            // handlers down so the background dispatch sources don't linger.
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            return HookOutcome(
                status: .error,
                exitCode: nil,
                detail: "Could not launch hook: \(error.localizedDescription)"
            )
        }

        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() >= deadline {
                timedOut = true
                process.terminate()
                let killDeadline = Date().addingTimeInterval(1.0)
                while process.isRunning && Date() < killDeadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.waitUntilExit()
        }

        // v0.21.74 — the readabilityHandlers (installed before run) have been
        // draining the pipes the whole time, so we DON'T call
        // `readDataToEndOfFile()` here (that would block / race with the
        // handlers). Instead: tear the handlers down, then synchronously read
        // whatever bytes are still buffered in the kernel after exit (a final
        // burst can land between the last handler fire and process exit), and
        // append it under the same lock. `readToEnd()` here is safe because
        // the write end is closed (process exited / killed), so it returns
        // promptly at EOF rather than blocking.
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        let trailingStdout = (try? stdoutHandle.readToEnd()) ?? nil
        let trailingStderr = (try? stderrHandle.readToEnd()) ?? nil
        outputLock.lock()
        if let trailingStdout { stdoutData.append(trailingStdout) }
        if let trailingStderr { stderrData.append(trailingStderr) }
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        outputLock.unlock()
        let combinedDetail = combine(stderr: stderr, stdout: stdout)

        if timedOut {
            return HookOutcome(
                status: .timeout,
                exitCode: process.terminationStatus,
                detail: "Hook exceeded \(Int(timeout))s timeout. " + combinedDetail
            )
        }

        let exitCode = process.terminationStatus
        if exitCode == 0 {
            return HookOutcome(status: .ok, exitCode: exitCode, detail: combinedDetail.nilIfBlank)
        } else {
            return HookOutcome(status: .error, exitCode: exitCode, detail: combinedDetail.nilIfBlank ?? "Hook exited with code \(exitCode).")
        }
    }

    private func combine(stderr: String, stdout: String) -> String {
        switch (stderr.isEmpty, stdout.isEmpty) {
        case (true, true): return ""
        case (false, true): return stderr
        case (true, false): return stdout
        case (false, false): return stderr + "\n" + stdout
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#endif
