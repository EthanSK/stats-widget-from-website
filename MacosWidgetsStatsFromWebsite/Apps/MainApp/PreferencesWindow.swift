//
//  PreferencesWindow.swift
//  MacosWidgetsStatsFromWebsite
//
//  Main preferences container.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PreferencesWindow: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var selection: PreferencesSection? = .trackers
    @State private var mcpIdentifyPresentation: MCPIdentifyPresentation?
    @State private var isSelectorPackDropTargeted = false
    @State private var selectorPackImportMessage: String?

    var body: some View {
        NavigationSplitView {
            List(PreferencesSection.allCases, selection: $selection) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
            .navigationTitle("Preferences")
        } detail: {
            switch selection ?? .trackers {
            case .trackers:
                TrackersListView()
            case .widgets:
                WidgetConfigsView()
            case .browser:
                SignInPrefsView()
            case .mcp:
                MCPPrefsView()
            case .logs:
                ActivityLogPrefsView()
            case .about:
                AboutPrefsView()
            }
        }
        .frame(minWidth: 780, minHeight: 520)
        .onDrop(
            of: [SelectorPack.contentTypeIdentifier, UTType.fileURL.identifier, UTType.json.identifier],
            isTargeted: $isSelectorPackDropTargeted,
            perform: importDroppedSelectorPacks
        )
        .overlay(alignment: .bottomTrailing) {
            if isSelectorPackDropTargeted {
                // v0.21.7: relabeled drop overlay to plain English.
                Label("Import tracker config", systemImage: "square.and.arrow.down")
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            } else if let selectorPackImportMessage {
                Text(selectorPackImportMessage)
                    .font(.caption)
                    .padding(10)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationEvents.openTrackerSettingsNotification)) { _ in
            selection = .trackers
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuBarPreferencesSectionRequested)) { notification in
            if let rawValue = notification.userInfo?["section"] as? String,
               let section = PreferencesSection(rawValue: rawValue) {
                selection = section
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .mcpIdentifyElementRequested)) { notification in
            openMCPIdentifyRequest(notification)
        }
        .sheet(item: $mcpIdentifyPresentation) { presentation in
            ChromeElementCaptureView(url: presentation.url, renderMode: presentation.renderMode) { pick in
                completeMCPIdentifyRequest(presentation, pick: pick)
            }
        }
    }

    private func importDroppedSelectorPacks(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    if let error {
                        showSelectorPackImportResult(error.localizedDescription)
                        return
                    }

                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        importSelectorPack(url)
                    } else if let url = item as? URL {
                        importSelectorPack(url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(SelectorPack.contentTypeIdentifier) || provider.hasItemConformingToTypeIdentifier(UTType.json.identifier) {
                handled = true
                let type = provider.hasItemConformingToTypeIdentifier(SelectorPack.contentTypeIdentifier)
                    ? SelectorPack.contentTypeIdentifier
                    : UTType.json.identifier
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let error {
                        showSelectorPackImportResult(error.localizedDescription)
                        return
                    }
                    guard let data else {
                        showSelectorPackImportResult("Dropped selector pack was empty.")
                        return
                    }
                    importSelectorPack(data)
                }
            }
        }
        return handled
    }

    private func importSelectorPack(_ url: URL) {
        do {
            let tracker = try SelectorPackImportCoordinator.importSelectorPack(at: url)
            DispatchQueue.main.async {
                store.reloadFromDisk()
                selection = .trackers
                showSelectorPackImportResult("Imported \(tracker.name).")
            }
        } catch {
            showSelectorPackImportResult(error.localizedDescription)
        }
    }

    private func importSelectorPack(_ data: Data) {
        do {
            let pack = try SelectorPack.decodeStrict(from: data)
            let tracker = try pack.makeTracker()
            try AppGroupStore.mutateSharedConfiguration { configuration in
                configuration.trackers.append(tracker)
            }
            DispatchQueue.main.async {
                store.reloadFromDisk()
                selection = .trackers
                showSelectorPackImportResult("Imported \(tracker.name).")
            }
        } catch {
            showSelectorPackImportResult(error.localizedDescription)
        }
    }

    private func showSelectorPackImportResult(_ message: String) {
        DispatchQueue.main.async {
            selectorPackImportMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if selectorPackImportMessage == message {
                    selectorPackImportMessage = nil
                }
            }
        }
    }

    private func openMCPIdentifyRequest(_ notification: Notification) {
        guard let trackerIDString = notification.userInfo?["trackerID"] as? String,
              let trackerID = UUID(uuidString: trackerIDString),
              let urlString = notification.userInfo?["url"] as? String,
              let url = TrackerURLValidator.httpOrHTTPSURL(from: urlString, defaultScheme: nil) else {
            return
        }
        let renderMode = RenderMode(rawValue: notification.userInfo?["renderMode"] as? String ?? "") ?? .text

        NSApp.activate(ignoringOtherApps: true)
        store.reloadFromDisk()

        if !store.trackers.contains(where: { $0.id == trackerID }) {
            store.addTracker(Tracker(id: trackerID, name: "Pending \(url.host ?? "Tracker")", url: url.absoluteString, renderMode: renderMode, selector: ""))
        }

        selection = .trackers
        let presentation = MCPIdentifyPresentation(trackerID: trackerID, url: url, renderMode: renderMode)
        guard mcpIdentifyPresentation != nil else {
            mcpIdentifyPresentation = presentation
            return
        }

        // Esc cancels the picker inside Chromium but can leave the SwiftUI
        // sheet alive. Force a fresh sheet instance so a repeated MCP
        // identify request re-arms instead of reusing a canceled controller.
        mcpIdentifyPresentation = nil
        DispatchQueue.main.async {
            mcpIdentifyPresentation = presentation
        }
    }

    private func completeMCPIdentifyRequest(_ presentation: MCPIdentifyPresentation, pick: ElementPick) {
        store.reloadFromDisk()
        guard let tracker = store.trackers.first(where: { $0.id == presentation.trackerID }) else {
            return
        }

        var updated = tracker
        if updated.name.hasPrefix("Pending ") {
            updated.name = presentation.url.host ?? "Tracked Element"
        }
        updated.selector = pick.selector
        updated.elementBoundingBox = pick.bbox
        updated.renderMode = presentation.renderMode
        updated.url = presentation.url.absoluteString
        store.updateTracker(updated)
        _ = try? AppGroupStore.resetFailureState(
            for: presentation.trackerID,
            reason: "Element was re-identified; waiting for the next scrape to verify it."
        )

        NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
    }
}

