//
//  main.swift
//  MacosWidgetsStatsFromWebsiteCLI
//
//  Power-user adjunct and MCP stdio entrypoint.
//

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--mcp-stdio") || arguments.first == "mcp-stdio" {
    MCPServer.shared.runStdioServer()
    exit(0)
}

if arguments.first == "mcp-token" {
    if let token = MCPServer.shared.currentToken() {
        print(token)
    } else {
        fputs("No MCP token is available. Launch the app to start the socket server.\n", stderr)
        exit(1)
    }
} else {
    print("macos-widgets-stats-from-website CLI v0.12.6")
    print("Usage: macos-widgets-stats-from-website mcp-stdio | mcp-token")
}
