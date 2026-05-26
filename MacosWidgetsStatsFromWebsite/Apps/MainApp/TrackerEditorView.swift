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
    @State private var previewState: PreviewState = .idle
    @State private var previewSelector: String = ""
    @State private var refreshIntervalUnit: RefreshIntervalUnit = .minutes
    /// v0.21.9: which element the active Identify-in-Chrome flow is
    /// capturing for. `.primary` → the existing top-level fields; `.secondary(id)`
    /// → append/update a secondary element. Set right before `browserPresentation`
    /// fires; consulted by `applyCapturedElement(_:)` once Chrome returns a pick.
    @State private var identifyTarget: IdentifyTarget = .primary

    let mode: Mode
    let autoStartIdentify: Bool
    let onSave: (Tracker) -> Void

    init(
        mode: Mode,
        tracker: Tracker,
        autoStartIdentify: Bool = false,
        onSave: @escaping (Tracker) -> Void
    ) {
        self.mode = mode
        self.autoStartIdentify = autoStartIdentify
        self.onSave = onSave
        _draft = State(initialValue: tracker)
        _labelText = State(initialValue: tracker.label ?? "")
        _accentColor = State(initialValue: Color(hexString: tracker.accentColorHex) ?? Color(hexString: Tracker.defaultAccentColorHex) ?? .accentColor)
        _capturedText = State(initialValue: "")
    }

    private enum PreviewState {
        case idle
        case loading
        case success(value: String, numeric: Double?, fetchedAt: Date)
        case failure(message: String, fetchedAt: Date)
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

                    // Typeable refresh interval input. Stored as seconds in the
                    // model; user types in the same unit the current value reads
                    // in (seconds when <60, minutes when <60min, hours otherwise).
                    // Range clamping happens on commit so an out-of-range type
                    // doesn't quietly break scheduling.
                    HStack(spacing: 8) {
                        Text("Refresh interval")
                        Spacer()
                        TextField("", value: refreshIntervalDisplayBinding, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $refreshIntervalUnit) {
                            Text("sec").tag(RefreshIntervalUnit.seconds)
                            Text("min").tag(RefreshIntervalUnit.minutes)
                            Text("hr").tag(RefreshIntervalUnit.hours)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 80)
                        .labelsHidden()
                    }
                } header: {
                    Text("Tracker")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Label", text: $labelText)
                        Text("Optional shorter caption shown by widget templates instead of Name. Leave empty to use Name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Value transform optionally rewrites the numeric reading
                    // before display + gradient interpolation. e.g. for a
                    // "Claude weekly usage: 1%" reading, `.invertFromHundred`
                    // displays it as "99% remaining" — and the gradient
                    // interpolates on 99 instead of 1, so the user typically
                    // wants to flip gradientMode at the same time.
                    Picker("Value display", selection: $draft.valueTransform) {
                        ForEach(ValueTransform.allCases, id: \.self) { transform in
                            Text(transform.displayName).tag(transform)
                        }
                    }
                } header: {
                    Text("Display")
                } footer: {
                    // v0.21.41 — accent color lives on the Widget
                    // configuration editor's Visuals section. SF Symbol
                    // picker + value gradient picker were dropped per
                    // voice 4206 ("get rid of that. Is that unnecessary?
                    // ... the color is the color stuff is useful, so
                    // keep that."). See WidgetConfigsView.swift →
                    // `TrackerVisualConfigCard`.
                    Text("Accent color is in the Widgets section.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        if !chromiumAvailable {
                            VStack(alignment: .leading, spacing: 6) {
                                Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.orange)
                                // v0.21.36 — user-facing copy rename pass (voice 4189).
                                Text("Identify needs the Chromium browser bundled inside this app. Reinstall Stats Widget from Website to restore the missing browser bundle.")
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

                        if !trimmedSelector.isEmpty {
                            previewSection
                        }

                        // v0.21.9: secondary elements editor. Hidden until
                        // the primary element has been captured (no point
                        // adding "secondary text" before the main text
                        // exists). Renders one row per element with the
                        // selector + a rename field + a remove button, plus
                        // a "+ Add secondary element" button that opens
                        // Identify-in-Chrome for the new element.
                        if !trimmedSelector.isEmpty {
                            secondaryElementsSection
                        }
                    }
                } header: {
                    Text("Capture")
                }

                Section {
                    hooksPanel
                } header: {
                    Text("Hooks")
                } footer: {
                    Text("Hooks fire after every scrape. New trackers get the built-in auto-repair failure hook by default — it spawns Claude Code in a new Terminal window when a scrape fails so the agent can re-identify the broken element. Disable it per tracker if you'd rather repair manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            // v0.21.9: secondary elements are always TEXT-mode reads (they
            // surface short status strings like "resets in 4d"), so force
            // .text into the capture flow when the active target is a
            // secondary. Primary keeps the tracker's own render mode.
            let captureMode: RenderMode = {
                switch identifyTarget {
                case .primary: return draft.renderMode
                case .secondary: return .text
                }
            }()
            ChromeElementCaptureView(url: presentation.url, renderMode: captureMode) { pick in
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
            // Caller (e.g. trackers-list "Tap to re-identify" hint) asked for
            // the Identify flow to fire as soon as the editor is on screen.
            // Defer a tick so the sheet animation has finished before the
            // Chromium launch shifts focus.
            if autoStartIdentify, chromiumAvailable, validatedURL != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    openIdentifyBrowser()
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    runPreviewScrape()
                } label: {
                    if case .loading = previewState {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scraping…")
                        }
                    } else {
                        Label(previewButtonTitle, systemImage: "arrow.clockwise")
                    }
                }
                .disabled(!canRunPreview)
                .help("Run a one-off scrape now using the captured selector. Does not modify any saved data.")

                if let fetchedDescription = previewTimestampDescription {
                    Text(fetchedDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            switch previewState {
            case .idle:
                Text("Test scrape to confirm the selector returns the number you expect before saving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading:
                EmptyView()
            case .success(let value, let numeric, _):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(value)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                    if let numeric, let parsed = formattedNumeric(numeric) {
                        Text("(\(parsed))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            case .failure(let message, _):
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: draft.selector) { newSelector in
            // Selector changed (user re-identified or edited) — invalidate any
            // stale preview so the user doesn't think the new selector has been
            // verified.
            if newSelector != previewSelector {
                previewState = .idle
            }
        }
    }

    private var canRunPreview: Bool {
        guard chromiumAvailable, validatedURL != nil, !trimmedSelector.isEmpty else {
            return false
        }

        if case .loading = previewState {
            return false
        }

        return true
    }

    private var previewButtonTitle: String {
        switch previewState {
        case .idle:
            return "Test scrape now"
        case .loading:
            return "Scraping…"
        case .success, .failure:
            return "Re-test scrape"
        }
    }

    private var previewTimestampDescription: String? {
        let fetchedAt: Date?
        switch previewState {
        case .success(_, _, let date), .failure(_, let date):
            fetchedAt = date
        case .idle, .loading:
            fetchedAt = nil
        }

        guard let fetchedAt else {
            return nil
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "fetched \(formatter.localizedString(for: fetchedAt, relativeTo: Date()))"
    }

    private func formattedNumeric(_ value: Double) -> String? {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value))
    }

    private func runPreviewScrape() {
        guard let url = validatedURL else {
            return
        }

        let trimmedSelectorValue = trimmedSelector
        guard !trimmedSelectorValue.isEmpty else {
            return
        }

        // Snapshot the selector at request-start so a slow scrape's stale result
        // doesn't overwrite a newer Identify the user kicked off in the meantime.
        previewSelector = trimmedSelectorValue
        previewState = .loading

        var probeTracker = draft
        probeTracker.url = url.absoluteString
        probeTracker.selector = trimmedSelectorValue
        probeTracker.browserProfile = Tracker.defaultBrowserProfile

        ChromeCDPScraper.previewScrape(tracker: probeTracker) { result in
            DispatchQueue.main.async {
                // Guard against late callbacks: if the user re-identified mid-scrape,
                // the previewSelector will have advanced. Drop the stale result.
                guard previewSelector == trimmedSelectorValue else {
                    return
                }

                switch result {
                case .success(let reading):
                    let value = reading.currentValue ?? ""
                    if value.isEmpty {
                        previewState = .failure(
                            message: "Selector matched but the element had no text.",
                            fetchedAt: Date()
                        )
                    } else {
                        previewState = .success(
                            value: value,
                            numeric: reading.currentNumeric,
                            fetchedAt: Date()
                        )
                    }
                case .failure(let error):
                    previewState = .failure(
                        message: error.localizedDescription,
                        fetchedAt: Date()
                    )
                }
            }
        }
    }

    private var canSave: Bool {
        // v0.21.38 — relaxed the elementBoundingBox requirement to only fire
        // for `.snapshot` renderMode (screenshot crop needs the bbox). For
        // `.text` renderMode the scrape just reads selector content; bbox is
        // irrelevant.
        //
        // Bug surfaced via Ethan voice 4194 (2026-05-26): the two MCP-created
        // session-usage trackers were saved without a bbox (MCP path doesn't
        // require it). Opening them in the editor to rename them grayed out
        // the Save button forever because the old check insisted on a bbox
        // even though text-mode scrapes don't use one. Now `canSave` only
        // requires bbox for snapshot-mode trackers (where the screenshot
        // crop actually needs the coordinates).
        guard !trimmedName.isEmpty,
              validatedURL != nil,
              !trimmedSelector.isEmpty else {
            return false
        }
        if draft.renderMode == .snapshot {
            return draft.elementBoundingBox != nil
        }
        return true
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

    /// SwiftUI Binding that lets the user type a number in the currently-
    /// selected unit (seconds/minutes/hours) and writes back to
    /// draft.refreshIntervalSec in seconds, clamped to refreshIntervalRange.
    private var refreshIntervalDisplayBinding: Binding<Int> {
        Binding<Int>(
            get: {
                let secs = draft.refreshIntervalSec
                switch refreshIntervalUnit {
                case .seconds: return secs
                case .minutes: return max(1, secs / 60)
                case .hours:   return max(1, secs / 3_600)
                }
            },
            set: { newValue in
                let multiplier: Int
                switch refreshIntervalUnit {
                case .seconds: multiplier = 1
                case .minutes: multiplier = 60
                case .hours:   multiplier = 3_600
                }
                let secs = max(1, newValue) * multiplier
                let clamped = min(max(secs, refreshIntervalRange.lowerBound), refreshIntervalRange.upperBound)
                draft.refreshIntervalSec = clamped
            }
        )
    }

    enum RefreshIntervalUnit: Hashable {
        case seconds, minutes, hours
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

        identifyTarget = .primary
        browserPresentation = IdentifyBrowserPresentation(url: url)
    }

    private func openIdentifyBrowserForSecondary(elementID: UUID) {
        guard let url = validatedURL else {
            return
        }

        identifyTarget = .secondary(elementID: elementID)
        browserPresentation = IdentifyBrowserPresentation(url: url)
    }

    private func addSecondaryElement() {
        let nextNumber = draft.secondaryElements.count + 2 // primary is "1"; first secondary is "2"
        let new = TrackerElement(name: "Element \(nextNumber)")
        draft.secondaryElements.append(new)
        // Immediately open Identify-in-Chrome so the user goes straight to
        // capture instead of staring at an empty row.
        openIdentifyBrowserForSecondary(elementID: new.id)
    }

    private func applyCapturedElement(_ pick: ElementPick) {
        switch identifyTarget {
        case .primary:
            draft.selector = pick.selector
            draft.elementBoundingBox = pick.bbox
            capturedText = pick.text
        case .secondary(let elementID):
            guard let index = draft.secondaryElements.firstIndex(where: { $0.id == elementID }) else {
                return
            }
            draft.secondaryElements[index].selector = pick.selector
            draft.secondaryElements[index].elementBoundingBox = pick.bbox
            // Auto-name from the captured text on first capture if the user
            // hasn't customized the name. Keeps "Element 2" → "73% used"
            // discoverable in the widget picker.
            let trimmed = pick.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty,
               draft.secondaryElements[index].name.hasPrefix("Element ") {
                let preview = String(trimmed.prefix(40))
                draft.secondaryElements[index].name = preview
            }
        }
        // Reset to primary so a subsequent ad-hoc tap of the main Identify
        // button doesn't accidentally route into a secondary slot.
        identifyTarget = .primary
    }

    @ViewBuilder
    private var secondaryElementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Secondary elements")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    addSecondaryElement()
                } label: {
                    Label("Add secondary element", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
                .disabled(validatedURL == nil || !chromiumAvailable)
                .help("Capture another element on the same page. The widget config UI lets you bind it as secondary text alongside the main value.")
            }

            if draft.secondaryElements.isEmpty {
                Text("Add a secondary element to surface a second value from the same page (e.g. \"resets in 4d\" next to \"73% used\"). Widget configurations choose which secondary text to render.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(draft.secondaryElements) { element in
                    secondaryElementRow(elementID: element.id)
                }
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private func secondaryElementRow(elementID: UUID) -> some View {
        let bindingIndex = draft.secondaryElements.firstIndex(where: { $0.id == elementID })
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let idx = bindingIndex {
                    TextField("Name", text: Binding(
                        get: { draft.secondaryElements[idx].name },
                        set: { draft.secondaryElements[idx].name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                Button {
                    openIdentifyBrowserForSecondary(elementID: elementID)
                } label: {
                    if let idx = bindingIndex,
                       draft.secondaryElements[idx].selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label("Identify", systemImage: "viewfinder")
                    } else {
                        Label("Re-identify", systemImage: "viewfinder")
                    }
                }
                .disabled(validatedURL == nil || !chromiumAvailable)

                Button(role: .destructive) {
                    draft.secondaryElements.removeAll { $0.id == elementID }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            if let idx = bindingIndex {
                let selector = draft.secondaryElements[idx].selector
                if !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(selector)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else {
                    Text("Not captured yet — tap Identify to pick an element.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    /// v0.21.9: which element a captured pick should be applied to. Set
    /// just before opening the Chrome capture sheet and consulted on
    /// return in `applyCapturedElement(_:)`.
    private enum IdentifyTarget: Equatable {
        case primary
        case secondary(elementID: UUID)
    }

    // MARK: - Hooks panel (v0.18.0+)

    @ViewBuilder
    private var hooksPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            hookGroup(title: "On failure", trigger: .onFailure, hooks: $draft.hooks.onFailure)
            Divider()
            hookGroup(title: "On success", trigger: .onSuccess, hooks: $draft.hooks.onSuccess)
        }
    }

    @ViewBuilder
    private func hookGroup(title: String, trigger: HookTrigger, hooks: Binding<[TrackerHook]>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    let new = TrackerHook(
                        name: "New \(title.lowercased()) hook",
                        trigger: trigger,
                        actionKind: .runShellCommand,
                        actionPayload: ""
                    )
                    hooks.wrappedValue.append(new)
                } label: {
                    Label("Add hook", systemImage: "plus.circle")
                }
                .buttonStyle(.borderless)
            }

            if hooks.wrappedValue.isEmpty {
                Text("No \(title.lowercased()) hooks configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hooks.wrappedValue) { hook in
                    hookRow(hook: hook, hooks: hooks)
                }
            }
        }
    }

    @ViewBuilder
    private func hookRow(hook: TrackerHook, hooks: Binding<[TrackerHook]>) -> some View {
        let bindingIndex = hooks.wrappedValue.firstIndex(where: { $0.id == hook.id })
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let idx = bindingIndex {
                    Toggle("", isOn: Binding(
                        get: { hooks.wrappedValue[idx].enabled },
                        set: { hooks.wrappedValue[idx].enabled = $0 }
                    ))
                    .labelsHidden()
                }
                if let idx = bindingIndex {
                    TextField("Name", text: Binding(
                        get: { hooks.wrappedValue[idx].name },
                        set: { hooks.wrappedValue[idx].name = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                if hook.builtInIdentifier != nil {
                    Text("built-in")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
                Button(role: .destructive) {
                    hooks.wrappedValue.removeAll { $0.id == hook.id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            if let idx = bindingIndex {
                HStack(spacing: 8) {
                    Picker("Action", selection: Binding(
                        get: { hooks.wrappedValue[idx].actionKind },
                        set: { hooks.wrappedValue[idx].actionKind = $0 }
                    )) {
                        Text("Shell").tag(HookActionKind.runShellCommand)
                        Text("AppleScript").tag(HookActionKind.runAppleScript)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                    Spacer()
                }

                TextField("Command…", text: Binding(
                    get: { hooks.wrappedValue[idx].actionPayload },
                    set: { hooks.wrappedValue[idx].actionPayload = $0 }
                ), axis: .vertical)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            }

            if let lastRun = hook.lastRun {
                hookLastRunChip(lastRun)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(6)
    }

    private func hookLastRunChip(_ lastRun: HookLastRun) -> some View {
        let symbol = hookLastRunSymbol(lastRun.status)
        let color = hookLastRunColor(lastRun.status)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let timestamp = lastRun.finishedAt ?? lastRun.startedAt

        return HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text("last run \(formatter.localizedString(for: timestamp, relativeTo: Date()))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let detail = lastRun.detail, !detail.isEmpty {
                Text("— \(detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func hookLastRunSymbol(_ status: HookLastRun.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .timeout: return "clock.badge.exclamationmark.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func hookLastRunColor(_ status: HookLastRun.Status) -> Color {
        switch status {
        case .ok: return .green
        case .error: return .red
        case .timeout: return .orange
        case .skipped: return .gray
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
