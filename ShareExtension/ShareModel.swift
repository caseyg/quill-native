import UIKit
import ImageIO
import Observation
import UniformTypeIdentifiers
import QuillCore

/// The post being made from shared content, and the two ways out of the sheet: save it as a draft or publish it.
@MainActor @Observable
final class ShareModel {
    enum Outcome { case saved, published }

    static let kinds: [PostKind] = [.bookmark, .note, .photo, .reply, .like, .repost]

    var draft = Draft(kind: .note)
    var loading = true
    var link: LinkContext?
    var linkImage: UIImage?
    var thumbnails: [Attachment.ID: UIImage] = [:]
    var config = ServerConfig()
    var knownTags: [String] = []
    var busy: Outcome?
    var outcome: Outcome?
    var failure: String?
    var failures = 0

    let account = SharedStorage.read(Account.self, key: "account")
    private let preferences = SharedStorage.read(Preferences.self, key: "preferences") ?? Preferences()
    private let finish: () -> Void
    private let dismiss: () -> Void
    private var serverTask: Task<Void, Never>?
    /// Set once the draft is on disk, so closing the sheet afterwards keeps it.
    private var kept = false

    init(finish: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.finish = finish
        self.dismiss = cancel
    }

    var client: MicropubClient? {
        guard let account, let token = try? Keychain.token(for: account.me.absoluteString) else { return nil }
        return MicropubClient(endpoint: account.micropub, token: token)
    }

    var canPublish: Bool { account != nil && busy == nil && outcome == nil }

