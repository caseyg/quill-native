import Foundation
import Security
import QuillCore

/// Sign-in tokens. They live in the App Group's keychain access group so the share extension can publish too.
enum Keychain {
    private static func query(_ account: String, shared: Bool = true) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"QuillNative.Micropub", kSecAttrAccount as String:account]
        // An App Group is also a keychain access group for every target that has the group entitlement.
        if shared { q[kSecAttrAccessGroup as String] = SharedStorage.group }
        return q
    }
    private static func read(_ q: [String: Any]) throws -> String? {
        var q = q; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw QuillError("Could not read your sign-in from Keychain.") }
        return value
    }
    static func token(for account: String) throws -> String? {
        if let value = try read(query(account)) { return value }
        // Tokens saved before sharing are in the app's own group. Copy one across so the extension can see it.
        guard let legacy = try read(query(account, shared: false)) else { return nil }
        try? save(legacy, for: account)
        return legacy
    }
    static func save(_ token: String, for account: String) throws {
        do { try write(token, query(account)) }
        catch let error as KeychainStatus where error.status == errSecMissingEntitlement { try write(token, query(account, shared: false)) }
    }
    private static func write(_ token: String, _ q: [String: Any]) throws {
        let attributes: [String:Any] = [kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(q.merging(attributes,uniquingKeysWith: { _,new in new }) as CFDictionary,nil)
            guard added == errSecSuccess else { throw KeychainStatus(status: added, message: "Could not securely save your sign-in.") }
        } else if status != errSecSuccess { throw KeychainStatus(status: status, message: "Could not update your sign-in.") }
    }
    /// Removes the token from every group, including a copy left from before sharing.
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account, shared: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuillError("Could not remove your sign-in.") }
    }
}

private struct KeychainStatus: LocalizedError {
    let status: OSStatus
    let message: String
    var errorDescription: String? { message }
}
