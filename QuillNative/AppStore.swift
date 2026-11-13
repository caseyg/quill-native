import SwiftUI
import Observation
import QuillCore

@MainActor @Observable
final class AppStore {
    var account: Account? = SharedStorage.read(Account.self,key:"account")
    var preferences = SharedStorage.read(Preferences.self,key:"preferences") ?? Preferences()
    var config = ServerConfig()
    var configWarning: String?
    var drafts: [Draft] = []
    var receipts: [Receipt] = SharedStorage.read([Receipt].self,key:"receipts") ?? []
    var composer: Draft?
    var tab = 0
    var error: String?
    var busy = false
    var publishMessage: String?
    let auth = AuthService()
    var client: MicropubClient? {
        guard let account, let token = try? Keychain.token(for:account.me.absoluteString) else { return nil }
        return MicropubClient(endpoint:account.micropub,token:token)
    }
    init() {
        reloadDrafts()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--fixture") {
            let me = URL(string:"http://localhost:8765/")!
            account = Account(me:me,micropub:me.appendingPathComponent("micropub"))
            try? Keychain.save("fixture-token",for:me.absoluteString)
        }
        #endif
    }
    func connectToken(site: String, token: String, scope: String) async {
        busy = true; defer { busy = false }
        do {
            let me = try WebURL.parse(site)
            guard me.scheme == "https" else { throw QuillError("Personal-token connections require HTTPS.") }
            let (data,response) = try await Network.send(URLRequest(url:me)); try Network.check(response)
            let links = Discovery.parse(html:String(decoding:data,as:UTF8.self),linkHeader:response.value(forHTTPHeaderField:"Link"),baseURL:response.url ?? me)
            guard let endpoint = links["micropub"], endpoint.scheme == "https", !token.isEmpty else { throw QuillError("Enter a token for a site with an HTTPS Micropub endpoint.") }
            let config = try await MicropubClient(endpoint:endpoint,token:token).configuration()
            let account = Account(me:me,micropub:endpoint,tokenEndpoint:links["token_endpoint"],scope:scope)
            try Keychain.save(token,for:me.absoluteString); try SharedStorage.write(account,key:"account")
            self.account = account; self.config = config; configWarning = nil
        } catch { self.error = error.localizedDescription }
    }
    func reloadDrafts() { do { drafts = try SharedStorage.drafts.load() } catch { self.error = "Could not load drafts: " + error.localizedDescription } }
    func save(_ draft: Draft) throws {
        var draft = draft; draft.modified = Date()
        try SharedStorage.drafts.save(draft); reloadDrafts()
    }
    func remove(_ draft: Draft) { do { try SharedStorage.drafts.delete(draft.id); reloadDrafts() } catch { self.error = error.localizedDescription } }
    func compose(_ kind: PostKind) {
        var draft = Draft(kind:kind); draft.accountURL = account?.me
        if kind == .itinerary { draft.legs = [Leg()] }
        if kind == .review { draft.fields["rating"] = "5" }
        composer = draft
    }
    func signIn(site: String, clientID: String) async {
        busy = true; defer { busy = false }
        do {
            let (account,token) = try await auth.login(site:site,clientID:clientID)
            try Keychain.save(token,for:account.me.absoluteString)
            try SharedStorage.write(account,key:"account"); self.account = account
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        guard let client else { return }
        do { config = try await client.configuration(); configWarning = nil }
        catch { configWarning = "Configuration could not be loaded. Basic posting remains available. " + error.localizedDescription }
    }
    func publish(_ original: Draft) async throws {
        guard let account, let client else { throw QuillError("Sign in to your site in Settings before publishing.") }
        guard original.accountURL == nil || original.accountURL == account.me else { throw QuillError("This draft belongs to another site. Sign in to that site before publishing.") }
        guard account.permits(original.editURL == nil ? "create" : "update") else { throw QuillError("Your token does not have the required permission. Sign in again and grant \(original.editURL == nil ? "create" : "update").") }
        var draft = original; draft.accountURL = account.me
        try Payload.validate(draft); try save(draft)
        if let media = config.mediaEndpoint {
            for index in draft.attachments.indices where draft.attachments[index].remoteURL == nil {
                draft.attachments[index].remoteURL = try await client.upload(draft.attachments[index],to:media)
                try save(draft) // Uploaded assets survive retry without uploading twice.
            }
        }
        let url: URL
        if draft.editURL != nil { url = try await client.update(draft,preferences:preferences) }
        else { url = try await client.create(draft,preferences:preferences,formEncoded:SharedStorage.defaults.bool(forKey:"formEncoded")) }
        let receipt = Receipt(draft:draft,url:url)
        receipts.insert(receipt,at:0)
        try SharedStorage.write(receipts,key:"receipts")
        try SharedStorage.drafts.delete(draft.id); reloadDrafts()
        composer = nil; tab = 2
        publishMessage = "\(receipt.status): \(url.absoluteString)"
    }
    func edit(_ value: String) async {
        guard let client else { error = "Sign in first."; return }
        busy = true; defer { busy = false }
        do { var draft = try await client.source(WebURL.parse(value)); draft.accountURL = account?.me; composer = draft }
        catch { self.error = error.localizedDescription }
    }
    func signOut(revoke: Bool) async {
        do {
            if revoke, let account, let endpoint = account.tokenEndpoint, let token = try Keychain.token(for:account.me.absoluteString) {
                var req = URLRequest(url:endpoint); req.httpMethod = "POST"; req.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
                req.httpBody = Form.encode(["action":"revoke","token":token]); let (_,response) = try await Network.send(req); try Network.check(response)
            }
            if let account { try Keychain.delete(account.me.absoluteString) }
            SharedStorage.defaults.removeObject(forKey:"account"); account = nil; config = ServerConfig()
        } catch { self.error = error.localizedDescription }
    }
    func handle(_ url: URL) {
        if url.host == "settings" { tab = 3; return }
        reloadDrafts()
        let c = URLComponents(url:url,resolvingAgainstBaseURL:false)
        let values = Dictionary((c?.queryItems ?? []).map { ($0.name,$0.value ?? "") },uniquingKeysWith:{ first,_ in first })
        if url.host == "draft", let id = values["id"], let draft = drafts.first(where: { $0.id.uuidString == id }) { composer = draft; return }
        let kind = PostKind(rawValue:values["type"] ?? url.host ?? "note") ?? .note
        compose(kind)
        composer?.published = values["published"] ?? ""
        composer?.content = values["text"] ?? ""; composer?.target = values["reply"] ?? values["url"] ?? ""
    }
}
