import Foundation
import CryptoKit

/// What has been written to a repository for each draft, so that saving a draft sends only what changed.
public struct DraftMirror: Codable, Equatable, Sendable {
    public var repository: String
    public var folder: String
    /// Keyed by draft ID.
    public var drafts: [String: Entry] = [:]

    public struct Entry: Codable, Equatable, Sendable {
        /// The SHA-256 of the Markdown file last written.
        public var digest = ""
        /// Path to blob SHA for each file written for the draft.
        public var files: [String: String] = [:]
    }

    public init(repository: String, folder: String) {
        self.repository = repository
        self.folder = DraftMirror.normalize(folder)
    }

    public static func normalize(_ folder: String) -> String {
        folder.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && $0 != "." && $0 != ".." }.joined(separator: "/")
    }

    /// One draft's changes: files to write, files to remove, and the digest to record once they are done.
    public struct Step: Equatable, Sendable {
        public var id: UUID
        public var title: String
        /// Attachments first, so the Markdown file never points at a file that isn't there yet.
        public var writes: [(path: String, data: Data)]
        public var removals: [(path: String, sha: String)]
        /// Nil when the draft is gone and its files are removed.
        public var digest: String?
        public var removesDraft: Bool { digest == nil }

        public static func == (a: Step, b: Step) -> Bool {
            a.id == b.id && a.title == b.title && a.digest == b.digest
                && a.writes.map(\.path) == b.writes.map(\.path) && a.writes.map(\.data) == b.writes.map(\.data)
                && a.removals.map(\.path) == b.removals.map(\.path) && a.removals.map(\.sha) == b.removals.map(\.sha)
        }
    }

    /// The writes and removals that make the repository match these drafts.
    public func plan(_ drafts: [Draft]) -> [Step] {
        var steps: [Step] = []
        for draft in drafts {
            let entry = self.drafts[draft.id.uuidString] ?? Entry()
            let markdown = DraftExport.markdown(draft)
            let digest = DraftExport.digest(markdown)
            let paths = DraftExport.paths(draft, folder: folder)
            // Attachments never change once added, so only new ones are sent.
            var writes = zip(paths.attachments, draft.attachments).filter { entry.files[$0.0] == nil }.map { (path: $0.0, data: $0.1.data) }
            if digest != entry.digest || entry.files[paths.markdown] == nil { writes.append((path: paths.markdown, data: Data(markdown.utf8))) }
            let current = Set([paths.markdown] + paths.attachments)
            let removals = entry.files.filter { !current.contains($0.key) }.sorted { $0.key < $1.key }.map { (path: $0.key, sha: $0.value) }
            if !writes.isEmpty || !removals.isEmpty { steps.append(Step(id: draft.id, title: draft.displayTitle, writes: writes, removals: removals, digest: digest)) }
        }
        let kept = Set(drafts.map(\.id.uuidString))
        for (key, entry) in self.drafts.sorted(by: { $0.key < $1.key }) where !kept.contains(key) {
            guard let id = UUID(uuidString: key) else { continue }
            let markdown = entry.files.keys.first { $0.hasSuffix(".md") }
            let title = markdown.map { ($0 as NSString).lastPathComponent } ?? key
            steps.append(Step(id: id, title: title, writes: [], removals: entry.files.sorted { $0.key < $1.key }.map { (path: $0.key, sha: $0.value) }, digest: nil))
        }
        return steps
    }

    /// Records a file written for a draft.
    public mutating func wrote(_ path: String, sha: String, for id: UUID) {
        drafts[id.uuidString, default: Entry()].files[path] = sha
    }

    /// Records a file removed for a draft.
    public mutating func removed(_ path: String, for id: UUID) {
        drafts[id.uuidString]?.files[path] = nil
    }

    /// Records that every file of a step is done.
    public mutating func finished(_ step: Step) {
        if let digest = step.digest { drafts[step.id.uuidString, default: Entry()].digest = digest }
        else { drafts[step.id.uuidString] = nil }
    }
}

