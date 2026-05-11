//
//  TrackerEditorView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Add/edit tracker form.
//

import AppKit
import SwiftUI

struct TrackerEditorView: View {
    enum Mode {
        case add
        case edit
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: Tracker
    @State private var labelText: String
    @State private var accentColor: Color
    @State private var browserPresentation: IdentifyBrowserPresentation?
    @State private var capturedText: String
    @State private var chromiumAvailable: Bool = ChromeBrowserProfile.shared.chromiumIsAvailable()
    @State private var isShowingChromiumInstallSheet: Bool = false

    let mode: Mode
    let onSave: (Tracker) -> Void

    init(mode: Mode, tracker: Tracker, onSave: @escaping (Tracker) -> Void) {
        self.mode = mode
        self.onSave = onSave
        _draft = State(initialValue: tracker)
        _labelText = State(initialValue: tracker.label ?? "")
        _accentColor = State(initialValue: Color(hexString: tracker.accentColorHex) ?? Color(hexString: Tracker.defaultAccentColorHex) ?? .accentColor)
        _capturedText = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("URL", text: $draft.url)
                        if !urlValidationMessage.isEmpty {
                            Text(urlValidationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    Picker("Render mode", selection: $draft.renderMode) {
                        ForEach(RenderMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Stepper(value: $draft.refreshIntervalSec, in: refreshIntervalRange, step: refreshIntervalStep) {
                        Text("Refresh interval: \(formattedRefreshInterval)")
                    }
                } header: {
                    Text("Tracker")
                }

                Section {
                    TextField("Label", text: $labelText)

                    HStack {
                        TextField("SF Symbol", text: $draft.icon)
                        Image(systemName: draft.icon.isEmpty ? Tracker.defaultIcon : draft.icon)
                            .frame(width: 24)
                    }

                    ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                } header: {
                    Text("Presentation")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if !chromiumAvailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                Text("Identify needs the Chromium browser bundled inside this app. Reinstall macOS Widgets Stats from Website to restore the missing browser bundle.")
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

                        HStack(spacing: 8) {
                            TextField("No element captured", text: readOnlySelectorBinding)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)

                            Button {
                                openIdentifyBrowser()
                            } label: {
                                Label(draft.selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Identify in Chrome" : "Re-identify in Chrome", systemImage: "viewfinder")
                            }
                            .disabled(validatedURL == nil || !chromiumAvailable)
                        }

                        if !captureValidationMessage.isEmpty {
                            Text(captureValidationMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if !capturedText.isEmpty {
                            Text(capturedText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }

                        if let bbox = draft.elementBoundingBox {
                            Text("Bounds: \(formattedBoundingBox(bbox))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Capture")
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .navigationTitle(mode == .add ? "Add Tracker" : "Edit Tracker")
        .onChange(of: draft.renderMode) { newMode in
            draft.refreshIntervalSec = newMode.defaultRefreshIntervalSec
        }
        .sheet(item: $browserPresentation) { presentation in
            ChromeElementCaptureView(url: presentation.url, renderMode: draft.renderMode) { pick in
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

    private var canSave: Bool {
        !trimmedName.isEmpty && validatedURL != nil && !trimmedSelector.isEmpty && draft.elementBoundingBox != nil
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedURL: String {
        draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSelector: String {
        draft.selector.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validatedURL: URL? {
        guard !trimmedURL.isEmpty else {
            return nil
        }

        let normalized = trimmedURL.contains("://") ? trimmedURL : "https://\(trimmedURL)"
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              let url = components.url else {
            return nil
        }

        return url
    }

    private var urlValidationMessage: String {
        guard !trimmedURL.isEmpty, validatedURL == nil else {
            return ""
        }

        return "Enter a valid http or https URL. You can omit https:// for normal domains."
    }

    private var captureValidationMessage: String {
        if validatedURL == nil {
            return "Enter a valid URL before opening Chrome to identify an element."
        }

        if trimmedSelector.isEmpty {
            return "Use Identify in Chrome to capture a CSS selector before saving."
        }

        if draft.elementBoundingBox == nil {
            return "Re-identify the element to capture its bounds."
        }

        return ""
    }

    private var readOnlySelectorBinding: Binding<String> {
        Binding(
            get: { draft.selector },
            set: { _ in }
        )
    }

    private var refreshIntervalRange: ClosedRange<Int> {
        switch draft.renderMode {
        case .text:
            return 60...86_400
        case .snapshot:
            return 1...60
        }
    }

    private var refreshIntervalStep: Int {
        draft.renderMode == .text ? 60 : 1
    }

    private var formattedRefreshInterval: String {
        if draft.refreshIntervalSec < 60 {
            return "\(draft.refreshIntervalSec) sec"
        }

        let minutes = draft.refreshIntervalSec / 60
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private func save() {
        guard let url = validatedURL else {
            return
        }

        var savedTracker = draft
        savedTracker.name = trimmedName
        savedTracker.url = url.absoluteString
        savedTracker.label = labelText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        savedTracker.icon = savedTracker.icon.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? Tracker.defaultIcon
        savedTracker.accentColorHex = accentColor.hexString ?? Tracker.defaultAccentColorHex
        savedTracker.browserProfile = Tracker.defaultBrowserProfile
        savedTracker.selector = trimmedSelector
        onSave(savedTracker)
        dismiss()
    }

    private func openIdentifyBrowser() {
        guard let url = validatedURL else {
            return
        }

        browserPresentation = IdentifyBrowserPresentation(url: url)
    }

    private func applyCapturedElement(_ pick: ElementPick) {
        draft.selector = pick.selector
        draft.elementBoundingBox = pick.bbox
        capturedText = pick.text
    }

    private func formattedBoundingBox(_ bbox: ElementBoundingBox) -> String {
        let width = Int(round(bbox.width))
        let height = Int(round(bbox.height))
        let x = Int(round(bbox.x))
        let y = Int(round(bbox.y))
        return "\(width)x\(height) at \(x), \(y)"
    }
}

private struct IdentifyBrowserPresentation: Identifiable {
    let id = UUID()
    let url: URL
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension Color {
    init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }

        guard value.count == 6, let hex = Int(value, radix: 16) else {
            return nil
        }

        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    var hexString: String? {
        let color = NSColor(self)
        guard let rgbColor = color.usingColorSpace(.sRGB) else {
            return nil
        }

        let red = Int(round(rgbColor.redComponent * 255))
        let green = Int(round(rgbColor.greenComponent * 255))
        let blue = Int(round(rgbColor.blueComponent * 255))
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
