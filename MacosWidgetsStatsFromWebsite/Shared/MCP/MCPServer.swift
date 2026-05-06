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
                    "version": "0.12.6"
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
        "add_tracker",
        "update_tracker",
        "delete_tracker",
        "update_widget_configuration",
        "delete_widget_configuration",
        "import_selector_pack",
        "attach_webhook",
        "reset_tracker_failure_state"
    ]

    static let toolNames = Set(tools.compactMap { $0["name"] as? String })

    static let tools: [[String: Any]] = [
        tool("get_status", "Return MCP server status, browser-profile details, data counts, and the available tool names.", [:]),
        tool("list_trackers", "Return all trackers with current values, status, and last-updated metadata.", [:]),
        tool("get_tracker", "Return one tracker with current value, sparkline, and full configuration.", [
            "id": stringSchema("Tracker UUID")
        ], required: ["id"]),
        tool("add_tracker", "Add a tracker. Selector is required unless the caller uses identify_element first.", [
            "name": stringSchema("Tracker name"),
            "url": stringSchema("HTTPS URL, or http://localhost for testing"),
            "renderMode": enumSchema(["text", "snapshot"]),
            "selector": stringSchema("CSS selector"),
            "elementBoundingBox": boundingBoxSchema(),
            "label": stringSchema("Optional widget label"),
            "icon": stringSchema("SF Symbol name"),
            "accentColorHex": stringSchema("Hex accent color, e.g. #10a37f"),
            "refreshIntervalSec": intSchema("Refresh interval in seconds"),
            "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots"))
        ], required: ["name", "url", "selector"]),
        tool("update_tracker", "Modify tracker fields such as name, URL, label, icon, refresh interval, mode, selector, element bounds, or hidden snapshot selectors.", [
            "id": stringSchema("Tracker UUID"),
            "name": stringSchema("Tracker name"),
            "url": stringSchema("HTTPS URL, or http://localhost for testing"),
            "renderMode": enumSchema(["text", "snapshot"]),
            "selector": stringSchema("CSS selector"),
            "elementBoundingBox": boundingBoxSchema(),
            "label": stringSchema("Optional widget label"),
            "icon": stringSchema("SF Symbol name"),
            "accentColorHex": stringSchema("Hex accent color, e.g. #10a37f"),
            "refreshIntervalSec": intSchema("Refresh interval in seconds"),
            "hideElements": arraySchema(stringSchema("CSS selector to hide before snapshots"))
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
            "renderMode": enumSchema(["text", "snapshot"])
        ]),
        tool("list_widget_configurations", "Return all widget compositions.", [:]),
        tool("get_widget_configuration", "Return one widget composition.", [
            "id": stringSchema("Widget configuration UUID")
        ], required: ["id"]),
        tool("update_widget_configuration", "Create or update a widget composition.", [
            "id": stringSchema("Widget configuration UUID; optional for create"),
            "name": stringSchema("Configuration name"),
            "templateID": enumSchema(WidgetTemplate.allCases.map(\.rawValue)),
            "size": enumSchema(WidgetConfigurationSize.allCases.map(\.rawValue)),
            "layout": enumSchema(WidgetConfigurationLayout.allCases.map(\.rawValue)),
            "trackerIDs": arraySchema(stringSchema("Tracker UUID")),
            "showSparklines": boolSchema("Whether to show sparkline charts where the template supports them"),
            "showLabels": boolSchema("Whether to show tracker labels")
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
        ], required: ["url"])
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
}