    var tags: [String] {
        draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    // MARK: Loading

    func load(_ items: [NSExtensionItem]) async {
        var url: URL?, texts: [String] = [], images: [Data] = []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    if let data = await ShareModel.image(from: provider) { images.append(data) }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    if let value = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, let web = try? WebURL.parse(value.absoluteString) { url = url ?? web }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    if let value = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String { texts.append(value) }
                }
            }
            // Safari puts the page title here; other apps put the shared text.
            if let text = item.attributedContentText?.string, !text.isEmpty { texts.insert(text, at: 0) }
        }
        texts = texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if url == nil, let index = texts.firstIndex(where: { !$0.contains(where: \.isWhitespace) && (try? WebURL.parse($0)) != nil }) {
            url = try? WebURL.parse(texts.remove(at: index))
        }
        if let url { texts.removeAll { $0 == url.absoluteString } }

        var draft = Draft(kind: url != nil ? .bookmark : (images.isEmpty ? .note : .photo))
        draft.accountURL = account?.me
        draft.target = url?.absoluteString ?? ""
        if url != nil, let first = texts.first, texts.count > 1 || !first.contains("\n") {
            draft.title = texts.removeFirst()
        }
        draft.content = texts.reduce(into: [String]()) { list, text in if !list.contains(text) { list.append(text) } }.joined(separator: "\n\n")
        for data in images { add(data, to: &draft, name: "shared") }
        self.draft = draft
        loading = false

        serverTask = Task { await loadServer() }
        Task { await loadLocalTags() }
        await lookUp()
    }

    func lookUp() async {
        guard draft.kind.hasLink, let url = try? WebURL.parse(draft.target) else { link = nil; linkImage = nil; return }
        guard let found = try? await LinkContext.fetch(url), draft.target == url.absoluteString else { return }
        link = found
        if draft.title.isEmpty { draft.title = found.title }
        if (draft.fields["summary"] ?? "").isEmpty { draft.fields["summary"] = found.description }
        if let image = found.image, let (data, response) = try? await Network.send(URLRequest(url: image)), (200..<300).contains(response.statusCode), data.count < 8_000_000 {
            linkImage = ShareModel.downsample(data, to: 1200).flatMap(UIImage.init(data:))
        }
    }

    private func loadServer() async {
        guard let client else { return }
        if let config = try? await client.configuration() { self.config = config }
        // Micropub's category query lists the tags a site already uses.
        if let data = try? await client.query("category"), let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            let names = (value.object?["categories"]?.array ?? []).compactMap { $0.string ?? $0.object?["name"]?.string }
            if !names.isEmpty {
                SharedStorage.defaults.set(names, forKey: "categories")
                merge(names)
            }
        }
    }

    /// Tags already used on the site, most used first: from the app's copy of its posts, then drafts, then the site's own list.
    private func loadLocalTags() async {
        let store = account.flatMap { SharedStorage.library(for: $0.me) }
        let used = await Task.detached(priority: .userInitiated) { () -> [String] in
            var counts: [String: Int] = [:], names: [String: String] = [:]
            let tags = (store?.load().posts ?? []).flatMap(\.categories)
                + ((try? SharedStorage.drafts.load()) ?? []).flatMap { $0.tags.split(separator: ",").map(String.init) }
            for raw in tags {
                let tag = raw.trimmingCharacters(in: .whitespaces)
                guard !tag.isEmpty, !tag.hasPrefix("http") else { continue } // Person tags are URLs.
                counts[tag.lowercased(), default: 0] += 1
                names[tag.lowercased()] = names[tag.lowercased()] ?? tag
            }
            return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.compactMap { names[$0.key] }
        }.value
        merge(used)
        merge(SharedStorage.defaults.stringArray(forKey: "categories") ?? [])
    }

    private func merge(_ names: [String]) {
        for name in names where !knownTags.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { knownTags.append(name) }
    }

    /// Page tags first, then the site's own, filtered by what is being typed.
    func suggestions(for input: String) -> [String] {
        let query = input.trimmingCharacters(in: .whitespaces).lowercased()
        let used = Set(tags.map { $0.lowercased() })
        var seen = Set<String>()
        return ((link?.tags ?? []) + knownTags).filter { tag in
            let key = tag.lowercased()
            guard !used.contains(key), seen.insert(key).inserted else { return false }
            return query.isEmpty || key.hasPrefix(query) || key.contains(" " + query)
        }.prefix(12).map { $0 }
    }

    // MARK: Editing

    func setKind(_ kind: PostKind) {
        if kind == .note, !draft.target.isEmpty, !draft.content.contains(draft.target) {
            draft.content += (draft.content.isEmpty ? "" : "\n\n") + draft.target
        }
        draft.kind = kind
        if !kind.hasLink { link = nil } else if link == nil { Task { await lookUp() } }
    }

    func addTag(_ value: String) {
        var list = tags
        for part in value.split(separator: ",") {
            let tag = part.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
            if !tag.isEmpty, !list.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) { list.append(tag) }
        }
        draft.tags = list.joined(separator: ", ")
    }

    func removeTag(_ tag: String) {
        draft.tags = tags.filter { $0 != tag }.joined(separator: ", ")
    }

    func addPhoto(_ data: Data) {
        guard let jpeg = ShareModel.downsample(data, to: 2560) else { return fail("A photo couldn’t be read.") }
        add(jpeg, to: &draft, name: "photo")
    }

    func remove(_ attachment: Attachment) {
        draft.attachments.removeAll { $0.id == attachment.id }
        thumbnails[attachment.id] = nil
    }

    private func add(_ jpeg: Data, to draft: inout Draft, name: String) {
        let attachment = Attachment(data: jpeg, filename: "\(name)-\(UUID().uuidString.prefix(8)).jpg", mimeType: "image/jpeg")
        draft.attachments.append(attachment)
        thumbnails[attachment.id] = ShareModel.downsample(jpeg, to: 300).flatMap(UIImage.init(data:))
    }

    func fail(_ message: String) {
        failure = message
        failures += 1
    }

    // MARK: Leaving

    func save() async {
        guard busy == nil else { return }
        busy = .saved; defer { busy = nil }
        do {
            try keep(draft)
            await done(.saved)
        } catch { fail(error.localizedDescription) }
    }

    func publish() async {
        guard busy == nil else { return }
        guard let account, let client else { return fail("Sign in to Quill to publish.") }
        guard account.permits("create") else { return fail("Your site didn’t allow posting. Sign in again in Quill.") }
        do { try Payload.validate(draft) } catch { return fail(error.localizedDescription) }
        failure = nil
        busy = .published; defer { busy = nil }
        await serverTask?.value
        var draft = self.draft
        draft.accountURL = account.me
        do {
            try keep(draft)
            if let media = config.mediaEndpoint {
                for index in draft.attachments.indices where draft.attachments[index].remoteURL == nil {
                    draft.attachments[index].remoteURL = try await client.upload(draft.attachments[index], to: media)
                    try keep(draft) // An upload survives a retry.
                }
            }
            let url = try await client.create(draft, preferences: preferences, formEncoded: SharedStorage.defaults.bool(forKey: "formEncoded"))
            try? SharedStorage.drafts.delete(draft.id)
            var receipts = SharedStorage.read([Receipt].self, key: "receipts") ?? []
            receipts.insert(Receipt(draft: draft, url: url), at: 0)
            try? SharedStorage.write(receipts, key: "receipts")
            self.draft = draft
            await done(.published)
        } catch {
            self.draft = draft
            fail(error.localizedDescription + " It’s saved in Quill’s drafts.")
        }
    }

    func cancel() {
        if kept, outcome == nil { try? keep(draft) }
        dismiss()
    }

    private func keep(_ value: Draft) throws {
        var value = value
        value.accountURL = value.accountURL ?? account?.me
        value.modified = Date()
        try SharedStorage.drafts.save(value)
        kept = true
    }

    private func done(_ result: Outcome) async {
        outcome = result
        try? await Task.sleep(for: .milliseconds(650))
        finish()
    }

    // MARK: Images

    private static func image(from provider: NSItemProvider) async -> Data? {
        guard let value = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier) else { return nil }
        if let url = value as? URL {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return (try? Data(contentsOf: url)).flatMap { downsample($0, to: 2560) }
        }
        if let data = value as? Data { return downsample(data, to: 2560) }
        if let image = value as? UIImage, let data = image.jpegData(compressionQuality: 0.9) { return downsample(data, to: 2560) }
        return nil
    }

    /// A JPEG no larger than `size` on its long edge, upright and without metadata such as GPS.
    /// Decoding through ImageIO keeps a large photo from exhausting the extension's small memory budget.
    static func downsample(_ data: Data, to size: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.85)
    }
}

extension PostKind {
    /// Kinds that respond to the shared link.
    var hasLink: Bool { [.bookmark, .reply, .like, .repost].contains(self) }
    var hasWords: Bool { [.note, .photo, .reply, .bookmark].contains(self) }
}
