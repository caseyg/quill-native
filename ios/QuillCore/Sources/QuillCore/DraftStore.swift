import Foundation

/// Separate atomic files avoid lost updates between the app and share extension.
public struct DraftStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func save(_ draft: Draft) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUnlessOpen]
        #else
        let options: Data.WritingOptions = [.atomic]
        #endif
        try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent(draft.id.uuidString + ".json"), options: options)
    }
    public func load() throws -> [Draft] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try JSONDecoder().decode(Draft.self, from: Data(contentsOf: $0)) }.sorted { $0.modified > $1.modified }
    }
    public func delete(_ id: UUID) throws {
        let url = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
