//
//  InAppBrowserView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Legacy embedded browser host. New user-facing capture flows use Chrome/CDP.
//

import AppKit
import SwiftUI
import WebKit

struct InAppBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: InAppBrowserController

    private let allowsElementIdentification: Bool
    private let onElementCaptured: ((ElementPick) -> Void)?

    init(
        initialURL: URL? = nil,
        renderMode: RenderMode = .text,
        allowsElementIdentification: Bool = true,
        onElementCaptured: ((ElementPick) -> Void)? = nil
    ) {
        _controller = StateObject(wrappedValue: InAppBrowserController(initialURL: initialURL, renderMode: renderMode))
        self.allowsElementIdentification = allowsElementIdentification
        self.onElementCaptured = onElementCaptured
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let inlineError = controller.inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            if let inlineNotice = controller.inlineNotice {
                Text(inlineNotice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }
            Divider()
            WebViewHost(webView: controller.webView)
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(item: $controller.preview) { preview in
            ElementCapturePreviewSheet(
                preview: preview,
                onUse: {
                    controller.preview = nil
                    onElementCaptured?(preview.pick)
                    dismiss()
                },
                onRetry: {
                    controller.preview = nil
                    controller.startIdentifying()
                }
            )
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                controller.goBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!controller.canGoBack)
            .help("Back")

            Button {
                controller.goForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!controller.canGoForward)
            .help("Forward")

            Button {
                controller.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            TextField("https://example.com", text: $controller.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    controller.loadURLFromBar()
                }

            Button {
                controller.loadURLFromBar()
            } label: {
                Image(systemName: "arrow.right")
            }
            .help("Go")

            Button {
                controller.openCurrentURLInProfileBrowser()
            } label: {
                Label("Open CDP Browser", systemImage: "globe")
            }
            .disabled(controller.currentURLForExternalOpen == nil)
            .help("Open the current page in the app's persistent Chrome/Chromium CDP profile")

            if allowsElementIdentification {
                Button {
                    if controller.isIdentifying {
                        controller.cancelIdentifying()
                    } else {
                        controller.startIdentifying()
                    }
                } label: {
                    Label(
                        controller.isIdentifying ? "Cancel Identify" : "Identify Element",
                        systemImage: controller.isIdentifying ? "xmark.circle" : "viewfinder"
                    )
                }
                .help(controller.isIdentifying ? "Cancel Identify Element" : "Identify Element")

                Button {
                    controller.startIdentifyingInProfileBrowser()
                } label: {
                    Label("Identify in CDP Browser", systemImage: "globe")
                }
                .disabled(controller.currentURLForExternalOpen == nil || controller.isIdentifying)
                .help("Open the current page in the app's persistent Chrome/Chromium CDP profile and pick an element there")
            }
        }
        .padding(8)
    }
}

