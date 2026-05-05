//
//  WidgetConfigsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Create, edit, and delete widget configurations.
//

import SwiftUI

struct WidgetConfigsView: View {
    var body: some View {
        WidgetConfigurationsView()
    }
}

struct WidgetConfigurationsView: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var selectedConfigurationID: UUID?
    @State private var editorPresentation: WidgetConfigurationEditorPresentation?

    var body: some View {
        ZStack {
            if store.widgetConfigurations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.grid.2x2")
                        .font(.system(size: 38))
                        .foregroundStyle(.secondary)
                    Text("No widget configurations yet")
                        .font(.headline)
                    Text(store.trackers.isEmpty ? "Add a tracker first, then create a widget configuration for the desktop widget picker." : "Create a configuration for each widget instance you want on the desktop.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 430)
                    Button {
                        add()
                    } label: {
                        Label("Create Widget Configuration", systemImage: "plus")
                    }
                    .disabled(store.trackers.isEmpty)
                    Text("After you create a configuration, add the desktop widget from macOS Edit Widgets. Control-click the placed widget and choose Edit “macOS Widgets Stats from Website” if that item appears, then select the configuration. If the menu only says Edit Widgets, remove and add the widget again from this build. Widget configuration requires macOS 14 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                    if store.trackers.isEmpty {
                        Text("Tip: the first-launch wizard creates one tracker and one widget configuration together.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(selection: $selectedConfigurationID) {
                    Section {
                        ForEach(store.widgetConfigurations) { configuration in
                            WidgetConfigurationRow(configuration: configuration, trackers: store.trackers) {
                                edit(configuration)
                            }
                            .tag(configuration.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                edit(configuration)
                            }
                                .contextMenu {
                                    Button("Edit") {
                                        edit(configuration)
                                    }
                                    Button("Duplicate") {
                                        duplicate(configuration)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        delete(configuration)
                                    }
                                }
                        }
                    } footer: {
                        WidgetSetupInstructionsFooter(configurationName: selectedConfiguration?.name ?? store.widgetConfigurations.first?.name)
                    }
                }
            }
        }
        .navigationTitle("Widgets")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    add()
                } label: {
                    Label("Add Widget Configuration", systemImage: "plus")
                }
                .help("Add Widget Configuration")

                Button {
                    editSelected()
                } label: {
                    Label("Edit Widget Configuration", systemImage: "pencil")
                }
                .disabled(selectedConfiguration == nil)
                .help("Edit Widget Configuration")

                Button {
                    if let selectedConfiguration {
                        delete(selectedConfiguration)
                    }
                } label: {
                    Label("Delete Widget Configuration", systemImage: "trash")
                }
                .disabled(selectedConfiguration == nil)
                .help("Delete Widget Configuration")
            }
        }
        .sheet(item: $editorPresentation) { presentation in
            WidgetConfigurationEditorView(
                mode: presentation.mode,
                configuration: presentation.configuration,
                trackers: store.trackers
            ) { savedConfiguration in
                store.upsertWidgetConfiguration(savedConfiguration)
                selectedConfigurationID = savedConfiguration.id
            }
            .frame(width: 560, height: 620)
        }
    }

    private var selectedConfiguration: WidgetConfiguration? {
        guard let selectedConfigurationID else {
            return nil
        }

        return store.widgetConfigurations.first { $0.id == selectedConfigurationID }
    }

    private func add() {
        let template = WidgetTemplate.singleBigNumber
        editorPresentation = WidgetConfigurationEditorPresentation(
            mode: .add,
            configuration: WidgetConfiguration(
                name: "New Widget",
                templateID: template,
                size: template.size,
                layout: template.defaultLayout,
                trackerIDs: store.trackers.prefix(template.slotCount.upperBound).map(\.id)
            )
        )
    }

    private func editSelected() {
        guard let selectedConfiguration else {
            return
        }

        edit(selectedConfiguration)
    }

    private func edit(_ configuration: WidgetConfiguration) {
        selectedConfigurationID = configuration.id
        editorPresentation = WidgetConfigurationEditorPresentation(mode: .edit, configuration: configuration)
    }

    private func duplicate(_ configuration: WidgetConfiguration) {
        var copy = configuration
        copy.id = UUID()
        copy.name = "\(configuration.name) Copy"
        store.addWidgetConfiguration(copy)
        selectedConfigurationID = copy.id
    }

    private func delete(_ configuration: WidgetConfiguration) {
        if selectedConfigurationID == configuration.id {
            selectedConfigurationID = nil
        }

        store.deleteWidgetConfiguration(id: configuration.id)
    }
}

private struct WidgetSetupInstructionsFooter: View {
    let configurationName: String?

