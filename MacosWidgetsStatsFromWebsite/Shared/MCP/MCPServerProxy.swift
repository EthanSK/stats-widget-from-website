//
//  MCPServerProxy.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Thin "this-stdio-process couldn't handle the request, forward it to
//  the running menu-bar host's Unix socket" shim for Sparkle-related
//  MCP tools (v0.21.43, Ethan voice 4212, 2026-05-26).
//
//  Why this exists
//  ---------------
//  Ethan's terminal Claude Code session is configured (in ~/.claude/.mcp.json)
//  to spawn the stats-widget MCP child via:
//
//      /Applications/Stats Widget from Website.app/Contents/MacOS/MacosWidgetsStatsFromWebsite --mcp-stdio
//
//  That `--mcp-stdio` mode is handled in MacosWidgetsStatsFromWebsiteApp.init()
//  by calling `MCPServer.shared.runStdioServer()` and then `Darwin.exit(0)`
//  — i.e. it never starts the SwiftUI app body, never invokes
//  UpdateController.start(), and therefore `MCPUpdateBridge.handler`
//  is nil in the stdio process. Result: any of the three Sparkle
//  tools (`check_for_updates`, `install_pending_update`, `upgrade_to_latest`)
//  would throw `MCPError.validation` in the stdio process, even though
//  the SEPARATE menu-bar host process IS running and DOES have the
//  bridge handler installed.
//
//  This proxy bridges that gap: when a Sparkle tool fires on stdio and
//  the bridge handler is nil, we open the host's Unix socket (via
//  the existing `MCPClient`), authenticate with the shared keychain
//  token (KeychainHelper.currentMCPToken — works across processes
//  because the keychain item is in the shared access group), forward
//  the JSON-RPC request, and return the result payload. The stdio
//  client's caller is none the wiser — they get a real MCP response.
//
//  Why this lives in Shared/ and not MainApp/
//  ------------------------------------------
//  The forwarder is invoked from `MCPToolDispatcher` (in Shared/MCP/MCPServer.swift)
//  which is compiled into BOTH the MainApp target AND the CLI stdio
//  target. Both paths see the same Swift file so the proxy is available
//  in both — though only the stdio path ever USES it (the MainApp's
//  socket-served session has the bridge handler installed and never
//  hits the proxy fallback).
//
//  Failure semantics
//  -----------------
//  - Host not running / socket file absent → return nil; the caller
//    falls through to its standard `MCPError.validation` throw with
//    a clear error message.
//  - Host running but auth token mismatch → return nil; same fallthrough.
//  - Host running, request forwarded, host responded with a
//    JSON-RPC error envelope → return nil so the caller's clean
//    error path runs (rather than trying to wrap a nested error).
//  - Host running, request forwarded, host returned a normal result
//    → unwrap the `result.content[0].text` JSON and return the
//    parsed `[String: Any]`.
//
//  All paths in this file are SYNCHRONOUS so they can be called from
//  `MCPToolDispatcher.perform` which has a synchronous return contract.
//
//  Timeout / bounding (corrected v0.21.74)
//  --------------------------------------
//  Earlier revisions of this comment claimed the socket round-trip was
//  "bounded by MCPClient's read-loop + a caller-side semaphore timeout".
//  That was WRONG and dangerous: before v0.21.74 `MCPClient.readLine`
//  looped on `readData(ofLength: 1)` with NO deadline whatsoever, so a
//  host that accepted the connection but never replied would pin this
//  synchronous call (and the MCPToolDispatcher thread behind it) FOREVER.
//  There is no caller-side semaphore on this path.
//
//  As of v0.21.74 the bound is real and lives in MCPClient: the connect
//  socket has SO_RCVTIMEO set (currently 30s, see
//  `MCPClient.socketReadTimeoutSeconds`), so a wedged/silent host makes
//  the read time out and surface as `ClientError.invalidResponse`, which
//  `forward(...)` catches and maps to nil (caller's standard error path).
//  We still don't add a SEPARATE timeout here — the client-side socket
//  timeout is the single source of truth for the read bound.
//

import Foundation

enum MCPServerProxy {
    /// Forward a Sparkle tool call to the running menu-bar host's
    /// Unix socket. Returns the parsed result payload or nil on any
    /// failure (caller falls through to standard error path).
    ///
    /// - Parameters:
    ///   - method: MCP tool name (`check_for_updates`, `install_pending_update`,
    ///             `upgrade_to_latest`). Pass through as-is — the host's
    ///             dispatcher matches by string.
    ///   - arguments: Tool arguments dictionary. Empty for all three
    ///             current Sparkle tools (they take no input params).
    static func forward(method: String, arguments: [String: Any]) -> [String: Any]? {
        // Check socket file exists before attempting to connect — if
        // the menu-bar host isn't running, fail fast rather than
        // waiting on connect(2) timeouts.
        let socketURL = AppGroupPaths.mcpSocketURL()
        guard FileManager.default.fileExists(atPath: socketURL.path) else {
            // Host not running. Caller will throw the standard
            // "Is the Stats Widget app running?" validation error,
            // which is the right surface for this case.
            return nil
        }

        // Pull the shared MCP token from the keychain. The token is
        // written by the menu-bar host on every startup via
        // MCPServer.rotateLaunchToken(), and stored in the shared
        // access group so both processes can read it.
        let token: String?
        do {
            token = try KeychainHelper.currentMCPToken()
        } catch {
            // Keychain read failed — likely a TCC / access-group
            // misconfiguration. Log via the standard MCP invocation
            // logger so the failure is traceable.
            NSLog("MCPServerProxy: keychain token read failed: %@", error.localizedDescription)
            return nil
        }

        // Build the client + invoke. MCPClient throws on socket errors;
        // any throw here means we couldn't reach the host, so fall
        // through to caller's standard error path.
        let client = MCPClient(socketURL: socketURL, token: token)
        let response: [String: Any]
        do {
            response = try client.call(toolName: method, arguments: arguments)
        } catch {
            NSLog(
                "MCPServerProxy: socket call to %@ failed: %@",
                method,
                error.localizedDescription
            )
            return nil
        }

        // MCP response envelope shape:
        //   {
        //     "jsonrpc": "2.0",
        //     "id": 1,
        //     "result": {
        //       "content": [
        //         { "type": "text", "text": "<JSON-string-encoded payload>" }
        //       ],
        //       "isError": false
        //     }
        //   }
        // OR on error:
        //   { "jsonrpc": "2.0", "id": 1, "error": { "code": ..., "message": ... } }
        //
        // We want the parsed payload from result.content[0].text. If
        // any of these unwraps fail, we return nil so caller's
        // standard error path runs.
        if response["error"] != nil {
            // Server returned an error — surface as nil so caller
            // throws its own standard error rather than a confusing
            // nested one. (We could parse + re-throw the host's
            // error, but the current callers all have specific
            // error messages that are clearer for users.)
            return nil
        }

        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let firstContent = content.first,
              let text = firstContent["text"] as? String,
              let textData = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: textData) as? [String: Any]
        else {
            // Response envelope didn't match expected shape. Likely a
            // server-side change; fall through to standard error path
            // so the user sees a sensible error rather than a partial
            // / null result.
            NSLog("MCPServerProxy: unexpected response shape for %@", method)
            return nil
        }

        return payload
    }
}
