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
                        // v0.21.50 — drag-and-drop reorder per voice 4275
                        // (2026-05-27): "I can drag and drop the widgets and
                        // the trackers around in the window the app window
                        // in the list of items. It's just organization."
                        // SwiftUI's native `.onMove` on `ForEach` inside a
                        // `List` provides hover-revealed drag handles on
                        // macOS 13+ — no edit-mode toggle required, no
                        // NSTableView wrapping. Reorder persists via
                        // AppGroupStore.moveWidgetConfigurations which
                        // writes the new order back to trackers.json.
                        // Mirror of the v0.2 .onMove on the trackers list.
                        .onMove(perform: store.moveWidgetConfigurations)
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
            // v0.21.41 — fixed leading icon: only one template + one size
            // (small) exist now, so the size-based icon switch was dead.
            Image(systemName: "square")
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(configuration.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                // v0.21.41 — dropped the template / size segment from the
                // subtitle (no more variants). Just shows bound tracker
                // name(s) now.
                Text(boundTrackerNames)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 10)

            // v0.21.41 — removed the "Text"/"Snapshot" mode capsule. With
            // a single template the mode tag is redundant.

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
    // v0.21.41 — `showTemplatesInfo` was dropped along with the templates
    // info popover. We only ship one template now; nothing to explain.

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

                    // v0.21.41 — the template Picker and the
                    // illustrated-info popover button were removed. Only
                    // one template ships (single-big-number) so there's
                    // nothing to pick. The `draft.templateID` field stays
                    // hard-pinned to `.singleBigNumber` (via the
                    // WidgetConfiguration init default + the decoder
                    // coercion in WidgetTemplate.swift).
                } header: {
                    Text("Configuration")
                } footer: {
                    Text("Small widget · 1 tracker slot. Pick the small size in macOS Edit Widgets.")
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
        // v0.21.41 — the `.onChange(of: draft.templateID)` watcher was
        // removed. It existed to keep `size` / `layout` / `trackerIDs`
        // in sync when the user changed the template picker; with the
        // picker gone and only one template ever in play, there's
        // nothing to react to.
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

/// Per-tracker visual controls. v0.21.41 — radically simplified per
/// voice 4206. Keeps ONLY the accent color picker; the SF Symbol icon
/// field and the value-gradient mode picker were dropped.
///
/// Voice 4206 quote:
///   "What's the s f symbol? I don't see that being used anywhere in
///    the widget. Can we get rid of that? Is that unnecessary?"
///   "And the visual stuff as well at the bottom, that configuration
///    can go. It's kinda oh, actually, what? The color is the color
///    stuff is useful, so keep that."
///
/// Why the SF Symbol field is gone:
///   - It WAS unused by the widget rendering layer (grep confirms zero
///     references to `tracker.icon` in
///     MacosWidgetsStatsFromWebsite/Apps/WidgetExtension/).
///   - It WAS used cosmetically in the slot-radio picker and the
///     trackers-list view — those keep falling back to
///     `Tracker.defaultIcon` (chart.line.uptrend.xyaxis), so removing
///     the picker UI loses no functionality. The `tracker.icon` field
///     stays on the Tracker model for backcompat — existing trackers
///     keep their stored value, but the UI no longer surfaces a way to
///     edit it. Future cleanup: drop the field from the model in a
///     later major.
///
/// Why the gradient picker is gone:
///   - It's "visual stuff" that doesn't affect the simplified widget
///     functionality. The underlying field (`tracker.gradientMode`)
///     stays on the model so any tracker that already had a gradient
///     configured keeps rendering with it via SingleBigNumberTemplate's
///     `gradientStyle` access path. The user just can't change it via
///     UI any more.
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
                // Show the stored icon as a read-only chip so the user can
                // see which icon their tracker is using even though the
                // picker is gone. Falls back to default icon if empty.
                Image(systemName: tracker.icon.isEmpty ? Tracker.defaultIcon : tracker.icon)
                    .foregroundStyle(accentColor)
                    .frame(width: 22)
                Text(tracker.name.isEmpty ? "Untitled tracker" : tracker.name)
                    .font(.body.weight(.medium))
                Spacer()
            }

            // Only the color picker survives the visual cleanup. Ethan
            // explicitly called out "The color is the color stuff is
            // useful, so keep that."
            ColorPicker("Accent color", selection: $accentColor, supportsOpacity: false)
                .onChange(of: accentColor) { newValue in
                    if let hex = newValue.hexString {
                        tracker.accentColorHex = hex
                    }
                }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }
}

// v0.21.41 — `WidgetTemplatesInfoView`, `TemplateIllustration`,
// `MockSparkline`, `MockStatCell`, `MockListRow`, `MockGridCell`, and
// the `WidgetTemplate.illustrationSubtitle` / `illustrationSlotCaption`
// extensions are all gone. They served the illustrated-templates info
// popover that explained what each variant looked like. Voice 4206
// killed templates entirely, so the popover has nothing left to
// illustrate. Pure dead code — removed.

private struct WidgetConfigurationEditorPresentation: Identifiable {
    let id = UUID()
    let mode: WidgetConfigurationEditorView.Mode
    let configuration: WidgetConfiguration
}