private struct MCPIdentifyPresentation: Identifiable {
    let id = UUID()
    let trackerID: UUID
    let url: URL
    let renderMode: RenderMode
}

enum PreferencesSection: String, CaseIterable, Hashable, Identifiable {
    case trackers
    case widgets
    case browser
    case mcp
    case logs
    case about

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .trackers:
            return "Trackers"
        case .widgets:
            return "Widgets"
        case .browser:
            return "Chrome Profile"
        case .mcp:
            return "MCP"
        case .logs:
            return "Activity Log"
        case .about:
            return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .trackers:
            return "list.bullet.rectangle"
        case .widgets:
            return "rectangle.grid.2x2"
        case .browser:
            return "globe"
        case .mcp:
            return "point.3.connected.trianglepath.dotted"
        case .logs:
            return "doc.text.magnifyingglass"
        case .about:
            return "info.circle"
        }
    }
}

private struct ActivityLogPrefsView: View {
    @State private var logText = ""
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activity Log")
                        .font(.title2.weight(.semibold))
                    Text("App, scrape, browser, MCP, and widget activity is written here for debugging.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload recent log entries")

                Button {
                    openLogFile()
                } label: {
                    Label("View Log", systemImage: "doc.text")
                }
                .help("Open activity.log")

                Button {
                    revealLogsFolder()
                } label: {
                    Label("Open Logs", systemImage: "folder")
                }
                .help("Reveal the logs folder in Finder")
            }

            Text(ActivityLogger.logFileURL().path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(logText.isEmpty ? "No activity has been logged yet." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(logText.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2))
            )
        }
        .padding(24)
        .navigationTitle("Activity Log")
        .onAppear {
            ActivityLogger.log("ui", "opened activity log preferences")
            refresh()
        }
    }

    private func refresh() {
        ActivityLogger.ensureLogFileExists()
        logText = ActivityLogger.recentLogText(lineLimit: 300)
        statusMessage = "Showing the most recent log lines."
    }

    private func openLogFile() {
        ActivityLogger.ensureLogFileExists()
        NSWorkspace.shared.open(ActivityLogger.logFileURL())
        statusMessage = "Opened activity.log."
        ActivityLogger.log("ui", "opened activity log file")
    }

    private func revealLogsFolder() {
        ActivityLogger.ensureLogFileExists()
        NSWorkspace.shared.activateFileViewerSelecting([ActivityLogger.logFileURL()])
        statusMessage = "Revealed the logs folder in Finder."
        ActivityLogger.log("ui", "revealed logs folder")
    }
}

