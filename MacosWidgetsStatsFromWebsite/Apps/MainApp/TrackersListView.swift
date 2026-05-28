//
//  TrackersListView.swift
//  MacosWidgetsStatsFromWebsite
//
//  List of configured trackers.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TrackersListView: View {
    @EnvironmentObject private var store: AppGroupStore
    @EnvironmentObject private var backgroundScheduler: BackgroundScheduler
    @State private var selectedTrackerID: UUID?
    @State private var editorPresentation: TrackerEditorPresentation?
    @State private var selectorPackExportMessage: String?
    /// v0.21.7 perf: single readings cache, refreshed by one parent-level
    /// notification subscriber instead of one per row. Codex review flagged
    /// per-row `AppGroupStore.reading(for:)` (which reads/decodes the whole
    /// readings file) and per-row notification subscriptions as a primary
    /// UI-lag cause during config / list navigation.
    @State private var readingsByTrackerID: [UUID: TrackerReading] = [:]

    var body: some View {
        ZStack {
            if store.trackers.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "target")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No trackers yet")
                        .font(.headline)
                    Text("Add a tracker, paste a page URL, then identify the value or page region in the app's Chrome profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                    Button {
                        add()
                    } label: {
                        Label("Add Tracker", systemImage: "plus")
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $selectedTrackerID) {
                    ForEach(store.trackers) { tracker in
                        TrackerRowView(
                            tracker: tracker,
                            reading: readingsByTrackerID[tracker.id],
                            isRefreshing: backgroundScheduler.inFlightTrackerIDs.contains(tracker.id),
                            onEdit: { edit(tracker) },
                            onRefresh: { backgroundScheduler.triggerScrapeNow(trackerID: tracker.id) },
                            onReIdentify: { reIdentify(tracker) }
                        )
                        .tag(tracker.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            edit(tracker)
                        }
                            .contextMenu {
                                Button("Edit") {
                                    edit(tracker)
                                }
                                Button("Duplicate") {
                                    store.duplicateTracker(tracker)
                                }
                                Button("Scrape Now") {
                                    backgroundScheduler.triggerScrapeNow(trackerID: tracker.id)
                                }
                                // v0.21.7: renamed from "Export Selector Pack"
                                // to the plain-English "Export Tracker Config"
                                // so the action is self-explanatory. Same
                                // file format under the hood.
                                Button("Export Tracker Config…") {
                                    exportSelectorPack(tracker)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    delete(tracker)
                                }
                            }
                    }
                    // Drag-and-drop reorder per voice 4275 (2026-05-27).
                    // SwiftUI's native `.onMove` on `ForEach` inside a
                    // `List` provides hover-revealed drag handles on
                    // macOS 13+. AppGroupStore.moveTrackers persists the
                    // new order to trackers.json. Pure organisation — no
                    // scrape impact, no id rewrites, no widget rebinding
                    // (widgets bind by tracker id, not list index).
                    .onMove(perform: store.moveTrackers)
                }
            }
        }
        .navigationTitle("Trackers")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    add()
                } label: {
                    Label("Add Tracker", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .help("Add Tracker")

                Button {
                    editSelected()
                } label: {
                    Label("Edit Tracker", systemImage: "pencil")
                }
                .disabled(selectedTracker == nil)
                .help("Edit Tracker")

                Button {
                    scrapeSelected()
                } label: {
                    Label("Scrape Now", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(selectedTracker == nil)
                .help("Scrape Now")

                // v0.21.7 prefs-button audit: Export Tracker Config (formerly
                // "Export Selector Pack") was rarely used as a toolbar button —
                // most users discover it via the context-menu / right-click on
                // a tracker. Keep the action available there + via File menu,
                // but drop the toolbar slot to reduce clutter.
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            TrackerEditorView(
                mode: presentation.mode,
                tracker: presentation.tracker,
                autoStartIdentify: presentation.autoStartIdentify
            ) { savedTracker in
                store.upsertTracker(savedTracker)
                selectedTrackerID = savedTracker.id
            }
            .frame(width: 620, height: 680)
        }
        .onAppear {
            refreshReadings()
            if let trackerID = AppNavigationEvents.consumePendingTrackerID() {
                let startIdentify = AppNavigationEvents.consumePendingShouldStartIdentify()
                openTrackerSettings(trackerID: trackerID, startIdentify: startIdentify)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BackgroundScheduler.trackerReadingDidChangeNotification)) { notification in
            // Single subscriber at the list level (v0.21.7) — each row used
            // to subscribe individually, causing N file reads per scrape
            // event. Patch only the changed tracker's row, not the whole map.
            if let trackerID = notification.userInfo?["trackerID"] as? UUID {
                if let updated = AppGroupStore.reading(for: trackerID) {
                    readingsByTrackerID[trackerID] = updated
                } else {
                    readingsByTrackerID.removeValue(forKey: trackerID)
                }
            } else {
                refreshReadings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationEvents.openTrackerSettingsNotification)) { notification in
            guard let trackerID = notification.userInfo?["trackerID"] as? UUID else {
                return
            }
            let startIdentify = (notification.userInfo?["startIdentify"] as? Bool) ?? false
            openTrackerSettings(trackerID: trackerID, startIdentify: startIdentify)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 6) {
                if let error = store.lastPersistenceError {
                    Text(error)
                        .foregroundStyle(.red)
                }
                if let selectorPackExportMessage {
                    Text(selectorPackExportMessage)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .padding(10)
            .opacity(store.lastPersistenceError == nil && selectorPackExportMessage == nil ? 0 : 1)
        }
    }

    private var selectedTracker: Tracker? {
        guard let selectedTrackerID else {
            return nil
        }

        return store.trackers.first { $0.id == selectedTrackerID }
    }

    private func add() {
        editorPresentation = TrackerEditorPresentation(mode: .add, tracker: Tracker())
    }

    private func editSelected() {
        guard let selectedTracker else {
            return
        }

        edit(selectedTracker)
    }

    private func scrapeSelected() {
        guard let selectedTrackerID else {
            return
        }

        backgroundScheduler.triggerScrapeNow(trackerID: selectedTrackerID)
    }

    private func exportSelectedSelectorPack() {
        guard let selectedTracker else {
            return
        }

        exportSelectorPack(selectedTracker)
    }

    private func exportSelectorPack(_ tracker: Tracker) {
        do {
            let data = try SelectorPack(tracker: tracker).encodedData()
            let panel = NSSavePanel()
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = "\(safeFileName(tracker.name.isEmpty ? "selector-pack" : tracker.name)).\(SelectorPack.fileExtension)"
            if let selectorPackType = UTType(SelectorPack.contentTypeIdentifier) ?? UTType(filenameExtension: SelectorPack.fileExtension) {
                panel.allowedContentTypes = [selectorPackType]
            }

            guard panel.runModal() == .OK, let url = panel.url else {
                return
            }

            try data.write(to: url, options: .atomic)
            showExportMessage("Exported \(url.lastPathComponent).")
        } catch {
            showExportMessage(error.localizedDescription)
        }
    }

    private func safeFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "selector-pack" : cleaned
    }

    private func showExportMessage(_ message: String) {
        selectorPackExportMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if selectorPackExportMessage == message {
                selectorPackExportMessage = nil
            }
        }
    }

    private func edit(_ tracker: Tracker) {
        selectedTrackerID = tracker.id
        editorPresentation = TrackerEditorPresentation(mode: .edit, tracker: tracker)
    }

    /// Opens the tracker editor with the Identify-in-Chrome flow already
    /// armed to fire. Used by the trackers-list "Tap to re-identify" hint
    /// surfaced under a tracker whose last scrape failed with a
    /// login-required / selector-not-found classification. The flag is
    /// consumed by `TrackerEditorView.onAppear` after a short delay so the
    /// sheet has time to settle before Chromium launches.
    private func reIdentify(_ tracker: Tracker) {
        selectedTrackerID = tracker.id
        editorPresentation = TrackerEditorPresentation(
            mode: .edit,
            tracker: tracker,
            autoStartIdentify: true
        )
    }

    private func delete(_ tracker: Tracker) {
        if selectedTrackerID == tracker.id {
            selectedTrackerID = nil
        }

        store.deleteTracker(id: tracker.id)
    }

    /// Bulk-load all readings into the parent-level cache. Decodes the
    /// readings file ONCE per refresh instead of N times (one per row).
    private func refreshReadings() {
        let file = AppGroupStore.loadReadings()
        var byID: [UUID: TrackerReading] = [:]
        byID.reserveCapacity(file.readings.count)
        for (key, reading) in file.readings {
            if let uuid = UUID(uuidString: key) {
                byID[uuid] = reading
            }
        }
        readingsByTrackerID = byID
    }

    private func openTrackerSettings(trackerID: UUID, startIdentify: Bool = false) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }

        selectedTrackerID = trackerID
        editorPresentation = TrackerEditorPresentation(
            mode: .edit,
            tracker: tracker,
            autoStartIdentify: startIdentify
        )
    }
}

