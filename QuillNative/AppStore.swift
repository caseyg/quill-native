import SwiftUI
import Observation
import QuillCore

@MainActor @Observable
final class AppStore {
    var account: Account? = SharedStorage.read(Account.self, key: "account")
    var preferences = SharedStorage.read(Preferences.self, key: "preferences") ?? Preferences()
    var config = ServerConfig()
    var drafts: [Draft] = []
    var receipts: [Receipt] = SharedStorage.read([Receipt].self, key: "receipts") ?? []
    /// Posts from the site, kept on device for browsing, search and editing.
    var library = Library()
    var syncing = false
    /// The post being fetched for editing.
    var opening: Post.ID?
    /// Posts sent this session, kept in the list until a sync includes them.
    private var recentlySent: Set<URL> = []
    var composer: Draft?
    /// The on-screen element the composer zooms out of: a draft row, or the compose button.
    var composerSource = AppStore.composeSource
    var showSettings = false
    var error: String?
    var busy = false
    let auth = AuthService()

    static let composeSource = "compose"

    /// The public page that identifies this app to IndieAuth servers. Set `QUILL_CLIENT_ID` to change it.
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "QuillIndieAuthClientID") as? String ?? "https://caseyg.github.io/quill-native/"

    var client: MicropubClient? {
        guard let account, let token = try? Keychain.token(for: account.me.absoluteString) else { return nil }
        return MicropubClient(endpoint: account.micropub, token: token)
    }

    init() {
        reloadDrafts()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture") {
            let me = URL(string: "http://localhost:8765/")!
            account = Account(me: me, micropub: me.appendingPathComponent("micropub"), scope: "create update delete media")
            try? Keychain.save("fixture-token", for: me.absoluteString)
        }
        #endif
        loadLibrary()
    }

    // MARK: Account

    func signIn(site: String) async throws {
        busy = true; defer { busy = false }
        let (account, token) = try await auth.login(site: site, clientID: AppStore.clientID)
        try Keychain.save(token, for: account.me.absoluteString)
        try SharedStorage.write(account, key: "account")
        self.account = account
        loadLibrary()
        await refresh()
    }

    func signIn(site: String, token: String) async throws {
        busy = true; defer { busy = false }
        let me = try WebURL.site(site)
        guard me.scheme == "https" else { throw QuillError("Token sign-in needs an https site.") }
        let (data, response) = try await Network.send(URLRequest(url: me)); try Network.check(response)
        let links = Discovery.parse(html: String(decoding: data, as: UTF8.self), linkHeader: response.value(forHTTPHeaderField: "Link"), baseURL: response.url ?? me)
        guard let endpoint = links["micropub"], endpoint.scheme == "https" else { throw QuillError("No Micropub endpoint found on this site.") }
        let config = try await MicropubClient(endpoint: endpoint, token: token).configuration()
        let account = Account(me: me, micropub: endpoint, tokenEndpoint: links["token_endpoint"], scope: "create update delete media draft")
        try Keychain.save(token, for: me.absoluteString)
        try SharedStorage.write(account, key: "account")
        self.account = account; self.config = config
        loadLibrary()
        await sync()
    }

    func refresh() async {
        guard let client else { return }
        if let config = try? await client.configuration() { self.config = config }
        await sync()
    }

    // MARK: Library

    private var libraryStore: LibraryStore? {
        guard let host = account?.me.host else { return nil }
        let name = host + (account?.me.path == "/" ? "" : account!.me.path.replacingOccurrences(of: "/", with: "_"))
        return LibraryStore(file: SharedStorage.root.appendingPathComponent("Library").appendingPathComponent(name + ".json"))
    }

    func loadLibrary() {
        library = libraryStore?.load() ?? Library()
        // Posts sent before the library existed.
        for receipt in receipts.reversed() where receipt.accountURL == nil || receipt.accountURL == account?.me {
            guard !library.posts.contains(where: { $0.url == receipt.url }) else { continue }
            var post = Post(url: receipt.url, kind: receipt.kind); post.name = receipt.title; post.published = receipt.date
            library.posts.append(post)
        }
    }

    /// Downloads every post the site lists. Failures leave the posts already on device in place.
    func sync() async {
        guard let account, let client, !syncing else { return }
        syncing = true; defer { syncing = false }
        do {
            let result = try await LibrarySync.fetch(client: client, me: account.me)
            guard self.account == account else { return }
            // A sync that began before a post was sent may not include it yet.
            let fetched = Set(result.posts.map(\.url))
            let sent = library.posts.filter { recentlySent.contains($0.url) && !fetched.contains($0.url) }
            recentlySent.subtract(fetched)
            library.replace(with: sent + result.posts, source: result.source)
            try libraryStore?.save(library)
        } catch {
            if library.posts.isEmpty { self.error = error.localizedDescription }
        }
    }

    func edit(_ post: Post) async {
        guard let client, opening == nil else { return }
        opening = post.id; defer { opening = nil }
        do {
            var draft = try await client.source(post.url); draft.accountURL = account?.me
            composerSource = post.id
            composer = draft
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ post: Post) async {
        guard let account, let client else { return }
        guard account.permits("delete") else { self.error = "Your site didn’t grant permission to delete posts. Sign in again."; return }
        do {
            try await client.delete(post.url)
            library.posts.removeAll { $0.id == post.id }
            forget(url: post.url)
            try? libraryStore?.save(library)
        } catch { self.error = error.localizedDescription }
    }

    /// Signs out here, and asks the site to revoke the token when it offers a way to.
    func signOut() async {
        guard let account else { return }
        let token = try? Keychain.token(for: account.me.absoluteString)
        libraryStore?.delete(); library = Library()
        try? Keychain.delete(account.me.absoluteString)
        SharedStorage.defaults.removeObject(forKey: "account")
        self.account = nil; config = ServerConfig(); showSettings = false
        if let endpoint = account.tokenEndpoint, let token {
            var request = URLRequest(url: endpoint); request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Form.encode(["action": "revoke", "token": token])
            _ = try? await Network.send(request)
        }
    }

    // MARK: Drafts

    func reloadDrafts() {
        do { drafts = try SharedStorage.drafts.load() } catch { self.error = error.localizedDescription }
    }

    func save(_ draft: Draft) throws {
        var draft = draft; draft.modified = Date()
        try SharedStorage.drafts.save(draft); reloadDrafts()
    }

    func remove(_ draft: Draft) {
        do { try SharedStorage.drafts.delete(draft.id); reloadDrafts() } catch { self.error = error.localizedDescription }
    }

    func compose(_ kind: PostKind) {
        var draft = Draft(kind: kind); draft.accountURL = account?.me
        draft.prepare(for: kind, markdown: preferences.markdown)
        composerSource = AppStore.composeSource
        composer = draft
    }

    func open(_ draft: Draft) {
        composerSource = draft.id.uuidString
        composer = draft
    }

    func edit(_ value: String) async {
        guard let client else { return }
        busy = true; defer { busy = false }
        do {
            var draft = try await client.source(WebURL.site(value)); draft.accountURL = account?.me
            composerSource = AppStore.composeSource
            composer = draft
        } catch { self.error = error.localizedDescription }
    }

    // MARK: Publishing

    func publish(_ original: Draft) async throws {
        guard let account, let client else { throw QuillError("Sign in to post.") }
        guard original.accountURL == nil || original.accountURL == account.me else {
            throw QuillError("This draft belongs to \(original.accountURL?.host ?? "another site").")
        }
        let action = original.editURL == nil ? "create" : "update"
        guard account.permits(action) else { throw QuillError("Your site didn’t grant permission to \(action) posts. Sign in again.") }
        var draft = original; draft.accountURL = account.me
        try Payload.validate(draft); try save(draft)
        if let media = config.mediaEndpoint {
            for index in draft.attachments.indices where draft.attachments[index].remoteURL == nil {
                draft.attachments[index].remoteURL = try await client.upload(draft.attachments[index], to: media)
                try save(draft) // Uploaded assets survive retry without uploading twice.
            }
        }
        let url: URL
        if draft.editURL != nil { url = try await client.update(draft, preferences: preferences) }
        else { url = try await client.create(draft, preferences: preferences, formEncoded: SharedStorage.defaults.bool(forKey: "formEncoded")) }
        try SharedStorage.drafts.delete(draft.id); reloadDrafts()
        receipts.insert(Receipt(draft: draft, url: url), at: 0)
        try SharedStorage.write(receipts, key: "receipts")
        // An update keeps the post's identity even if the server answers with another Location.
        var post = Post(draft: draft, url: draft.editURL ?? url)
        if let old = library.posts.first(where: { $0.url == post.url }) {
            if post.photo == nil { post.photo = old.photo; post.photoAlt = old.photoAlt }
            if draft.editURL != nil { post.published = old.published }
        }
        library.upsert(post)
        recentlySent.insert(post.url)
        try? libraryStore?.save(library)
    }

    private func forget(url: URL) {
        receipts.removeAll { $0.url == url }
        try? SharedStorage.write(receipts, key: "receipts")
    }

    // MARK: Routing

    func handle(_ url: URL) {
        if url.host == "settings" { showSettings = account != nil; return }
        reloadDrafts()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = Dictionary((components?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        if url.host == "draft", let id = values["id"], let draft = drafts.first(where: { $0.id.uuidString == id }) { open(draft); return }
        compose(PostKind(rawValue: values["type"] ?? url.host ?? "note") ?? .note)
        composer?.published = values["published"] ?? ""
        composer?.content = values["text"] ?? ""
        composer?.target = values["reply"] ?? values["url"] ?? ""
    }
}

extension Draft {
    /// Fills in what a post type needs before it can be edited.
    mutating func prepare(for kind: PostKind, markdown: Bool = false) {
        self.kind = kind
        if kind == .itinerary && legs.isEmpty { legs = [Leg()] }
        if kind == .review && (fields["rating"] ?? "").isEmpty { fields["rating"] = "5" }
        isHTML = kind == .article && !markdown
        if markdown && (Preferences.markdownKinds.contains(kind) || kind == .event) { fields["p3k-content-type"] = "text/markdown" }
        else if fields["p3k-content-type"] == "text/markdown" && !markdown { fields["p3k-content-type"] = nil }
    }
}

extension Post {
    /// What a just-sent draft looks like in the list until the next sync.
    init(draft: Draft, url: URL) {
        self.init(url: url, kind: draft.kind)
        name = draft.title
        text = draft.isHTML ? HTML.text(draft.content) : (draft.fields["p3k-content-type"] == "text/markdown" ? Markdown.text(draft.content) : draft.content)
        target = draft.target
        categories = draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let photo = draft.attachments.first { self.photo = photo.remoteURL; photoAlt = photo.alt }
        published = ISO8601DateFormatter().date(from: draft.published) ?? Date()
        isDraft = draft.remoteDraft
    }
}
