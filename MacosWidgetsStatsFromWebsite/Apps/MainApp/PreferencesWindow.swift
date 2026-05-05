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
                Label("Import selector pack", systemImage: "square.and.arrow.down")
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
              let url = URL(string: urlString) else {
            return
        }
        let renderMode = RenderMode(rawValue: notification.userInfo?["renderMode"] as? String ?? "") ?? .text

        NSApp.activate(ignoringOtherApps: true)
        store.reloadFromDisk()

        if !store.trackers.contains(where: { $0.id == trackerID }) {
            store.addTracker(Tracker(id: trackerID, name: "Pending \(url.host ?? "Tracker")", url: url.absoluteString, renderMode: renderMode, selector: ""))
        }

        selection = .trackers
        mcpIdentifyPresentation = MCPIdentifyPresentation(trackerID: trackerID, url: url, renderMode: renderMode)
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

private enum PreferencesSection: String, CaseIterable, Hashable, Identifiable {
    case trackers
    case widgets
    case browser
    case mcp
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
        case .about:
            return "info.circle"
        }
    }
}

private struct AboutPrefsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("macOS Widgets Stats from Website")
                .font(.title2.weight(.semibold))
            Text("Preferences shell for v0.2.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(28)
        .navigationTitle("About")
    }
}
