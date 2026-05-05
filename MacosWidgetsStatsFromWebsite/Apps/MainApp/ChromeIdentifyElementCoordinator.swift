//
//  ChromeIdentifyElementCoordinator.swift
//  MacosWidgetsStatsFromWebsite
//
//  User-facing Chrome/CDP element capture flow.
//

import SwiftUI

struct ChromeElementCaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ChromeElementCaptureController

    private let onElementCaptured: (ElementPick) -> Void

    init(
        url: URL,
        renderMode: RenderMode,
        onElementCaptured: @escaping (ElementPick) -> Void
    ) {
        _controller = StateObject(wrappedValue: ChromeElementCaptureController(url: url, renderMode: renderMode))
        self.onElementCaptured = onElementCaptured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Identify Element in Chrome")
                    .font(.title3.weight(.semibold))
                Text("The app uses its persistent Chrome/Chromium CDP profile so signed-in pages, Google auth, and dashboard sessions behave like a real browser.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LabeledContent("URL") {
                Text(controller.url.absoluteString)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Chrome will open or reuse the matching tab.", systemImage: "1.circle")
                Label("Sign in or navigate in Chrome if needed.", systemImage: "2.circle")
                Label("Hover the value or region, click it, then confirm the preview here.", systemImage: "3.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if controller.isIdentifying {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.notice ?? "Opening Chrome/CDP picker…")
                        .foregroundStyle(.secondary)
                }
            } else if let notice = controller.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            HStack {
                Button("Cancel") {
                    controller.cancel()
                    dismiss()
                }
                Spacer()
                Button(controller.hasStarted ? "Try Again" : "Open Chrome and Identify") {
                    controller.start()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controller.isIdentifying)
            }
        }
        .padding(22)
        .frame(width: 680)
        .frame(minHeight: 360)
        .onAppear {
            controller.startIfNeeded()
        }
        .onDisappear {
            controller.cancelIfActive()
        }
        .sheet(item: $controller.preview) { preview in
            ElementCapturePreviewSheet(
                preview: preview,
                onUse: {
                    controller.preview = nil
                    onElementCaptured(preview.pick)
                    dismiss()
                },
                onRetry: {
                    controller.preview = nil
                    controller.start()
                }
            )
        }
    }
}

private final class ChromeElementCaptureController: ObservableObject {
    let url: URL
    let renderMode: RenderMode

    @Published var isIdentifying = false
    @Published var notice: String?
    @Published var errorMessage: String?
    @Published var preview: ElementCapturePreview?
    @Published private(set) var hasStarted = false

    private var coordinator: ChromeIdentifyElementCoordinator?
    private var lastTargetID: String?

    init(url: URL, renderMode: RenderMode) {
        self.url = url
        self.renderMode = renderMode
    }

    func startIfNeeded() {
        guard !hasStarted else { return }
        start()
    }

    func start() {
        coordinator?.cancel()
        coordinator = nil
        hasStarted = true
        isIdentifying = true
        notice = "Opening Chrome/CDP picker…"
        errorMessage = nil
        preview = nil

        let nextCoordinator = ChromeIdentifyElementCoordinator(
            renderMode: renderMode,
            onPreviewReady: { [weak self] preview in
                self?.coordinator = nil
                self?.isIdentifying = false
                self?.notice = nil
                self?.errorMessage = nil
                self?.preview = preview
            },
            onError: { [weak self] message, isTerminal in
                self?.errorMessage = message
                if isTerminal {
                    self?.coordinator = nil
                    self?.isIdentifying = false
                    self?.notice = nil
                } else {
                    self?.isIdentifying = true
                }
            },
            onNotice: { [weak self] message in
                self?.notice = message
            },
            onTargetSelected: { [weak self] targetID in
                self?.lastTargetID = targetID
            },
            onCancelled: { [weak self] in
                self?.coordinator = nil
                self?.isIdentifying = false
                self?.notice = "Identify Element canceled."
            }
        )

        coordinator = nextCoordinator
        nextCoordinator.start(url: url, preferredTargetID: lastTargetID)
    }

    func cancel() {
        coordinator?.cancel()
        coordinator = nil
        isIdentifying = false
    }

    func cancelIfActive() {
        guard isIdentifying else { return }
        cancel()
    }
}