private struct AboutPrefsView: View {
    // v0.21.39 — observe UpdateController so the "Last checked"
    // timestamp + "Check for Updates…" button reflect Sparkle's
    // live state. The shared instance is started by AppDelegate at
    // launch, so it's safe to depend on it from here.
    @ObservedObject private var updateController = UpdateController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // About panel title — matches the renamed .app wrapper from
            // v0.21.22 (voice 4002 / MBP-CC bridge msg-65036391). The
            // CFBundleDisplayName and AboutPrefsView header are the two
            // most-seen user-facing product names; keep them in sync.
            Text("Stats Widget from Website")
                .font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("App version", value: appVersion.displayText)
                LabeledContent("Widget extension", value: widgetVersion.displayText)
            }
            .textSelection(.enabled)
            .foregroundStyle(.secondary)

            Text("Use these version/build numbers to confirm macOS is loading the latest app and widget extension.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // v0.21.39 — new "Updates" section.
            //
            // Voice 4196: Ethan asked where the "Check for Updates"
            // button lives. It DID exist in the menu-bar status item
            // (MenuBarController.swift), but the menu-bar menu only
            // appears when he clicks the status icon — which he didn't
            // realise. Surface the same control here so opening the
            // About pane is also a valid path. The button calls into
            // the SAME UpdateController.checkForUpdates() entry point
            // the menu-bar item uses, so behaviour is identical
            // (Sparkle's standard "no update / install now" dialog).
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Updates")
                    .font(.headline)

                HStack(spacing: 12) {
                    Button {
                        // No sender — UpdateController.checkForUpdates
                        // accepts Any? so passing nil is fine and
                        // matches the menu-bar invocation path.
                        UpdateController.shared.checkForUpdates(nil)
                    } label: {
                        Label("Check for Updates…", systemImage: "arrow.down.circle")
                    }
                    // Disable while a probe is mid-flight so rapid
                    // clicks don't queue extra Sparkle cycles. The
                    // controller flips this back on cycle completion.
                    .disabled(updateController.isCheckingForUpdates)
                    .help("Ask Sparkle to look for a newer version on the appcast.")

                    if updateController.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                // Last-checked timestamp. Uses a relative date format so
                // it reads as "moments ago" / "5 minutes ago" / "2 hours
                // ago" — easier to skim than an absolute timestamp. If
                // Sparkle has never run a cycle in this user-defaults
                // namespace we fall back to "Never" so there's no
                // confusion about whether the system is wired up.
                LabeledContent("Last checked") {
                    Text(lastCheckedText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text("Updates are installed automatically in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .navigationTitle("About")
    }

    private var appVersion: BundleVersion {
        BundleVersion(bundle: .main)
    }

    private var widgetVersion: BundleVersion {
        guard let widgetURL = Bundle.main.builtInPlugInsURL?.appendingPathComponent("MacosWidgetsStatsFromWebsiteWidget.appex"),
              let widgetBundle = Bundle(url: widgetURL) else {
            return BundleVersion(version: "Not found", build: "-")
        }

        return BundleVersion(bundle: widgetBundle)
    }

    /// Human-readable rendering of the most recent Sparkle check
    /// timestamp. Returns "Never" if Sparkle has not yet completed a
    /// cycle on this account (typical: fresh install). Uses
    /// RelativeDateTimeFormatter for "5 minutes ago"-style output, which
    /// is what users actually want to skim.
    private var lastCheckedText: String {
        guard let date = updateController.lastCheckDate else {
            return "Never"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct BundleVersion {
    let version: String
    let build: String

    init(bundle: Bundle) {
        version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }

    init(version: String, build: String) {
        self.version = version
        self.build = build
    }

    var displayText: String {
        "v\(version) (build \(build))"
    }
}
