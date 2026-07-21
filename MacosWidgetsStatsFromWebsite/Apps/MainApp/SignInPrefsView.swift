//
//  SignInPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Browser-account management and Chrome/CDP sign-in controls.
//

import AppKit
import SwiftUI

struct SignInPrefsView: View {
    @EnvironmentObject private var store: AppGroupStore

    @State private var selectedAccountID: String?
    @State private var urlText = ""
    @State private var statusMessage: String?
    @State private var accountEditor: BrowserAccountEditorPresentation?
    @State private var pendingDestructiveAction: BrowserAccountDestructiveAction?
    @State private var chromiumAvailable: Bool = ChromeBrowserProfile.shared.chromiumIsAvailable()
    @State private var isShowingChromiumInstallSheet = false
    @State private var isWorking = false

    private var selectedAccount: BrowserAccount {
        store.browserAccounts.first(where: { $0.id == selectedAccountID })
            ?? store.browserAccounts.first
            ?? .defaultAccount
    }

    private var browserConfiguration: ChromeBrowserLaunchConfiguration {
        ChromeBrowserProfile.shared.configuration(profileName: selectedAccount.id)
    }

    private var selectedTrackerCount: Int {
        store.trackers.lazy.filter { $0.browserProfile == selectedAccount.id }.count
    }

