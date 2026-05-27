//
//  ChromeIdentifyElementCoordinator.swift
//  MacosWidgetsStatsFromWebsite
//
//  User-facing Chrome/CDP element capture flow.
//

import AppKit
import Foundation
import SwiftUI

struct ElementPick: Equatable {
    var selector: String
    var text: String
    var bbox: ElementBoundingBox
}

struct ElementCapturePreview: Identifiable {
    let id = UUID()
    var pick: ElementPick
    var snapshot: NSImage?
}

struct ChromeElementCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ChromeElementCaptureController
    @State private var chromiumAvailable: Bool = ChromeBrowserProfile.shared.chromiumIsAvailable()
    @State private var isShowingChromiumInstallSheet: Bool = false

    private let onElementCaptured: (ElementPick) -> Void

    init(
        url: URL,
        renderMode: RenderMode,
        onElementCaptured: @escaping (ElementPick) -> Void
    ) {
        _controller = StateObject(wrappedValue: ChromeElementCaptureController(url: url, renderMode: renderMode))
        self.onElementCaptured = onElementCaptured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Identify Element in Chrome")
                    .font(.title3.weight(.semibold))
                Text("The app uses its persistent Chrome/Chromium CDP profile so signed-in pages, Google auth, and dashboard sessions behave like a real browser.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("URL") {
                Text(controller.url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Chrome will open or reuse the matching tab.", systemImage: "1.circle")
                Label("Sign in or navigate in Chrome if needed.", systemImage: "2.circle")
                Label("Hover the value or region, click it, then confirm the preview here.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if controller.isIdentifying {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.notice ?? "Opening Chrome/CDP picker…")
                        .foregroundStyle(.secondary)
                }
            } else if let notice = controller.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !chromiumAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    // v0.21.36 — user-facing copy rename pass (voice 4189).
                    Text("Identify needs the Chromium browser bundled inside this app. Reinstall Stats Widget from Website to restore the missing browser bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            HStack {
                Button("Cancel") {
                    controller.cancel()
                    dismiss()
                }
                Spacer()
                if !chromiumAvailable {
                    Button {
                        isShowingChromiumInstallSheet = true
                    } label: {
                        Label("Check Chromium", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    // v0.21.47 — "Re-inject Picker" escape hatch (voice 4269).
                    //
                    // After the persistent-Chromium / extra-`about:` tab
                    // refactor in this build, the picker overlay should land
                    // on the right tab the first time. But Chromium has
                    // occasional flakes (slow page load behind a redirect,
                    // user clicked away mid-inject, etc.) where the overlay
                    // doesn't appear OR was dismissed accidentally. Rather
                    // than force the user to cancel + reopen the whole sheet,
                    // give them a one-tap "Re-inject Picker" that re-runs
                    // injectOverlay against the SAME tab the controller
                    // already chose — preserving the user's logged-in
                    // session + tab focus, just re-arming the overlay.
                    //
                    // This is distinct from "Try Again" (which tears down the
                    // CDP client and restarts the whole flow including target
                    // selection — slower, more disruptive). Re-inject is
                    // fast (one Runtime.evaluate) and is the right move when
                    // the user CAN see the target page but no overlay.
                    if controller.hasStarted && controller.canReinjectPicker {
                        Button("Re-inject Picker") {
                            controller.reinjectPicker()
                        }
                        .disabled(controller.isReinjectingPicker)
                    }
                    Button(controller.hasStarted ? "Try Again" : "Open Chrome and Identify") {
                        controller.start()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.isIdentifying)
                }
            }
        }
        .padding(22)
        .frame(width: 680)
        .frame(minHeight: 360)
        .onAppear {
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            if chromiumAvailable {
                controller.startIfNeeded()
            }
        }
        .onDisappear {
            controller.cancelIfActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            let nowAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            chromiumAvailable = nowAvailable
            if nowAvailable && !controller.hasStarted {
                controller.start()
            }
        }
        .sheet(isPresented: $isShowingChromiumInstallSheet) {
            ChromiumInstallSheet(onCompletion: {
                chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            })
        }
        .sheet(item: $controller.preview) { preview in
            ElementCapturePreviewSheet(
                preview: preview,
                onUse: {
                    controller.preview = nil
                    onElementCaptured(preview.pick)
                    dismiss()
                },
                onRetry: {
                    controller.preview = nil
                    controller.start()
                }
            )
        }
    }
}

private final class ChromeElementCaptureController: ObservableObject {
    let url: URL
    let renderMode: RenderMode

    @Published var isIdentifying = false
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var preview: ElementCapturePreview?
    @Published private(set) var hasStarted = false
    /// v0.21.47 — exposes whether the active coordinator is currently in
    /// the post-overlay-inject state (i.e. we have a live CDP client on
    /// the target tab and re-injecting is a meaningful operation). The
    /// "Re-inject Picker" button is hidden until this becomes true so we
    /// don't show a button that would no-op against a disconnected
    /// coordinator.
    @Published private(set) var canReinjectPicker = false
    /// v0.21.47 — set true while a re-inject is in flight so the button
    /// disables itself and prevents double-firing.
    @Published private(set) var isReinjectingPicker = false

    private var coordinator: ChromeIdentifyElementCoordinator?
    private var lastTargetID: String?

    init(url: URL, renderMode: RenderMode) {
        self.url = url
        self.renderMode = renderMode
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    func start() {
        coordinator?.cancel()
        coordinator = nil
        hasStarted = true
        isIdentifying = true
        notice = "Opening Chrome/CDP picker…"
        errorMessage = nil
        preview = nil
        // v0.21.47 — fresh start means no overlay is live yet; hide the
        // "Re-inject Picker" button until the coordinator confirms the
        // overlay was injected successfully.
        canReinjectPicker = false
        isReinjectingPicker = false

        let nextCoordinator = ChromeIdentifyElementCoordinator(
            renderMode: renderMode,
            onPreviewReady: { [weak self] preview in
                self?.coordinator = nil
                self?.isIdentifying = false
                self?.notice = nil
                self?.errorMessage = nil
                self?.preview = preview
                // Preview captured → overlay no longer live → hide re-inject.
                self?.canReinjectPicker = false
                self?.isReinjectingPicker = false
            },
            onError: { [weak self] message, isTerminal in
                self?.errorMessage = message
                if isTerminal {
                    self?.coordinator = nil
                    self?.isIdentifying = false
                    self?.notice = nil
                    // Terminal failure → CDP client gone → re-inject impossible.
                    self?.canReinjectPicker = false
                    self?.isReinjectingPicker = false
                } else {
                    self?.isIdentifying = true
                    // Non-terminal failAndRearm reinjects internally, so the
                    // re-inject button should remain available.
                    self?.isReinjectingPicker = false
                }
            },
            onNotice: { [weak self] message in
                self?.notice = message
            },
            onTargetSelected: { [weak self] targetID in
                self?.lastTargetID = targetID
            },
            // v0.21.47 — coordinator pings this once it successfully injects
            // the overlay so the UI knows the "Re-inject Picker" escape
            // hatch is meaningful.
            onOverlayReady: { [weak self] in
                self?.canReinjectPicker = true
                self?.isReinjectingPicker = false
            },
            onCancelled: { [weak self] in
                self?.coordinator = nil
                self?.isIdentifying = false
                self?.notice = "Identify Element canceled."
                self?.canReinjectPicker = false
                self?.isReinjectingPicker = false
            }
        )

        coordinator = nextCoordinator
        nextCoordinator.start(url: url, preferredTargetID: lastTargetID)
    }

    /// v0.21.47 — re-runs `injectOverlay` against the already-selected
    /// target without restarting the whole identify flow. Cheap (~1
    /// Runtime.evaluate roundtrip) and preserves the user's logged-in
    /// page state. No-op if the coordinator isn't in the right state
    /// (no CDP client / already completed / mid-validation).
    func reinjectPicker() {
        guard let coordinator else { return }
        isReinjectingPicker = true
        errorMessage = nil
        notice = "Re-injecting picker…"
        coordinator.reinjectOverlay()
    }

    func cancel() {
        coordinator?.cancel()
        coordinator = nil
        isIdentifying = false
        canReinjectPicker = false
        isReinjectingPicker = false
    }

    func cancelIfActive() {
        guard isIdentifying else { return }
        cancel()
    }
}

struct ElementCapturePreviewSheet: View {
    let preview: ElementCapturePreview
    let onUse: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Element captured — preview")
                .font(.title3.weight(.semibold))

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Extracted text")
                        .font(.headline)
                    ScrollView {
                        Text(preview.pick.text.isEmpty ? "No text captured." : preview.pick.text)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(width: 280, height: 180)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Snapshot")
                        .font(.headline)
                    Group {
                        if let snapshot = preview.snapshot {
                            Image(nsImage: snapshot)
                                .resizable()
                                .scaledToFit()
                        } else {
                            Text("Snapshot unavailable.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(width: 280, height: 180)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("CSS selector")
                    .font(.headline)
                TextField("Selector", text: .constant(preview.pick.selector))
                    .textFieldStyle(.roundedBorder)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Re-identify", action: onRetry)
                Button("Use Element", action: onUse)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

final class ChromeIdentifyElementCoordinator {
    private let renderMode: RenderMode
    private let onPreviewReady: (ElementCapturePreview) -> Void
    private let onError: (String, Bool) -> Void
    private let onNotice: (String) -> Void
    private let onTargetSelected: (String) -> Void
    // v0.21.47 — fired AFTER `injectOverlay` succeeds. Lets the UI flip
    // the "Re-inject Picker" button to enabled state — we never want to
    // show that button BEFORE the first successful inject (it would
    // be a no-op against a not-yet-connected CDP client).
    private let onOverlayReady: () -> Void
    private let onCancelled: () -> Void

    private var client: ChromeCDPClient?
    private var timeout: DispatchWorkItem?
    private var didComplete = false
    private var didInjectOverlay = false
    private var isValidatingPick = false
    /// Tracks whether the tab in use was created by THIS identify flow
    /// (vs. reused from an existing CDP target). Set in handleTarget /
    /// handleExistingTargetLookup so cleanupAndClose can REST-close the
    /// tab on terminal exit only when we know we created it. Reusing a
    /// tab and then closing it would defeat the point of preserving the
    /// user's logged-in session (Ethan voice 3775 — tab leak fix v0.21.6).
    private var didCreateNewTab = false
    private var currentTarget: ChromeBrowserTarget?
    private var currentConfiguration: ChromeBrowserLaunchConfiguration?

    init(
        renderMode: RenderMode,
        onPreviewReady: @escaping (ElementCapturePreview) -> Void,
        onError: @escaping (String, Bool) -> Void,
        onNotice: @escaping (String) -> Void,
        onTargetSelected: @escaping (String) -> Void,
        // v0.21.47 — defaults to no-op for any future caller that
        // doesn't care about the overlay-ready event.
        onOverlayReady: @escaping () -> Void = {},
        onCancelled: @escaping () -> Void
    ) {
        self.renderMode = renderMode
        self.onPreviewReady = onPreviewReady
        self.onError = onError
        self.onNotice = onNotice
        self.onTargetSelected = onTargetSelected
        self.onOverlayReady = onOverlayReady
        self.onCancelled = onCancelled
    }

    func start(url: URL, preferredTargetID: String? = nil) {
        armTimeout()
        ChromeBrowserProfile.shared.ensureLaunched(profileName: Tracker.defaultBrowserProfile, foreground: true) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleBrowserLaunch(result, url: url, preferredTargetID: preferredTargetID)
            }
        }
    }

    func cancel() {
        guard !didComplete else {
            return
        }

        didComplete = true
        timeout?.cancel()
        cleanupAndClose()
        onCancelled()
    }

    private func handleBrowserLaunch(
        _ result: Result<ChromeBrowserLaunchConfiguration, Error>,
        url: URL,
        preferredTargetID: String?
    ) {
        guard !didComplete else { return }

        switch result {
        case .success(let configuration):
            ChromeBrowserProfile.shared.bestExistingPageTarget(
                preferredTargetID: preferredTargetID,
                matching: url,
                configuration: configuration
            ) { [weak self] existingResult in
                DispatchQueue.main.async {
                    self?.handleExistingTargetLookup(existingResult, configuration: configuration, fallbackURL: url)
                }
            }
        case .failure(let error):
            finishWithError(error.localizedDescription)
        }
    }

    private func handleExistingTargetLookup(
        _ result: Result<ChromeBrowserTarget, Error>,
        configuration: ChromeBrowserLaunchConfiguration,
        fallbackURL: URL
    ) {
        guard !didComplete else { return }
        currentConfiguration = configuration

        switch result {
        case .success(let target):
            // Reused — DO NOT close on exit; preserves the user's
            // logged-in session.
            didCreateNewTab = false
            onNotice("Reusing the existing CDP browser tab so the logged-in profile/session is preserved.")
            handleTarget(.success(target))
        case .failure:
            // Created — flag for cleanup so we don't leak the
            // identify-launched tab once the user finishes (Ethan voice 3775).
            didCreateNewTab = true
            let safeURL = ChromeBrowserProfile.safeInitialURL(for: fallbackURL)
            ChromeBrowserProfile.shared.openTab(url: safeURL, configuration: configuration) { [weak self] result in
                DispatchQueue.main.async {
                    self?.handleTarget(result)
                }
            }
        }
    }

    private func handleTarget(_ result: Result<ChromeBrowserTarget, Error>) {
        guard !didComplete else { return }

        switch result {
        case .success(let target):
            currentTarget = target
            onTargetSelected(target.id)

            // v0.21.47 — fix for voice 4269 ("extra about: tab opens, picker
            // never appears"). Two things go wrong post-v0.21.46 without this:
            //
            //   1. When `ensureLaunched(foreground: true)` tore down the
            //      headless persistent-mode Chromium and spawned a fresh
            //      headed instance, the new Chromium boots with one tab on
            //      `about:blank` (from the trailing `["about:blank"]` arg in
            //      `buildChromeLaunchArguments` + launch). That tab stays
            //      FOREGROUND.
            //   2. `openTab` creates a NEW tab via /json/new for the target
            //      URL. Chromium does NOT auto-activate newly-created CDP
            //      tabs — the user-visible window keeps `about:blank` as the
            //      front tab, the target URL sits in the background, the
            //      picker overlay gets injected into the (correct) background
            //      tab but the user can't see it because they're looking at
            //      `about:blank`. Flow looks broken even though the CDP
            //      machinery is working.
            //
            // Fix: call `/json/activate/<id>` to bring the new target tab to
            // the front BEFORE we start injecting. The REST endpoint is
            // fire-and-forget and idempotent; Chromium 150 honors it instantly.
            // Pair this with a single same-cycle orphan sweep that closes the
            // stranded `about:blank` (and any other disposables) so the user
            // ends up with one window, one tab — the right one.
            if let configuration = currentConfiguration {
                ChromeBrowserProfile.shared.activateTarget(id: target.id, configuration: configuration)

                // Sweep about:blank / chrome://newtab/ orphans NOW (before
                // we wait for documentReady + inject) so the Chrome window
                // is visually clean by the time the user looks at it. We
                // pin the just-selected target via `keepTargetIDs` so the
                // sweep can NEVER nuke the tab we're about to inject into,
                // regardless of URL classification or maxKeep cap. We also
                // pin every in-flight scrape target to honor the v0.21.12
                // parallel-scrape race fix (a sweep firing here must not
                // race-kill a concurrent background scrape's page).
                let pinnedIDs = ChromeCDPScraper.activeScrapeTargetIDs().union([target.id])
                ChromeBrowserProfile.shared.closeOrphanPageTargets(
                    configuration: configuration,
                    keepURLs: [],
                    keepTargetIDs: pinnedIDs,
                    maxKeep: 8,
                    completion: nil
                )
            }

            let client = ChromeCDPClient(webSocketURL: target.webSocketDebuggerURL)
            self.client = client
            client.connect()
            client.prepareOpenClawStylePage { [weak self] in
                DispatchQueue.main.async {
                    // v0.21.47 belt-and-suspenders: also call Page.bringToFront
                    // on the CDP page websocket once domains are enabled. On
                    // some macOS / Chromium combinations the /json/activate/
                    // REST call queues the activation against the renderer
                    // process but doesn't reliably raise the window itself;
                    // Page.bringToFront sends a direct browser-level command
                    // through the same socket the overlay JS will land on,
                    // which Chromium-150 handles synchronously and is what
                    // actually moves the target tab forward in headed mode.
                    self?.bringTargetToFront()
                    self?.waitForDocumentReady(deadline: Date().addingTimeInterval(15))
                }
            }
        case .failure(let error):
            finishWithError(error.localizedDescription)
        }
    }

    /// v0.21.47 — issue a CDP `Page.bringToFront` so the foreground Chrome
    /// window actually focuses the newly-created target tab. Best-effort:
    /// fire-and-forget. If Chromium ignores or the websocket is gone, the
    /// `/json/activate/<id>` REST call issued upstream is the fallback.
    private func bringTargetToFront() {
        guard !didComplete, let client else { return }
        client.sendBringToFront()
    }

    private func waitForDocumentReady(deadline: Date) {
        guard !didComplete, let client else {
            finishWithError(ChromeCDPClientError.disconnected.localizedDescription)
            return
        }

        client.evaluate(Self.documentReadyScript) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleDocumentReady(result, deadline: deadline)
            }
        }
    }

    private func handleDocumentReady(_ result: Result<Any?, Error>, deadline: Date) {
        guard !didComplete else { return }

        if case .success(let value) = result,
           let status = SelectorExtractionJS.dictionary(from: value),
           SelectorExtractionJS.boolValue(status["ready"]) == true {
            injectOverlay()
            return
        }

        guard Date() < deadline else {
            finishWithError("The CDP browser page did not finish loading in time. Finish sign-in in Chrome, then try Identify in CDP Browser again.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitForDocumentReady(deadline: deadline)
        }
    }

    private func injectOverlay() {
        guard !didComplete, let client else {
            finishWithError(ChromeCDPClientError.disconnected.localizedDescription)
            return
        }

        client.evaluate(InspectOverlayJS.inspectOverlayJS, returnByValue: false) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleOverlayInjected(result)
            }
        }
    }

    private func handleOverlayInjected(_ result: Result<Any?, Error>) {
        guard !didComplete else { return }

        switch result {
        case .success:
            didInjectOverlay = true
            onNotice("Chrome/CDP Identify is active. In the Chrome window, hover an element, click to preview it, or press Esc to cancel.")
            // v0.21.47 — overlay is live; tell the UI it can offer the
            // "Re-inject Picker" button now. Safe to call multiple times
            // (e.g. after failAndRearm); the UI just keeps the button on.
            onOverlayReady()
            pollForPick(deadline: Date().addingTimeInterval(120))
        case .failure(let error):
            finishWithError("Identify Element could not start in the CDP browser: \(error.localizedDescription)")
        }
    }

    /// v0.21.47 — public escape hatch for the "Re-inject Picker" button.
    ///
    /// Reruns `injectOverlay` against the EXISTING target + CDP client. No
    /// new tab is created, no new target selection happens, no Chrome
    /// window is raised — just the JS overlay state is rebuilt on the
    /// page that's already loaded. The overlay JS itself is idempotent
    /// (`window.__statsWidgetInspectCleanup` is checked + called at the
    /// top before the new overlay installs), so re-injecting is safe even
    /// if the previous overlay was still partially live.
    ///
    /// No-op if:
    ///   - the coordinator already completed (`didComplete == true`)
    ///   - there's no CDP client (we haven't reached the inject step yet
    ///     or we crashed out of it terminally)
    ///   - validation is in flight (don't fight the validation roundtrip)
    func reinjectOverlay() {
        guard !didComplete else { return }
        guard client != nil else { return }
        guard !isValidatingPick else { return }
        // Reset the inject flag so handleOverlayInjected's onOverlayReady
        // ping is still meaningful on the second pass (some UIs key off
        // the rising edge).
        didInjectOverlay = false
        injectOverlay()
    }

    private func pollForPick(deadline: Date) {
        guard !didComplete, !isValidatingPick, let client else {
            if !didComplete {
                finishWithError(ChromeCDPClientError.disconnected.localizedDescription)
            }
            return
        }

        client.evaluate(Self.pollScript) { [weak self] result in
            DispatchQueue.main.async {
                self?.handlePoll(result, deadline: deadline)
            }
        }
    }

    private func handlePoll(_ result: Result<Any?, Error>, deadline: Date) {
        guard !didComplete else { return }

        switch result {
        case .success(let value):
            guard let state = SelectorExtractionJS.dictionary(from: value) else {
                finishWithError("The CDP Identify Element state was not readable.")
                return
            }

            if let picked = SelectorExtractionJS.dictionary(from: state["picked"]) {
                guard let pick = decodePick(from: picked) else {
                    failAndRearm("The selected element payload was not readable.")
                    return
                }
                validate(pick)
                return
            }

            if SelectorExtractionJS.boolValue(state["canceled"]) == true {
                finishCancelled()
                return
            }

            if let error = SelectorExtractionJS.dictionary(from: state["error"]),
               let message = error["message"] as? String,
               !message.isEmpty {
                failAndRearm(message)
                return
            }

            if didInjectOverlay, SelectorExtractionJS.boolValue(state["active"]) != true {
                finishWithError("The CDP page navigated or reloaded before an element was picked. Finish sign-in in Chrome, then try Identify in CDP Browser again.")
                return
            }
        case .failure(let error):
            guard Date() < deadline else {
                finishWithError(error.localizedDescription)
                return
            }
        }

        guard Date() < deadline else {
            finishWithError("Timed out waiting for an element pick in the CDP browser.")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pollForPick(deadline: deadline)
        }
    }

    private func validate(_ pick: ElementPick) {
        guard !didComplete, let client else {
            finishWithError(ChromeCDPClientError.disconnected.localizedDescription)
            return
        }

        let selector = pick.selector.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selector.isEmpty else {
            failAndRearm("The selected element did not produce a CSS selector.")
            return
        }

        isValidatingPick = true
        client.evaluate(SelectorExtractionJS.validationScript(for: selector)) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleValidationResult(result, originalPick: pick)
            }
        }
    }

    private func handleValidationResult(_ result: Result<Any?, Error>, originalPick: ElementPick) {
        guard !didComplete else { return }

        switch result {
        case .success(let value):
            guard let validation = SelectorExtractionJS.dictionary(from: value) else {
                failAndRearm("The selector validation result was not readable.")
                return
            }

            if let scriptError = validation["error"] as? String, !scriptError.isEmpty {
                failAndRearm("The selector is invalid: \(scriptError)")
                return
            }

            let matchCount = SelectorExtractionJS.intValue(validation["count"]) ?? 0
            guard matchCount == 1 else {
                failAndRearm("The selector matches \(matchCount) elements; choose a more specific element.")
                return
            }

            var finalPick = originalPick
            if let validatedText = validation["text"] as? String {
                finalPick.text = validatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let bbox = SelectorExtractionJS.elementBoundingBox(from: validation["bbox"]) {
                finalPick.bbox = bbox
            }

            switch renderMode {
            case .text:
                guard !finalPick.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failAndRearm("The selected element has no text to extract.")
                    return
                }
            case .snapshot:
                guard finalPick.bbox.width * finalPick.bbox.height > 0 else {
                    failAndRearm("The selected element has no visible area to snapshot.")
                    return
                }
            }

            isValidatingPick = false
            makePreview(for: finalPick)
        case .failure(let error):
            failAndRearm("The selector could not be validated: \(error.localizedDescription)")
        }
    }

    private func makePreview(for pick: ElementPick) {
        guard !didComplete, let client else {
            finishWithPreview(ElementCapturePreview(pick: pick, snapshot: nil))
            return
        }

        client.evaluate(Self.snapshotRectScript(for: pick.selector)) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleSnapshotRect(result, pick: pick)
            }
        }
    }

    private func handleSnapshotRect(_ result: Result<Any?, Error>, pick: ElementPick) {
        guard !didComplete, let client else {
            finishWithPreview(ElementCapturePreview(pick: pick, snapshot: nil))
            return
        }

        let rect: CGRect?
        switch result {
        case .success(let value):
            rect = SelectorExtractionJS.rect(from: value)
        case .failure:
            rect = nil
        }

        guard let rect, rect.width > 0, rect.height > 0 else {
            finishWithPreview(ElementCapturePreview(pick: pick, snapshot: nil))
            return
        }

        let clip: [String: Any] = [
            "x": max(0, rect.origin.x),
            "y": max(0, rect.origin.y),
            "width": max(1, rect.width),
            "height": max(1, rect.height),
            "scale": 1
        ]

        client.captureScreenshot(clip: clip) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    self?.finishWithPreview(ElementCapturePreview(pick: pick, snapshot: NSImage(data: data)))
                case .failure:
                    self?.finishWithPreview(ElementCapturePreview(pick: pick, snapshot: nil))
                }
            }
        }
    }

    private func failAndRearm(_ message: String) {
        guard !didComplete else { return }
        isValidatingPick = false
        didInjectOverlay = false
        onError(message, false)
        injectOverlay()
    }

    private func finishWithPreview(_ preview: ElementCapturePreview) {
        guard !didComplete else { return }
        didComplete = true
        timeout?.cancel()
        client?.close()
        // Close the tab on the success path too — when we created a new
        // tab for identify, the preview sheet already snapshotted what
        // the user needs and the tab serves no further purpose. Reused
        // tabs are NOT closed so the user's existing session stays intact
        // (Ethan voice 3775 tab-leak fix).
        closeCreatedTabIfNeeded()
        onPreviewReady(preview)
    }

    private func finishWithError(_ message: String) {
        guard !didComplete else { return }
        didComplete = true
        timeout?.cancel()
        cleanupAndClose()
        onError(message, true)
    }

    private func finishCancelled() {
        guard !didComplete else { return }
        didComplete = true
        timeout?.cancel()
        client?.close()
        closeCreatedTabIfNeeded()
        onCancelled()
    }

    private func cleanupAndClose() {
        if let client {
            client.evaluate("window.__statsWidgetInspectCleanup && window.__statsWidgetInspectCleanup();", returnByValue: false) { _ in
                client.close()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                client.close()
            }
        }
        closeCreatedTabIfNeeded()
    }

    /// REST-closes the page target we created in this identify flow, but
    /// only when `didCreateNewTab == true`. Reused tabs are never closed.
    /// Best-effort + idempotent (Chromium returns 404 for an already-
    /// closed target, which closeTarget() logs but treats as success).
    private func closeCreatedTabIfNeeded() {
        guard didCreateNewTab,
              let target = currentTarget,
              let configuration = currentConfiguration else {
            return
        }
        ChromeBrowserProfile.shared.closeTarget(id: target.id, configuration: configuration)
        // Belt-and-suspenders: schedule an orphan sweep on the same CDP
        // port so any side-effect tabs (OAuth redirect bounces, etc.)
        // that landed on about:blank get nuked too.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            // v0.21.12 race fix: pin in-flight scrape targets so this
            // Identify-flow teardown sweep cannot accidentally close a
            // background scraper's live tab. activeScrapeTargetIDs must be
            // read on main (it's gated by the same dispatch discipline as
            // activeScrapers).
            DispatchQueue.main.async {
                let pinnedIDs = ChromeCDPScraper.activeScrapeTargetIDs()
                ChromeBrowserProfile.shared.closeOrphanPageTargets(
                    configuration: configuration,
                    keepURLs: [],
                    keepTargetIDs: pinnedIDs,
                    maxKeep: 8,
                    completion: nil
                )
            }
        }
    }

    private func armTimeout() {
        let item = DispatchWorkItem { [weak self] in
            self?.finishWithError("Timed out waiting for an element pick in the CDP browser.")
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func decodePick(from dictionary: [String: Any]) -> ElementPick? {
        guard let selector = dictionary["selector"] as? String,
              let text = dictionary["text"] as? String,
              let bbox = SelectorExtractionJS.elementBoundingBox(from: dictionary["bbox"]) else {
            return nil
        }

        return ElementPick(selector: selector, text: text, bbox: bbox)
    }

    private static let documentReadyScript = """
    (() => {
      const readyState = String(document.readyState || '');
      return {
        ready: readyState === 'interactive' || readyState === 'complete',
        href: String(window.location && window.location.href || ''),
        title: String(document.title || '')
      };
    })()
    """

    private static let pollScript = """
    (() => ({
      picked: window.__statsWidgetPicked || null,
      error: window.__statsWidgetInspectError || null,
      canceled: !!window.__statsWidgetInspectCanceled,
      active: !!window.__statsWidgetInspectCleanup
    }))()
    """

    private static func snapshotRectScript(for selector: String) -> String {
        let selectorLiteral = javaScriptStringLiteral(selector)
        return """
        (() => {
          const element = document.querySelector(\(selectorLiteral));
          if (!element) {
            return null;
          }

          try {
            element.scrollIntoView({ block: 'center', inline: 'center', behavior: 'auto' });
          } catch (_) {
            try { element.scrollIntoView(false); } catch (_) {}
          }

          const rect = element.getBoundingClientRect();
          return {
            x: Math.max(0, rect.left + window.scrollX),
            y: Math.max(0, rect.top + window.scrollY),
            width: rect.width,
            height: rect.height,
            viewportWidth: window.innerWidth,
            viewportHeight: window.innerHeight,
            devicePixelRatio: window.devicePixelRatio || 1
          };
        })()
        """
    }

    private static func javaScriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }

        return literal
    }
}
