//
//  MCPServer.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Embedded JSON-RPC MCP server over stdio or a local UNIX socket.
//

import Darwin
import Foundation

extension Notification.Name {
    static let mcpIdentifyElementRequested = Notification.Name("MacosWidgetsStatsFromWebsite.MCP.identifyElementRequested")
    static let mcpConfigurationChanged = Notification.Name("MacosWidgetsStatsFromWebsite.MCP.configurationChanged")
}

final class MCPServer {
    static let shared = MCPServer()

    // Single source of truth for the runtime marketing version: read from
    // Bundle.main.infoDictionary at startup so the only place to bump the
    // version is project.yml's MARKETING_VERSION setting (see settings.base).
    // Cached as a static let so hot paths (initialize, debugDescribe) don't
    // re-hit infoDictionary on every JSON-RPC call.
    static let marketingVersion: String =
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"

    private let socketQueue = DispatchQueue(label: "com.ethansk.macos-widgets-stats-from-website.mcp.socket", qos: .utility)
    private let sessionQueue = DispatchQueue(label: "com.ethansk.macos-widgets-stats-from-website.mcp.sessions", qos: .utility, attributes: .concurrent)
    private var socketFD: Int32 = -1
    private var socketRunning = false

    private init() {}

    @discardableResult
    func rotateLaunchToken() -> String? {
        try? KeychainHelper.rotateMCPToken()
    }

    func currentToken() -> String? {
        try? KeychainHelper.currentMCPToken()
    }

    func startSocketServer() {
        guard !socketRunning else {
            return
        }

        socketRunning = true
        rotateLaunchToken()

        socketQueue.async { [weak self] in
            self?.runSocketServer()
        }
    }

    func stopSocketServer() {
        socketRunning = false
        wakeSocketServerIfNeeded()
    }

    func runStdioServer() {
        let session = MCPConnectionSession(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput,
            transport: .stdio,
            expectedTokenProvider: { nil }
        )
        session.run()
    }

    private func runSocketServer() {
        let socketURL = AppGroupPaths.mcpSocketURL()
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? FileManager.default.removeItem(at: socketURL)
        } catch {
            MCPInvocationLogger.logSystem("socket_setup_failed", detail: error.localizedDescription)
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            MCPInvocationLogger.logSystem("socket_create_failed", detail: String(errno))
            return
        }

        socketFD = fd
        defer {
            if socketFD == fd {
                socketFD = -1
            }
            close(fd)
            try? FileManager.default.removeItem(at: socketURL)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let path = socketURL.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else {
            MCPInvocationLogger.logSystem("socket_path_too_long", detail: path)
            return
        }

        _ = path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pointer, maxPathLength - 1)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            MCPInvocationLogger.logSystem("socket_bind_failed", detail: String(errno))
            return
        }

        chmod(socketURL.path, S_IRUSR | S_IWUSR)

        guard listen(fd, 8) == 0 else {
            MCPInvocationLogger.logSystem("socket_listen_failed", detail: String(errno))
            return
        }

        while socketRunning {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if socketRunning {
                    MCPInvocationLogger.logSystem("socket_accept_failed", detail: String(errno))
                }
                continue
            }

            guard socketRunning else {
                close(clientFD)
                break
            }

            sessionQueue.async {
                let handle = FileHandle(fileDescriptor: clientFD, closeOnDealloc: true)
                let session = MCPConnectionSession(
                    input: handle,
                    output: handle,
                    transport: .unixSocket,
                    expectedTokenProvider: { MCPServer.shared.currentToken() }
                )
                session.run()
            }
        }
    }

    private func wakeSocketServerIfNeeded() {
        guard socketFD >= 0 else {
            try? FileManager.default.removeItem(at: AppGroupPaths.mcpSocketURL())
            return
        }

        let socketURL = AppGroupPaths.mcpSocketURL()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let path = socketURL.path
        let maxPathLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxPathLength else { return }

        _ = path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                tuplePointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                    strncpy(destination, pointer, maxPathLength - 1)
                }
            }
        }

        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

private enum MCPTransport {
    case stdio
    case unixSocket
}

private struct MCPToolContext {
    let transport: MCPTransport

    var supportsInteractiveBrowser: Bool {
        transport == .unixSocket
    }
}

private final class MCPConnectionSession {
    private let input: FileHandle
    private let output: FileHandle
    private let transport: MCPTransport
    private let expectedTokenProvider: () -> String?
    private var isAuthenticated: Bool
    private var usesContentLengthFraming = false
    private var destructiveOperationDates: [Date] = []
    private var operationDatesByTool: [String: [Date]] = [:]

    init(
        input: FileHandle,
        output: FileHandle,
        transport: MCPTransport,
        expectedTokenProvider: @escaping () -> String?
    ) {
        self.input = input
        self.output = output
        self.transport = transport
        self.expectedTokenProvider = expectedTokenProvider
        isAuthenticated = transport == .stdio
    }

    func run() {
        var pendingHeaders: [String: String] = [:]

        while let lineData = readLineData() {
            guard let line = String(data: lineData, encoding: .utf8) else {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if let contentLength = pendingContentLength(from: pendingHeaders) {
                    guard let body = readExactly(byteCount: contentLength) else {
                        return
                    }
                    usesContentLengthFraming = true
                    pendingHeaders.removeAll()
                    handleJSONLine(body)
                }
                continue
            }

            if let header = parseHeaderLine(trimmed) {
                pendingHeaders[header.name.lowercased()] = header.value
                handleAuthenticationHeader(name: header.name, value: header.value)
                if header.name.caseInsensitiveCompare("Content-Length") == .orderedSame {
                    usesContentLengthFraming = true
                }
                continue
            }

            pendingHeaders.removeAll()
            handleJSONLine(Data(trimmed.utf8))
        }
    }

    private func readLineData() -> Data? {
        var data = Data()
        while true {
            let byte = input.readData(ofLength: 1)
            if byte.isEmpty {
                return data.isEmpty ? nil : data
            }

            if byte[byte.startIndex] == 10 {
                return data
            }

            data.append(byte)
        }
    }

    private func readExactly(byteCount: Int) -> Data? {
        guard byteCount >= 0 else {
            return nil
        }

        var data = Data()
        while data.count < byteCount {
            let chunk = input.readData(ofLength: byteCount - data.count)
            if chunk.isEmpty {
                return nil
            }
            data.append(chunk)
        }
        return data
    }

    private func parseHeaderLine(_ line: String) -> (name: String, value: String)? {
        guard !line.hasPrefix("{"),
              let separatorIndex = line.firstIndex(of: ":") else {
            return nil
        }

        let name = String(line[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return nil
        }
        return (name, value)
    }

    private func pendingContentLength(from headers: [String: String]) -> Int? {
        headers["content-length"].flatMap(Int.init)
    }

    private func handleAuthenticationHeader(name: String, value: String) {
        guard name.caseInsensitiveCompare("X-Auth") == .orderedSame else {
            return
        }

        isAuthenticated = tokenMatches(value)
    }

    private func handleJSONLine(_ data: Data) {
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = request["method"] as? String else {
                write(error: MCPError.invalidRequest, id: nil)
                return
            }

            let id = request["id"]
            let params = request["params"] as? [String: Any] ?? [:]

            if method.hasPrefix("notifications/") {
                return
            }

            let result = try handle(method: method, params: params)
            if id != nil {
                write(result: result, id: id)
            }
        } catch let error as MCPError {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"]
            write(error: error, id: id ?? nil)
        } catch {
            let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"]
            write(error: .internalError(error.localizedDescription), id: id ?? nil)
        }
    }

    private func handle(method: String, params: [String: Any]) throws -> Any {
        if method == "initialize" {
            try authenticateIfNeeded(params: params)
            return [
                "protocolVersion": "2024-11-05",
                "serverInfo": [
                    "name": "macos-widgets-stats-from-website",
                    "version": MCPServer.marketingVersion
                ],
                "capabilities": [
                    "tools": [:]
                ]
            ]
        }

        guard isAuthenticated else {
            throw MCPError.unauthorized
        }

        switch method {
        case "tools/list":
            return ["tools": MCPToolCatalog.tools]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw MCPError.invalidParams("Missing tool name.")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            try rateLimit(toolName: name)
            let toolResult = try MCPToolDispatcher.perform(name: name, arguments: arguments, context: MCPToolContext(transport: transport))
            return [
                "content": [
                    [
                        "type": "text",
                        "text": MCPJSON.stringify(toolResult)
                    ]
                ],
                "isError": false
            ]
        default:
            guard MCPToolCatalog.toolNames.contains(method) else {
                throw MCPError.methodNotFound(method)
            }
            try rateLimit(toolName: method)
            return try MCPToolDispatcher.perform(name: method, arguments: params, context: MCPToolContext(transport: transport))
        }
    }

    private func authenticateIfNeeded(params: [String: Any]) throws {
        guard transport == .unixSocket else {
            isAuthenticated = true
            return
        }

        if isAuthenticated {
            return
        }

        let token = (params["token"] as? String)
            ?? ((params["headers"] as? [String: Any])?["X-Auth"] as? String)
            ?? ((params["headers"] as? [String: Any])?["x-auth"] as? String)

        guard let token, tokenMatches(token) else {
            throw MCPError.unauthorized
        }

        isAuthenticated = true
    }

    private func tokenMatches(_ token: String) -> Bool {
        guard let expectedToken = expectedTokenProvider(), !expectedToken.isEmpty else {
            return false
        }

        return token == expectedToken
    }

    private func rateLimit(toolName: String) throws {
        let now = Date()
        let oneMinuteAgo = now.addingTimeInterval(-60)

        var toolDates = operationDatesByTool[toolName, default: []].filter { $0 > oneMinuteAgo }
        guard toolDates.count < 60 else {
            throw MCPError.rateLimited("Too many \(toolName) calls in the last minute.")
        }
        toolDates.append(now)
        operationDatesByTool[toolName] = toolDates

        if MCPToolCatalog.destructiveToolNames.contains(toolName) {
            destructiveOperationDates = destructiveOperationDates.filter { $0 > oneMinuteAgo }
            guard destructiveOperationDates.count < 10 else {
                throw MCPError.rateLimited("Too many destructive MCP operations in the last minute.")
            }
            destructiveOperationDates.append(now)
        }
    }

    private func write(result: Any, id: Any?) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "result": result
        ])
    }

    private func write(error: MCPError, id: Any?) {
        writeJSONObject([
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": [
                "code": error.code,
                "message": error.message
            ]
        ])
    }

    private func writeJSONObject(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }

        if usesContentLengthFraming {
            let header = "Content-Length: \(data.count)\r\n\r\n"
            try? output.write(contentsOf: Data(header.utf8) + data)
        } else {
            var line = data
            line.append(10)
            try? output.write(contentsOf: line)
        }
    }
}

private enum MCPError: Error {
    case invalidRequest
    case invalidParams(String)
    case methodNotFound(String)
    case toolNotFound(String)
    case unauthorized
    case notFound(String)
    case validation(String)
    case rateLimited(String)
    case internalError(String)

    var code: Int {
        switch self {
        case .invalidRequest:
            return -32600
        case .methodNotFound, .toolNotFound:
            return -32601
        case .invalidParams, .validation:
            return -32602
        case .unauthorized:
            return -32001
        case .notFound:
            return -32004
        case .rateLimited:
            return -32029
        case .internalError:
            return -32603
        }
    }

    var message: String {
        switch self {
        case .invalidRequest:
            return "Invalid JSON-RPC request."
        case .invalidParams(let message),
             .validation(let message),
             .rateLimited(let message),
             .internalError(let message):
            return message
        case .methodNotFound(let method):
            return "Method not found: \(method)."
        case .toolNotFound(let tool):
            return "Tool not found: \(tool)."
        case .unauthorized:
            return "Unauthorized MCP socket session. Send the Keychain-backed token in initialize params or an X-Auth header line."
        case .notFound(let message):
            return message
        }
    }
}

private enum MCPToolCatalog {
    static let destructiveToolNames: Set<String> = [
        "add_browser_account",
        "update_browser_account",
        "add_tracker",
        "update_tracker",
        "delete_tracker",
        "update_widget_configuration",
        "delete_widget_configuration",
        "import_selector_pack",
        "attach_webhook",
        "reset_tracker_failure_state",
        "repair_tracker",
        "add_tracker_hook",
        "update_tracker_hook",
        "delete_tracker_hook"
    ]

