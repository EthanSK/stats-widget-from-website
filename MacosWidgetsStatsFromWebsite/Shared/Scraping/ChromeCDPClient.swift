//
//  ChromeCDPClient.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Minimal CDP JSON-RPC client. Intentionally uses Runtime.evaluate directly
//  and never sends Runtime.enable, matching the Google-login-safe control style
//  Ethan asked for.
//

import Foundation

enum ChromeCDPClientError: LocalizedError {
    case encodingFailed
    case disconnected
    case invalidMessage
    case protocolError(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Could not encode the CDP command."
        case .disconnected:
            return "The CDP websocket disconnected."
        case .invalidMessage:
            return "The CDP websocket returned an unreadable message."
        case .protocolError(let message):
            return message
        }
    }
}

final class ChromeCDPClient {
    static let pagePreparationDomains = ["Page.enable", "Network.enable", "DOM.enable"]

    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "ChromeCDPClient")
    private var nextID = 1
    private var pending: [Int: (Result<[String: Any], Error>) -> Void] = [:]
    private var isClosed = false

    init(webSocketURL: URL) {
        task = URLSession.shared.webSocketTask(with: webSocketURL)
    }

    func connect() {
        task.resume()
        receiveLoop()
    }

    func prepareOpenClawStylePage(completion: @escaping () -> Void) {
        // Match the useful OpenClaw/CDP setup domains while deliberately
        // leaving Runtime.enable OFF. Runtime.evaluate below is still allowed
        // and is all selector extraction needs. Accessibility.enable is
        // intentionally omitted: the scraper never reads the accessibility
        // tree, and Chromium 150 on macOS 26 has shown native AppKit recursion
        // crashes in this area.
        enableDomains(Self.pagePreparationDomains, completion: completion)
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            self.task.cancel(with: .goingAway, reason: nil)
            self.failPending(ChromeCDPClientError.disconnected)
        }
    }

    /// Send `Page.close` to the connected page-level CDP target so Chromium
    /// drops the tab and frees its memory. Must be called BEFORE `close()` —
    /// once the websocket is cancelled the page-level RPC can no longer be
    /// delivered, and Chromium leaves the tab open as a zombie that consumes
    /// RAM for every subsequent scrape iteration.
    ///
    /// The call is best-effort with a 1-second timeout: in either the success
    /// or timeout case the completion fires exactly once so the caller can
    /// proceed to `close()` + the `/json/close/<id>` REST fallback without
    /// risking a hung scrape.
    func closePageTarget(completion: @escaping (Result<Void, Error>) -> Void) {
        let lock = NSLock()
        var didFinish = false

        func finishOnce(_ result: Result<Void, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard !didFinish else { return }
            didFinish = true
            completion(result)
        }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.0) {
            finishOnce(.failure(ChromeCDPClientError.protocolError("Page.close timed out after 1s")))
        }

        send(method: "Page.close") { result in
            switch result {
            case .success:
                finishOnce(.success(()))
            case .failure(let error):
                finishOnce(.failure(error))
            }
        }
    }

    /// v0.21.47 — fire-and-forget `Page.bringToFront`.
    ///
    /// Called by the Identify-in-Chrome flow after openTab creates a new
    /// page target. Chromium does NOT auto-focus newly-created CDP tabs;
    /// without this the user-visible Chrome window stays on whichever tab
    /// was foregrounded before (typically the launch-spawned `about:blank`
    /// from `--user-data-dir` boot), so the user opens Chrome and sees
    /// `about:blank` instead of the picker page (voice 4269 bug).
    ///
    /// Best-effort: no completion handler is exposed. If Chromium ignores
    /// the call or the websocket is gone, the user still has the
    /// `/json/activate/<id>` REST call as a fallback (issued in
    /// `ChromeIdentifyElementCoordinator.handleTarget`). One of the two
    /// reliably wins in practice on Chromium-150 on macOS 26.
    func sendBringToFront() {
        send(method: "Page.bringToFront") { _ in
            // Intentionally ignored — visual focus is best-effort.
        }
    }

    /// Move the Chromium top-level window that owns `targetID`.
    ///
    /// Chromium on macOS can ignore launch-time `--window-position` /
    /// `--window-size` when the profile restores prior window state. The
    /// Browser domain applies bounds after the target exists, which is the
    /// reliable point for foreground Identify placement.
    func setWindowBoundsForTarget(
        targetID: String,
        bounds: [String: Any],
        timeout: TimeInterval = 2,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let lock = NSLock()
        var didFinish = false

        func finishOnce(_ result: Result<Void, Error>) {
            let shouldFinish: Bool
            lock.lock()
            if didFinish {
                shouldFinish = false
            } else {
                didFinish = true
                shouldFinish = true
            }
            lock.unlock()

            guard shouldFinish else { return }
            completion(result)
        }

        if timeout > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finishOnce(.failure(ChromeCDPClientError.protocolError("Browser.setWindowBounds timed out after \(Int(timeout))s")))
            }
        }

        send(method: "Browser.getWindowForTarget", params: ["targetId": targetID]) { [weak self] result in
            switch result {
            case .success(let response):
                guard let outer = response["result"] as? [String: Any],
                      let windowID = outer["windowId"] as? Int else {
                    finishOnce(.failure(ChromeCDPClientError.invalidMessage))
                    return
                }

                self?.send(
                    method: "Browser.setWindowBounds",
                    params: [
                        "windowId": windowID,
                        "bounds": bounds
                    ]
                ) { result in
                    switch result {
                    case .success:
                        finishOnce(.success(()))
                    case .failure(let error):
                        finishOnce(.failure(error))
                    }
                }
            case .failure(let error):
                finishOnce(.failure(error))
            }
        }
    }

    func evaluate(
        _ expression: String,
        returnByValue: Bool = true,
        completion: @escaping (Result<Any?, Error>) -> Void
    ) {
        // Deliberately do NOT call Runtime.enable. Runtime.evaluate is enough
        // for selector extraction and avoids enabling the full Runtime domain
        // during Google/OAuth pages.
        send(
            method: "Runtime.evaluate",
            params: [
                "expression": expression,
                "returnByValue": returnByValue,
                "awaitPromise": false,
                "userGesture": false
            ]
        ) { result in
            switch result {
            case .success(let response):
                do {
                    completion(.success(try Self.runtimeValue(from: response)))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func captureScreenshot(
        clip: [String: Any]? = nil,
        timeout: TimeInterval = 5,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let lock = NSLock()
        var didFinish = false

        func finishOnce(_ result: Result<Data, Error>) {
            let shouldFinish: Bool
            lock.lock()
            if didFinish {
                shouldFinish = false
            } else {
                didFinish = true
                shouldFinish = true
            }
            lock.unlock()

            guard shouldFinish else { return }
            completion(result)
        }

        if timeout > 0 {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finishOnce(.failure(ChromeCDPClientError.protocolError("Page.captureScreenshot timed out after \(Int(timeout))s")))
            }
        }

        var params: [String: Any] = [
            "format": "png",
            "fromSurface": true,
            "captureBeyondViewport": true
        ]
        if let clip {
            params["clip"] = clip
        }

        send(method: "Page.captureScreenshot", params: params) { result in
            switch result {
            case .success(let response):
                guard let outer = response["result"] as? [String: Any],
                      let base64 = outer["data"] as? String,
                      let data = Data(base64Encoded: base64) else {
                    finishOnce(.failure(ChromeCDPClientError.invalidMessage))
                    return
                }
                finishOnce(.success(data))
            case .failure(let error):
                finishOnce(.failure(error))
            }
        }
    }

    func send(
        method: String,
        params: [String: Any]? = nil,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else {
                completion(.failure(ChromeCDPClientError.disconnected))
                return
            }

            let id = self.nextID
            self.nextID += 1
            var payload: [String: Any] = [
                "id": id,
                "method": method
            ]
            if let params {
                payload["params"] = params
            }

            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let string = String(data: data, encoding: .utf8) else {
                completion(.failure(ChromeCDPClientError.encodingFailed))
                return
            }

            self.pending[id] = completion
            self.task.send(.string(string)) { [weak self] error in
                guard let error else { return }
                self?.queue.async {
                    let callback = self?.pending.removeValue(forKey: id)
                    callback?(.failure(error))
                }
            }
        }
    }

    private func enableDomains(_ methods: [String], completion: @escaping () -> Void) {
        guard let method = methods.first else {
            completion()
            return
        }

        // v0.21.8 item #9: per-CDP-command timing for the page-prep sequence
        // (Page.enable, Network.enable, DOM.enable). The failure mode this
        // catches: a Chromium that ACKs the page-target
        // creation but then never replies to Page.enable, leaving the scrape
        // stuck in `prepareOpenClawStylePage` until the outer 30s timeout
        // fires with no other useful log signal.
        let startedAt = Date()
        ActivityLogger.log("cdp", "enableDomain started", metadata: [
            "method": method
        ])
        send(method: method) { [weak self] result in
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            switch result {
            case .success:
                ActivityLogger.log("cdp", "enableDomain ended", metadata: [
                    "method": method,
                    "elapsedMs": "\(elapsedMs)",
                    "result": "success"
                ])
            case .failure(let error):
                ActivityLogger.log("cdp", "enableDomain ended", metadata: [
                    "method": method,
                    "elapsedMs": "\(elapsedMs)",
                    "result": "failure",
                    "error": error.localizedDescription
                ])
            }
            self?.enableDomains(Array(methods.dropFirst()), completion: completion)
        }
    }

    private func receiveLoop() {
        task.receive { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveLoop()
            case .failure(let error):
                self.queue.async {
                    self.isClosed = true
                    self.failPending(error)
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let string):
            data = string.data(using: .utf8)
        case .data(let payload):
            data = payload
        @unknown default:
            data = nil
        }

        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return
        }

        queue.async { [weak self] in
            guard let callback = self?.pending.removeValue(forKey: id) else {
                return
            }

            if let error = json["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "CDP command failed."
                callback(.failure(ChromeCDPClientError.protocolError(message)))
                return
            }

            callback(.success(json))
        }
    }

    private func failPending(_ error: Error) {
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0(.failure(error)) }
    }

    private static func runtimeValue(from response: [String: Any]) throws -> Any? {
        guard let outer = response["result"] as? [String: Any] else {
            throw ChromeCDPClientError.invalidMessage
        }

        if let exception = outer["exceptionDetails"] as? [String: Any] {
            let text = exception["text"] as? String ?? "Runtime.evaluate threw an exception."
            throw ChromeCDPClientError.protocolError(text)
        }

        guard let result = outer["result"] as? [String: Any] else {
            return nil
        }

        if let unserializable = result["unserializableValue"] as? String {
            return unserializable
        }

        return result["value"]
    }
}