    var body: some View {
        HStack(spacing: 0) {
            accountList
            Divider()
            accountDetail
        }
        .navigationTitle("Website Logins")
        .sheet(item: $accountEditor) { presentation in
            BrowserAccountEditorSheet(
                presentation: presentation,
                existingAccounts: store.browserAccounts,
                onSave: saveAccount
            )
        }
        .alert(item: $pendingDestructiveAction) { action in
            switch action {
            case .reset(let account):
                return Alert(
                    title: Text("Reset \(account.name)?"),
                    message: Text("This closes the login's browser window and moves its sign-in data to the Trash. Tracked values stay assigned to this login, but you will need to sign in again."),
                    primaryButton: .destructive(Text("Reset Sign-In Data")) {
                        resetBrowserData(for: account)
                    },
                    secondaryButton: .cancel()
                )
            case .remove(let account):
                return Alert(
                    title: Text("Remove \(account.name)?"),
                    message: Text("This closes the login's browser window, moves its browser data to the Trash, and removes the login from Stats Widget from Website."),
                    primaryButton: .destructive(Text("Remove Website Login")) {
                        removeBrowserAccount(account)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
        .sheet(isPresented: $isShowingChromiumInstallSheet) {
            ChromiumInstallSheet(onCompletion: {
                chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            })
        }
        .onAppear {
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            ensureSelection()
        }
        .onChange(of: store.browserAccounts) { _ in
            ensureSelection()
        }
        .onChange(of: selectedAccountID) { _ in
            urlText = ""
            statusMessage = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Website Logins")
                    .font(.headline)
                Spacer()
                Button {
                    accountEditor = .create
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add Website Login")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            List(selection: $selectedAccountID) {
                ForEach(store.browserAccounts) { account in
                    HStack(spacing: 10) {
                        BrowserAccountBadge(account: account, size: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.name)
                                .lineLimit(1)
                            let count = store.trackers.lazy.filter { $0.browserProfile == account.id }.count
                            Text(count == 1 ? "1 tracker" : "\(count) trackers")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if account.isDefault {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.secondary)
                                .help("Original website login")
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(account.id)
                }
            }
            .listStyle(.sidebar)

            Text("Each website login keeps its own cookies and signed-in session. Every tracked value refreshes with the login you choose.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        }
        .frame(minWidth: 225, idealWidth: 245, maxWidth: 280)
    }

    private var accountDetail: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    BrowserAccountBadge(account: selectedAccount, size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(selectedAccount.name)
                                .font(.title2.weight(.semibold))
                            if selectedAccount.isDefault {
                                Text("Default")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text(selectedTrackerCount == 1 ? "Used by 1 tracked value" : "Used by \(selectedTrackerCount) tracked values")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit") {
                        accountEditor = .edit(selectedAccount)
                    }
                }
            }

            Section("Sign in") {
                if chromiumAvailable {
                    Label("Bundled Chromium is ready.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Reinstall Stats Widget from Website to restore Identify, sign-in, and scraping.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Check Chromium") {
                            isShowingChromiumInstallSheet = true
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button("Open \(selectedAccount.name)") {
                        openProfileBrowser(url: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!chromiumAvailable || isWorking)

                    Button("Reveal Data Folder") {
                        revealProfileFolder()
                    }
                    .disabled(isWorking)
                }

                HStack(spacing: 8) {
                    TextField("https://example.com/dashboard", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { openEnteredURL() }
                    Button("Open URL") {
                        openEnteredURL()
                    }
                    .disabled(!chromiumAvailable || isWorking)
                }

                Text("Open this login, sign in to the website, then choose it for a tracked value. Passwords are entered in the browser and are never stored by the widget app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Technical details") {
                LabeledContent("Engine", value: "Chromium via CDP")
                LabeledContent("Profile ID") {
                    Text(selectedAccount.id)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("CDP endpoint") {
                    Text(browserConfiguration.cdpURL.absoluteString)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent("User data") {
                    Text(browserConfiguration.userDataDirectory.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Section("Maintenance") {
                Button("Reset Sign-In Data…", role: .destructive) {
                    pendingDestructiveAction = .reset(selectedAccount)
                }
                .disabled(isWorking)

                if !selectedAccount.isDefault {
                    Button("Remove Website Login…", role: .destructive) {
                        pendingDestructiveAction = .remove(selectedAccount)
                    }
                    .disabled(isWorking || selectedTrackerCount > 0)

                    if selectedTrackerCount > 0 {
                        Text("Move its \(selectedTrackerCount) tracked value\(selectedTrackerCount == 1 ? "" : "s") to another website login before removing it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Closing Chromium and updating account data…")
                            .foregroundStyle(.secondary)
                    }
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ensureSelection() {
        if let selectedAccountID,
           store.browserAccounts.contains(where: { $0.id == selectedAccountID }) {
            return
        }
        selectedAccountID = store.browserAccounts.first?.id ?? Tracker.defaultBrowserProfile
    }

    private func saveAccount(name: String, colorHex: String, editingID: String?) throws {
        if let editingID {
            try store.updateBrowserAccount(id: editingID, name: name, colorHex: colorHex)
            selectedAccountID = editingID
            statusMessage = "Browser account updated."
        } else {
            let account = try store.addBrowserAccount(named: name, colorHex: colorHex)
            selectedAccountID = account.id
            statusMessage = "Created \(account.name). Open it to sign in."
        }
    }

    private func openEnteredURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            openProfileBrowser(url: nil)
            return
        }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            statusMessage = "Enter a valid http or https URL."
            return
        }

        urlText = url.absoluteString
        openProfileBrowser(url: url)
    }

    private func openProfileBrowser(url: URL?) {
        let account = selectedAccount
        isWorking = true
        statusMessage = "Opening \(account.name)…"
        ChromeBrowserProfile.shared.openVisibleBrowserTarget(
            url: url.map(ChromeBrowserProfile.safeInitialURL(for:)),
            profileName: account.id
        ) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    statusMessage = url == nil
                        ? "Opened \(account.name)."
                        : "Opened \(url?.host ?? "the URL") in \(account.name)."
                case .failure(let error):
                    statusMessage = error.localizedDescription
                }
                isWorking = false
            }
        }
    }

    private func revealProfileFolder() {
        let url = browserConfiguration.userDataDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        statusMessage = "Revealed \(selectedAccount.name)'s data folder."
    }

    private func resetBrowserData(for account: BrowserAccount) {
        isWorking = true
        statusMessage = "Closing \(account.name)…"
        ChromeBrowserProfile.shared.terminateProfile(profileName: account.id) {
            DispatchQueue.main.async {
                let dataURL = ChromeBrowserProfile.shared
                    .configuration(profileName: account.id)
                    .userDataDirectory
                do {
                    if FileManager.default.fileExists(atPath: dataURL.path) {
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: dataURL, resultingItemURL: &trashedURL)
                        statusMessage = "Reset \(account.name). Its sign-in data is in the Trash."
                    } else {
                        statusMessage = "\(account.name) is already signed out."
                    }
                } catch {
                    statusMessage = "Could not reset \(account.name): \(error.localizedDescription)"
                }
                isWorking = false
            }
        }
    }

    private func removeBrowserAccount(_ account: BrowserAccount) {
        let trackerCount = store.trackers.lazy.filter { $0.browserProfile == account.id }.count
        guard trackerCount == 0 else {
            statusMessage = BrowserAccountCatalogError
                .accountInUse(name: account.name, trackerCount: trackerCount)
                .localizedDescription
            return
        }

        isWorking = true
        statusMessage = "Closing \(account.name)…"
        ChromeBrowserProfile.shared.terminateProfile(profileName: account.id) {
            DispatchQueue.main.async {
                let profileRoot = ChromeBrowserProfile.shared
                    .configuration(profileName: account.id)
                    .userDataDirectory
                    .deletingLastPathComponent()
                do {
                    // Persist the guarded catalog removal before touching the
                    // profile directory. If a tracker was assigned meanwhile,
                    // or configuration storage fails, the account and its
                    // sign-in data both remain intact.
                    try store.deleteBrowserAccount(id: account.id)
                    selectedAccountID = Tracker.defaultBrowserProfile
                    if FileManager.default.fileExists(atPath: profileRoot.path) {
                        var trashedURL: NSURL?
                        try FileManager.default.trashItem(at: profileRoot, resultingItemURL: &trashedURL)
                    }
                    statusMessage = "Removed \(account.name). Its browser data is in the Trash."
                } catch {
                    if store.browserAccounts.contains(where: { $0.id == account.id }) {
                        statusMessage = "Could not remove \(account.name): \(error.localizedDescription)"
                    } else {
                        statusMessage = "Removed \(account.name), but its browser data could not be moved to the Trash: \(error.localizedDescription)"
                    }
                }
                isWorking = false
            }
        }
    }
}

private enum BrowserAccountDestructiveAction: Identifiable {
    case reset(BrowserAccount)
    case remove(BrowserAccount)

    var id: String {
        switch self {
        case .reset(let account): return "reset-\(account.id)"
        case .remove(let account): return "remove-\(account.id)"
        }
    }
}

private enum BrowserAccountEditorPresentation: Identifiable {
    case create
    case edit(BrowserAccount)

    var id: String {
        switch self {
        case .create: return "create"
        case .edit(let account): return "edit-\(account.id)"
        }
    }

    var account: BrowserAccount? {
        guard case .edit(let account) = self else { return nil }
        return account
    }
}

private struct BrowserAccountEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var colorHex: String
    @State private var errorMessage: String?

    let presentation: BrowserAccountEditorPresentation
    let existingAccounts: [BrowserAccount]
    let onSave: (String, String, String?) throws -> Void

    init(
        presentation: BrowserAccountEditorPresentation,
        existingAccounts: [BrowserAccount],
        onSave: @escaping (String, String, String?) throws -> Void
    ) {
        self.presentation = presentation
        self.existingAccounts = existingAccounts
        self.onSave = onSave
        _name = State(initialValue: presentation.account?.name ?? "")
        _colorHex = State(initialValue: presentation.account?.colorHex ?? BrowserAccount.palette[existingAccounts.count % BrowserAccount.palette.count])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BrowserAccountBadge(account: previewAccount, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.account == nil ? "New Website Login" : "Edit Website Login")
                        .font(.title3.weight(.semibold))
                    Text("Use a name that makes the signed-in identity obvious.")
                        .foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Name", text: $name)
                LabeledContent("Colour") {
                    HStack(spacing: 10) {
                        ForEach(BrowserAccount.palette, id: \.self) { color in
                            Button {
                                colorHex = color
                            } label: {
                                Circle()
                                    .fill(Color(hexString: color) ?? .accentColor)
                                    .frame(width: 22, height: 22)
                                    .overlay {
                                        if color.caseInsensitiveCompare(colorHex) == .orderedSame {
                                            Circle()
                                                .strokeBorder(.primary, lineWidth: 2)
                                                .padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Account colour \(color)")
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(presentation.account == nil ? "Create Account" : "Save Changes") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var previewAccount: BrowserAccount {
        BrowserAccount(
            id: presentation.account?.id ?? "preview",
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "New Account" : name,
            colorHex: colorHex
        )
    }

    private func save() {
        do {
            _ = try BrowserAccountCatalog.validatedName(
                name,
                excludingID: presentation.account?.id,
                existing: existingAccounts
            )
            try onSave(name, colorHex, presentation.account?.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