    static let toolNames = Set(tools.compactMap { $0["name"] as? String })

    static let tools: [[String: Any]] = [
        tool("get_status", "Return MCP server status, browser-account details, data counts, and the available tool names.", [:]),
        tool("list_browser_accounts", "List isolated browser accounts available for tracker sign-in and scraping.", [:]),
        tool("add_browser_account", "Create an isolated browser account. Open it in the app's Browser Accounts screen to sign in before scraping authenticated pages.", [
            "name": stringSchema("Unique user-facing browser account name"),
            "colorHex": stringSchema("Optional six-digit badge colour, e.g. #4C8DFF")
        ], required: ["name"]),
        tool("update_browser_account", "Rename or recolour a browser account without changing its stable profile ID or sign-in data.", [
            "id": stringSchema("Browser account profile ID"),
            "name": stringSchema("Unique user-facing browser account name"),
            "colorHex": stringSchema("Optional six-digit badge colour, e.g. #4C8DFF")
        ], required: ["id"]),
        tool("list_trackers", "Return all trackers with current values, status, and last-updated metadata.", [:]),
        tool("get_tracker", "Return one tracker with current value, sparkline, and full configuration.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("add_tracker", "Add a tracker. Selector is required unless the caller uses identify_element first.", [
            "name": stringSchema("Tracker name"),
            "url": stringSchema("HTTPS URL, or http://localhost for testing"),
            "browserProfile": stringSchema("Browser account profile ID from list_browser_accounts. Defaults to the original Default account."),
            "renderMode": enumSchema(["text", "snapshot"]),
            "selector": stringSchema("CSS selector"),
            "contentSelectorHint": stringSchema("Optional content hint used when the saved CSS selector no longer matches, e.g. session, weekly, or 5h"),
            "elementBoundingBox": boundingBoxSchema(),
            "label": stringSchema("Optional widget label"),
            "icon": stringSchema("SF Symbol name"),
            "accentColorHex": stringSchema("Hex accent color, e.g. #10a37f"),
            "gradientMode": gradientModeSchema(),
            "valueTransform": valueTransformSchema(),
            "valueStripLetters": boolSchema("Remove letters/words from the displayed value. Default true, so values like '99% remaining' render as '99%'."),
            "valueStripPercentSymbol": boolSchema("Remove the percent sign from the displayed value. Default false."),
            "refreshIntervalSec": intSchema("Refresh interval in seconds"),
            "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots"))
        ], required: ["name", "url", "selector"]),
        tool("update_tracker", "Modify tracker fields such as name, URL, label, icon, refresh interval, mode, selector, content fallback hint, element bounds, or hidden snapshot selectors. Includes gradientMode for coloring the big-number value (red↔green sweep based on whether high values are bad or good), valueTransform for displaying e.g. '99% remaining' instead of '1% used', and valueStripLetters/valueStripPercentSymbol for compact widget numbers. Also supports secondaryElements — additional elements scraped from the SAME page that can be bound into a widget slot as secondary text (e.g. a 'Resets …' line under the main number).", [
            "id": stringSchema("Tracker UUID"),
            "name": stringSchema("Tracker name"),
            "url": stringSchema("HTTPS URL, or http://localhost for testing"),
            "browserProfile": stringSchema("Browser account profile ID from list_browser_accounts"),
            "renderMode": enumSchema(["text", "snapshot"]),
            "selector": stringSchema("CSS selector"),
            "contentSelectorHint": stringSchema("Optional content hint used when the saved CSS selector no longer matches, e.g. session, weekly, or 5h"),
            "elementBoundingBox": boundingBoxSchema(),
            "label": stringSchema("Optional widget label"),
            "icon": stringSchema("SF Symbol name"),
            "accentColorHex": stringSchema("Hex accent color, e.g. #10a37f"),
            "gradientMode": gradientModeSchema(),
            "valueTransform": valueTransformSchema(),
            "valueStripLetters": boolSchema("Remove letters/words from the displayed value. Default true, so values like '99% remaining' render as '99%'."),
            "valueStripPercentSymbol": boolSchema("Remove the percent sign from the displayed value. Default false."),
            "refreshIntervalSec": intSchema("Refresh interval in seconds"),
            "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots")),
            "secondaryElements": secondaryElementsSchema()
        ], required: ["id"]),
        tool("delete_tracker", "Delete a tracker and unlink it from widget configurations.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("trigger_scrape", "Force-refresh one tracker now and return the resulting reading.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("reset_tracker_failure_state", "Clear stale/broken failure metadata after a manual selector or sign-in repair, then mark the tracker stale until the next scrape proves it works.", [
            "id": stringSchema("Tracker UUID"),
            "reason": stringSchema("Optional short reason recorded in lastError while the next scrape is pending")
        ], required: ["id"]),
        tool("identify_element", "Open the running app's visible browser and wait for the user to confirm an element. Requires the app socket transport; stdio-only clients cannot show UI.", [
            "trackerId": stringSchema("Existing tracker UUID to update after the user picks an element. Omit to create a pending tracker."),
            "url": stringSchema("HTTPS URL, or http://localhost for testing. Required when trackerId is omitted."),
            "browserProfile": stringSchema("Browser account profile ID. Defaults to the existing tracker's account, or Default for a new tracker."),
            "renderMode": enumSchema(["text", "snapshot"])
        ]),
        tool("list_widget_configurations", "Return all widget compositions.", [:]),
        tool("get_widget_configuration", "Return one widget composition.", [
            "id": stringSchema("Widget configuration UUID")
        ], required: ["id"]),
        tool("update_widget_configuration", "Create or update a widget composition. secondaryElementIDsBySlot binds a tracker's secondary elements into widget slots as secondary text (e.g. show a 'Resets …' line under slot 0's main number).", [
            "id": stringSchema("Widget configuration UUID; optional for create"),
            "name": stringSchema("Configuration name"),
            "templateID": enumSchema(WidgetTemplate.allCases.map(\.rawValue)),
            "size": enumSchema(WidgetConfigurationSize.allCases.map(\.rawValue)),
            "layout": enumSchema(WidgetConfigurationLayout.allCases.map(\.rawValue)),
            "trackerIDs": arraySchema(stringSchema("Tracker UUID")),
            "showSparklines": boolSchema("Whether to show sparkline charts where the template supports them"),
            "showLabels": boolSchema("Whether to show tracker labels"),
            "secondaryElementIDsBySlot": secondaryElementIDsBySlotSchema()
        ]),
        tool("delete_widget_configuration", "Delete a widget composition.", [
            "id": stringSchema("Widget configuration UUID")
        ], required: ["id"]),
        tool("export_selector_pack", "Serialize one tracker as selector pack JSON.", [
            "trackerId": stringSchema("Tracker UUID")
        ], required: ["trackerId"]),
        tool("import_selector_pack", "Add a tracker from selector pack JSON. Scripts are rejected.", [
            "json": [
                "description": "Selector pack object or JSON string",
                "oneOf": [
                    ["type": "object"],
                    ["type": "string"]
                ]
            ]
        ], required: ["json"]),
        tool("attach_webhook", "Set or clear the generic notification webhook.", [
            "url": [
                "type": ["string", "null"],
                "description": "Webhook URL, or null to clear."
            ]
        ], required: ["url"]),
        tool("reload_widget_timelines", "Force every placed WidgetKit widget to reload its timeline. Use after changing tracker/config state from a separate process (e.g. the CLI stdio MCP), or when widgets look stale. Idempotent.", [:]),
        tool("get_widget_diagnostics", "Return a focused diagnostic snapshot for one widget configuration (or every config when id is omitted): bound trackers, their last reading, status, last error, snapshot freshness, and which configuration the placed widget would currently render.", [
            "id": stringSchema("Optional widget configuration UUID. Omit to return diagnostics for every saved configuration.")
        ]),
        tool("repair_tracker", "Repair a misconfigured or wedged tracker. Clears stale snapshot caches, resets the failure counter, optionally rewrites selector / url, then waits for the next scrape to verify. Use when a widget is rendering wrong data, frozen, or stuck on a stale snapshot.", [
            "id": stringSchema("Tracker UUID"),
            "selector": stringSchema("Optional new CSS selector"),
            "url": stringSchema("Optional new URL"),
            "clearSnapshot": boolSchema("Clear cached snapshot before next scrape (default true)"),
            "triggerScrape": boolSchema("Trigger a scrape immediately after repair (default true)")
        ], required: ["id"]),
        tool("list_tracker_hooks", "List the scrape-lifecycle hooks configured on one tracker. Each hook records its trigger ('onSuccess' or 'onFailure'), action kind, payload, enabled state, and last-run telemetry.", [
            "trackerId": stringSchema("Tracker UUID")
        ], required: ["trackerId"]),
        tool("add_tracker_hook", "Add a scrape-lifecycle hook to a tracker. Hooks fire after every scrape — onSuccess after a clean reading, onFailure after any scrape error. Action kinds: 'runShellCommand' (passed to /bin/bash -lc) or 'runAppleScript' (passed to /usr/bin/osascript -e). Hooks see TRACKER_ID, TRACKER_URL, TRACKER_SELECTOR, ERROR_KIND, ERROR_MESSAGE, SCRAPE_VALUE env vars.", [
            "trackerId": stringSchema("Tracker UUID"),
            "name": stringSchema("Hook name (free text)"),
            "trigger": hookTriggerSchema(),
            "actionKind": hookActionKindSchema(),
            "actionPayload": stringSchema("Shell command or AppleScript source. The literal token ${AUTO_REPAIR_SCRIPT} is substituted with the bundled auto-repair script path at run-time."),
            "enabled": boolSchema("Default true.")
        ], required: ["trackerId", "name", "trigger", "actionKind", "actionPayload"]),
        tool("update_tracker_hook", "Update an existing tracker hook. Pass trackerId + hookId; any omitted field is left alone.", [
            "trackerId": stringSchema("Tracker UUID"),
            "hookId": stringSchema("Hook UUID"),
            "name": stringSchema("New name"),
            "trigger": hookTriggerSchema(),
            "actionKind": hookActionKindSchema(),
            "actionPayload": stringSchema("New payload"),
            "enabled": boolSchema("Enable/disable")
        ], required: ["trackerId", "hookId"]),
        tool("delete_tracker_hook", "Delete a tracker hook. Idempotent — succeeds when the hook is already gone.", [
            "trackerId": stringSchema("Tracker UUID"),
            "hookId": stringSchema("Hook UUID")
        ], required: ["trackerId", "hookId"]),
        // ---------------------------------------------------------
        // Sparkle update tools (v0.21.15+, Ethan voice 3991, 2026-05-24)
        //
        // These three tools let an agent end-to-end-verify a Sparkle
        // release pipeline: push tag → CI builds + signs → appcast
        // updates → running app probe sees the new version via
        // `check_for_updates` → agent triggers install via
        // `install_pending_update`. `get_version` is the cheap "what
        // am I running right now" readout that the bump-and-tag script
        // (Sub B) calls before AND after the release to confirm
        // propagation across the fleet.
        //
        // All three require the MainApp socket transport — they go
        // through `MCPUpdateBridge.handler` which is populated by
        // `UpdateController.start()` in the menu-bar host. From CLI
        // stdio (which doesn't link Sparkle and is a one-shot process)
        // they return a clear validation error, same pattern as
        // identify_element guarding the interactive-browser path.
        // ---------------------------------------------------------
        tool(
            "check_for_updates",
            // HIGH 2 + HIGH 3 (Codex xhigh review, voice 3991): the call
            // now waits for Sparkle's actual probe completion (up to 30s)
            // before returning, and `latestAppcastVersion` is populated
            // even when current == latest (Sparkle exposes this via
            // SPULatestAppcastItemFoundKey on the no-update path). Agents
            // can confirm "I'm on the newest" via currentVersion ==
            // latestAppcastVersion && installPending == false, instead
            // of inferring from null fields.
            "Programmatically probe Sparkle for a newer appcast version. Does NOT show any UI — uses Sparkle's `checkForUpdateInformation` probing path. Waits up to 30s for Sparkle's actual probe to complete (timeout falls back to cached state). Returns currentVersion (CFBundleShortVersionString of the running binary), latestAppcastVersion (latest version from the appcast feed — populated for both 'update available' AND 'already up to date' cases; null only before any probe has succeeded), installPending (true iff latestAppcastVersion differs from currentVersion), and hasUpdateAvailable (alias for installPending). Requires the MainApp socket transport.",
            [:]
        ),
        tool(
            "install_pending_update",
            "Trigger install of the pending Sparkle update if one is queued. NOTE: Sparkle's standard user driver surfaces an 'install now / later' dialog on the running app — there is no fully-headless install path on the standard updater. Returns scheduled (true iff an update was found + install was dispatched) and pendingVersion (the version that will be installed). If nothing is pending, returns scheduled=false. Requires the MainApp socket transport.",
            [:]
        ),
        tool(
            "get_version",
            "Read the running binary's version metadata synchronously from Bundle.main.infoDictionary. Returns marketingVersion (CFBundleShortVersionString), buildNumber (CFBundleVersion), and bundleId (CFBundleIdentifier). Cheap probe used by the bump-and-tag release flow to confirm propagation. Works on any MCP transport (stdio or socket) — no Sparkle dependency.",
            [:]
        ),
        // v0.21.43 (Ethan voice 4212, 2026-05-26) — autonomous upgrade
        // orchestrator. One MCP call replaces the old check_for_updates
        // → install_pending_update chain. Flips Sparkle's
        // `automaticallyDownloadsUpdates` flag ON if a newer version
        // is found, so future updates install silently on next app
        // launch. See MCPUpgradeResult / UpdateController.upgradeToLatest
        // docs for the silent-install caveat — `SPUStandardUserDriver`
        // still shows the install-and-relaunch dialog the FIRST time;
        // subsequent updates are dialog-free. Stdio CLI transport
        // proxies this call to the running menu-bar host's Unix socket
        // (see MCPServerProxy), so terminal CC sessions can invoke
        // this tool too without linking Sparkle into the CLI binary.
        tool(
            "upgrade_to_latest",
            "Autonomous one-shot upgrade orchestrator. Probes Sparkle for a newer appcast version, and if one is found: (1) enables Sparkle's `automaticallyDownloadsUpdates` flag so future updates install with NO dialog on relaunch, (2) dispatches Sparkle's install path (the FIRST install in a session may still show an 'install and relaunch' dialog because the standard user driver doesn't support fully-headless first-time install; subsequent updates are silent), and (3) returns a result describing the outcome. Returns upgraded (true iff a newer version was found + install dispatched), reason (`already_latest` | `no_appcast` | `updater_unavailable` when upgraded=false, null when upgraded=true), fromVersion (running CFBundleShortVersionString before dispatch), toVersion (latest appcast version, null on no_appcast), automaticUpdatesEnabled (true iff Sparkle's silent-update flag is now ON), and elapsedMs (total wall-clock duration in milliseconds). Times out at 30s on the Sparkle probe. Use get_version after the menu-bar host has been relaunched to confirm the new version applied.",
            [:]
        )
    ]

    private static func tool(
        _ name: String,
        _ description: String,
        _ properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": true
            ]
        ]
    }

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func intSchema(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    private static func numberSchema(_ description: String) -> [String: Any] {
        ["type": "number", "description": description]
    }

    private static func boolSchema(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    private static func enumSchema(_ values: [String]) -> [String: Any] {
        ["type": "string", "enum": values]
    }

    private static func arraySchema(_ itemSchema: [String: Any]) -> [String: Any] {
        ["type": "array", "items": itemSchema]
    }

    private static func gradientModeSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": GradientMode.allCases.map(\.rawValue),
            "description": "Gradient color for the big-number value text. 'highIsBad' = 0 green → 100 red. 'highIsGood' = 0 red → 100 green. 'none' = default text color (no gradient)."
        ]
    }

    private static func hookTriggerSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": HookTrigger.allCases.map(\.rawValue),
            "description": "When the hook fires. 'onSuccess' = after a clean scrape, 'onFailure' = after any scrape error."
        ]
    }

    private static func hookActionKindSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": HookActionKind.allCases.map(\.rawValue),
            "description": "How to run the hook. 'runShellCommand' passes actionPayload to /bin/bash -lc. 'runAppleScript' passes it to /usr/bin/osascript -e."
        ]
    }

    private static func valueTransformSchema() -> [String: Any] {
        [
            "type": "string",
            "enum": ValueTransform.allCases.map(\.rawValue),
            "description": "Numeric transform applied before rendering. 'none' shows the raw scraped value. 'invertFromHundred' shows (100 - numeric) — useful for usage percentages that should read as 'remaining' instead of 'used'. When using invertFromHundred, you typically also want to flip gradientMode (highIsBad ↔ highIsGood) so the color sweep still matches the new framing."
        ]
    }

    private static func boundingBoxSchema() -> [String: Any] {
        [
            "type": "object",
            "description": "Element bounding box captured by Identify Element",
            "properties": [
                "x": numberSchema("X coordinate in CSS pixels"),
                "y": numberSchema("Y coordinate in CSS pixels"),
                "width": numberSchema("Width in CSS pixels"),
                "height": numberSchema("Height in CSS pixels"),
                "viewportWidth": numberSchema("Viewport width in CSS pixels"),
                "viewportHeight": numberSchema("Viewport height in CSS pixels"),
                "devicePixelRatio": numberSchema("Device pixel ratio")
            ],
            "additionalProperties": false
        ]
    }

    /// v0.21.78 — input schema for `update_tracker`'s `secondaryElements`
    /// array. Mirrors the shape `secondaryElementPayload` EMITS in the read
    /// path so an agent can round-trip (read → tweak one element → send back).
    /// Each entry: omit `id` to ADD a new element (a UUID is generated);
    /// include a known `id` to EDIT that element (field-level merge — only the
    /// keys you send change); include `id` + `_delete: true` to REMOVE one.
    /// The valueParser.type accepts raw | currencyOrNumber | percent — use
    /// `raw` for verbatim text passthrough (e.g. a "Resets Friday" line that
    /// should NOT be coerced to a number).
    private static func secondaryElementsSchema() -> [String: Any] {
        [
            "type": "array",
            "description": "Secondary elements scraped from the same page. Omit id to add; pass a known id to edit (field-merge); pass id + _delete:true to remove. Send [] to clear all. Mirrors the read payload shape.",
            "items": [
                "type": "object",
                "properties": [
                    "id": stringSchema("Existing secondary element UUID. Omit to add a NEW element."),
                    "name": stringSchema("Human-readable label shown in widget-config pickers, e.g. 'Resets'."),
                    "selector": stringSchema("CSS selector for this element on the same page."),
                    "contentSelectorHint": stringSchema("Optional content hint used when the CSS selector no longer matches. Empty string or null clears it."),
                    "elementBoundingBox": boundingBoxSchema(),
                    "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots")),
                    "valueParser": [
                        "type": "object",
                        "description": "How to parse the scraped text. type 'raw' passes verbatim text through; 'currencyOrNumber' parses a number; 'percent' parses a percentage.",
                        "properties": [
                            "type": enumSchema(["raw", "currencyOrNumber", "percent"]),
                            "stripChars": arraySchema(stringSchema("Characters to strip before parsing"))
                        ],
                        "additionalProperties": false
                    ],
                    "_delete": boolSchema("When true (with a matching id), removes this secondary element.")
                ],
                "additionalProperties": true
            ]
        ]
    }

    /// v0.21.78 — input schema for `update_widget_configuration`'s
    /// `secondaryElementIDsBySlot`. Map of slot-index string → array of the
    /// bound tracker's secondary-element UUID strings. "Replace" semantics:
    /// send the COMPLETE desired map; send {} to clear all bindings. Mirrors
    /// the read payload shape so it round-trips.
    private static func secondaryElementIDsBySlotSchema() -> [String: Any] {
        [
            "type": "object",
            "description": "Per-slot secondary-element bindings: keys are slot-index strings ('0','1',…), values are arrays of secondary-element UUID strings from the tracker bound to that slot. Replace semantics — send the full map; {} clears all.",
            "additionalProperties": arraySchema(stringSchema("Secondary element UUID"))
        ]
    }
}

