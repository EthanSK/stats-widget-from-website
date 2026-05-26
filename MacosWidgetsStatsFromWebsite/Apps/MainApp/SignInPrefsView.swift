//
//  SignInPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Chrome/CDP profile controls.
//

import AppKit
import SwiftUI

struct SignInPrefsView: View {
    @State private var urlText = ""
    @State private var statusMessage: String?
    @State private var showsResetConfirmation = false
    @State private var chromiumAvailable: Bool = ChromeBrowserProfile.shared.chromiumIsAvailable()
    @State private var isShowingChromiumInstallSheet: Bool = false

    private var browserConfiguration: ChromeBrowserLaunchConfiguration {
        ChromeBrowserProfile.shared.configuration()
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Engine") {
                    Text("Chrome/Chromium via CDP")
                }
                LabeledContent("Profile") {
                    Text(browserConfiguration.profileName)
                        .monospaced()
                }
                LabeledContent("CDP endpoint") {
                    Text(browserConfiguration.cdpURL.absoluteString)
                        .monospaced()
                        .textSelection(.enabled)
                }
                LabeledContent("User data") {
                    Text(browserConfiguration.userDataDirectory.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Text("Trackers, first launch, MCP identify requests, and manual re-identify all use this same local Chrome/Chromium profile. Cookies and page state stay on this Mac.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Browser profile")
            }

            Section {
                if chromiumAvailable {
                    Label("Bundled Chromium detected.", systemImage: "checkmark.seal")
                        .foregroundStyle(.green)
                    Text("The app will use the Chromium browser bundled inside its app bundle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Bundled Chromium is missing.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        // v0.21.36 — user-facing copy rename pass (voice 4189). Legacy
                        // "macOS Widgets Stats from Website" → current "Stats Widget from
                        // Website". File paths + bundle IDs deliberately unchanged.
                        Text("Identify, sign-in, and scraping need the Chromium browser bundled inside this app. Reinstall Stats Widget from Website to restore it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            isShowingChromiumInstallSheet = true
                        } label: {
                            Label("Check Chromium", systemImage: "arrow.clockwise.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                Text("Chromium")
            }

            Section {
                HStack(spacing: 12) {
                    Button("Open Chrome Profile") {
                        openProfileBrowser(url: nil)
                    }

                    Button("Reveal Profile Folder") {
                        revealProfileFolder()
                    }

                    Button("Reset Chrome Profile", role: .destructive) {
                        showsResetConfirmation = true
                    }
                }

                HStack(spacing: 8) {
                    TextField("https://example.com/dashboard", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            openEnteredURL()
                        }
                    Button("Open URL") {
                        openEnteredURL()
                    }
                }

                Text("To track any signed-in dashboard, paste that service's URL here or in a tracker. The app no longer ships vendor-specific shortcut buttons.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Actions")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .navigationTitle("Chrome Profile")
        .alert("Reset Chrome profile?", isPresented: $showsResetConfirmation) {
            Button("Reset Chrome Profile", role: .destructive) {
                resetBrowserData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the app's Chrome/Chromium user-data folder to the Trash. Close any Chrome window opened by this app first if reset fails.")
        }
        .sheet(isPresented: $isShowingChromiumInstallSheet) {
            ChromiumInstallSheet(onCompletion: {
                chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
            })
        }
        .onAppear {
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
        }
        .onReceive(NotificationCenter.default.publisher(for: ChromeBrowserProfile.chromiumAvailabilityDidChangeNotification)) { _ in
            chromiumAvailable = ChromeBrowserProfile.shared.chromiumIsAvailable()
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
        statusMessage = "Opening Chrome profile…"
        ChromeBrowserProfile.shared.openVisibleBrowserTarget(url: url.map(ChromeBrowserProfile.safeInitialURL(for:))) { result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    statusMessage = url == nil ? "Chrome profile opened." : "Opened \(url?.host ?? "URL") in the Chrome profile."
                case .failure(let error):
                    statusMessage = error.localizedDescription
                }
            }
        }
    }

    private func revealProfileFolder() {
        let url = browserConfiguration.userDataDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        statusMessage = "Revealed Chrome profile folder."
    }

    private func resetBrowserData() {
        let url = browserConfiguration.userDataDirectory
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                statusMessage = "Chrome profile is already empty."
                return
            }

            var trashedURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
            statusMessage = "Chrome profile moved to Trash. It will be recreated next time Chrome opens."
        } catch {
            statusMessage = "Could not reset Chrome profile: \(error.localizedDescription)"
        }
    }
}