/// How a draft looks in a repository: a Markdown file with YAML front matter, plus its photos and recordings beside it.
public enum DraftExport {
    public static func paths(_ draft: Draft, folder: String) -> (markdown: String, attachments: [String]) {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let short = String(draft.id.uuidString.prefix(8)).lowercased()
        // Named by title only, since a name taken from the body would change, and move the file, with each edit.
        let titled = slug(draft.title)
        let name = titled.isEmpty ? draft.kind.rawValue : titled
        let attachments = draft.attachments.map { attachment in
            prefix + "media/\(short)-\(String(attachment.id.uuidString.prefix(8)).lowercased()).\(fileExtension(attachment))"
        }
        return (prefix + "\(name)-\(short).md", attachments)
    }

    public static func markdown(_ draft: Draft) -> String {
        var lines = ["---", "type: \(draft.kind.rawValue)"]
        func add(_ key: String, _ value: String) {
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lines.append("\(key): \(quote(value))") }
        }
        add("title", draft.title)
        add("target", draft.target)
        let tags = draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !tags.isEmpty { lines.append("tags: [" + tags.map(quote).joined(separator: ", ") + "]") }
        add("slug", draft.slug)
        add("published", draft.published)
        add("visibility", draft.visibility)
        add("channel", draft.channel)
        add("location", draft.location)
        if !draft.syndication.isEmpty { lines.append("syndicate-to: [" + draft.syndication.map(quote).joined(separator: ", ") + "]") }
        if draft.remoteDraft { lines.append("post-status: draft") }
        if draft.isHTML { lines.append("html: true") }
        let fields = draft.fields.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        if !fields.isEmpty {
            lines.append("fields:")
            lines += fields.map { "  \(quote($0.key)): \(quote($0.value))" }
        }
        if !draft.legs.isEmpty {
            lines.append("legs:")
            for leg in draft.legs {
                let values = [("transit-type", leg.transitType), ("operator", leg.operatorName), ("number", leg.number), ("origin", leg.origin),
                              ("destination", leg.destination), ("departure", leg.departure), ("arrival", leg.arrival)].filter { !$0.1.isEmpty }
                lines.append("  - {" + values.map { "\(quote($0.0)): \(quote($0.1))" }.joined(separator: ", ") + "}")
            }
        }
        if !draft.attachments.isEmpty {
            lines.append("attachments:")
            for (attachment, path) in zip(draft.attachments, paths(draft, folder: "").attachments) {
                lines.append("  - file: \(quote(path))")
                lines.append("    type: \(quote(attachment.mimeType))")
                if !attachment.alt.isEmpty { lines.append("    alt: \(quote(attachment.alt))") }
                if let url = attachment.remoteURL { lines.append("    url: \(quote(url.absoluteString))") }
            }
        }
        if let url = draft.editURL { add("edits", url.absoluteString) }
        if let site = draft.accountURL { add("site", site.absoluteString) }
        lines.append("---")
        let body = draft.content.trimmingCharacters(in: .newlines)
        return lines.joined(separator: "\n") + "\n" + (body.isEmpty ? "" : "\n" + body + "\n")
    }

    public static func digest(_ markdown: String) -> String {
        SHA256.hash(data: Data(markdown.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A double-quoted YAML string. JSON's string escapes are valid YAML.
    static func quote(_ value: String) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
    }

    static func slug(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        var result = ""
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) { result.unicodeScalars.append(scalar) }
            else if !result.isEmpty, !result.hasSuffix("-") { result.append("-") }
            if result.count >= 50 { break }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func fileExtension(_ attachment: Attachment) -> String {
        let named = (attachment.filename as NSString).pathExtension.lowercased()
        if !named.isEmpty, named.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return named }
        switch attachment.mimeType.lowercased() {
        case "image/jpeg": return "jpg"
        case "image/png": return "png"
        case "image/heic": return "heic"
        case "image/gif": return "gif"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        default: return "bin"
        }
    }
}