private enum MCPToolDispatcher {
    static func perform(name: String, arguments: [String: Any], context: MCPToolContext) throws -> Any {
        MCPInvocationLogger.logTool(name, arguments: arguments)

        switch name {
        case "get_status":
            return getStatus(context: context)
        case "list_browser_accounts":
            return listBrowserAccounts()
        case "add_browser_account":
            return try addBrowserAccount(arguments)
        case "update_browser_account":
            return try updateBrowserAccount(arguments)
        case "list_trackers":
            return listTrackers()
        case "get_tracker":
            return try getTracker(arguments)
        case "add_tracker":
            return try addTracker(arguments)
        case "update_tracker":
            return try updateTracker(arguments)
        case "delete_tracker":
            return try deleteTracker(arguments)
        case "trigger_scrape":
            return try triggerScrape(arguments)
        case "reset_tracker_failure_state":
            return try resetTrackerFailureState(arguments)
        case "identify_element":
            return try identifyElement(arguments, context: context)
        case "list_widget_configurations":
            return listWidgetConfigurations()
        case "get_widget_configuration":
            return try getWidgetConfiguration(arguments)
        case "update_widget_configuration":
            return try updateWidgetConfiguration(arguments)
        case "delete_widget_configuration":
            return try deleteWidgetConfiguration(arguments)
        case "export_selector_pack":
            return try exportSelectorPack(arguments)
        case "import_selector_pack":
            return try importSelectorPack(arguments)
        case "attach_webhook":
            return try attachWebhook(arguments)
        case "reload_widget_timelines":
            return reloadWidgetTimelines()
        case "get_widget_diagnostics":
            return try getWidgetDiagnostics(arguments)
        case "repair_tracker":
            return try repairTracker(arguments)
        case "list_tracker_hooks":
            return try listTrackerHooks(arguments)
        case "add_tracker_hook":
            return try addTrackerHook(arguments)
        case "update_tracker_hook":
            return try updateTrackerHook(arguments)
        case "delete_tracker_hook":
            return try deleteTrackerHook(arguments)
        // Sparkle update tools — see catalog block above for rationale.
        // All three route through MCPUpdateBridge.handler which the
        // MainApp's UpdateController installs at startup. CLI stdio
        // builds (which don't link Sparkle) leave the bridge nil and
        // these tools throw a clear "transport doesn't support this"
        // error.
        case "check_for_updates":
            return try checkForUpdates(context: context)
        case "install_pending_update":
            return try installPendingUpdate(context: context)
        case "get_version":
            return getVersion()
        // v0.21.43 — autonomous upgrade orchestrator. See tool catalog
        // entry above for the full semantics + silent-install caveat.
        case "upgrade_to_latest":
            return try upgradeToLatest(context: context)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    private static func getStatus(context: MCPToolContext) -> Any {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings
        let health = trackerHealthPayload(trackers: configuration.trackers, readings: readings)
        #if WIDGET_EXTENSION
        let browserProfilePayload: [String: Any] = [
            "engine": "chrome_cdp",
            "name": Tracker.defaultBrowserProfile
        ]
        let browserAccountPayloads = configuration.browserAccounts.map {
            browserAccountPayload($0, trackers: configuration.trackers, includeTechnicalDetails: false)
        }
        #else
        let browserConfiguration = ChromeBrowserProfile.shared.configuration()
        let browserProfilePayload: [String: Any] = [
            "engine": "chrome_cdp",
            "name": browserConfiguration.profileName,
            "cdpURL": browserConfiguration.cdpURL.absoluteString,
            "userDataDirectory": browserConfiguration.userDataDirectory.path
        ]
        let browserAccountPayloads = configuration.browserAccounts.map {
            browserAccountPayload($0, trackers: configuration.trackers, includeTechnicalDetails: true)
        }
        #endif
        return [
            "serverInfo": [
                "name": "macos-widgets-stats-from-website",
                "version": MCPServer.marketingVersion
            ],
            "transport": context.transport == .unixSocket ? "unixSocket" : "stdio",
            "interactiveElementIdentification": context.supportsInteractiveBrowser ? "available" : "requires_app_socket",
            "socketPath": AppGroupPaths.mcpSocketURL().path,
            "browserProfile": browserProfilePayload,
            "browserAccounts": browserAccountPayloads,
            "counts": [
                "trackers": configuration.trackers.count,
                "browserAccounts": configuration.browserAccounts.count,
                "widgetConfigurations": configuration.widgetConfigurations.count
            ],
            "health": health,
            "tools": Array(MCPToolCatalog.toolNames).sorted()
        ]
    }

    private static func listBrowserAccounts() -> Any {
        let configuration = AppGroupStore.loadSharedConfiguration()
        return configuration.browserAccounts.map {
            browserAccountPayload($0, trackers: configuration.trackers, includeTechnicalDetails: true)
        }
    }

    private static func addBrowserAccount(_ arguments: [String: Any]) throws -> Any {
        let name = try stringArgument("name", arguments)
        let requestedColor = (arguments["colorHex"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedColor, !requestedColor.isEmpty,
           BrowserAccountCatalog.normalizedColorHex(requestedColor) == nil {
            throw MCPError.validation("colorHex must be a six-digit hex colour such as #4C8DFF.")
        }

        var created: BrowserAccount?
        let saved = try AppGroupStore.mutateSharedConfiguration { configuration in
            do {
                var account = try BrowserAccountCatalog.makeAccount(
                    named: name,
                    existing: configuration.browserAccounts
                )
                if let requestedColor, !requestedColor.isEmpty {
                    account.colorHex = BrowserAccountCatalog.normalizedColorHex(requestedColor)!
                }
                configuration.browserAccounts.append(account)
                created = account
            } catch let error as BrowserAccountCatalogError {
                throw MCPError.validation(error.localizedDescription)
            }
        }
        let account = try require(created, "Created browser account was not produced.")
        notifyConfigurationChanged()
        return browserAccountPayload(account, trackers: saved.trackers, includeTechnicalDetails: true)
    }

    private static func updateBrowserAccount(_ arguments: [String: Any]) throws -> Any {
        let id = BrowserAccountCatalog.normalizedProfileID(try stringArgument("id", arguments))
        var updated: BrowserAccount?
        let saved = try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.browserAccounts.firstIndex(where: { $0.id == id }) else {
                throw MCPError.notFound("Browser account \(id) was not found.")
            }

            if let rawName = arguments["name"] as? String {
                do {
                    configuration.browserAccounts[index].name = try BrowserAccountCatalog.validatedName(
                        rawName,
                        excludingID: id,
                        existing: configuration.browserAccounts
                    )
                } catch let error as BrowserAccountCatalogError {
                    throw MCPError.validation(error.localizedDescription)
                }
            }
            if let rawColor = arguments["colorHex"] as? String {
                guard let normalizedColor = BrowserAccountCatalog.normalizedColorHex(rawColor) else {
                    throw MCPError.validation("colorHex must be a six-digit hex colour such as #4C8DFF.")
                }
                configuration.browserAccounts[index].colorHex = normalizedColor
            }
            updated = configuration.browserAccounts[index]
        }
        let account = try require(updated, "Updated browser account was not produced.")
        notifyConfigurationChanged()
        return browserAccountPayload(account, trackers: saved.trackers, includeTechnicalDetails: true)
    }

    private static func listTrackers() -> Any {
        let configuration = AppGroupStore.loadSharedConfiguration()
        return configuration.trackers.map { trackerPayload($0, includeHistory: false) }
    }

    private static func getTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }
        return trackerPayload(tracker, includeHistory: true)
    }

    private static func addTracker(_ arguments: [String: Any]) throws -> Any {
        let url = try urlArgument("url", arguments)
        let name = try stringArgument("name", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        let selector = try stringArgument("selector", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPError.validation("Tracker name cannot be empty.")
        }
        guard !selector.isEmpty else {
            throw MCPError.validation("Selector is required. Use identify_element when the user needs to pick it.")
        }

        let configuration = AppGroupStore.loadSharedConfiguration()
        let browserProfile = try resolvedBrowserProfile(
            arguments["browserProfile"],
            fallback: Tracker.defaultBrowserProfile,
            configuration: configuration
        )
        let renderMode = renderModeArgument(arguments["renderMode"]) ?? .text
        let tracker = Tracker(
            name: name,
            url: url.absoluteString,
            browserProfile: browserProfile,
            renderMode: renderMode,
            selector: selector,
            contentSelectorHint: (arguments["contentSelectorHint"] as? String)?.nilIfEmpty,
            elementBoundingBox: try boundingBoxArgument("elementBoundingBox", arguments),
            refreshIntervalSec: intArgument("refreshIntervalSec", arguments),
            label: arguments["label"] as? String,
            icon: (arguments["icon"] as? String)?.nilIfEmpty ?? Tracker.defaultIcon,
            accentColorHex: (arguments["accentColorHex"] as? String)?.nilIfEmpty ?? Tracker.defaultAccentColorHex,
            gradientMode: try gradientModeArgument(arguments["gradientMode"]) ?? Tracker.defaultGradientMode,
            valueTransform: try valueTransformArgument(arguments["valueTransform"]) ?? Tracker.defaultValueTransform,
            valueDisplayOptions: ValueDisplayOptions(
                stripLetters: boolArgument("valueStripLetters", arguments) ?? Tracker.defaultValueDisplayOptions.stripLetters,
                stripPercentSymbol: boolArgument("valueStripPercentSymbol", arguments) ?? Tracker.defaultValueDisplayOptions.stripPercentSymbol
            ),
            hideElements: stringArrayArgument("hideElements", arguments) ?? []
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }
        notifyConfigurationChanged()
        return ["id": tracker.id.uuidString, "tracker": trackerPayload(tracker, includeHistory: true)]
    }

    private static func updateTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        var updatedTracker: Tracker?
        var shouldResetFailureState = false

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.trackers.firstIndex(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }

            var tracker = configuration.trackers[index]
            if let value = arguments["name"] as? String {
                tracker.name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if arguments.keys.contains("url") {
                tracker.url = try urlArgument("url", arguments).absoluteString
                shouldResetFailureState = true
            }
            if arguments.keys.contains("browserProfile") {
                tracker.browserProfile = try resolvedBrowserProfile(
                    arguments["browserProfile"],
                    fallback: tracker.browserProfile,
                    configuration: configuration
                )
                shouldResetFailureState = true
            }
            if let value = arguments["label"] as? String {
                tracker.label = value.nilIfEmpty
            }
            if let value = arguments["icon"] as? String {
                tracker.icon = value.nilIfEmpty ?? Tracker.defaultIcon
            }
            if let value = arguments["accentColorHex"] as? String {
                tracker.accentColorHex = value
            }
            if let mode = try gradientModeArgument(arguments["gradientMode"]) {
                tracker.gradientMode = mode
            }
            if let transform = try valueTransformArgument(arguments["valueTransform"]) {
                tracker.valueTransform = transform
            }
            if let value = boolArgument("valueStripLetters", arguments) {
                tracker.valueDisplayOptions.stripLetters = value
            }
            if let value = boolArgument("valueStripPercentSymbol", arguments) {
                tracker.valueDisplayOptions.stripPercentSymbol = value
            }
            if let value = intArgument("refreshIntervalSec", arguments) {
                tracker.refreshIntervalSec = max(1, value)
            }
            if let mode = renderModeArgument(arguments["renderMode"]) {
                tracker.renderMode = mode
                shouldResetFailureState = true
            }
            if let value = arguments["selector"] as? String {
                tracker.selector = value.trimmingCharacters(in: .whitespacesAndNewlines)
                shouldResetFailureState = true
            }
            if arguments.keys.contains("contentSelectorHint") {
                tracker.contentSelectorHint = (arguments["contentSelectorHint"] as? String)?.nilIfEmpty
                shouldResetFailureState = true
            }
            if arguments.keys.contains("elementBoundingBox") {
                tracker.elementBoundingBox = try boundingBoxArgument("elementBoundingBox", arguments)
                shouldResetFailureState = true
            }
            if let hideElements = stringArrayArgument("hideElements", arguments) {
                tracker.hideElements = hideElements
                shouldResetFailureState = true
            }

            // v0.21.78 (Ethan voice 4501) — MCP write support for secondary
            // elements. Previously update_tracker emitted secondaryElements in
            // the READ payload but had NO parse here, so the field looked
            // settable but was output-only. We now accept a `secondaryElements`
            // array mirroring the read shape and apply edits/adds/removes via
            // the pure `SecondaryElementMCPParser` (which lives in
            // Shared/Models/ so it's unit-testable — the MCP dir is excluded
            // from the test target). Local parse errors are mapped onto the
            // MCP -32602 codes so JSON-RPC clients see a clean error.
            //
            // Any change to secondary elements resets the failure state +
            // forces a fresh scrape, same as primary-selector edits, because a
            // new/changed secondary selector hasn't been proven against the
            // live DOM yet.
            if arguments.keys.contains("secondaryElements") {
                do {
                    tracker.secondaryElements = try SecondaryElementMCPParser.applySecondaryElements(
                        arguments["secondaryElements"],
                        to: tracker.secondaryElements
                    )
                } catch let error as SecondaryElementParseError {
                    // .elementNotFound is semantically a validation/not-found
                    // problem (a real id that doesn't exist); the rest are
                    // malformed-input (-32602). Both surface a clear message.
                    switch error {
                    case .elementNotFound(let message):
                        throw MCPError.validation(message)
                    case .malformedInput(let message), .invalidParserType(let message):
                        throw MCPError.invalidParams(message)
                    }
                }
                shouldResetFailureState = true
            }

            configuration.trackers[index] = tracker
            updatedTracker = tracker
        }

        let tracker = try require(updatedTracker, "Updated tracker was not produced.")
        if shouldResetFailureState {
            try AppGroupStore.resetFailureState(for: tracker.id, reason: "Tracker configuration changed; waiting for the next scrape to verify it.")
        }

        notifyConfigurationChanged()
        return trackerPayload(tracker, includeHistory: true)
    }

    private static func deleteTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)

