// Reproduces token rotation with a disposable native keychain. A persistent
// item reference proves that rotating a value preserves saved access grants.
// No login-keychain item, user password or real MCP token is accessed.

import Security
import XCTest

final class KeychainRotationTests: XCTestCase {
    func testRotationKeepsTheExistingKeychainItem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let password = UUID().uuidString
        var keychain: SecKeychain?
        let created = password.withCString {
            SecKeychainCreate(directory.appendingPathComponent("rotation.keychain-db").path, UInt32(password.utf8.count), $0, false, nil, &keychain)
        }
        XCTAssertEqual(created, errSecSuccess)
        let isolated = try XCTUnwrap(keychain)
        defer { SecKeychainDelete(isolated) }

        let service = "rotation-fixture"
        let account = "fixture"
        try KeychainHelper.saveGenericPassword("first", service: service, account: account, accessGroup: nil, keychain: isolated)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchSearchList as String: [isolated],
            kSecReturnPersistentRef as String: true
        ]
        var original: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &original), errSecSuccess)
        let originalReference = try XCTUnwrap(original as? Data)

        try KeychainHelper.saveGenericPassword("second", service: service, account: account, accessGroup: nil, keychain: isolated)
        var rotated: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &rotated), errSecSuccess)
        XCTAssertEqual(rotated as? Data, originalReference, "Rotation must preserve the item that owns saved approvals")

        var valueQuery = query
        valueQuery.removeValue(forKey: kSecReturnPersistentRef as String)
        valueQuery[kSecReturnData as String] = true
        var value: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(valueQuery as CFDictionary, &value), errSecSuccess)
        XCTAssertEqual(value as? Data, Data("second".utf8))
    }
}
