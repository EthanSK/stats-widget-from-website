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
                    Text(store.trackers.isEmpty ? "Add a tracker first, then create the widget configuration the desktop widget will show." : "Create or edit the configuration the desktop widget pulls from the app.")
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
                    Text("After you create a configuration, add the desktop widget from macOS Edit Widgets, then choose this configuration in the widget's edit panel. Requires macOS 14 or later.")
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
                        // v0.21.7 perf: precompute a name lookup once per
                        // render instead of doing N×M nested array scans
                        // (one .first per slot × every visible row). Codex
                        // review flagged the old shape as a re-render
                        // hotspot.
                        let trackerNamesByID: [UUID: String] = Dictionary(
                            uniqueKeysWithValues: store.trackers.map { ($0.id, $0.name) }
                        )
                        ForEach(store.widgetConfigurations) { configuration in
                            WidgetConfigurationRow(configuration: configuration, trackerNamesByID: trackerNamesByID) {
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
            // v0.21.7: editor now edits per-tracker visuals (icon, accent,
            // gradient), so the store must be available in the sheet.
            // Sheets don't always inherit env objects on macOS, re-inject.
            .environmentObject(store)
            .frame(width: 620, height: 720)
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
        Text("Add the widget from macOS Edit Widgets, then choose \(quotedConfigurationName) in the placed widget's edit panel. Requires macOS 14 or later.")
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
    let trackerNamesByID: [UUID: String]
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
                Text("\(configuration.templateID.displayName) · \(configuration.templateID.size.displayName) · \(boundTrackerNames)")
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
        // v0.21.7 perf: O(slots) dictionary lookups instead of O(slots × trackers)
        // nested array scans per row render. Map is computed once by the
        // parent list.
        let names = configuration.trackerIDs.compactMap { trackerNamesByID[$0] }
        return names.isEmpty ? "No trackers" : names.joined(separator: ", ")
    }

    private var iconName: String {
        switch configuration.templateID.size {
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

    @EnvironmentObject private var store: AppGroupStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WidgetConfiguration
    @State private var trackerDrafts: [UUID: Tracker]
    @State private var showTemplatesInfo: Bool = false

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
        // Snapshot of bound trackers so the v0.21.7 visual-controls (icon,
        // accent color, gradient) can be edited inside the widget-config
        // editor without round-tripping through TrackerEditorView. Stored
        // back to the AppGroupStore on Save.
        var snapshot: [UUID: Tracker] = [:]
        for tracker in trackers {
            snapshot[tracker.id] = tracker
        }
        _trackerDrafts = State(initialValue: snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $draft.name)

                    // Templates picker with an info-button on the right that
                    // opens an illustrated explainer popover. Added v0.21.7
                    // so new users can see what each template looks like
                    // before committing.
                    HStack {
                        Picker("Template", selection: $draft.templateID) {
                            ForEach(WidgetTemplate.allCases, id: \.self) { template in
                                Text(template.displayName).tag(template)
                            }
                        }
                        Button {
                            showTemplatesInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .symbolRenderingMode(.hierarchical)
                                .imageScale(.large)
                        }
                        .buttonStyle(.borderless)
                        .help("Show illustrations of every widget template")
                        .accessibilityLabel("About widget templates")
                        .popover(isPresented: $showTemplatesInfo, arrowEdge: .trailing) {
                            WidgetTemplatesInfoView()
                        }
                    }
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("\(draft.templateID.size.displayName) widget · \(slotDescription) Pick the matching widget size in macOS Edit Widgets.")
                }

                Section {
                    if trackers.isEmpty {
                        Text("Add trackers before binding this widget.")
                            .foregroundStyle(.secondary)
                    } else {
                        // Per-slot radio button groups (v0.21.7). Each slot
                        // picks exactly one tracker; selection is exclusive
                        // within the slot's radio group. For variable-slot
                        // templates (statsListWatchlist 4-6,
                        // megaDashboardGrid 6-8) we render slots up to the
                        // upper bound and tag the optional ones.
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(0..<slotsShown, id: \.self) { slotIndex in
                                TrackerSlotRadioGroup(
                                    slotIndex: slotIndex,
                                    isOptional: slotIndex >= draft.templateID.slotCount.lowerBound,
                                    trackers: trackers,
                                    selection: slotBinding(for: slotIndex)
                                )

                                // v0.21.9: secondary-text picker. Surfaces
                                // the tracker's secondary elements (if any)
                                // so the user can render extra values next
                                // to the main one (e.g. "resets in 4d"
                                // beside "73% used"). Hidden when the
                                // bound tracker has zero secondary elements
                                // — the typical case for existing trackers
                                // so the editor stays uncluttered.
                                if let trackerID = currentSlotTrackerID(slotIndex),
                                   let tracker = trackers.first(where: { $0.id == trackerID }),
                                   !tracker.secondaryElements.isEmpty {
                                    SecondaryElementPicker(
                                        slotIndex: slotIndex,
                                        tracker: tracker,
                                        selectedIDs: secondaryElementSlotBinding(for: slotIndex)
                                    )
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tracker Slots")
                } footer: {
                    Text(slotFooterDescription)
                }

                // v0.21.7: visual presentation controls (icon, accent
                // color, gradient) moved here from the per-tracker editor.
                // One inline editor card per bound tracker — keeps the
                // visual config in the same place the user is composing
                // the widget.
                if !boundTrackerIDs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(boundTrackerIDs, id: \.self) { trackerID in
                                if let draftTracker = trackerDrafts[trackerID] {
                                    TrackerVisualConfigCard(
                                        tracker: Binding<Tracker>(
                                            get: { trackerDrafts[trackerID] ?? draftTracker },
                                            set: { trackerDrafts[trackerID] = $0 }
                                        )
                                    )
                                }
                            }
                        }
                    } header: {
                        Text("Visuals")
                    } footer: {
                        Text("Icon, accent color, and value gradient apply wherever this tracker is rendered, including other widgets.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
            // Size/layout are now derived from the template (the picker UI
            // for them was removed in v0.17.11 — they were dead controls,
            // never consumed by the widget extension). Keep the persisted
            // fields in sync with the chosen template so MCP clients still
            // see consistent values.
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

    private var slotsShown: Int {
        // Show all slots up to the upper bound. Optional slots are tagged
        // in the row UI so the user knows they don't need to fill every one.
        draft.templateID.slotCount.upperBound
    }

    private var boundTrackerIDs: [UUID] {
        // Preserve assignment order so the visual cards line up with the
        // slot order above.
        draft.trackerIDs
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

    /// Binding for a single slot index — radio-group semantics. Writing
    /// nil removes the slot (only allowed for optional slots beyond the
    /// lowerBound). Writing a tracker ID overwrites that slot.
    private func slotBinding(for slotIndex: Int) -> Binding<UUID?> {
        Binding<UUID?>(
            get: {
                guard slotIndex < draft.trackerIDs.count else { return nil }
                return draft.trackerIDs[slotIndex]
            },
            set: { newValue in
                guard let newValue else {
                    // Removing a slot — only meaningful for optional ones.
                    // Compact the array so downstream consumers see a dense
                    // list.
                    if slotIndex < draft.trackerIDs.count {
                        draft.trackerIDs.remove(at: slotIndex)
                    }
                    return
                }

                // Replace existing slot or append a new one. Same tracker
                // is allowed in multiple slots — templates like
                // dualStatCompare benefit from comparing a tracker against
                // itself with different transforms, and the upstream
                // template renderers don't dedupe.
                if slotIndex < draft.trackerIDs.count {
                    draft.trackerIDs[slotIndex] = newValue
                } else {
                    // Grow the array up to slotIndex by padding with the
                    // first available tracker, then write the chosen one.
                    while draft.trackerIDs.count < slotIndex {
                        if let first = trackers.first?.id {
                            draft.trackerIDs.append(first)
                        } else {
                            break
                        }
                    }
                    draft.trackerIDs.append(newValue)
                }
            }
        )
    }

    private func save() {
        var savedConfiguration = draft
        savedConfiguration.name = trimmedName
        // Persist any visual-control edits the user made in this editor.
        // We update every bound tracker — the store dedupes via the
        // tracker id and the SwiftUI dependency graph will only republish
        // for trackers whose serialised form actually changed.
        for trackerID in draft.trackerIDs {
            if let draftTracker = trackerDrafts[trackerID] {
                store.updateTracker(draftTracker)
            }
        }
        onSave(savedConfiguration)
        dismiss()
    }

    /// v0.21.9: tracker ID currently bound to the given slot (or nil).
    /// Used by the per-slot secondary-element picker to look up the
    /// tracker and read its `secondaryElements` for the dropdown options.
    private func currentSlotTrackerID(_ slotIndex: Int) -> UUID? {
        guard slotIndex < draft.trackerIDs.count else { return nil }
        return draft.trackerIDs[slotIndex]
    }

    /// v0.21.9: SwiftUI binding for the per-slot list of selected secondary
    /// element IDs. Writes back into `draft.secondaryElementIDsBySlot`
    /// keyed by `String(slotIndex)`. Empty list = no secondary text on
    /// this slot.
    private func secondaryElementSlotBinding(for slotIndex: Int) -> Binding<[UUID]> {
        Binding<[UUID]>(
            get: { draft.secondaryElementIDsBySlot[String(slotIndex)] ?? [] },
            set: { newValue in
                if newValue.isEmpty {
                    draft.secondaryElementIDsBySlot.removeValue(forKey: String(slotIndex))
                } else {
                    draft.secondaryElementIDsBySlot[String(slotIndex)] = newValue
                }
            }
        )
    }
}

// MARK: - v0.21.7 helpers

/// Radio-button group for a single tracker slot. Wraps the SwiftUI
/// `.pickerStyle(.radioGroup)` API to keep the per-slot UI consistent.
private struct TrackerSlotRadioGroup: View {
    let slotIndex: Int
    let isOptional: Bool
    let trackers: [Tracker]
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Slot \(slotIndex + 1)")
                    .font(.subheadline.weight(.semibold))
                if isOptional {
                    Text("Optional")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(4)
                }
                Spacer()
                if isOptional && selection != nil {
                    Button {
                        selection = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this slot")
                }
            }

            // Native radio-group picker. Tagging with the tracker UUID
            // (wrapped in Optional for the empty-state) lets SwiftUI bind
            // selection directly without an intermediate index map.
            Picker(selection: $selection) {
                ForEach(trackers) { tracker in
                    HStack(spacing: 8) {
                        Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                            .foregroundStyle(Color(hexString: tracker.accentColorHex) ?? .accentColor)
                            .frame(width: 18)
                        Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(tracker.renderMode.displayName)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .tag(Optional<UUID>(tracker.id))
                }
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

/// v0.21.9: secondary-text picker for a single widget slot. Renders a
/// list of toggles, one per `tracker.secondaryElements` entry, so the
/// user can opt-in any number of secondary values to render alongside
/// the primary on that slot. Empty selection = no secondary text on
/// the slot (the historical behavior every existing widget gets).
///
/// Multiple elements can be selected; the widget rendering layer joins
/// them with a separator. Order follows the tracker's `secondaryElements`
/// array (the order the user added them).
private struct SecondaryElementPicker: View {
    let slotIndex: Int
    let tracker: Tracker
    @Binding var selectedIDs: [UUID]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secondary text for slot \(slotIndex + 1)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(tracker.secondaryElements) { element in
                Toggle(isOn: bindingForElement(element.id)) {
                    HStack(spacing: 6) {
                        Text(element.name.isEmpty ? "Unnamed element" : element.name)
                            .font(.caption)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(element.selector)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if tracker.secondaryElements.isEmpty {
                Text("Tracker has no secondary elements. Add one in the tracker editor.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Text("Picked secondary text appears beside the main value (templates that support it) or below.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(6)
        .padding(.leading, 10)
    }

    private func bindingForElement(_ elementID: UUID) -> Binding<Bool> {
        Binding<Bool>(
            get: { selectedIDs.contains(elementID) },
            set: { isOn in
                if isOn {
                    if !selectedIDs.contains(elementID) {
                        // Preserve the tracker.secondaryElements order so the
                        // widget renders them in the same order they appear
                        // in the tracker editor.
                        let order = tracker.secondaryElements.map(\.id)
                        var union = Set(selectedIDs)
                        union.insert(elementID)
                        selectedIDs = order.filter { union.contains($0) }
                    }
                } else {
                    selectedIDs.removeAll { $0 == elementID }
                }
            }
        )
    }
}

/// Per-tracker visual controls (SF Symbol, accent color, gradient).
/// v0.21.7: relocated here from TrackerEditorView's Presentation section.
private struct TrackerVisualConfigCard: View {
    @Binding var tracker: Tracker
    @State private var accentColor: Color

    init(tracker: Binding<Tracker>) {
        self._tracker = tracker
        let initial = Color(hexString: tracker.wrappedValue.accentColorHex)
            ?? Color(hexString: Tracker.defaultAccentColorHex)
            ?? .accentColor
        self._accentColor = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                    .foregroundStyle(accentColor)
                    .frame(width: 22)
                Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                    .font(.body.weight(.medium))
                Spacer()
            }

            HStack {
                TextField("SF Symbol", text: $tracker.icon)
                Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                    .frame(width: 24)
            }

            ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                .onChange(of: accentColor) { newValue in
                    if let hex = newValue.hexString {
                        tracker.accentColorHex = hex
                    }
                }

            Picker("Value gradient", selection: $tracker.gradientMode) {
                ForEach(GradientMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

/// Illustrated explainer popover for the Templates picker. Each row
/// pairs the template's display name with a tiny SwiftUI mockup that
/// previews its visual structure — single big number, number + sparkline,
/// gauge, snapshot tile, etc. v0.21.7 (frontend-design pass).
private struct WidgetTemplatesInfoView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Widget templates")
                    .font(.title3.weight(.semibold))
                Text("Each template renders one or more trackers differently. Pick the one that matches the story you want to tell on your desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                ForEach(WidgetTemplate.allCases, id: \.self) { template in
                    HStack(alignment: .top, spacing: 12) {
                        TemplateIllustration(template: template)
                            .frame(width: 110, height: 70)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.2))
                            )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.displayName)
                                .font(.subheadline.weight(.semibold))
                            Text(template.illustrationSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(template.illustrationSlotCaption)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(18)
        }
        .frame(width: 420, height: 520)
    }
}

/// Tiny SwiftUI mockup of each template. Composed from primitives so the
/// illustration scales with the popover and doesn't depend on bundled
/// raster assets. Per Ethan voice 3786 (v0.21.7 frontend-design pass).
private struct TemplateIllustration: View {
    let template: WidgetTemplate

    @ViewBuilder
    var body: some View {
        switch template {
        case .singleBigNumber:
            VStack(spacing: 2) {
                Text("87")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                Text("revenue")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .numberPlusSparkline:
            VStack(alignment: .leading, spacing: 4) {
                Text("87")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                MockSparkline()
                    .frame(height: 16)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .gaugeRing:
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("70%")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .padding(10)
        case .liveSnapshotTile:
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.blue.opacity(0.5), .purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text("live")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(4)
                    .foregroundStyle(.white)
            }
        case .headlineSparkline:
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Revenue")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("$2.1k")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                MockSparkline()
                    .frame(height: 22)
            }
            .padding(8)
        case .dualStatCompare:
            HStack(spacing: 6) {
                MockStatCell(label: "Today", value: "87")
                Divider()
                MockStatCell(label: "Yest.", value: "62")
            }
            .padding(8)
        case .dashboard3Up:
            HStack(spacing: 4) {
                MockStatCell(label: "A", value: "12")
                MockStatCell(label: "B", value: "34")
                MockStatCell(label: "C", value: "56")
            }
            .padding(8)
        case .snapshotPlusStat:
            HStack(spacing: 6) {
                Rectangle()
                    .fill(LinearGradient(colors: [.green.opacity(0.6), .teal.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 36)
                    .cornerRadius(4)
                VStack(alignment: .leading) {
                    Text("87")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("active")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(8)
        case .statsListWatchlist:
            VStack(alignment: .leading, spacing: 2) {
                MockListRow(label: "AAPL", value: "182")
                MockListRow(label: "TSLA", value: "215")
                MockListRow(label: "NVDA", value: "905")
                MockListRow(label: "MSFT", value: "428")
            }
            .padding(6)
        case .heroPlusDetail:
            VStack(alignment: .leading, spacing: 4) {
                Text("$2.1k")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("orders today")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                MockSparkline()
                    .frame(height: 12)
            }
            .padding(8)
        case .liveSnapshotHero:
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [.orange.opacity(0.5), .red.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(alignment: .leading) {
                    Text("Live")
                        .font(.system(size: 9, weight: .semibold))
                        .padding(4)
                        .background(Color.white.opacity(0.18))
                        .cornerRadius(3)
                    Spacer()
                    Text("Hero")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.leading, 4)
                        .padding(.bottom, 4)
                }
            }
        case .megaDashboardGrid:
            VStack(spacing: 3) {
                HStack(spacing: 3) {
                    MockGridCell()
                    MockGridCell()
                    MockGridCell()
                    MockGridCell()
                }
                HStack(spacing: 3) {
                    MockGridCell()
                    MockGridCell()
                    MockGridCell()
                    MockGridCell()
                }
            }
            .padding(6)
        }
    }
}

private struct MockSparkline: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let points: [CGFloat] = [0.7, 0.5, 0.65, 0.4, 0.55, 0.3, 0.45, 0.2]
                let dx = geo.size.width / CGFloat(points.count - 1)
                path.move(to: CGPoint(x: 0, y: geo.size.height * points[0]))
                for (i, value) in points.enumerated().dropFirst() {
                    path.addLine(to: CGPoint(x: CGFloat(i) * dx, y: geo.size.height * value))
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}

private struct MockStatCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
            Text(label)
                .font(.system(size: 7))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MockListRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 8, weight: .medium))
            Spacer()
            Text(value)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

private struct MockGridCell: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.accentColor.opacity(0.25))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension WidgetTemplate {
    var illustrationSubtitle: String {
        switch self {
        case .singleBigNumber:
            return "One huge number, perfect for a KPI you want to glance at from across the room."
        case .numberPlusSparkline:
            return "Headline number with a small trend chart underneath."
        case .gaugeRing:
            return "Circular gauge from 0 to 100 — best for percentages or completion ratios."
        case .liveSnapshotTile:
            return "Embeds a live image snapshot of the captured page region."
        case .headlineSparkline:
            return "Caption + headline number + a wider sparkline. Medium-width layout."
        case .dualStatCompare:
            return "Two trackers side-by-side, for compare/contrast (e.g. today vs yesterday)."
        case .dashboard3Up:
            return "Three small numbers in a row — quick overview of three metrics."
        case .snapshotPlusStat:
            return "Image snapshot beside one big number — visual + value."
        case .statsListWatchlist:
            return "A scrollable list of 4-6 trackers, like a watchlist."
        case .heroPlusDetail:
            return "Large hero number with extra detail and a trend chart below."
        case .liveSnapshotHero:
            return "Full-bleed live snapshot of the captured page region."
        case .megaDashboardGrid:
            return "A grid of 6-8 trackers, for a dense full-screen dashboard."
        }
    }

    var illustrationSlotCaption: String {
        let range = slotCount
        if range.lowerBound == range.upperBound {
            return "\(size.displayName) · \(range.lowerBound) slot\(range.lowerBound == 1 ? "" : "s")"
        }

        return "\(size.displayName) · \(range.lowerBound)-\(range.upperBound) slots"
    }
}

private struct WidgetConfigurationEditorPresentation: Identifiable {
    let id = UUID()
    let mode: WidgetConfigurationEditorView.Mode
    let configuration: WidgetConfiguration
}