private struct TrackerRowView: View {
    let tracker: Tracker
    /// v0.21.7: reading is now provided by the parent's single readings
    /// cache instead of being read+subscribed per-row. See
    /// TrackersListView.readingsByTrackerID.
    let reading: TrackerReading?
    let isRefreshing: Bool
    let onEdit: () -> Void
    let onRefresh: () -> Void
    let onReIdentify: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                .foregroundStyle(Color(hexString: tracker.accentColorHex) ?? .accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(tracker.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Failure-status subtitle (v0.21.6). Surfaces a short
                // user-actionable label like "Login required — Tap to
                // re-identify" right under the URL so the user doesn't
                // have to open the editor to learn what's wrong. For
                // kinds that benefit from re-identifying the element
                // (login walls + missing selectors) we wrap the row in a
                // tap gesture that opens the editor with the Identify
                // flow pre-armed.
                if let failureKind = currentFailureKind {
                    failureSubtitle(failureKind)
                }
            }

            Spacer(minLength: 12)

            // Latest scraped value + freshness, surfaced inline so the user
            // can see at a glance whether the saved selector is producing the
            // expected number without opening the editor.
            VStack(alignment: .trailing, spacing: 2) {
                Text(displayedValue)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(valueColor)
                if let timestamp = displayedTimestamp {
                    Text(timestamp)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 60, alignment: .trailing)

            Text(tracker.renderMode.rawValue)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(tracker.renderMode == .text ? Color.green.opacity(0.18) : Color.blue.opacity(0.16))
                )
                .foregroundStyle(tracker.renderMode == .text ? .green : .blue)

            Button(action: onRefresh) {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .disabled(isRefreshing)
            .help("Scrape \(tracker.name.isEmpty ? "tracker" : tracker.name) now")
            .accessibilityLabel("Scrape tracker now")

            Button(action: onEdit) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Edit \(tracker.name.isEmpty ? "tracker" : tracker.name)")
            .accessibilityLabel("Edit tracker")
        }
        .padding(.vertical, 4)
    }

