import Foundation
import QuillCore

enum SharedStorage {
    static let group = "group.com.quillnative.app"
    static var root: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuillNative")
    }
    static var drafts: DraftStore { DraftStore(directory: root.appendingPathComponent("Drafts")) }
    static var defaults: UserDefaults { UserDefaults(suiteName: group) ?? .standard }
    static func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey:key).flatMap { try? JSONDecoder().decode(type, from:$0) }
    }
    static func write<T: Encodable>(_ value: T, key: String) throws { defaults.set(try JSONEncoder().encode(value), forKey:key) }
}
