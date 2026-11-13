import Foundation
import Security
import QuillCore

enum Keychain {
    private static func query(_ account: String) -> [String: Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"QuillNative.Micropub", kSecAttrAccount as String:account] }
    static func token(for account: String) throws -> String? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data:data,encoding:.utf8) else { throw QuillError("Could not read your sign-in from Keychain.") }
        return value
    }
    static func save(_ token: String, for account: String) throws {
        let q = query(account)
        let attributes: [String:Any] = [kSecValueData as String:Data(token.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(q.merging(attributes,uniquingKeysWith: { _,new in new }) as CFDictionary,nil) == errSecSuccess else { throw QuillError("Could not securely save your sign-in.") }
        } else if status != errSecSuccess { throw QuillError("Could not update your sign-in.") }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw QuillError("Could not remove your sign-in.") }
    }
}
