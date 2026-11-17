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
    /// Whether posts are kept on this device. Nil until the person has been asked.
    private(set) var syncEnabled: Bool? = SharedStorage.defaults.object(forKey: "syncEnabled") as? Bool
    /// Shows the question about keeping posts on this device.
    var askingToSync = false
    var syncing = false
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// The post being fetched for editing.
    var opening: Post.ID?
    /// Posts sent this session, kept in the list until a sync includes them.
    private var recentlySent: Set<URL> = []
    var composer: Draft?
    /// The on-screen element the composer zooms out of: a draft row, or the compose button.
    var composerSource = AppStore.composeSource
    var showSettings = false
    /// Opens the next composer straight into recording.
    var startsVoiceNote = false
    var error: String?
    var busy = false
    let auth = AuthService()
    /// The copy of drafts kept in a GitHub repository, when the person turns it on.
    let github = GitHubBackup()

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
            syncEnabled = !ProcessInfo.processInfo.arguments.contains("--sync-off")
        }
        #endif
        // Libraries downloaded before syncing was a choice stay on.
        if syncEnabled == nil, account != nil, libraryStore?.load().synced != nil { setSync(true, starting: false) }
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
        await refresh(asking: true)
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
        await refresh(asking: true)
    }

    /// Reloads the server's settings and fetches new posts. `asking` offers to sync when it is off,
    /// as after signing in or pulling to refresh.
    func refresh(asking: Bool = false) async {
        guard let client else { return }
        if let config = try? await client.configuration() { self.config = config }
        guard syncEnabled == true else { askingToSync = asking; return }
        // Only posts newer than the ones on device; a first download runs on without holding the refresh.
        if library.isComplete { await sync() } else { startSync() }
    }

    /// Turns keeping posts on device on or off. Off deletes the posts kept here; the site is not touched.
    func setSync(_ on: Bool, starting: Bool = true) {
        syncEnabled = on
        SharedStorage.defaults.set(on, forKey: "syncEnabled")
        if on {
            if starting { startSync() }
        } else {
            syncTask?.cancel(); syncTask = nil
            libraryStore?.delete()
            loadLibrary()
        }
    }

    /// Downloads every post again, which also drops posts deleted on the site.
    func syncEverything() {
        library.complete = false
        startSync()
    }

    private func startSync() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            await self?.sync()
            self?.syncTask = nil
        }
    }

    // MARK: Library

    private var libraryStore: LibraryStore? { account.flatMap { SharedStorage.library(for: $0.me) } }

    func loadLibrary() {
        library = syncEnabled == true ? libraryStore?.load() ?? Library() : Library()
        // Posts sent before the library existed.
        for receipt in receipts.reversed() where receipt.accountURL == nil || receipt.accountURL == account?.me {
            guard !library.posts.contains(where: { $0.url == receipt.url }) else { continue }
            var post = Post(url: receipt.url, kind: receipt.kind); post.name = receipt.title; post.published = receipt.date
            library.posts.append(post)
        }
    }

    /// Fetches posts newer than the ones on device, or every post when the library is new or unfinished.
    /// Failures leave the posts already on device in place.
    func sync() async {
        guard syncEnabled == true, let account, let client, !syncing else { return }
        syncing = true; defer { syncing = false; syncProgress = nil }
        let incremental = library.isComplete
        let known = incremental ? Set(library.posts.map(\.id)) : []
        // Dates of posts already on device let the bar show how far back the sync has reached.
        let oldest = library.posts.compactMap(\.published).min()
        if !incremental { syncProgress = SyncProgress(count: 0, fraction: oldest == nil ? nil : 0) }
        do {
            let result = try await LibrarySync.fetch(client: client, me: account.me, known: known) { [weak self] page in
                await self?.received(page, oldest: oldest, filling: !incremental, for: account)
            }
            guard self.account == account, syncEnabled == true, !Task.isCancelled else { return }
            // A sync that began before a post was sent may not include it yet.
            let fetched = Set(result.posts.map(\.url))
            let sent = library.posts.filter { recentlySent.contains($0.url) && !fetched.contains($0.url) }
            recentlySent.subtract(fetched)
            library.replace(with: sent + result.posts, source: result.source, keeping: incremental, complete: result.finished)
            saveLibrary()
        } catch {
            if library.posts.isEmpty && !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    struct SyncProgress: Equatable {
        var count: Int
        /// How far back in time the sync has reached, when there are earlier posts to compare with.
        var fraction: Double?
    }
    var syncProgress: SyncProgress?

    /// Shows each page as it arrives. A first sync lists posts right away instead of after the last page.
    private func received(_ page: [Post], oldest: Date?, filling: Bool, for account: Account) {
        // A sync still running after signing out or into another site must not touch this list.
        guard self.account == account, syncEnabled == true, var progress = syncProgress else { return }
        progress.count += page.count
        if let oldest, let reached = page.compactMap(\.published).min() {
            let span = Date().timeIntervalSince(oldest)
            if span > 0 { progress.fraction = max(progress.fraction ?? 0, min(1, Date().timeIntervalSince(reached) / span)) }
        }
        syncProgress = progress
        if filling {
            let known = Set(library.posts.map(\.id))
            library.posts += page.filter { !known.contains($0.id) }
        }
    }

    /// Encodes and writes the library away from the main thread.
    private func saveLibrary() {
        guard syncEnabled == true, let store = libraryStore else { return }
        let snapshot = library
        Task.detached(priority: .utility) { try? store.save(snapshot) }
    }

    @ObservationIgnored private var describing: Set<Post.ID> = []
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Reads the author and text of the page a like, repost, reply or bookmark points to, once.
    func describe(_ post: Post) async {
        guard post.needsCite, let url = try? WebURL.parse(post.target), describing.insert(post.id).inserted else { return }
        defer { describing.remove(post.id) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let summary: (author: String, text: String)
        // Only HTML is read, and only the first 2 MB, since the page is untrusted.
        if let (data, response) = try? await Network.send(request, limit: 2_000_000), (200..<300).contains(response.statusCode),
           (response.value(forHTTPHeaderField: "Content-Type") ?? "text/html").lowercased().contains("html") {
            summary = PageSummary.parse(html: String(decoding: data, as: UTF8.self))
        } else if Task.isCancelled {
            return // Scrolled away; try again when the row returns.
        } else {
            summary = ("", "")
        }
        guard let index = library.posts.firstIndex(where: { $0.id == post.id }) else { return }
        library.posts[index].citeAuthor = summary.author
        library.posts[index].citeText = summary.text
        // Rows fill in quickly while scrolling, so write to disk once they settle.
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.saveLibrary()
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
            saveLibrary()
        } catch { self.error = error.localizedDescription }
    }

    /// Whether a published post can be sent to more of the server's syndication targets.
    func syndicationTargets(for post: Post) -> [SyndicationTarget] {
        guard !post.isDraft, account?.permits("update") == true else { return [] }
        return post.unsyndicated(config.targets)
    }

    /// Asks the site to syndicate a published post, then reads the post again for its new links.
    func syndicate(_ post: Post, to target: SyndicationTarget) async {
        guard let client else { return }
        guard account?.permits("update") == true else { self.error = "Your site didn’t grant permission to update posts. Sign in again."; return }
        do {
            try await client.syndicate(post.url, to: [target.uid], preferences: preferences)
            syndicated += 1
        } catch { self.error = error.localizedDescription; return }
        // Some servers syndicate in the background, so the link may appear only on a later sync.
        guard var fresh = try? await client.post(post.url), let index = library.posts.firstIndex(where: { $0.id == post.id }) else { return }
        let old = library.posts[index]
        if fresh.needsCite, old.target == fresh.target { fresh.citeAuthor = old.citeAuthor; fresh.citeText = old.citeText }
        if fresh.photo == nil { fresh.photo = old.photo; fresh.photoAlt = old.photoAlt }
        if fresh.published == nil { fresh.published = old.published }
        library.posts[index] = fresh
        saveLibrary()
    }
    /// Counts syndication requests the site accepted, for haptic feedback.
    var syndicated = 0

    /// Signs out here, and asks the site to revoke the token when it offers a way to.
    func signOut() async {
        guard let account else { return }
        let token = try? Keychain.token(for: account.me.absoluteString)
        syncTask?.cancel(); syncTask = nil
        libraryStore?.delete(); library = Library()
        // The next site signed in to is asked again.
        syncEnabled = nil; SharedStorage.defaults.removeObject(forKey: "syncEnabled")
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
        // Every change to drafts, including ones from the share extension, passes through here.
        github.schedule()
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
        draft.prepare(for: kind, preferences: preferences)
        composerSource = AppStore.composeSource
        composer = draft
    }

    func composeVoiceNote() {
        compose(.note)
        startsVoiceNote = true
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
        saveLibrary()
    }

    private func forget(url: URL) {
        receipts.removeAll { $0.url == url }
        try? SharedStorage.write(receipts, key: "receipts")
    }

    // MARK: Routing

    func handle(_ url: URL) {
        if url.host == "settings" { showSettings = account != nil; return }
        if url.host == "voice" { composeVoiceNote(); return }
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

extension Post {
    /// What a just-sent draft looks like in the list until the next sync.
    init(draft: Draft, url: URL) {
        self.init(url: url, kind: draft.kind)
        name = draft.title
        text = draft.isHTML ? HTML.text(draft.content) : (draft.fields["p3k-content-type"] == "text/markdown" ? Markdown.text(draft.content) : draft.content)
        target = draft.target
        categories = draft.tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let photo = draft.attachments.first(where: { !$0.isAudio }) { self.photo = photo.remoteURL; photoAlt = photo.alt }
        published = ISO8601DateFormatter().date(from: draft.published) ?? Date()
        isDraft = draft.remoteDraft
    }
}