    var body: some View {
        Text("Add the widget from macOS Edit Widgets. To bind a saved configuration, Control-click the placed widget and choose Edit “macOS Widgets Stats from Website”, then select \(quotedConfigurationName) from Configuration. If the menu only says Edit Widgets, remove and add the widget again from this build. Widget configuration requires macOS 14 or later.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
    }

    private var quotedConfigurationName: String {
        guard let configurationName, !configurationName.isEmpty else {
            return "the widget configuration you created"
        }

        return "\"\(configurationName)\""
    }
}

private struct WidgetConfigurationRow: View {
    let configuration: WidgetConfiguration
    let trackers: [Tracker]
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(configuration.templateID.displayName) · \(configuration.size.displayName) · \(boundTrackerNames)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            Text(configuration.templateID.mode.rawValue.capitalized)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))

            Button(action: onEdit) {
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .help("Edit \(configuration.name.isEmpty ? "widget configuration" : configuration.name)")
            .accessibilityLabel("Edit widget configuration")
        }
        .padding(.vertical, 5)
    }

    private var boundTrackerNames: String {
        let names = configuration.trackerIDs.compactMap { id in
            trackers.first { $0.id == id }?.name
        }

        return names.isEmpty ? "No trackers" : names.joined(separator: ", ")
    }

    private var iconName: String {
        switch configuration.size {
        case .small:
            return "square"
        case .medium:
            return "rectangle"
        case .large:
            return "rectangle.grid.1x2"
        case .extraLarge:
            return "rectangle.grid.2x2"
        }
    }
}

private struct WidgetConfigurationEditorView: View {
    enum Mode {
        case add
        case edit
    }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: WidgetConfiguration

    let mode: Mode
    let trackers: [Tracker]
    let onSave: (WidgetConfiguration) -> Void

    init(
        mode: Mode,
        configuration: WidgetConfiguration,
        trackers: [Tracker],
        onSave: @escaping (WidgetConfiguration) -> Void
    ) {
        self.mode = mode
        self.trackers = trackers
        self.onSave = onSave
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)

                    Picker("Template", selection: $draft.templateID) {
                        ForEach(WidgetTemplate.allCases, id: \.self) { template in
                            Text(template.displayName).tag(template)
                        }
                    }

                    Picker("Size", selection: $draft.size) {
                        ForEach(WidgetConfigurationSize.allCases, id: \.self) { size in
                            Text(size.displayName).tag(size)
                        }
                    }

                    Picker("Layout", selection: $draft.layout) {
                        ForEach(WidgetConfigurationLayout.allCases, id: \.self) { layout in
                            Text(layout.displayName).tag(layout)
                        }
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("\(draft.templateID.mode.rawValue.capitalized) template · \(slotDescription)")
                }

                Section {
                    Toggle("Show labels", isOn: $draft.showLabels)
                    Toggle("Show sparklines", isOn: $draft.showSparklines)
                } header: {
                    Text("Display")
                }

                Section {
                    if trackers.isEmpty {
                        Text("Add trackers before binding this widget.")
                            .foregroundStyle(.secondary)
                    } else {
                        List(trackers) { tracker in
                            Toggle(isOn: binding(for: tracker.id)) {
                                HStack(spacing: 8) {
                                    Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                                        Text(tracker.renderMode.displayName)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 180)
                    }
                } header: {
                    Text("Tracker Slots")
                } footer: {
                    Text(slotFooterDescription)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding()
        }
        .navigationTitle(mode == .add ? "Add Widget Configuration" : "Edit Widget Configuration")
        .onChange(of: draft.templateID) { template in
            draft.size = template.size
            draft.layout = template.defaultLayout
            draft.trackerIDs = Array(draft.trackerIDs.prefix(template.slotCount.upperBound))
        }
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && draft.templateID.slotCount.contains(draft.trackerIDs.count)
    }

    private var slotDescription: String {
        let range = draft.templateID.slotCount
        if range.lowerBound == range.upperBound {
            return "Requires \(range.lowerBound) tracker\(range.lowerBound == 1 ? "" : "s")."
        }

        return "Requires \(range.lowerBound)-\(range.upperBound) trackers."
    }

    private var slotFooterDescription: String {
        let selected = draft.trackerIDs.count
        let range = draft.templateID.slotCount
        if selected < range.lowerBound {
            return "Selected \(selected). Add \(range.lowerBound - selected) more tracker\((range.lowerBound - selected) == 1 ? "" : "s") to save. \(slotDescription)"
        }
        if selected > range.upperBound {
            return "Selected \(selected). Remove \(selected - range.upperBound) tracker\((selected - range.upperBound) == 1 ? "" : "s") to save. \(slotDescription)"
        }
        return "Selected \(selected). Ready to save. \(slotDescription)"
    }

    private func binding(for trackerID: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.trackerIDs.contains(trackerID) },
            set: { isSelected in
                if isSelected {
                    guard !draft.trackerIDs.contains(trackerID),
                          draft.trackerIDs.count < draft.templateID.slotCount.upperBound else {
                        return
                    }
                    draft.trackerIDs.append(trackerID)
                } else {
                    draft.trackerIDs.removeAll { $0 == trackerID }
                }
            }
        )
    }

    private func save() {
        var savedConfiguration = draft
        savedConfiguration.name = trimmedName
        onSave(savedConfiguration)
        dismiss()
    }
}

private struct WidgetConfigurationEditorPresentation: Identifiable {
    let id = UUID()
    let mode: WidgetConfigurationEditorView.Mode
    let configuration: WidgetConfiguration
}
