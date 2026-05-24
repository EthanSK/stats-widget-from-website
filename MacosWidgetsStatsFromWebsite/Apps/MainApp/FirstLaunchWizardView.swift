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
        .frame(width: 640)
        .frame(minHeight: 470)
        .sheet(item: $identifyBrowser) { presentation in
            ChromeElementCaptureView(url: presentation.url, renderMode: renderMode) { pick in
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
        }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            // User-facing welcome header — matches the renamed .app wrapper
            // "Stats Widget from Website.app" introduced in v0.21.22 (voice
            // 4002 / MBP-CC bridge msg-65036391). Internal product name in
            // build artefacts / log labels stays MacosWidgetsStatsFromWebsite.
            Text("Welcome to Stats Widget from Website")
                .font(.title2.weight(.semibold))
            Text(step.subtitle)
                .foregroundStyle(.secondary)
        }
    }

    private var urlStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Start with any website")
                    .font(.headline)
                Text("Paste the page you want to track. The app opens its persistent Chrome/Chromium profile when it is time to choose the exact value or region.")
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
                    Text("Examples: a usage dashboard, bank balance, weather page, status page, or any page with a value you care about.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Cookies stay in the app's local Chrome/Chromium profile. Nothing is sent to a third-party server.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            HStack {
                Button("Skip") {
                    skip()
                }
                Spacer()
                Button("Continue") {
                    continueWithURL()
                }
                .disabled(validatedCustomURL == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var captureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section {
                    LabeledContent("URL") {
                        Text(selectedURL?.absoluteString ?? "No URL selected")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    TextField("Tracker name", text: $trackerName)

                    Picker("Render mode", selection: $renderMode) {
                        ForEach(RenderMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("First widget layout", selection: $widgetTemplate) {
                        ForEach(availableWidgetTemplates, id: \.rawValue) { template in
                            Text("\(template.displayName) — \(template.size.displayName)").tag(template)
                        }
                    }

                    Text(widgetTemplateHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Tracker")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if !chromiumAvailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                // v0.21.22 rename: user-facing product name is "Stats Widget from Website".
                                Text("Identify needs the Chromium browser bundled inside this app. Reinstall Stats Widget from Website to restore it.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button {
                                    isShowingChromiumInstallSheet = true
                                } label: {
                                    Label("Check Chromium", systemImage: "arrow.clockwise.circle")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .padding(.bottom, 4)
                        }

                        Button {
                            openIdentifyBrowser()
                        } label: {
                            Label(capturedPick == nil ? "Open Chrome and Identify Element" : "Re-identify in Chrome", systemImage: "viewfinder")
                        }
                        .disabled(selectedURL == nil || !chromiumAvailable)

                        if let capturedPick {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Captured selector")
                                    .font(.caption.weight(.semibold))
                                Text(capturedPick.selector)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(2)
                                    .textSelection(.enabled)

                                Text(capturedPick.text.isEmpty ? "No text captured; snapshot mode can still use the selected region." : capturedPick.text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .textSelection(.enabled)

                                Text("Bounds: \(formattedBoundingBox(capturedPick.bbox))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        } else {
                            Text("Required before saving: Chrome opens with the app profile. Sign in or navigate if needed, hover the value or region, then click to preview and use it.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Capture")
                }

                Section {
                    HStack {
                        TextField("SF Symbol", text: $icon)
                        Image(systemName: icon.isEmpty ? Tracker.defaultIcon : icon)
                            .frame(width: 24)
                    }

                    ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                } header: {
                    Text("Presentation")
                }
            }
            .formStyle(.grouped)
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
                Button("Skip") {
                    skip()
                }
                Spacer()
                Button("Back") {
                    errorMessage = nil
                    step = .url
                }
                Button("Save Tracker") {
                    saveFirstTracker()
                }
                .disabled(!canSaveTracker)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var widgetStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let createdTracker {
                LabeledContent("Tracker") {
                    Text(createdTracker.name)
                        .textSelection(.enabled)
                }
            }

            if let createdWidgetConfiguration {
                LabeledContent("Widget configuration") {
                    Text("\(createdWidgetConfiguration.name) - \(createdWidgetConfiguration.templateID.displayName) - \(createdWidgetConfiguration.size.displayName)")
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Add it from the desktop widget picker:")
                    .font(.headline)
                Text("1. Right-click the desktop and choose Edit Widgets")
                // v0.21.22: instruct users to look up the renamed widget name in
                // the desktop widget picker. The system shows whatever the widget
                // extension's configurationDisplayName resolves to (see StatsWidget
                // + PlaceholderWidget — both renamed to "Stats Widget from Website").
                Text("2. Search for Stats Widget from Website")
                Text("3. Drag a \(createdWidgetConfiguration?.size.displayName.lowercased() ?? "small") widget onto the desktop")
                Text("4. Click/right-click the placed widget and choose Edit “Stats Widget from Website”")
                Text("5. Choose \"\(createdWidgetConfiguration?.name ?? "your new configuration")\" from the configuration picker")
                Text("   Desktop widgets require macOS 14 or later.")
            }
            .foregroundStyle(.secondary)

            Spacer(minLength: 16)

            HStack {
                Button("I'll do this later") {
                    finish()
                }
                Spacer()
                Button("Done") {
                    finish()
                }
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
            return "Enter and continue with a URL before saving."
        }

        if trimmedTrackerName.isEmpty {
            return "Name the tracker before saving."
        }

        if capturedPick == nil {
            return "Open Chrome and identify the value or region before saving the tracker."
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
        identifyBrowser = BrowserPresentation(url: url)
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
        tracker.browserProfile = Tracker.defaultBrowserProfile

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

    private func validatedURL(from string: String) -> URL? {
        guard !string.isEmpty else {
            return nil
        }

        let normalized = string.contains("://") ? string : "https://\(string)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }

        return url
    }

    private func defaultTrackerName(for url: URL) -> String {
        guard let host = url.host?.replacingOccurrences(of: "www.", with: ""), !host.isEmpty else {
            return "Website Tracker"
        }

        return "\(host) Tracker"
    }

    private func availableWidgetTemplates(for mode: RenderMode) -> [WidgetTemplate] {
        switch mode {
        case .text:
            return [.singleBigNumber, .numberPlusSparkline, .gaugeRing, .headlineSparkline, .heroPlusDetail]
        case .snapshot:
            return [.liveSnapshotTile, .liveSnapshotHero]
        }
    }

    private static func defaultWidgetTemplate(for mode: RenderMode) -> WidgetTemplate {
        switch mode {
        case .text:
            return .singleBigNumber
        case .snapshot:
            return .liveSnapshotTile
        }
    }

    private func formattedBoundingBox(_ bbox: ElementBoundingBox) -> String {
        let width = Int(round(bbox.width))
        let height = Int(round(bbox.height))
        let x = Int(round(bbox.x))
        let y = Int(round(bbox.y))
        return "\(width)x\(height) at \(x), \(y)"
    }
}

private enum Step {
    case url
    case capture
    case widget

    var subtitle: String {
        switch self {
        case .url:
            return "Step 1 of 3: enter the page you want to track."
        case .capture:
            return "Step 2 of 3: choose the render mode and capture the value or page region."
        case .widget:
            return "Step 3 of 3: add the first desktop widget."
        }
    }
}

private struct BrowserPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
