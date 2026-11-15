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
            account = Account(me: me, micropub: me.appendingPathComponent("micropub"))
            try? Keychain.save("fixture-token", for: me.absoluteString)
        }
        #endif
    }

    // MARK: Account

    func signIn(site: String) async throws {
        busy = true; defer { busy = false }
        let (account, token) = try await auth.login(site: site, clientID: AppStore.clientID)
        try Keychain.save(token, for: account.me.absoluteString)
        try SharedStorage.write(account, key: "account")
        self.account = account
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
    }

    func refresh() async {
        guard let client else { return }
        if let config = try? await client.configuration() { self.config = config }
    }

    /// Signs out here, and asks the site to revoke the token when it offers a way to.
    func signOut() async {
        guard let account else { return }
        let token = try? Keychain.token(for: account.me.absoluteString)
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
        draft.prepare(for: kind)
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
    }

    func forget(_ receipt: Receipt) {
        receipts.removeAll { $0.id == receipt.id }
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
    mutating func prepare(for kind: PostKind) {
        self.kind = kind
        if kind == .itinerary && legs.isEmpty { legs = [Leg()] }
        if kind == .review && (fields["rating"] ?? "").isEmpty { fields["rating"] = "5" }
        isHTML = kind == .article
    }
}