    /// Latest failure classification for this row. Returns nil when the
    /// tracker is currently in the .ok state — keeps the row clean for
    /// healthy trackers.
    private var currentFailureKind: TrackerFailureKind? {
        guard let reading else { return nil }
        return TrackerFailureKind.classify(reading: reading)
    }

    @ViewBuilder
    private func failureSubtitle(_ kind: TrackerFailureKind) -> some View {
        // Wrap the headline + action hint in a single HStack so the user's
        // tap target is obvious. For kinds where re-identifying makes
        // sense, we add a tap gesture that surfaces the Identify flow.
        let color: Color = {
            switch reading?.status {
            case .broken: return .red
            case .stale: return .orange
            default: return .secondary
            }
        }()

        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(color)
            Text(kind.headline)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
            if let hint = kind.actionHint {
                Text("— \(hint)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .underline()
                    .lineLimit(1)
            }
        }
        .padding(.top, 1)
        // Only intercept taps when there's a re-identify action to fire.
        // Without this guard the row swallows the parent's "tap to edit"
        // gesture for OK trackers too.
        .contentShape(Rectangle())
        .onTapGesture {
            if kind.benefitsFromReIdentify {
                onReIdentify()
            } else {
                onEdit()
            }
        }
        .help(detailedHelpText(for: kind))
    }

    /// Tooltip text for the failure subtitle. Keeps the on-screen label
    /// short while the hover-help exposes the raw error message for power
    /// users / bug reporters.
    private func detailedHelpText(for kind: TrackerFailureKind) -> String {
        switch kind {
        case .browserChallenge:
            return "The page is showing a browser verification challenge. The last good value is kept and the background scheduler will retry without asking you to re-identify."
        case .loginRequired:
            return "The tracker's URL needs sign-in inside the app's Chromium profile. Tap to open Identify in Chrome and re-capture the selector once you're logged in."
        case .selectorNotFound:
            return "The saved CSS selector no longer matches anything on the page. Tap to re-capture it via Identify in Chrome."
        case .pageTimeout:
            return "Chromium took too long to load the tracker URL. Open Edit to inspect or change the refresh interval."
        case .staleSuccess:
            return "The last scrape succeeded but the next refresh is overdue. The background scheduler will retry shortly."
        case .other(let message):
            return message
        }
    }

    private var displayedValue: String {
        if let value = tracker.displayValue(for: reading) {
            return value
        }

        if tracker.renderMode == .snapshot, reading?.snapshotCacheKey != nil {
            return "(snapshot)"
        }

        return "—"
    }

    private var valueColor: Color {
        switch reading?.status {
        case .broken:
            return .red
        case .stale:
            return .secondary
        case .ok, nil:
            return .primary
        }
    }

    private var displayedTimestamp: String? {
        guard let lastUpdated = reading?.lastUpdatedAt else {
            return nil
        }

        return TrackerRowView.relativeFormatter.localizedString(for: lastUpdated, relativeTo: Date())
    }

    // v0.21.7 perf: hoist the formatter out of the per-row body recomputation
    // path. Codex flagged this as a hot allocation during widget-config
    // / tracker-list re-renders (one formatter per row per re-render).
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct TrackerEditorPresentation: Identifiable {
    let id = UUID()
    let mode: TrackerEditorView.Mode
    let tracker: Tracker
    var autoStartIdentify: Bool = false
}
