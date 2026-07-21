//
//  FirstLaunchWizardView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Skippable first-launch setup: enter a URL, identify an element, create first widget.
//

import SwiftUI

struct FirstLaunchWizardView: View {
    @EnvironmentObject private var store: AppGroupStore
    @Binding var isPresented: Bool

    @State private var step: Step = .url
    @State private var customURL = ""
    @State private var selectedURL: URL?
    @State private var selectedBrowserAccountID = Tracker.defaultBrowserProfile
    @State private var identifyBrowser: BrowserPresentation?

    @State private var trackerName = ""
    @State private var renderMode: RenderMode = .text
    @State private var widgetTemplate: WidgetTemplate = .singleBigNumber
    @State private var icon = Tracker.defaultIcon
    @State private var accentColor = Color(hexString: Tracker.defaultAccentColorHex) ?? .accentColor
    @State private var capturedPick: ElementPick?
    @State private var createdTracker: Tracker?
    @State private var createdWidgetConfiguration: WidgetConfiguration?
    @State private var errorMessage: String?
    @State private var chromiumAvailable: Bool = ChromeBrowserProfile.shared.chromiumIsAvailable()
    @State private var isShowingChromiumInstallSheet: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            switch step {
            case .url:
                urlStep
            case .capture:
                captureStep
            case .widget:
                widgetStep
            }
        }
        .padding(28)
        .frame(width: 660)
        .frame(minHeight: 540)
        .sheet(item: $identifyBrowser) { presentation in
            ChromeElementCaptureView(
                url: presentation.url,
                renderMode: renderMode,
                browserAccount: selectedBrowserAccount,
                contextLabel: presentation.contextLabel
            ) { pick in
                applyCapturedElement(pick)
            }
        }
        .sheet(isPresented: $isShowingChromiumInstallSheet) {
            ChromiumInstallSheet(onCompletion: {
                chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            })
        }
        .onAppear {
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            ensureSelectedBrowserAccount()
        }
        .onChange(of: store.browserAccounts) { _ in ensureSelectedBrowserAccount() }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            // User-facing welcome header — matches the renamed .app wrapper
            // "Stats Widget from Website.app" introduced in v0.21.22 (voice
            // 4002 / MBP-CC bridge msg-65036391). Internal product name in
            // build artefacts / log labels stays MacosWidgetsStatsFromWebsite.
            Text("Welcome to Stats Widget from Website")
                .font(.title2.weight(.semibold))

            HStack(spacing: 8) {
                ForEach(Step.allCases) { candidate in
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(candidate.index <= step.index ? Color.accentColor : Color.secondary.opacity(0.16))
                            if candidate.index < step.index {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(candidate.index + 1)")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(candidate.index <= step.index ? Color.white : Color.secondary)
                            }
                        }
                        .frame(width: 22, height: 22)

                        Text(candidate.shortTitle)
                            .font(.caption.weight(candidate == step ? .semibold : .regular))
                            .foregroundStyle(candidate == step ? Color.primary : Color.secondary)
                    }

                    if candidate != Step.allCases.last {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 1)
                    }
                }
            }

            Text(step.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var urlStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start with any website")
                    .font(.headline)
                Text("Paste the page where the number lives. Next, the app will open it and let you click exactly what you want to see.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("https://example.com/dashboard", text: $customURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        continueWithURL()
                    }

                if let urlValidationMessage {
                    Text(urlValidationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("Examples: a usage limit, account balance, follower count, queue size, or status page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Label("Your login stays on this Mac. The app does not send page data to a third-party server.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            HStack {
                Button("Not now") {
                    skip()
                }
                Spacer()
                Button("Choose a value") {
                    continueWithURL()
                }
                .disabled(validatedCustomURL == nil)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Page") {
                    Text(selectedURL?.absoluteString ?? "No page selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                LabeledContent("Name") {
                    TextField("What should this be called?", text: $trackerName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 330)
                }

                if store.browserAccounts.count > 1 {
                    LabeledContent("Website login") {
                        Picker("Website login", selection: $selectedBrowserAccountID) {
                            ForEach(store.browserAccounts) { account in
                                BrowserAccountLabel(account: account).tag(account.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 330)
                    }
                }

                LabeledContent("Show as") {
                    Picker("Show as", selection: $renderMode) {
                        Text("Number or text").tag(RenderMode.text)
                        Text("Picture of page area").tag(RenderMode.snapshot)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 330)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )

            VStack(alignment: .leading, spacing: 12) {
                Text("Choose what you want to see")
                    .font(.headline)

                if !chromiumAvailable {
                    Label("The app's browser is missing. Reinstall Stats Widget from Website to restore it.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Check Browser") { isShowingChromiumInstallSheet = true }
                }

                Button {
                    openIdentifyBrowser()
                } label: {
                    Label(capturedPick == nil ? "Open Browser and Choose Value" : "Choose a Different Value", systemImage: "viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURL == nil || !chromiumAvailable)

                if let capturedPick {
                    Label("Value selected", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)

                    Text(capturedPick.text.isEmpty ? "The selected page area is ready." : "Preview: \(capturedPick.text)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else {
                    Text("The browser will explain what to do. Sign in if needed, hover over the number, then click it and confirm the preview.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.075))
            )
            .onChange(of: renderMode) { newMode in
                if !availableWidgetTemplates(for: newMode).contains(widgetTemplate) {
                    widgetTemplate = Self.defaultWidgetTemplate(for: newMode)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let saveReadinessMessage {
                Text(saveReadinessMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            HStack {
                Button("Back") {
                    errorMessage = nil
                    step = .url
                }
                Spacer()
                Button("Create My Widget") {
                    saveFirstTracker()
                }
                .disabled(!canSaveTracker)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var widgetStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your first value is ready")
                        .font(.title2.weight(.semibold))
                    Text("\(createdTracker?.name ?? "Your value") will refresh automatically in the background.")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Text("One last step: add it to your desktop")
                    .font(.headline)
                Text("The app has already prepared the widget. macOS controls where it appears.")
                    .foregroundStyle(.secondary)
            }

            DesktopWidgetInstructionsView(configurationName: createdWidgetConfiguration?.name)

            Text("Desktop widgets require macOS 14 or later.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            HStack {
                Spacer()
                Button("Finish") {
                    finish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var trimmedCustomURL: String {
        customURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedTrackerName: String {
        trackerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedCustomURL: URL? {
        validatedURL(from: trimmedCustomURL)
    }

    private var urlValidationMessage: String? {
        guard !trimmedCustomURL.isEmpty, validatedCustomURL == nil else {
            return nil
        }

        return "Enter a valid http or https URL. You can omit https:// for normal domains."
    }

    private var availableWidgetTemplates: [WidgetTemplate] {
        availableWidgetTemplates(for: renderMode)
    }

    private var widgetTemplateHelp: String {
        "Creates a \(widgetTemplate.size.displayName.lowercased()) widget using \(widgetTemplate.displayName). These first-widget choices are the one-tracker layouts; you can build multi-stat widgets later in Preferences."
    }

    private var saveReadinessMessage: String? {
        if selectedURL == nil {
            return "Enter the webpage before continuing."
        }

        if trimmedTrackerName.isEmpty {
            return "Give this value a name before continuing."
        }

        if capturedPick == nil {
            return "Open the browser and choose the value before creating the widget."
        }

        return nil
    }

    private var canSaveTracker: Bool {
        saveReadinessMessage == nil
    }

    private func continueWithURL() {
        guard let url = validatedCustomURL else {
            return
        }

        let previousDefaultName = selectedURL.map(defaultTrackerName(for:))
        if selectedURL != url {
            capturedPick = nil
        }

        selectedURL = url
        customURL = url.absoluteString
        errorMessage = nil

        if trimmedTrackerName.isEmpty || previousDefaultName == trackerName {
            trackerName = defaultTrackerName(for: url)
        }

        step = .capture
    }

    private func openIdentifyBrowser() {
        guard let url = selectedURL else {
            errorMessage = "Enter a URL before identifying an element."
            step = .url
            return
        }

        errorMessage = nil
        identifyBrowser = BrowserPresentation(
            url: url,
            contextLabel: trimmedTrackerName.nilIfEmpty ?? defaultTrackerName(for: url)
        )
    }

    private func applyCapturedElement(_ pick: ElementPick) {
        capturedPick = pick
        errorMessage = nil
    }

    private func saveFirstTracker() {
        guard let url = selectedURL else {
            errorMessage = "Enter a URL before saving."
            step = .url
            return
        }

        guard !trimmedTrackerName.isEmpty else {
            errorMessage = "Name the tracker before saving."
            return
        }

        guard let capturedPick else {
            errorMessage = "Identify an element before saving the tracker."
            return
        }

        var tracker = Tracker(
            name: trimmedTrackerName,
            url: url.absoluteString,
            renderMode: renderMode,
            selector: capturedPick.selector,
            elementBoundingBox: capturedPick.bbox,
            label: nil,
            icon: icon.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Tracker.defaultIcon,
            accentColorHex: accentColor.hexString ?? Tracker.defaultAccentColorHex
        )
        tracker.browserProfile = selectedBrowserAccount.id

        let widgetConfiguration = WidgetConfiguration(
            name: "\(tracker.name) Widget",
            templateID: widgetTemplate,
            size: widgetTemplate.size,
            layout: widgetTemplate.defaultLayout,
            trackerIDs: [tracker.id]
        )

        store.addTracker(tracker)
        store.addWidgetConfiguration(widgetConfiguration)
        store.persist()
        createdTracker = tracker
        createdWidgetConfiguration = widgetConfiguration
        step = .widget
    }

    private func skip() {
        store.persist()
        isPresented = false
    }

    private func finish() {
        store.persist()
        isPresented = false
    }

    private var selectedBrowserAccount: BrowserAccount {
        store.browserAccounts.first(where: { $0.id == selectedBrowserAccountID })
            ?? store.browserAccounts.first
            ?? .defaultAccount
    }

    private func ensureSelectedBrowserAccount() {
        guard store.browserAccounts.contains(where: { $0.id == selectedBrowserAccountID }) else {
            selectedBrowserAccountID = store.browserAccounts.first?.id ?? Tracker.defaultBrowserProfile
            return
        }
    }

    private func validatedURL(from string: String) -> URL? {
        TrackerURLValidator.httpOrHTTPSURL(from: string)
    }

    private func defaultTrackerName(for url: URL) -> String {
        guard let host = url.host?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty else {
            return "Website value"
        }

        return host
    }

    /// v0.21.41 — collapsed to a single-element list. The previous
    /// switch returned 5 text templates / 2 snapshot templates; with
    /// only `.singleBigNumber` surviving, every render mode picks the
    /// same template.
    private func availableWidgetTemplates(for mode: RenderMode) -> [WidgetTemplate] {
        _ = mode
        return [.singleBigNumber]
    }

    /// v0.21.41 — always single-big-number. See `availableWidgetTemplates`.
    private static func defaultWidgetTemplate(for mode: RenderMode) -> WidgetTemplate {
        _ = mode
        return .singleBigNumber
    }

}

private enum Step: Int, CaseIterable, Identifiable {
    case url
    case capture
    case widget

    var id: Int { rawValue }
    var index: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .url: return "Webpage"
        case .capture: return "Choose value"
        case .widget: return "Desktop"
        }
    }

    var subtitle: String {
        switch self {
        case .url:
            return "First, tell us where the number lives."
        case .capture:
            return "Now choose exactly what should appear in the widget."
        case .widget:
            return "Your value is ready. Add it to the Mac desktop."
        }
    }
}

private struct BrowserPresentation: Identifiable {
    let id = UUID()
    let url: URL
    let contextLabel: String?
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