private final class InAppBrowserController: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView

    @Published var urlText: String
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var isIdentifying = false
    @Published var inlineError: String?
    @Published var inlineNotice: String?
    @Published var preview: ElementCapturePreview?

    var currentURLForExternalOpen: URL? {
        webView.url ?? URL(string: urlText)
    }

    private enum IdentifyMode {
        case webView
        case chromeCDP
    }

    private let renderMode: RenderMode
    private let userContentController: WKUserContentController
    private let identifyCoordinator: IdentifyElementCoordinator
    private var chromeIdentifyCoordinator: ChromeIdentifyElementCoordinator?
    private var activeIdentifyMode: IdentifyMode?
    private var lastProfileBrowserTargetID: String?
    private var observations: [NSKeyValueObservation] = []

    init(initialURL: URL?, renderMode: RenderMode) {
        self.renderMode = renderMode
        urlText = initialURL?.absoluteString ?? ""
        userContentController = WKUserContentController()
        identifyCoordinator = IdentifyElementCoordinator(
            renderMode: renderMode,
            onPreviewReady: { _ in },
            onError: { _ in }
        )

        userContentController.add(identifyCoordinator, name: "elementPicked")
        userContentController.add(identifyCoordinator, name: "inspectError")
        userContentController.add(identifyCoordinator, name: "inspectCanceled")
        webView = WebViewProfile.shared.makeWebView(frame: .zero, userContentController: userContentController)

        super.init()

        identifyCoordinator.webView = webView
        identifyCoordinator.renderMode = renderMode
        identifyCoordinator.setCallbacks(
            onPreviewReady: { [weak self] preview in
                self?.isIdentifying = false
                self?.activeIdentifyMode = nil
                self?.inlineError = nil
                self?.inlineNotice = nil
                self?.preview = preview
            },
            onError: { [weak self] message in
                self?.inlineError = message
                self?.isIdentifying = true
                self?.activeIdentifyMode = .webView
            },
            onCancelled: { [weak self] in
                self?.isIdentifying = false
                self?.activeIdentifyMode = nil
                self?.inlineError = nil
                self?.inlineNotice = "Identify Element canceled."
            }
        )

        webView.navigationDelegate = self
        webView.uiDelegate = self
        installObservers()

        if let initialURL {
            load(initialURL)
        }
    }

    deinit {
        chromeIdentifyCoordinator?.cancel()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        userContentController.removeScriptMessageHandler(forName: "elementPicked")
        userContentController.removeScriptMessageHandler(forName: "inspectError")
        userContentController.removeScriptMessageHandler(forName: "inspectCanceled")
    }

    func goBack() {
        webView.goBack()
    }

    func goForward() {
        webView.goForward()
    }

    func reload() {
        if webView.url == nil {
            loadURLFromBar()
        } else {
            webView.reload()
        }
    }

    func loadURLFromBar() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inlineError = "Enter a URL to load."
            return
        }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            inlineError = "Enter a valid http or https URL."
            return
        }

        load(url)
    }

    func load(_ url: URL) {
        inlineError = nil
        inlineNotice = nil
        urlText = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func openCurrentURLInProfileBrowser() {
        guard let url = currentURLForExternalOpen else {
            inlineError = "Load a page before opening it in the CDP browser."
            return
        }

        openProfileBrowser(url)
    }

    func startIdentifying() {
        guard webView.url != nil else {
            inlineError = "Load a page before identifying an element."
            return
        }

        if isIdentifying {
            cancelIdentifying()
        }

        inlineError = nil
        inlineNotice = "Hover an element, click to preview it, or press Esc to cancel."
        preview = nil
        isIdentifying = true
        activeIdentifyMode = .webView
        webView.evaluateJavaScript(InspectOverlayJS.inspectOverlayJS) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let error else {
                    return
                }
                self?.isIdentifying = false
                self?.activeIdentifyMode = nil
                self?.inlineError = "Identify Element could not start: \(error.localizedDescription)"
            }
        }
    }

    func startIdentifyingInProfileBrowser() {
        guard let url = currentURLForExternalOpen else {
            inlineError = "Load a page before identifying an element in the CDP browser."
            return
        }

        if isIdentifying {
            cancelIdentifying()
        }

        inlineError = nil
        inlineNotice = "Opening the CDP browser for element picking…"
        preview = nil
        isIdentifying = true
        activeIdentifyMode = .chromeCDP

        let coordinator = ChromeIdentifyElementCoordinator(
            renderMode: renderMode,
            onPreviewReady: { [weak self] preview in
                self?.chromeIdentifyCoordinator = nil
                self?.activeIdentifyMode = nil
                self?.isIdentifying = false
                self?.inlineError = nil
                self?.inlineNotice = nil
                self?.preview = preview
            },
            onError: { [weak self] message, isTerminal in
                self?.inlineError = message
                if isTerminal {
                    self?.chromeIdentifyCoordinator = nil
                    self?.activeIdentifyMode = nil
                    self?.isIdentifying = false
                } else {
                    self?.isIdentifying = true
                    self?.activeIdentifyMode = .chromeCDP
                }
            },
            onNotice: { [weak self] message in
                self?.inlineNotice = message
            },
            onTargetSelected: { [weak self] targetID in
                self?.lastProfileBrowserTargetID = targetID
            },
            onCancelled: { [weak self] in
                self?.chromeIdentifyCoordinator = nil
                self?.activeIdentifyMode = nil
                self?.isIdentifying = false
                self?.inlineError = nil
                self?.inlineNotice = "Identify Element canceled."
            }
        )
        chromeIdentifyCoordinator = coordinator
        coordinator.start(url: url, preferredTargetID: lastProfileBrowserTargetID)
    }

    func cancelIdentifying() {
        let mode = activeIdentifyMode
        isIdentifying = false
        activeIdentifyMode = nil
        inlineError = nil
        inlineNotice = "Identify Element canceled."

        if mode == .chromeCDP {
            let coordinator = chromeIdentifyCoordinator
            chromeIdentifyCoordinator = nil
            coordinator?.cancel()
            return
        }

        webView.evaluateJavaScript("window.__statsWidgetInspectCleanup && window.__statsWidgetInspectCleanup();", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let wasWebViewIdentifying = activeIdentifyMode == .webView && isIdentifying
        isLoading = true
        if wasWebViewIdentifying {
            isIdentifying = false
            activeIdentifyMode = nil
            inlineNotice = nil
        }
        inlineError = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        if let url = webView.url {
            urlText = url.absoluteString
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        guard !isBenignNavigationCancellation(error) else {
            return
        }
        inlineError = browserErrorMessage(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        guard !isBenignNavigationCancellation(error) else {
            return
        }
        inlineError = browserErrorMessage(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        inlineError = "The web content process quit unexpectedly. Reloading the page…"
        webView.reload()
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "data", "blob"].contains(scheme) {
            openExternalURL(url)
            decisionHandler(.cancel)
            return
        }

        if Self.shouldDeflectGoogleOAuthConsent(navigationAction: navigationAction, url: url) {
            deflectGoogleOAuthConsent(url)
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
            decisionHandler(.cancel)
            return
        }

        decisionHandler(.allow)
    }

    // Google's OAuth consent step can stall indefinitely in WKWebView after
    // email/password/2FA succeeds. Punt that known-broken consent/picker route
    // to the same persistent Chrome/Chromium CDP profile used by scrapes.
    private static func shouldDeflectGoogleOAuthConsent(navigationAction: WKNavigationAction, url: URL) -> Bool {
        guard isGoogleOAuthConsentURL(url) else { return false }
        guard let targetFrame = navigationAction.targetFrame else { return true }
        return targetFrame.isMainFrame
    }

    private static func isGoogleOAuthConsentURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let isAccountsGoogleHost = host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
        guard isAccountsGoogleHost else { return false }

        let path = url.path
        return path.hasPrefix("/signin/oauth/consent")
            || path.hasPrefix("/o/oauth2/auth/oauthchooseaccount")
            || path.hasSuffix("/oauthchooseaccount")
    }

    private func deflectGoogleOAuthConsent(_ url: URL) {
        let notice = "Google sign-in was opened in the app's persistent CDP browser because the embedded WebKit browser can stall on Google's OAuth consent step. Finish the sign-in there, then return here."
        inlineNotice = notice
        openProfileBrowser(
            url,
            successNotice: notice,
            failurePrefix: "Google sign-in needs the CDP browser, but opening it failed"
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isGoogleOAuthConsentURL(url) {
            deflectGoogleOAuthConsent(url)
            return nil
        }

        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website message"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website confirmation"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Website prompt"
        alert.informativeText = prompt
        let textField = NSTextField(string: defaultText ?? "")
        textField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = textField
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil)
    }

    private func openExternalURL(_ url: URL) {
        guard ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_SUPPRESS_EXTERNAL_BROWSER_OPEN"] != "1" else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    private func openProfileBrowser(_ url: URL, successNotice: String? = nil, failurePrefix: String? = nil) {
        guard ProcessInfo.processInfo.environment["MACOS_WIDGETS_STATS_SUPPRESS_EXTERNAL_BROWSER_OPEN"] != "1" else {
            return
        }

        ChromeBrowserProfile.shared.openVisibleBrowserTarget(url: ChromeBrowserProfile.safeInitialURL(for: url)) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success(let target):
                    if let target {
                        self?.lastProfileBrowserTargetID = target.id
                    }
                    self?.inlineError = nil
                    self?.inlineNotice = successNotice ?? "Opened in the app's persistent Chrome/Chromium CDP browser profile."
                case .failure(let error):
                    if let failurePrefix {
                        self?.inlineError = "\(failurePrefix): \(error.localizedDescription)"
                    } else {
                        self?.inlineError = error.localizedDescription
                    }
                }
            }
        }
    }

    private func browserErrorMessage(_ error: Error) -> String {
        "Page load failed: \(error.localizedDescription)"
    }

    private func isBenignNavigationCancellation(_ error: Error) -> Bool {
        let nsError = error as NSError
        // NSURLErrorCancelled (-999): we canceled the navigation ourselves, or the
        // user clicked away mid-load. Not a real failure.
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        // WebKitErrorDomain code 102 == WKErrorFrameLoadInterrupted: fired when
        // a navigation is interrupted (e.g. by another navigation, or by us calling
        // decisionHandler(.cancel)). Not a user-facing error.
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 {
            return true
        }
        return false
    }

    private func installObservers() {
        observations = [
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.canGoBack = webView.canGoBack
                }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.canGoForward = webView.canGoForward
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] webView, _ in
                self?.publishOnMain {
                    self?.isLoading = webView.isLoading
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                guard let url = webView.url else {
                    return
                }
                self?.publishOnMain {
                    self?.urlText = url.absoluteString
                }
            }
        ]
    }

    private func publishOnMain(_ update: @escaping () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
    private let onCancelled: () -> Void

    private var client: ChromeCDPClient?
    private var timeout: DispatchWorkItem?
    private var didComplete = false
    private var didInjectOverlay = false
    private var isValidatingPick = false

    init(
        renderMode: RenderMode,
        onPreviewReady: @escaping (ElementCapturePreview) -> Void,
        onError: @escaping (String, Bool) -> Void,
        onNotice: @escaping (String) -> Void,
        onTargetSelected: @escaping (String) -> Void,
        onCancelled: @escaping () -> Void
    ) {
        self.renderMode = renderMode
        self.onPreviewReady = onPreviewReady
        self.onError = onError
        self.onNotice = onNotice
        self.onTargetSelected = onTargetSelected
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

        switch result {
        case .success(let target):
            onNotice("Reusing the existing CDP browser tab so the logged-in profile/session is preserved.")
            handleTarget(.success(target))
        case .failure:
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
            onTargetSelected(target.id)
            let client = ChromeCDPClient(webSocketURL: target.webSocketDebuggerURL)
            self.client = client
            client.connect()
            client.prepareOpenClawStylePage { [weak self] in
                DispatchQueue.main.async {
                    self?.waitForDocumentReady(deadline: Date().addingTimeInterval(15))
                }
            }
        case .failure(let error):
            finishWithError(error.localizedDescription)
        }
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
            pollForPick(deadline: Date().addingTimeInterval(120))
        case .failure(let error):
            finishWithError("Identify Element could not start in the CDP browser: \(error.localizedDescription)")
        }
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
        onCancelled()
    }

    private func cleanupAndClose() {
        guard let client else { return }
        client.evaluate("window.__statsWidgetInspectCleanup && window.__statsWidgetInspectCleanup();", returnByValue: false) { _ in
            client.close()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            client.close()
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
