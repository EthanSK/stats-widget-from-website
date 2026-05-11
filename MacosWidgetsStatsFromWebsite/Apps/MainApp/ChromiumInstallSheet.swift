//
//  ChromiumInstallSheet.swift
//  MacosWidgetsStatsFromWebsite
//
//  Defensive UI for the "Chromium not available" path.
//
//  In 0.14.0+ upstream Chromium is bundled INSIDE the .app at build time
//  (see scripts/embed-chromium.sh + Resources/Browsers/Chromium.app), so
//  normal installs never see this sheet. It only appears when the gating
//  view detects the bundled Chromium is missing — i.e. a corrupt install
//  or a build that somehow shipped without the embed phase running.
//
//  The 0.13.x lazy-download path that this sheet originally drove was
//  fundamentally broken under App Sandbox (macOS auto-re-attaches
//  com.apple.quarantine on every touch from the sandboxed app, and the
//  sandbox denies execve from Application Support paths regardless),
//  so the install button no longer downloads anything — it simply
//  rechecks availability and surfaces a clear "reinstall the app" message
//  if Chromium is still missing.
//

import AppKit
import SwiftUI

struct ChromiumInstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = ChromiumInstallViewModel()

    var onCompletion: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label(headerLabel, systemImage: headerIcon)
                    .font(.title3.weight(.semibold))
                Text(headerSubtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            switch viewModel.state {
            case .idle:
                idleBody
            case .downloading(let fraction):
                downloadingBody(fraction: fraction)
            case .completed:
                completedBody
            case .failed(let message):
                failedBody(message: message)
            }

            Spacer(minLength: 8)

            HStack {
                Spacer()
                switch viewModel.state {
                case .idle:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        viewModel.start()
                    } label: {
                        Label("Check Chromium", systemImage: "arrow.clockwise.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .downloading:
                    Button("Hide") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                case .completed:
                    Button("Done") {
                        onCompletion?()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        viewModel.start()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .onChange(of: viewModel.state) { newState in
            if case .completed = newState {
                onCompletion?()
            }
        }
    }

    private var headerLabel: String {
        switch viewModel.state {
        case .completed:
            return "Chromium Available"
        case .failed:
            return "Bundled Chromium Missing"
        default:
            return "Check Chromium"
        }
    }

    private var headerIcon: String {
        switch viewModel.state {
        case .completed:
            return "checkmark.seal"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "arrow.clockwise.circle"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.state {
        case .idle:
            return "This app bundles upstream Chromium inside its own .app so the Identify-in-Chrome flow can launch a Google-sign-in-compatible browser without any extra install steps. This dialog re-checks the bundled Chromium is reachable — normal installs should never see this."
        case .downloading:
            return "Re-checking the bundled Chromium…"
        case .completed:
            return "The bundled Chromium is reachable. You can now open Identify in Chrome from any tracker."
        case .failed:
            return "The bundled Chromium inside the .app is missing or corrupt. Reinstall macOS Widgets Stats from Website from the GitHub release page to restore it."
        }
    }

    private var idleBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "shippingbox")
                    .foregroundStyle(.secondary)
                Text("Chromium is bundled inside Resources/Browsers/Chromium.app at build time — no download, no network, no Application Support extraction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.secondary)
                Text("Signed by the same Apple Developer ID as the outer app, with hardened-runtime + JIT entitlements so V8 / renderer processes start under sandbox.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func downloadingBody(fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: fraction, total: 1.0)
                .progressViewStyle(.linear)
            Text(progressStatusText(fraction: fraction))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var completedBody: some View {
        Label("Chromium installed and ready.", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
            .font(.callout)
    }

    private func failedBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("Reinstall macOS Widgets Stats from Website from the GitHub release page to restore the bundled Chromium.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func progressStatusText(fraction: Double) -> String {
        if fraction <= 0 {
            return "Checking…"
        }
        if fraction >= 0.995 {
            return "Verifying bundled Chromium…"
        }
        return "Checking…"
    }
}

@MainActor
final class ChromiumInstallViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case completed
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    func start() {
        // Idempotent — if the bundled Chromium is already reachable (the
        // expected path in 0.14.0+ installs), short-circuit immediately.
        if ChromeBrowserProfile.shared.chromiumIsAvailable() {
            state = .completed
            return
        }

        // Defensive path — bundled Chromium missing or unreachable. Call
        // installChromium() (now a no-op that just rechecks availability +
        // posts the change notification) so any UI listening for the
        // notification still refreshes. Then surface a clear "reinstall"
        // message rather than a download progress bar.
        state = .downloading(0)
        ChromeBrowserProfile.shared.installChromium(progress: { _ in
            // No-op — the new install path is synchronous and has no
            // intermediate progress.
        }, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if ChromeBrowserProfile.shared.chromiumIsAvailable() {
                    self.state = .completed
                } else {
                    self.state = .failed(
                        "The bundled Chromium inside the .app could not be reached after the recheck. Reinstall macOS Widgets Stats from Website to restore it."
                    )
                }
            case .failure(let error):
                let description = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self.state = .failed(description)
            }
        })
    }
}