private enum MCPToolDispatcher {
    static func perform(name: String, arguments: [String: Any], context: MCPToolContext) throws -> Any {
        MCPInvocationLogger.logTool(name, arguments: arguments)

        switch name {
        case "get_status":
            return getStatus(context: context)
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
        #else
        let browserConfiguration = ChromeBrowserProfile.shared.configuration()
        let browserProfilePayload: [String: Any] = [
            "engine": "chrome_cdp",
            "name": browserConfiguration.profileName,
            "cdpURL": browserConfiguration.cdpURL.absoluteString,
            "userDataDirectory": browserConfiguration.userDataDirectory.path
        ]
        #endif
        return [
            "serverInfo": [
                "name": "macos-widgets-stats-from-website",
                "version": "0.12.6"
            ],
            "transport": context.transport == .unixSocket ? "unixSocket" : "stdio",
            "interactiveElementIdentification": context.supportsInteractiveBrowser ? "available" : "requires_app_socket",
            "socketPath": AppGroupPaths.mcpSocketURL().path,
            "browserProfile": browserProfilePayload,
            "counts": [
                "trackers": configuration.trackers.count,
                "widgetConfigurations": configuration.widgetConfigurations.count
            ],
            "health": health,
            "tools": Array(MCPToolCatalog.toolNames).sorted()
        ]
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

        let renderMode = renderModeArgument(arguments["renderMode"]) ?? .text
        let tracker = Tracker(
            name: name,
            url: url.absoluteString,
            renderMode: renderMode,
            selector: selector,
            elementBoundingBox: try boundingBoxArgument("elementBoundingBox", arguments),
            refreshIntervalSec: intArgument("refreshIntervalSec", arguments),
            label: arguments["label"] as? String,
            icon: (arguments["icon"] as? String)?.nilIfEmpty ?? Tracker.defaultIcon,
            accentColorHex: (arguments["accentColorHex"] as? String)?.nilIfEmpty ?? Tracker.defaultAccentColorHex,
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
            if let value = arguments["label"] as? String {
                tracker.label = value.nilIfEmpty
            }
            if let value = arguments["icon"] as? String {
                tracker.icon = value.nilIfEmpty ?? Tracker.defaultIcon
            }
            if let value = arguments["accentColorHex"] as? String {
                tracker.accentColorHex = value
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
            if arguments.keys.contains("elementBoundingBox") {
                tracker.elementBoundingBox = try boundingBoxArgument("elementBoundingBox", arguments)
                shouldResetFailureState = true
            }
            if let hideElements = stringArrayArgument("hideElements", arguments) {
                tracker.hideElements = hideElements
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

        try AppGroupStore.mutateSharedConfiguration { configuration in
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
        let trackerID: UUID
        if let existingTracker {
            trackerID = existingTracker.id
        } else {
            let tracker = Tracker(
                name: "Pending \(url.host ?? "Tracker")",
                url: url.absoluteString,
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
                    "renderMode": renderMode.rawValue
                ]
            )
        }

        return [
            "trackerId": trackerID.uuidString,
            "status": "awaiting_user",
            "url": url.absoluteString,
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

        try AppGroupStore.mutateSharedConfiguration { configuration in
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

    private static func trackerPayload(_ tracker: Tracker, includeHistory: Bool) -> [String: Any] {
        var payload: [String: Any] = [
            "id": tracker.id.uuidString,
            "name": tracker.name,
            "url": tracker.url,
            "browserProfile": tracker.browserProfile,
            "renderMode": tracker.renderMode.rawValue,
            "selector": tracker.selector,
            "refreshIntervalSec": tracker.refreshIntervalSec,
            "label": tracker.label as Any? ?? NSNull(),
            "icon": tracker.icon,
            "accentColorHex": tracker.accentColorHex,
            "hideElements": tracker.hideElements,
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
            "consecutiveFailureCount": reading.consecutiveFailureCount as Any? ?? NSNull()
        ]
        if includeHistory {
            payload["sparkline"] = reading.sparkline
        }
        return payload
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
            "showLabels": configuration.showLabels
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
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw MCPError.validation("URL is invalid.")
        }

        if scheme == "https" || (scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host == "::1")) {
            return url
        }

        throw MCPError.validation("Scrape URLs must be https://, or http://localhost for testing.")
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

    private static func notifyConfigurationChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpConfigurationChanged, object: nil)
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
