//
//  MCPPrefsView.swift
//  MacosWidgetsStatsFromWebsite
//
//  Local MCP connection details for external automation agents.
//

import AppKit
import SwiftUI

struct MCPPrefsView: View {
    @State private var mcpToken: String?

    var body: some View {
        Form {
            Section {
                LabeledContent("Socket") {
                    Text(AppGroupPaths.mcpSocketURL().path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                if let mcpToken {
                    Text(mcpToken)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text("Token hidden.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Reveal token") {
                        mcpToken = MCPServer.shared.currentToken()
                    }

                    Button("Copy token") {
                        let token = mcpToken ?? MCPServer.shared.currentToken()
                        if let token {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            mcpToken = token
                        }
                    }
                }
            } header: {
                Text("Local socket")
            } footer: {
                Text("Socket clients authenticate with this launch token in X-Auth or initialize params. Stdio MCP does not require a token, but interactive browser element picking requires the running app socket.")
            }

            Section {
                Text("Agents can list, create, edit, and delete trackers; request visible browser element identification; trigger scrapes; reset stale/broken failure state after a manual repair; attach a webhook; and manage widget configurations.")
                    .foregroundStyle(.secondary)
            } header: {
                Text("Tool coverage")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Automation")
    }
}
