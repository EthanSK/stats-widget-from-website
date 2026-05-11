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
                            isRefreshing: backgroundScheduler.inFlightTrackerIDs.contains(tracker.id),
                            onEdit: { edit(tracker) },
                            onRefresh: { backgroundScheduler.triggerScrapeNow(trackerID: tracker.id) }
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
                                Button("Export Selector Pack") {
                                    exportSelectorPack(tracker)
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    delete(tracker)
                                }
                            }
                    }
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

                Button {
                    exportSelectedSelectorPack()
                } label: {
                    Label("Export Selector Pack", systemImage: "square.and.arrow.up")
                }
                .disabled(selectedTracker == nil)
                .help("Export Selector Pack")
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            TrackerEditorView(mode: presentation.mode, tracker: presentation.tracker) { savedTracker in
                store.upsertTracker(savedTracker)
                selectedTrackerID = savedTracker.id
            }
            .frame(width: 620, height: 680)
        }
        .onAppear {
            if let trackerID = AppNavigationEvents.consumePendingTrackerID() {
                openTrackerSettings(trackerID: trackerID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppNavigationEvents.openTrackerSettingsNotification)) { notification in
            guard let trackerID = notification.userInfo?["trackerID"] as? UUID else {
                return
            }

            openTrackerSettings(trackerID: trackerID)
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

    private func delete(_ tracker: Tracker) {
        if selectedTrackerID == tracker.id {
            selectedTrackerID = nil
        }

        store.deleteTracker(id: tracker.id)
    }

    private func openTrackerSettings(trackerID: UUID) {
        guard let tracker = store.trackers.first(where: { $0.id == trackerID }) else {
            return
        }

        selectedTrackerID = trackerID
        editorPresentation = TrackerEditorPresentation(mode: .edit, tracker: tracker)
    }
}

private struct TrackerRowView: View {
    let tracker: Tracker
    let isRefreshing: Bool
    let onEdit: () -> Void
    let onRefresh: () -> Void

    @State private var reading: TrackerReading?

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
        .onAppear {
            reading = AppGroupStore.reading(for: tracker.id)
        }
        .onReceive(NotificationCenter.default.publisher(for: BackgroundScheduler.trackerReadingDidChangeNotification)) { notification in
            guard let trackerID = notification.userInfo?["trackerID"] as? UUID,
                  trackerID == tracker.id else {
                return
            }
            reading = AppGroupStore.reading(for: tracker.id)
        }
    }

    private var displayedValue: String {
        if let value = reading?.currentValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: lastUpdated, relativeTo: Date())
    }
}

private struct TrackerEditorPresentation: Identifiable {
    let id = UUID()
    let mode: TrackerEditorView.Mode
    let tracker: Tracker
}
