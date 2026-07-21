//
//  GettingStartedPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  A calm home screen that keeps the product's end-to-end setup path visible.
//

import SwiftUI

struct GettingStartedPrefsView: View {
    @EnvironmentObject private var store: AppGroupStore
    @State private var showsDesktopInstructions = false

    let onStartGuidedSetup: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                journeyStrip
                setupChecklist
                setupSummary
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Home")
        .sheet(isPresented: $showsDesktopInstructions) {
            DesktopWidgetInstructionsSheet(configurationName: preferredConfigurationName)
        }
    }

    private var journey: SetupJourneyState {
        SetupJourneyState(
            trackerCount: store.trackers.count,
            widgetConfigurationCount: store.widgetConfigurations.count
        )
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 9) {
                Text(heroEyebrow)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Text(heroTitle)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))

                Text(heroDetail)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button(action: onStartGuidedSetup) {
                        Label(primaryActionTitle, systemImage: journey.hasTrackedValue ? "plus" : "sparkles")
                    }
                    .buttonStyle(.borderedProminent)

                    if journey.hasDesktopWidget {
                        Button("How to add it to my desktop") {
                            showsDesktopInstructions = true
                        }
                    }
                }
                .padding(.top, 4)
            }

            Spacer(minLength: 8)

            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 58, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(0.09))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        )
    }

    private var journeyStrip: some View {
        HStack(spacing: 0) {
            JourneyNode(icon: "globe", title: "Open a webpage", detail: "Any page with a number")
            JourneyConnector()
            JourneyNode(icon: "viewfinder", title: "Choose the value", detail: "Click exactly what matters")
            JourneyConnector()
            JourneyNode(icon: "rectangle", title: "See it on your desktop", detail: "The app keeps it refreshed")
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Open a webpage, choose the value, then see it on your desktop")
    }

    private var setupChecklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your setup")
                .font(.title3.weight(.semibold))

            SetupChecklistRow(
                number: 1,
                title: "Choose a value from a webpage",
                detail: journey.hasTrackedValue
                    ? trackedValueSummary
                    : "The guided setup opens the page and lets you click the number you want.",
                isComplete: journey.hasTrackedValue,
                actionTitle: journey.hasTrackedValue ? "Add another" : "Start",
                action: onStartGuidedSetup
            )

            SetupChecklistRow(
                number: 2,
                title: "Prepare the desktop widget",
                detail: journey.hasDesktopWidget
                    ? desktopWidgetSummary
                    : "The app prepares the small widget that will display your value.",
                isComplete: journey.hasDesktopWidget,
                actionTitle: journey.hasTrackedValue && !journey.hasDesktopWidget ? "Prepare" : nil,
                action: prepareDesktopWidget
            )

            SetupChecklistRow(
                number: 3,
                title: "Add it to your Mac desktop",
                detail: "This final step happens in macOS Edit Widgets. It takes about thirty seconds.",
                isComplete: false,
                actionTitle: journey.hasDesktopWidget ? "Show me how" : nil,
                action: { showsDesktopInstructions = true }
            )
        }
    }

    private var setupSummary: some View {
        HStack(spacing: 18) {
            SetupSummaryItem(value: store.trackers.count, label: store.trackers.count == 1 ? "tracked value" : "tracked values")
            Divider().frame(height: 28)
            SetupSummaryItem(value: store.widgetConfigurations.count, label: store.widgetConfigurations.count == 1 ? "desktop widget" : "desktop widgets")
            Divider().frame(height: 28)
            SetupSummaryItem(value: store.browserAccounts.count, label: store.browserAccounts.count == 1 ? "website login" : "website logins")
            Spacer()
        }
        .padding(.top, 2)
        .foregroundStyle(.secondary)
    }

    private var heroEyebrow: String {
        journey.hasTrackedValue ? "Your stats at a glance" : "Let’s set up one useful thing"
    }

    private var heroTitle: String {
        journey.hasTrackedValue ? "Your values, without opening another tab." : "Put one number on your desktop."
    }

    private var heroDetail: String {
        journey.hasTrackedValue
            ? "Stats Widget from Website watches the pages you choose and keeps their important numbers visible on your Mac."
            : "Paste a webpage, click the number you care about, and the app prepares the desktop widget for you."
    }

    private var primaryActionTitle: String {
        journey.hasTrackedValue ? "Add another value" : "Set up my first widget"
    }

    private var trackedValueSummary: String {
        store.trackers.count == 1
            ? "1 value is ready and refreshing in the background."
            : "\(store.trackers.count) values are ready and refreshing in the background."
    }

    private var desktopWidgetSummary: String {
        store.widgetConfigurations.count == 1
            ? "1 widget is ready to add from macOS Edit Widgets."
            : "\(store.widgetConfigurations.count) widgets are ready to add from macOS Edit Widgets."
    }

    private var preferredConfigurationName: String? {
        store.widgetConfigurations.first?.name
    }

    private func prepareDesktopWidget() {
        guard store.widgetConfigurations.isEmpty, let tracker = store.trackers.first else {
            return
        }

        let template = WidgetTemplate.singleBigNumber
        store.addWidgetConfiguration(WidgetConfiguration(
            name: "\(tracker.name) Widget",
            templateID: template,
            size: template.size,
            layout: template.defaultLayout,
            trackerIDs: [tracker.id]
        ))
    }
}

private struct JourneyNode: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct JourneyConnector: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
            .accessibilityHidden(true)
    }
}

private struct SetupChecklistRow: View {
    let number: Int
    let title: String
    let detail: String
    let isComplete: Bool
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(isComplete ? Color.green : Color.secondary.opacity(0.13))
                if isComplete {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            if let actionTitle {
                Button(actionTitle, action: action)
            } else if !isComplete {
                Text("Finish the previous step first")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
    }
}

private struct SetupSummaryItem: View {
    let value: Int
    let label: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text("\(value)")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
        }
    }
}

struct DesktopWidgetInstructionsView: View {
    let configurationName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DesktopInstructionRow(number: 1, text: "Right-click an empty area of your desktop and choose Edit Widgets.")
            DesktopInstructionRow(number: 2, text: "Search for “Stats Widget from Website”.")
            DesktopInstructionRow(number: 3, text: "Drag the small widget onto your desktop.")
            DesktopInstructionRow(number: 4, text: "Right-click the new widget, choose Edit Widget, then select \(quotedConfigurationName).")
        }
    }

    private var quotedConfigurationName: String {
        guard let configurationName, !configurationName.isEmpty else {
            return "the widget you prepared"
        }
        return "“\(configurationName)”"
    }
}

struct DesktopWidgetInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let configurationName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 34))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add your widget to the desktop")
                        .font(.title2.weight(.semibold))
                    Text("The app has prepared it. macOS controls the final placement.")
                        .foregroundStyle(.secondary)
                }
            }

            DesktopWidgetInstructionsView(configurationName: configurationName)

            Text("You can repeat these steps for every widget you create.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 560, height: 410)
    }
}

private struct DesktopInstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }
}
