//
//  KeychainHelper.swift
//  MacosWidgetsStatsFromWebsiteShared
//
//  Small Keychain wrapper used for MCP shared-secret auth.
//

import Foundation
import Security

enum KeychainHelper {
    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        case invalidData

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                return "Keychain returned status \(status)."
            case .invalidData:
                return "Keychain item data was not readable."
            }
        }
    }

    static let mcpService = "mcp-secret"
    static let mcpAccount = "macos-widgets-stats-from-website"
    private static let keychainAccessGroupsEntitlement = "keychain-access-groups"
    private static let sharedAccessGroupSuffix = ".com.ethansk.macos-widgets-stats-from-website"

    static func saveGenericPassword(_ password: String, service: String, account: String) throws {
        var lastError: Error?
        for accessGroup in accessGroupCandidates() {
            do {
                try saveGenericPassword(password, service: service, account: account, accessGroup: accessGroup)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? KeychainError.unexpectedStatus(errSecInternalError)
    }

    static func saveGenericPassword(_ password: String, service: String, account: String, accessGroup: String?, keychain: SecKeychain? = nil) throws {
        let data = Data(password.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        if let keychain {
            // Used by isolated native regression tests, never the login
            // keychain. Match only this keychain when rotating its fixture.
            query[kSecMatchSearchList as String] = [keychain]
        }

        // Ethan's "keeps asking for pw" was the CLI reading mcp-secret,
        // not the signing key. Restarting the host rotates this token;
        // deleting/recreating it discarded every saved Always Allow grant.
        // Update the value in place so the item and its native ACL survive.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(updateStatus)
        }

        var attributes = query
        attributes.removeValue(forKey: kSecMatchSearchList as String)
        if let keychain { attributes[kSecUseKeychain as String] = keychain }
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func readGenericPassword(service: String, account: String, allowInteraction: Bool = true) throws -> String? {
        var lastError: Error?
        for accessGroup in accessGroupCandidates() {
            do {
                if let password = try readGenericPassword(service: service, account: account, accessGroup: accessGroup, allowInteraction: allowInteraction) {
                    return password
                }
            } catch {
                lastError = error
            }
        }

        if let lastError, accessGroupCandidates().count == 1 {
            throw lastError
        }

        return nil
    }

    private static func readGenericPassword(service: String, account: String, accessGroup: String?, allowInteraction: Bool) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        if !allowInteraction {
            // Automated checks must prove saved authorization works; they
            // must not silently ask Ethan to approve another native prompt.
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }

        return password
    }

    private static func accessGroupCandidates() -> [String?] {
        var candidates: [String?] = []
        if let accessGroup = sharedKeychainAccessGroup() {
            candidates.append(accessGroup)
        }
        candidates.append(nil)
        return candidates
    }

    private static func sharedKeychainAccessGroup() -> String? {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, keychainAccessGroupsEntitlement as CFString, nil) else {
            return nil
        }

        let groups = value as? [String] ?? []
        return groups.first { $0.hasSuffix(sharedAccessGroupSuffix) }
    }

    @discardableResult
    static func rotateMCPToken() throws -> String {
        let token = "\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        try saveGenericPassword(token, service: mcpService, account: mcpAccount)
        return token
    }

    static func currentMCPToken(allowInteraction: Bool = true) throws -> String? {
        try readGenericPassword(service: mcpService, account: mcpAccount, allowInteraction: allowInteraction)
    }
}