        try AppGroupStore.mutateSharedConfiguration(allowEmptyOverwrite: true) { configuration in
            guard configuration.trackers.contains(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }
            configuration.trackers.removeAll { $0.id == id }
            configuration.widgetConfigurations = configuration.widgetConfigurations.map { widgetConfiguration in
                var updated = widgetConfiguration
                updated.trackerIDs.removeAll { $0 == id }
                return updated
            }
        }

        notifyConfigurationChanged()
        return ["ok": true]
    }

    private static func triggerScrape(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }
        guard tracker.isScrapeReady else {
            ActivityLogger.log("mcp", "trigger_scrape skipped incomplete tracker", metadata: [
                "reason": "selector-empty",
                "trackerID": tracker.id.uuidString,
                "trackerName": tracker.name
            ])
            throw MCPError.validation("Tracker selector is empty. Finish Identify Element before triggering a scrape.")
        }

        let result = blockingScrape(tracker)
        let reading: TrackerReading
        switch result {
        case .success(let newReading):
            try AppGroupStore.record(reading: newReading, for: tracker)
            reading = newReading
        case .failure(let error):
            reading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
        }

        return readingPayload(reading, includeHistory: true)
    }

    private static func resetTrackerFailureState(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }

        _ = try AppGroupStore.resetFailureState(for: id, reason: arguments["reason"] as? String)
        notifyConfigurationChanged()
        return trackerPayload(tracker, includeHistory: true)
    }

    private static func identifyElement(_ arguments: [String: Any], context: MCPToolContext) throws -> Any {
        guard context.supportsInteractiveBrowser else {
            throw MCPError.validation("identify_element requires the running app socket MCP server so the visible browser can open. Connect to the app's mcp.sock, or use update_tracker with a known selector.")
        }

        let existingTrackerID = try optionalUUIDArgument("trackerId", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        let existingTracker = existingTrackerID.flatMap { id in
            configuration.trackers.first { $0.id == id }
        }
        if let existingTrackerID, existingTracker == nil {
            throw MCPError.notFound("Tracker \(existingTrackerID.uuidString) was not found.")
        }

        let url: URL
        if arguments.keys.contains("url") {
            url = try urlArgument("url", arguments)
        } else if let existingTracker {
            url = try validatedURL(from: existingTracker.url)
        } else {
            throw MCPError.invalidParams("url is required when trackerId is omitted.")
        }

        let renderMode = renderModeArgument(arguments["renderMode"]) ?? existingTracker?.renderMode ?? .text
        let browserProfile = try resolvedBrowserProfile(
            arguments["browserProfile"],
            fallback: existingTracker?.browserProfile ?? Tracker.defaultBrowserProfile,
            configuration: configuration
        )
        let trackerID: UUID
        if let existingTracker {
            trackerID = existingTracker.id
        } else {
            let tracker = Tracker(
                name: "Pending \(url.host ?? "Tracker")",
                url: url.absoluteString,
                browserProfile: browserProfile,
                renderMode: renderMode,
                selector: ""
            )
            trackerID = tracker.id
            try AppGroupStore.mutateSharedConfiguration { configuration in
                configuration.trackers.append(tracker)
            }
            notifyConfigurationChanged()
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .mcpIdentifyElementRequested,
                object: nil,
                userInfo: [
                    "trackerID": trackerID.uuidString,
                    "url": url.absoluteString,
                    "browserProfile": browserProfile,
                    "renderMode": renderMode.rawValue
                ]
            )
        }

        return [
            "trackerId": trackerID.uuidString,
            "status": "awaiting_user",
            "url": url.absoluteString,
            "browserProfile": browserProfile,
            "renderMode": renderMode.rawValue
        ]
    }

    private static func listWidgetConfigurations() -> Any {
        AppGroupStore.loadSharedConfiguration().widgetConfigurations.map(widgetConfigurationPayload)
    }

    private static func getWidgetConfiguration(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let widgetConfiguration = configuration.widgetConfigurations.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Widget configuration \(id.uuidString) was not found.")
        }
        return widgetConfigurationPayload(widgetConfiguration)
    }

    private static func updateWidgetConfiguration(_ arguments: [String: Any]) throws -> Any {
        let id: UUID
        if let idString = arguments["id"] as? String {
            guard let parsedID = UUID(uuidString: idString) else {
                throw MCPError.invalidParams("id must be a valid widget configuration UUID.")
            }
            id = parsedID
        } else {
            id = UUID()
        }

        if arguments.keys.contains("templateID"), widgetTemplateArgument(arguments["templateID"]) == nil {
            throw MCPError.invalidParams("templateID is not a supported widget template.")
        }
        if arguments.keys.contains("size"), widgetSizeArgument(arguments["size"]) == nil {
            throw MCPError.invalidParams("size is not a supported widget size.")
        }
        if arguments.keys.contains("layout"), widgetLayoutArgument(arguments["layout"]) == nil {
            throw MCPError.invalidParams("layout is not a supported widget layout.")
        }

        var updatedConfiguration: WidgetConfiguration?

        try AppGroupStore.mutateSharedConfiguration { configuration in
            let existingIndex = configuration.widgetConfigurations.firstIndex(where: { $0.id == id })
            let template = widgetTemplateArgument(arguments["templateID"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].templateID }
                ?? .singleBigNumber
            let size = widgetSizeArgument(arguments["size"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].size }
                ?? template.size
            let layout = widgetLayoutArgument(arguments["layout"])
                ?? existingIndex.map { configuration.widgetConfigurations[$0].layout }
                ?? template.defaultLayout
            let trackerIDs = try uuidArrayArgument("trackerIDs", arguments)
                ?? existingIndex.map { configuration.widgetConfigurations[$0].trackerIDs }
                ?? []
            let name = (arguments["name"] as? String)
                ?? existingIndex.map { configuration.widgetConfigurations[$0].name }
                ?? "\(template.displayName) Widget"
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmedName.isEmpty else {
                throw MCPError.validation("Widget configuration name cannot be empty.")
            }

            let availableTrackerIDs = Set(configuration.trackers.map(\.id))
            let missingTrackerIDs = trackerIDs.filter { !availableTrackerIDs.contains($0) }
            guard missingTrackerIDs.isEmpty else {
                throw MCPError.validation("Unknown trackerIDs: \(missingTrackerIDs.map(\.uuidString).joined(separator: ", ")).")
            }
            guard template.slotCount.contains(trackerIDs.count) else {
                throw MCPError.validation("\(template.displayName) requires \(slotCountDescription(template.slotCount)); got \(trackerIDs.count).")
            }

            var widgetConfiguration = existingIndex.map { configuration.widgetConfigurations[$0] }
                ?? WidgetConfiguration(name: name, templateID: template)
            widgetConfiguration.id = id
            widgetConfiguration.name = trimmedName
            widgetConfiguration.templateID = template
            widgetConfiguration.size = size
            widgetConfiguration.layout = layout
            widgetConfiguration.trackerIDs = trackerIDs

            if let showSparklines = arguments["showSparklines"] as? Bool {
                widgetConfiguration.showSparklines = showSparklines
            }
            if let showLabels = arguments["showLabels"] as? Bool {
                widgetConfiguration.showLabels = showLabels
            }

            // v0.21.78 (Ethan voice 4501) — MCP write support for per-slot
            // secondary-element bindings. Previously update_widget_configuration
            // emitted secondaryElementIDsBySlot in the READ payload but never
            // parsed it, so binding a secondary element into a widget slot was
            // impossible via MCP. We now accept the full map (slot-index-string
            // → [element UUID string]) and replace the binding. "Replace"
            // semantics (send the COMPLETE desired map) match how the read
            // payload hands the agent the whole current map to edit; send {}
            // to clear all slot bindings. Element-id existence is NOT validated
            // here against the bound tracker's secondaryElements — an id that
            // doesn't resolve simply renders no secondary text (same lenient
            // behaviour the SwiftUI editor + render path already tolerate), so
            // we don't reject a binding just because the tracker's element set
            // is being edited in a separate call.
            if arguments.keys.contains("secondaryElementIDsBySlot") {
                do {
                    widgetConfiguration.secondaryElementIDsBySlot = try SecondaryElementMCPParser.parseSecondaryElementIDsBySlot(
                        arguments["secondaryElementIDsBySlot"]
                    )
                } catch let error as SecondaryElementParseError {
                    throw MCPError.invalidParams(error.message)
                }
            }

            if let existingIndex {
                configuration.widgetConfigurations[existingIndex] = widgetConfiguration
            } else {
                configuration.widgetConfigurations.append(widgetConfiguration)
            }
            updatedConfiguration = widgetConfiguration
        }

        notifyConfigurationChanged()
        return widgetConfigurationPayload(try require(updatedConfiguration, "Updated widget configuration was not produced."))
    }

    private static func deleteWidgetConfiguration(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)

        try AppGroupStore.mutateSharedConfiguration(allowEmptyOverwrite: true) { configuration in
            guard configuration.widgetConfigurations.contains(where: { $0.id == id }) else {
                throw MCPError.notFound("Widget configuration \(id.uuidString) was not found.")
            }
            configuration.widgetConfigurations.removeAll { $0.id == id }
        }

        notifyConfigurationChanged()
        return ["ok": true]
    }

    private static func exportSelectorPack(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("trackerId", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == id }) else {
            throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
        }

        return try SelectorPack(tracker: tracker).jsonObject()
    }

    private static func importSelectorPack(_ arguments: [String: Any]) throws -> Any {
        let pack = try selectorPackArgument(arguments["json"])
        let tracker = try pack.makeTracker()

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.trackers.append(tracker)
        }
        notifyConfigurationChanged()
        return ["trackerId": tracker.id.uuidString]
    }

    private static func attachWebhook(_ arguments: [String: Any]) throws -> Any {
        guard arguments.keys.contains("url") else {
            throw MCPError.invalidParams("url is required; pass null to clear the webhook.")
        }

        let webhookURL: String?
        if arguments["url"] is NSNull {
            webhookURL = nil
        } else if let value = arguments["url"] as? String, let trimmed = value.nilIfEmpty {
            guard isValidWebhookURL(trimmed) else {
                throw MCPError.validation("Webhook URL must be http:// or https:// with a host.")
            }
            webhookURL = trimmed
        } else {
            throw MCPError.invalidParams("url must be a webhook URL string or null.")
        }

        try AppGroupStore.mutateSharedConfiguration { configuration in
            configuration.preferences.notificationChannels.webhook = webhookURL
        }
        notifyConfigurationChanged()
        return ["ok": true]
    }

    /// Forces every placed WidgetKit widget to reload its timeline.
    ///
    /// WidgetCenter must be called from the main app process. We get there
    /// by writing the cross-process reload sentinel into the same
    /// directory BackgroundScheduler already watches for pending scrape
    /// requests — see PendingScrapeRequest.reloadTimelinesSentinel. Works
    /// regardless of which MCP transport the caller is using:
    ///
    /// - Embedded socket: main app sees the file event immediately.
    /// - Stdio (CLI): main app picks it up on the next file-watcher tick
    ///   (typically <50ms after write). If the main app isn't running,
    ///   the sentinel is harmless; the widget gallery and freshly placed
    ///   widgets always read App Group state from disk anyway, and the
    ///   sentinel is cleaned up on next drain.
    private static func reloadWidgetTimelines() -> Any {
        do {
            try PendingScrapeRequestStore.requestScrape(
                trackerID: PendingScrapeRequest.reloadTimelinesSentinel
            )
            return ["ok": true, "queued": true]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// Returns diagnostics for one widget configuration (when id is
    /// provided) or every saved widget configuration (when omitted).
    /// Includes bound trackers + their readings, last error, snapshot
    /// freshness, and a "wouldRender" hint that mirrors the resolution
    /// logic in StatsWidgetProvider.selectConfiguration so the caller can
    /// tell what a placed widget would actually display right now.
    private static func getWidgetDiagnostics(_ arguments: [String: Any]) throws -> Any {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let readings = AppGroupStore.loadReadings().readings

        let configurationsToReport: [WidgetConfiguration]
        if arguments.keys.contains("id") {
            let id = try uuidArgument("id", arguments)
            guard let match = configuration.widgetConfigurations.first(where: { $0.id == id }) else {
                throw MCPError.notFound("Widget configuration \(id.uuidString) was not found.")
            }
            configurationsToReport = [match]
        } else {
            configurationsToReport = configuration.widgetConfigurations
        }

        let now = Date()
        let isoFormatter = ISO8601DateFormatter()

        let widgetReports: [[String: Any]] = configurationsToReport.map { widgetConfiguration in
            let boundTrackers = widgetConfiguration.trackerIDs.compactMap { trackerID in
                configuration.trackers.first { $0.id == trackerID }
            }
            let missingTrackerIDs = widgetConfiguration.trackerIDs.filter { trackerID in
                !configuration.trackers.contains { $0.id == trackerID }
            }

            let trackerReports: [[String: Any]] = boundTrackers.map { tracker in
                let reading = readings[tracker.id.uuidString]
                var trackerReport: [String: Any] = [
                    "id": tracker.id.uuidString,
                    "name": tracker.name,
                    "renderMode": tracker.renderMode.rawValue,
                    "selector": tracker.selector,
                    "url": tracker.url,
                    "refreshIntervalSec": tracker.refreshIntervalSec,
                    "status": reading?.status.rawValue ?? "notReadYet",
                    "currentValue": reading?.currentValue as Any? ?? NSNull(),
                    "lastError": reading?.lastError as Any? ?? NSNull(),
                    "lastUpdatedAt": reading?.lastUpdatedAt.map(isoFormatter.string(from:)) as Any? ?? NSNull(),
                    "consecutiveFailureCount": reading?.consecutiveFailureCount as Any? ?? NSNull(),
                    "snapshotPath": reading?.snapshotPath as Any? ?? NSNull(),
                    "snapshotCachedInMemory": SnapshotSharedCache.shared.data(for: tracker.id) != nil
                ]
                if let snapshotCapturedAt = reading?.snapshotCapturedAt {
                    trackerReport["snapshotCapturedAt"] = isoFormatter.string(from: snapshotCapturedAt)
                    trackerReport["snapshotAgeSec"] = Int(now.timeIntervalSince(snapshotCapturedAt))
                } else {
                    trackerReport["snapshotCapturedAt"] = NSNull()
                    trackerReport["snapshotAgeSec"] = NSNull()
                }
                if let updatedAt = reading?.lastUpdatedAt {
                    trackerReport["valueAgeSec"] = Int(now.timeIntervalSince(updatedAt))
                } else {
                    trackerReport["valueAgeSec"] = NSNull()
                }
                return trackerReport
            }

            var report: [String: Any] = [
                "id": widgetConfiguration.id.uuidString,
                "name": widgetConfiguration.name,
                "templateID": widgetConfiguration.templateID.rawValue,
                "size": widgetConfiguration.size.rawValue,
                "layout": widgetConfiguration.layout.rawValue,
                "showSparklines": widgetConfiguration.showSparklines,
                "showLabels": widgetConfiguration.showLabels,
                "trackerIDs": widgetConfiguration.trackerIDs.map(\.uuidString),
                "boundTrackers": trackerReports,
                "missingTrackerIDs": missingTrackerIDs.map(\.uuidString)
            ]

            // Health summary: did every bound tracker scrape OK recently?
            let okCount = trackerReports.filter { ($0["status"] as? String) == "ok" }.count
            let staleCount = trackerReports.filter { ($0["status"] as? String) == "stale" }.count
            let brokenCount = trackerReports.filter { ($0["status"] as? String) == "broken" }.count
            let notReadCount = trackerReports.filter { ($0["status"] as? String) == "notReadYet" }.count
            report["health"] = [
                "ok": okCount,
                "stale": staleCount,
                "broken": brokenCount,
                "notReadYet": notReadCount,
                "missing": missingTrackerIDs.count
            ]
            return report
        }

        return [
            "configurations": widgetReports,
            "totalConfigurations": configuration.widgetConfigurations.count,
            "totalTrackers": configuration.trackers.count
        ]
    }

    /// Repairs a misconfigured/wedged tracker. Optionally rewrites url/
    /// selector, clears the in-memory snapshot cache, resets failure
    /// counters, and (by default) triggers an immediate scrape so the
    /// repair is visible without waiting for the next scheduled tick.
    private static func repairTracker(_ arguments: [String: Any]) throws -> Any {
        let id = try uuidArgument("id", arguments)
        let clearSnapshot = (arguments["clearSnapshot"] as? Bool) ?? true
        let triggerScrape = (arguments["triggerScrape"] as? Bool) ?? true

        var updatedTracker: Tracker?
        var changedFields: [String] = []

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.trackers.firstIndex(where: { $0.id == id }) else {
                throw MCPError.notFound("Tracker \(id.uuidString) was not found.")
            }

            var tracker = configuration.trackers[index]

            if arguments.keys.contains("url") {
                tracker.url = try urlArgument("url", arguments).absoluteString
                changedFields.append("url")
            }
            if let value = arguments["selector"] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw MCPError.validation("Selector cannot be empty when supplied to repair_tracker.")
                }
                tracker.selector = trimmed
                changedFields.append("selector")
            }

            configuration.trackers[index] = tracker
            updatedTracker = tracker
        }

        let tracker = try require(updatedTracker, "repair_tracker could not load tracker.")

        if clearSnapshot {
            SnapshotSharedCache.shared.remove(for: id)
            changedFields.append("snapshotCache")
        }

        _ = try AppGroupStore.resetFailureState(
            for: id,
            reason: "repair_tracker invoked; waiting for next scrape to verify."
        )
        changedFields.append("failureState")

        notifyConfigurationChanged()

        var payload: [String: Any] = [
            "ok": true,
            "trackerId": id.uuidString,
            "changedFields": changedFields,
            "tracker": trackerPayload(tracker, includeHistory: true)
        ]

        if triggerScrape {
            let result = blockingScrape(tracker)
            let reading: TrackerReading
            switch result {
            case .success(let newReading):
                try AppGroupStore.record(reading: newReading, for: tracker)
                reading = newReading
            case .failure(let error):
                reading = try AppGroupStore.recordFailure(message: error.localizedDescription, for: tracker)
            }
            payload["postRepairReading"] = readingPayload(reading, includeHistory: true)
        }

        // Always poke the widget timelines so the repaired state surfaces
        // without waiting for the next 5-min tick.
        _ = reloadWidgetTimelines()

        return payload
    }

    // MARK: - Tracker hook tools (v0.18.0+)

    private static func listTrackerHooks(_ arguments: [String: Any]) throws -> Any {
        let trackerID = try uuidArgument("trackerId", arguments)
        let configuration = AppGroupStore.loadSharedConfiguration()
        guard let tracker = configuration.trackers.first(where: { $0.id == trackerID }) else {
            throw MCPError.notFound("Tracker \(trackerID.uuidString) was not found.")
        }
        return [
            "trackerId": trackerID.uuidString,
            "onSuccess": tracker.hooks.onSuccess.map(hookPayload),
            "onFailure": tracker.hooks.onFailure.map(hookPayload)
        ]
    }

    private static func addTrackerHook(_ arguments: [String: Any]) throws -> Any {
        let trackerID = try uuidArgument("trackerId", arguments)
        let name = try stringArgument("name", arguments).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MCPError.validation("Hook name cannot be empty.")
        }
        let trigger = try hookTriggerArgument(arguments["trigger"])
        let actionKind = try hookActionKindArgument(arguments["actionKind"])
        let actionPayload = try stringArgument("actionPayload", arguments)
        guard !actionPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPError.validation("Hook actionPayload cannot be empty.")
        }
        let enabled = (arguments["enabled"] as? Bool) ?? true

        let hook = TrackerHook(
            name: name,
            trigger: trigger,
            actionKind: actionKind,
            actionPayload: actionPayload,
            enabled: enabled
        )

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let index = configuration.trackers.firstIndex(where: { $0.id == trackerID }) else {
                throw MCPError.notFound("Tracker \(trackerID.uuidString) was not found.")
            }
            switch trigger {
            case .onSuccess:
                configuration.trackers[index].hooks.onSuccess.append(hook)
            case .onFailure:
                configuration.trackers[index].hooks.onFailure.append(hook)
            }
        }
        notifyConfigurationChanged()
        return ["hookId": hook.id.uuidString, "hook": hookPayload(hook)]
    }

    private static func updateTrackerHook(_ arguments: [String: Any]) throws -> Any {
        let trackerID = try uuidArgument("trackerId", arguments)
        let hookID = try uuidArgument("hookId", arguments)

        var updatedHook: TrackerHook?

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let trackerIndex = configuration.trackers.firstIndex(where: { $0.id == trackerID }) else {
                throw MCPError.notFound("Tracker \(trackerID.uuidString) was not found.")
            }
            var tracker = configuration.trackers[trackerIndex]

            let succeeded = try updateHookInList(&tracker.hooks.onSuccess, hookID: hookID, arguments: arguments)
                || (try updateHookInList(&tracker.hooks.onFailure, hookID: hookID, arguments: arguments))
            guard succeeded else {
                throw MCPError.notFound("Hook \(hookID.uuidString) was not found on tracker \(trackerID.uuidString).")
            }

            // If trigger changed, move the hook between lists. We detect
            // this by looking for the hook in the "wrong" list relative
            // to its updated trigger.
            if let hook = (tracker.hooks.onSuccess + tracker.hooks.onFailure).first(where: { $0.id == hookID }) {
                let needsMove: Bool
                switch hook.trigger {
                case .onSuccess: needsMove = !tracker.hooks.onSuccess.contains(where: { $0.id == hookID })
                case .onFailure: needsMove = !tracker.hooks.onFailure.contains(where: { $0.id == hookID })
                }
                if needsMove {
                    tracker.hooks.onSuccess.removeAll { $0.id == hookID }
                    tracker.hooks.onFailure.removeAll { $0.id == hookID }
                    switch hook.trigger {
                    case .onSuccess: tracker.hooks.onSuccess.append(hook)
                    case .onFailure: tracker.hooks.onFailure.append(hook)
                    }
                }
                updatedHook = hook
            }

            configuration.trackers[trackerIndex] = tracker
        }

        notifyConfigurationChanged()
        guard let hook = updatedHook else {
            throw MCPError.internalError("update_tracker_hook lost the updated hook in flight.")
        }
        return ["hookId": hook.id.uuidString, "hook": hookPayload(hook)]
    }

    /// Helper: applies argument overrides to a hook found in `list` and
    /// returns true when the hook was found (regardless of whether any
    /// field actually changed). Throws on bad argument types.
    private static func updateHookInList(_ list: inout [TrackerHook], hookID: UUID, arguments: [String: Any]) throws -> Bool {
        guard let index = list.firstIndex(where: { $0.id == hookID }) else {
            return false
        }
        var hook = list[index]
        if let value = arguments["name"] as? String {
            hook.name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if arguments.keys.contains("trigger") {
            hook.trigger = try hookTriggerArgument(arguments["trigger"])
        }
        if arguments.keys.contains("actionKind") {
            hook.actionKind = try hookActionKindArgument(arguments["actionKind"])
        }
        if let value = arguments["actionPayload"] as? String {
            hook.actionPayload = value
        }
        if let value = arguments["enabled"] as? Bool {
            hook.enabled = value
        }
        list[index] = hook
        return true
    }

    private static func deleteTrackerHook(_ arguments: [String: Any]) throws -> Any {
        let trackerID = try uuidArgument("trackerId", arguments)
        let hookID = try uuidArgument("hookId", arguments)

        try AppGroupStore.mutateSharedConfiguration { configuration in
            guard let trackerIndex = configuration.trackers.firstIndex(where: { $0.id == trackerID }) else {
                throw MCPError.notFound("Tracker \(trackerID.uuidString) was not found.")
            }
            configuration.trackers[trackerIndex].hooks.onSuccess.removeAll { $0.id == hookID }
            configuration.trackers[trackerIndex].hooks.onFailure.removeAll { $0.id == hookID }
        }
        notifyConfigurationChanged()
        return ["ok": true]
    }

    private static func hookTriggerArgument(_ value: Any?) throws -> HookTrigger {
        guard let raw = value as? String, let trigger = HookTrigger(rawValue: raw) else {
            let valid = HookTrigger.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams("trigger must be one of \(valid).")
        }
        return trigger
    }

    private static func hookActionKindArgument(_ value: Any?) throws -> HookActionKind {
        guard let raw = value as? String, let kind = HookActionKind(rawValue: raw) else {
            let valid = HookActionKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams("actionKind must be one of \(valid).")
        }
        return kind
    }

    private static func hookPayload(_ hook: TrackerHook) -> [String: Any] {
        var payload: [String: Any] = [
            "id": hook.id.uuidString,
            "name": hook.name,
            "trigger": hook.trigger.rawValue,
            "actionKind": hook.actionKind.rawValue,
            "actionPayload": hook.actionPayload,
            "enabled": hook.enabled
        ]
        if let builtIn = hook.builtInIdentifier {
            payload["builtInIdentifier"] = builtIn
        }
        if let lastRun = hook.lastRun {
            payload["lastRun"] = hookLastRunPayload(lastRun)
        }
        return payload
    }

    private static func hookLastRunPayload(_ lastRun: HookLastRun) -> [String: Any] {
        var payload: [String: Any] = [
            "startedAt": ISO8601DateFormatter().string(from: lastRun.startedAt),
            "status": lastRun.status.rawValue
        ]
        if let finishedAt = lastRun.finishedAt {
            payload["finishedAt"] = ISO8601DateFormatter().string(from: finishedAt)
        }
        if let exitCode = lastRun.exitCode {
            payload["exitCode"] = exitCode
        }
        if let detail = lastRun.detail {
            payload["detail"] = detail
        }
        return payload
    }

    private static func blockingScrape(_ tracker: Tracker) -> Result<TrackerReading, Error> {
        var result: Result<TrackerReading, Error>?
        ChromeCDPScraper.scrape(tracker: tracker) { scrapeResult in
            result = scrapeResult
        }

        if Thread.isMainThread {
            while result == nil {
                RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            while result == nil {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        return result ?? .failure(MCPError.internalError("Scrape finished without a result."))
    }

    private static func trackerHealthPayload(trackers: [Tracker], readings: [String: TrackerReading]) -> [String: Any] {
        var statusCounts: [String: Int] = [
            "ok": 0,
            "stale": 0,
            "broken": 0,
            "notReadYet": 0
        ]
        var staleTrackerIDs: [String] = []
        var brokenTrackerIDs: [String] = []

        for tracker in trackers {
            guard let reading = readings[tracker.id.uuidString] else {
                statusCounts["notReadYet", default: 0] += 1
                staleTrackerIDs.append(tracker.id.uuidString)
                continue
            }

            statusCounts[reading.status.rawValue, default: 0] += 1
            switch reading.status {
            case .ok:
                break
            case .stale:
                staleTrackerIDs.append(tracker.id.uuidString)
            case .broken:
                brokenTrackerIDs.append(tracker.id.uuidString)
            }
        }

        return [
            "statusCounts": statusCounts,
            "staleTrackerIds": staleTrackerIDs,
            "brokenTrackerIds": brokenTrackerIDs
        ]
    }

    private static func browserAccountPayload(
        _ account: BrowserAccount,
        trackers: [Tracker],
        includeTechnicalDetails: Bool
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "id": account.id,
            "name": account.name,
            "colorHex": account.colorHex,
            "isDefault": account.isDefault,
            "trackerCount": trackers.lazy.filter { $0.browserProfile == account.id }.count
        ]
        if includeTechnicalDetails {
            let browserConfiguration = ChromeBrowserProfile.shared.configuration(profileName: account.id)
            payload["cdpURL"] = browserConfiguration.cdpURL.absoluteString
            payload["userDataDirectory"] = browserConfiguration.userDataDirectory.path
        }
        return payload
    }

    private static func trackerPayload(_ tracker: Tracker, includeHistory: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "id": tracker.id.uuidString,
            "name": tracker.name,
            "url": tracker.url,
            "browserProfile": tracker.browserProfile,
            "renderMode": tracker.renderMode.rawValue,
            "selector": tracker.selector,
            "contentSelectorHint": tracker.contentSelectorHint as Any? ?? NSNull(),
            "refreshIntervalSec": tracker.refreshIntervalSec,
            "label": tracker.label as Any? ?? NSNull(),
            "icon": tracker.icon,
            "accentColorHex": tracker.accentColorHex,
            "gradientMode": tracker.gradientMode.rawValue,
            "valueTransform": tracker.valueTransform.rawValue,
            "valueDisplayOptions": [
                "stripLetters": tracker.valueDisplayOptions.stripLetters,
                "stripPercentSymbol": tracker.valueDisplayOptions.stripPercentSymbol
            ],
            "hideElements": tracker.hideElements,
            "hooks": [
                "onSuccess": tracker.hooks.onSuccess.map(hookPayload),
                "onFailure": tracker.hooks.onFailure.map(hookPayload)
            ],
            // v0.21.9: secondary elements (multi-element trackers).
            "secondaryElements": tracker.secondaryElements.map(secondaryElementPayload),
            "reading": AppGroupStore.reading(for: tracker.id).map { readingPayload($0, includeHistory: includeHistory) } as Any? ?? NSNull()
        ]

        if includeHistory {
            payload["history"] = tracker.historyPayload
            payload["valueParser"] = tracker.valueParserPayload
        }

        if let box = tracker.elementBoundingBox {
            payload["elementBoundingBox"] = boundingBoxPayload(box)
        } else {
            payload["elementBoundingBox"] = NSNull()
        }

        return payload
    }

    private static func readingPayload(_ reading: TrackerReading, includeHistory: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "currentValue": reading.currentValue as Any? ?? NSNull(),
            "currentNumeric": reading.currentNumeric as Any? ?? NSNull(),
            "snapshotPath": reading.snapshotPath as Any? ?? NSNull(),
            "snapshotCacheKey": reading.snapshotCacheKey as Any? ?? NSNull(),
            "snapshotCapturedAt": reading.snapshotCapturedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "lastUpdatedAt": reading.lastUpdatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
            "status": reading.status.rawValue,
            "lastError": reading.lastError as Any? ?? NSNull(),
            "consecutiveFailureCount": reading.consecutiveFailureCount as Any? ?? NSNull(),
            // v0.21.9: per-element secondary values from the same scrape cycle.
            "secondaryValues": reading.secondaryValues.mapValues(secondaryValuePayload)
        ]
        if includeHistory {
            payload["sparkline"] = reading.sparkline
        }
        return payload
    }

    /// v0.21.9: JSON payload for one secondary `TrackerElement`. Mirrors
    /// the primary element fields exposed at the top level of trackerPayload.
    private static func secondaryElementPayload(_ element: TrackerElement) -> [String: Any] {
        var payload: [String: Any] = [
            "id": element.id.uuidString,
            "name": element.name,
            "selector": element.selector,
            "contentSelectorHint": element.contentSelectorHint as Any? ?? NSNull(),
            "hideElements": element.hideElements,
            "valueParser": [
                "type": element.valueParser.type.rawValue,
                "stripChars": element.valueParser.stripChars
            ]
        ]
        if let box = element.elementBoundingBox {
            payload["elementBoundingBox"] = boundingBoxPayload(box)
        } else {
            payload["elementBoundingBox"] = NSNull()
        }
        return payload
    }

    private static func secondaryValuePayload(_ value: TrackerSecondaryValue) -> [String: Any] {
        [
            "value": value.value as Any? ?? NSNull(),
            "numeric": value.numeric as Any? ?? NSNull(),
            "lastError": value.lastError as Any? ?? NSNull()
        ]
    }

    private static func widgetConfigurationPayload(_ configuration: WidgetConfiguration) -> [String: Any] {
        [
            "id": configuration.id.uuidString,
            "name": configuration.name,
            "templateID": configuration.templateID.rawValue,
            "size": configuration.size.rawValue,
            "layout": configuration.layout.rawValue,
            "trackerIDs": configuration.trackerIDs.map(\.uuidString),
            "showSparklines": configuration.showSparklines,
            "showLabels": configuration.showLabels,
            // v0.21.9: per-slot secondary-element bindings, JSON-safe shape.
            "secondaryElementIDsBySlot": configuration.secondaryElementIDsBySlot.mapValues { ids in
                ids.map(\.uuidString)
            }
        ]
    }

    private static func boundingBoxPayload(_ box: ElementBoundingBox) -> [String: Any] {
        [
            "x": box.x,
            "y": box.y,
            "width": box.width,
            "height": box.height,
            "viewportWidth": box.viewportWidth,
            "viewportHeight": box.viewportHeight,
            "devicePixelRatio": box.devicePixelRatio
        ]
    }

    private static func selectorPackArgument(_ value: Any?) throws -> SelectorPack {
        if let dictionary = value as? [String: Any] {
            return try SelectorPack.decodeStrict(from: dictionary)
        } else if let string = value as? String,
                  let data = string.data(using: .utf8) {
            return try SelectorPack.decodeStrict(from: data)
        } else {
            throw MCPError.invalidParams("json must be a selector pack object or JSON string.")
        }
    }

    private static func urlArgument(_ key: String, _ arguments: [String: Any]) throws -> URL {
        try validatedURL(from: try stringArgument(key, arguments))
    }

    private static func validatedURL(from string: String) throws -> URL {
        guard let url = TrackerURLValidator.httpOrHTTPSURL(
            from: string,
            defaultScheme: nil,
            allowHTTPOnlyForLocalhost: true
        ) else {
            throw MCPError.validation("Scrape URLs must be https://, or http://localhost for testing.")
        }

        return url
    }

    private static func isValidWebhookURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            return false
        }

        return scheme == "https" || scheme == "http"
    }

    private static func stringArgument(_ key: String, _ arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else {
            throw MCPError.invalidParams("Missing string argument: \(key).")
        }
        return value
    }

    private static func resolvedBrowserProfile(
        _ value: Any?,
        fallback: String,
        configuration: AppConfiguration
    ) throws -> String {
        let profileID: String
        if let rawValue = value as? String {
            profileID = BrowserAccountCatalog.normalizedProfileID(rawValue)
        } else if value == nil {
            profileID = BrowserAccountCatalog.normalizedProfileID(fallback)
        } else {
            throw MCPError.invalidParams("browserProfile must be a string profile ID from list_browser_accounts.")
        }

        guard configuration.browserAccounts.contains(where: { $0.id == profileID }) else {
            throw MCPError.validation("Browser account \(profileID) was not found. Use list_browser_accounts to choose an existing profile ID.")
        }
        return profileID
    }

    private static func uuidArgument(_ key: String, _ arguments: [String: Any]) throws -> UUID {
        guard let value = arguments[key] as? String, let id = UUID(uuidString: value) else {
            throw MCPError.invalidParams("Missing or invalid UUID argument: \(key).")
        }
        return id
    }

    private static func optionalUUIDArgument(_ key: String, _ arguments: [String: Any]) throws -> UUID? {
        guard arguments.keys.contains(key) else {
            return nil
        }
        guard let value = arguments[key] as? String, let id = UUID(uuidString: value) else {
            throw MCPError.invalidParams("Invalid UUID argument: \(key).")
        }
        return id
    }

    private static func uuidArrayArgument(_ key: String, _ arguments: [String: Any]) throws -> [UUID]? {
        guard arguments.keys.contains(key) else {
            return nil
        }

        guard let values = arguments[key] as? [String] else {
            throw MCPError.invalidParams("\(key) must be an array of UUID strings.")
        }

        var ids: [UUID] = []
        for value in values {
            guard let id = UUID(uuidString: value) else {
                throw MCPError.invalidParams("\(key) contains an invalid UUID: \(value).")
            }
            ids.append(id)
        }

        guard Set(ids).count == ids.count else {
            throw MCPError.validation("\(key) cannot contain duplicate tracker IDs.")
        }

        return ids
    }

    private static func boundingBoxArgument(_ key: String, _ arguments: [String: Any]) throws -> ElementBoundingBox? {
        guard arguments.keys.contains(key) else {
            return nil
        }
        if arguments[key] is NSNull {
            return nil
        }
        guard let object = arguments[key] as? [String: Any] else {
            throw MCPError.invalidParams("\(key) must be an object or null.")
        }

        guard let x = doubleValue(object["x"]),
              let y = doubleValue(object["y"]),
              let width = doubleValue(object["width"]),
              let height = doubleValue(object["height"]),
              let viewportWidth = doubleValue(object["viewportWidth"]),
              let viewportHeight = doubleValue(object["viewportHeight"]),
              let devicePixelRatio = doubleValue(object["devicePixelRatio"]) else {
            throw MCPError.invalidParams("\(key) must include numeric x, y, width, height, viewportWidth, viewportHeight, and devicePixelRatio.")
        }

        return ElementBoundingBox(
            x: x,
            y: y,
            width: width,
            height: height,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            devicePixelRatio: devicePixelRatio
        )
    }

    private static func intArgument(_ key: String, _ arguments: [String: Any]) -> Int? {
        if let value = arguments[key] as? Int {
            return value
        }
        if let value = arguments[key] as? NSNumber {
            return value.intValue
        }
        if let value = arguments[key] as? String {
            return Int(value)
        }
        return nil
    }

    private static func boolArgument(_ key: String, _ arguments: [String: Any]) -> Bool? {
        if let value = arguments[key] as? Bool {
            return value
        }
        if let value = arguments[key] as? NSNumber {
            return value.boolValue
        }
        if let value = arguments[key] as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? NSNumber {
            return value.doubleValue
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private static func renderModeArgument(_ value: Any?) -> RenderMode? {
        (value as? String).flatMap(RenderMode.init(rawValue:))
    }

    /// Parses a `gradientMode` argument. Returns nil when the caller omitted
    /// the field (so we leave the existing value alone on update). Throws
    /// `MCPError.invalidParams` if the field is present but not one of the
    /// canonical enum values — silently falling back would mask typos like
    /// `"highisbad"` (lowercase, no camelCase) that look right at a glance.
    private static func gradientModeArgument(_ value: Any?) throws -> GradientMode? {
        guard let rawString = value as? String else {
            return nil
        }
        guard let mode = GradientMode(rawValue: rawString) else {
            let allowed = GradientMode.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams("gradientMode must be one of: \(allowed).")
        }
        return mode
    }

    /// Parses a `valueTransform` argument. Returns nil when the caller
    /// omitted the field (preserves existing value on update). Throws
    /// `MCPError.invalidParams` on unknown values so typos surface early
    /// instead of silently being ignored.
    private static func valueTransformArgument(_ value: Any?) throws -> ValueTransform? {
        guard let rawString = value as? String else {
            return nil
        }
        guard let transform = ValueTransform(rawValue: rawString) else {
            let allowed = ValueTransform.allCases.map(\.rawValue).joined(separator: ", ")
            throw MCPError.invalidParams("valueTransform must be one of: \(allowed).")
        }
        return transform
    }

    private static func widgetTemplateArgument(_ value: Any?) -> WidgetTemplate? {
        (value as? String).flatMap(WidgetTemplate.init(rawValue:))
    }

    private static func widgetSizeArgument(_ value: Any?) -> WidgetConfigurationSize? {
        (value as? String).flatMap(WidgetConfigurationSize.init(rawValue:))
    }

    private static func widgetLayoutArgument(_ value: Any?) -> WidgetConfigurationLayout? {
        (value as? String).flatMap(WidgetConfigurationLayout.init(rawValue:))
    }

    private static func stringArrayArgument(_ key: String, _ arguments: [String: Any]) -> [String]? {
        stringArray(from: arguments[key])
    }

    private static func stringArray(from value: Any?) -> [String]? {
        value as? [String]
    }

    /// Notifies the running main app that on-disk tracker / widget config has
    /// changed and the BackgroundScheduler needs to re-read it. Posts to TWO
    /// channels because MCP can be served from one of two process contexts:
    ///
    /// 1. Embedded socket MCP — running INSIDE the main app process. The
    ///    in-process `NotificationCenter` post lands directly in the
    ///    `MacosWidgetsStatsFromWebsiteApp` scene's `.onReceive`, which calls
    ///    `store.reloadFromDisk() + backgroundScheduler.sync()`.
    ///
    /// 2. Stdio CLI MCP — running in a SEPARATE process (spawned by Claude
    ///    Code et al.). The in-process NotificationCenter post lands inside
    ///    the CLI's own process and is dropped on the floor; the main app
    ///    never hears about it. To bridge this gap, we ALSO write the
    ///    pre-existing `reloadTimelinesSentinel` file — the main app's
    ///    `BackgroundScheduler.drainPendingScrapeRequests()` file-watcher
    ///    picks it up within milliseconds and runs the same
    ///    `store.reloadFromDisk() + sync() + reloadAllTimelines()` chain.
    ///
    /// Before this dual-channel push (≤0.17.5), tracker config changes made
    /// from the stdio CLI MCP were quietly invisible to the running
    /// BackgroundScheduler — e.g. changing refreshIntervalSec from 1800 to
    /// 600 wouldn't reschedule the timer until the next app restart.
    private static func notifyConfigurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
        }

        // Best-effort cross-process bridge. Failure is non-fatal because the
        // in-process post above handles the embedded-socket case; we only
        // lose hot-reload on the stdio path in pathological cases (App Group
        // container unavailable, disk full).
        do {
            try PendingScrapeRequestStore.requestScrape(
                trackerID: PendingScrapeRequest.reloadTimelinesSentinel
            )
        } catch {
            MCPInvocationLogger.logSystem(
                "config-changed-sentinel-failed",
                detail: error.localizedDescription
            )
        }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw MCPError.validation(message)
        }
        return value
    }

    private static func slotCountDescription(_ range: ClosedRange<Int>) -> String {
        if range.lowerBound == range.upperBound {
            return "\(range.lowerBound) tracker\(range.lowerBound == 1 ? "" : "s")"
        }

        return "\(range.lowerBound)-\(range.upperBound) trackers"
    }

    // MARK: - Sparkle update tools (Ethan voice 3991, 2026-05-24)
    //
    // These three implementations sit BEHIND the MCPUpdateBridge handler
    // (see MCPUpdateBridge.swift) so this file does not have to
    // `import Sparkle`. Sparkle is not linked into the CLI target —
    // routing through the bridge keeps MCPServer.swift compilable in
    // both MainApp (Sparkle present) and CLI (Sparkle absent) targets.
    //
    // `check_for_updates` and `install_pending_update` are async on the
    // Sparkle side (must hop to the main queue + wait for delegate
    // callbacks). The MCP dispatcher contract is synchronous-return,
    // so we use a DispatchSemaphore to bridge — with a generous
    // timeout so a hung Sparkle network call cannot pin an MCP
    // session forever. The timeout still falls back to the cached
    // state from prior delegate hooks rather than throwing, matching
    // the documented behaviour: "latestAppcastVersion may be null if
    // not yet checked".

    /// Maximum time to wait for Sparkle's main-thread delegate hop +
    /// network probe to complete before returning the cached state.
    ///
    /// HIGH 2 (Codex xhigh review, voice 3991): bumped 10s → 30s. The
    /// UpdateController now waits for Sparkle's actual probe completion
    /// (`didFinishUpdateCycleFor`) instead of a single runloop tick,
    /// so a real network round-trip happens within this window. 30s
    /// matches the Codex finding's recommended ceiling — long enough
    /// for slow networks, short enough that a flaky network cannot
    /// stall the MCP session forever. On timeout the bridge falls back
    /// to the cached snapshot rather than throwing.
    private static let updateBridgeTimeoutSeconds: TimeInterval = 30

    private static func checkForUpdates(context: MCPToolContext) throws -> Any {
        // Bridge handler is installed by UpdateController.start() on
        // the MainApp side. Absent ⇒ we're running in a transport
        // (CLI stdio) or process state (pre-startup) that does not
        // expose Sparkle.
        //
        // v0.21.43 (Ethan voice 4212, 2026-05-26): instead of throwing
        // immediately on the stdio path, try proxying to the running
        // menu-bar host's Unix socket first — terminal CC sessions
        // talk to us via stdio (see ~/.claude/.mcp.json), and the
        // running host on the socket DOES have the bridge handler
        // installed. The proxy only fires on stdio + handler-nil; the
        // socket path keeps the validation throw as before (if the
        // socket-served process somehow has no bridge handler, that's
        // a real bug we want surfaced).
        guard let handler = MCPUpdateBridge.handler else {
            if context.transport == .stdio,
               let proxied = MCPServerProxy.forward(method: "check_for_updates", arguments: [:]) {
                return proxied
            }
            throw MCPError.validation("check_for_updates requires the running app's MCP socket — Sparkle is not linked into the CLI stdio MCP transport, and the proxy to the running menu-bar host's socket also failed. Is the Stats Widget app running?")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: MCPUpdateCheckResult?
        handler.checkForUpdates { result in
            captured = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + updateBridgeTimeoutSeconds)

        // Even on timeout, return what we have so the agent can move
        // forward — bridge's snapshot() always returns the running
        // binary's currentVersion (it never blocks on the network),
        // so on timeout we surface currentVersion + null fields.
        let result = captured ?? MCPUpdateCheckResult(
            currentVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            latestAppcastVersion: nil,
            installPending: false
        )

        return [
            "currentVersion": result.currentVersion,
            // NSNull keeps the JSON shape stable — clients see
            // `"latestAppcastVersion": null` instead of the field
            // being absent, which makes the agent's branching easier.
            // The `as Any` cast silences the Swift implicit-coercion
            // warning when the operands of `??` are `String?` + `NSNull`.
            "latestAppcastVersion": (result.latestAppcastVersion as Any?) ?? NSNull(),
            // hasUpdateAvailable mirrors installPending semantically
            // ("Sparkle's appcast probe found a newer version") and is
            // exposed as a separate field so agent code can branch on
            // a self-documenting boolean without first checking
            // whether `latestAppcastVersion` is null. Per MBP-CC's
            // bridge msg-86d0f1c2 (voice 3991 follow-up): "the MCP
            // response should include both latestAppcastVersion AND
            // hasUpdateAvailable so agent code can do 'is there an
            // update? install it' without parsing version strings."
            "hasUpdateAvailable": result.installPending,
            "installPending": result.installPending
        ]
    }

    private static func installPendingUpdate(context: MCPToolContext) throws -> Any {
        guard let handler = MCPUpdateBridge.handler else {
            // Same stdio→socket proxy fallback pattern as checkForUpdates.
            // See that function's comment block for the full rationale.
            if context.transport == .stdio,
               let proxied = MCPServerProxy.forward(method: "install_pending_update", arguments: [:]) {
                return proxied
            }
            throw MCPError.validation("install_pending_update requires the running app's MCP socket — Sparkle is not linked into the CLI stdio MCP transport, and the proxy to the running menu-bar host's socket also failed. Is the Stats Widget app running?")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: MCPUpdateInstallResult?
        handler.installPendingUpdate { result in
            captured = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + updateBridgeTimeoutSeconds)

        let result = captured ?? MCPUpdateInstallResult(scheduled: false, pendingVersion: nil)

        return [
            "scheduled": result.scheduled,
            // Cast through Any? so the `??` operands type-check against
            // NSNull (the dictionary's value type is Any, so we need
            // a uniform fallback for the null case).
            "pendingVersion": (result.pendingVersion as Any?) ?? NSNull()
        ]
    }

    /// Autonomous probe + install orchestrator (v0.21.43, Ethan voice 4212,
    /// 2026-05-26). Behind the same bridge handler pattern as
    /// check_for_updates / install_pending_update — the MainApp side
    /// implements `MCPUpdateBridgeHandler.upgradeToLatest`, this side
    /// just dispatches through the bridge + bridges async-to-sync with
    /// a semaphore.
    ///
    /// Timeout: we extend the standard 30s update-bridge timeout to
    /// 60s here because the orchestrator chains a probe + an install
    /// dispatch, and 30s on each step would put us over budget if both
    /// the network and Sparkle are slow.
    private static func upgradeToLatest(context: MCPToolContext) throws -> Any {
        guard let handler = MCPUpdateBridge.handler else {
            // stdio fallback — same pattern as check_for_updates.
            // Important: the proxy must NOT use the standard 30s timeout
            // for this method because the orchestrator can legitimately
            // take 30-60s (probe + download dispatch). The proxy uses
            // a per-method timeout map; see MCPServerProxy.timeoutFor.
            if context.transport == .stdio,
               let proxied = MCPServerProxy.forward(method: "upgrade_to_latest", arguments: [:]) {
                return proxied
            }
            throw MCPError.validation("upgrade_to_latest requires the running app's MCP socket — Sparkle is not linked into the CLI stdio MCP transport, and the proxy to the running menu-bar host's socket also failed. Is the Stats Widget app running?")
        }

        // Wall-clock budget for the orchestrator: 60s. We double the
        // probe-side 30s because the orchestrator chains probe + install
        // dispatch. If Sparkle hangs we still return rather than pinning
        // the MCP session.
        let upgradeTimeoutSeconds: TimeInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var captured: MCPUpgradeResult?
        handler.upgradeToLatest { result in
            captured = result
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + upgradeTimeoutSeconds)

        // On timeout, build a defensive "we don't know what happened"
        // result with the running binary's current version so the
        // agent has something to log. reason="updater_unavailable" is
        // overloaded slightly here (also covers "timeout"), but matches
        // the bridge handler's missing-handler path semantically — in
        // both cases we couldn't reach Sparkle for an answer.
        let result = captured ?? MCPUpgradeResult(
            upgraded: false,
            reason: "updater_unavailable",
            fromVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown",
            toVersion: nil,
            automaticUpdatesEnabled: false,
            elapsedMs: Int(upgradeTimeoutSeconds * 1000)
        )

        return [
            "upgraded": result.upgraded,
            // `as Any?` cast keeps NSNull / String? operands type-compatible
            // in a [String: Any] dictionary.
            "reason": (result.reason as Any?) ?? NSNull(),
            "fromVersion": result.fromVersion,
            "toVersion": (result.toVersion as Any?) ?? NSNull(),
            "automaticUpdatesEnabled": result.automaticUpdatesEnabled,
            "elapsedMs": result.elapsedMs
        ]
    }

    private static func getVersion() -> Any {
        // Synchronous Bundle.main.infoDictionary readout — no Sparkle
        // dependency, works on every MCP transport. This is the cheap
        // "what am I running right now" probe that the bump-and-tag
        // release flow uses to confirm propagation across the fleet.
        let info = Bundle.main.infoDictionary
        return [
            "marketingVersion": (info?["CFBundleShortVersionString"] as? String) ?? "unknown",
            "buildNumber": (info?["CFBundleVersion"] as? String) ?? "unknown",
            "bundleId": (info?["CFBundleIdentifier"] as? String) ?? "unknown"
        ]
    }
}

private enum MCPInvocationLogger {
    static func logTool(_ toolName: String, arguments: [String: Any]) {
        let fingerprint = arguments.keys.sorted().joined(separator: ",")
        write("tool=\(toolName) caller=local args=[\(fingerprint)]")
    }

    static func logSystem(_ event: String, detail: String) {
        write("event=\(event) detail=\(detail)")
    }

    private static func write(_ line: String) {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macOS Widgets Stats from Website", isDirectory: true)
        let url = directory.appendingPathComponent("mcp.log", isDirectory: false)
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let payload = "\(timestamp) \(line)\n"

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(payload.utf8))
                try handle.close()
            } else {
                try Data(payload.utf8).write(to: url, options: .atomic)
            }
        } catch {
            // Logging must not affect MCP tool execution.
        }
    }
}

private enum MCPJSON {
    static func stringify(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}

private extension Tracker {
    var historyPayload: [String: Any] {
        [
            "retentionPolicy": history.retentionPolicy.rawValue,
            "retentionValue": history.retentionValue,
            "displayWindow": history.displayWindow
        ]
    }

    var valueParserPayload: [String: Any] {
        [
            "type": valueParser.type.rawValue,
            "stripChars": valueParser.stripChars
        ]
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
