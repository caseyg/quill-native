import Foundation

public struct SyndicationTarget: Codable, Identifiable, Equatable, Sendable {
    public var uid: String
    public var name: String
    public var id: String { uid }
    public init(uid: String, name: String) { self.uid = uid; self.name = name }
}
public struct ServerConfig: Decodable, Sendable {
    public var mediaEndpoint: URL?
    public var targets: [SyndicationTarget] = []
    public var channels: [String] = []
    public var visibility: [String] = []
    public var postTypes: [String] = []
    public init() {}
    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder).object ?? [:]
        mediaEndpoint = value["media-endpoint"]?.string.flatMap { try? WebURL.parse($0) }
        targets = (value["syndicate-to"]?.array ?? []).compactMap { item in
            guard let o = item.object, let uid = o["uid"]?.string ?? o["target"]?.string else { return nil }
            return SyndicationTarget(uid: uid, name: o["name"]?.string ?? o["target"]?.string ?? uid)
        }
        channels = (value["channels"]?.array ?? []).compactMap { $0.string ?? $0.object?["uid"]?.string }
        visibility = (value["visibility"]?.array ?? []).compactMap(\.string)
        postTypes = (value["post-types"]?.array ?? []).compactMap { $0.object?["type"]?.string }
    }
}

/// Refuse authenticated redirects to a different origin; do not forward bearer tokens.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest, Network.allowsRedirect(original:original,redirect:request) else { completionHandler(nil); return }
        completionHandler(request)
    }
}
public enum Network {
    public static func allowsRedirect(original: URLRequest, redirect: URLRequest) -> Bool {
        guard let from = original.url, let to = redirect.url, ["https","http"].contains(to.scheme ?? "") else { return false }
        if from.scheme == "https" && to.scheme != "https" { return false }
        if original.value(forHTTPHeaderField:"Authorization") != nil || original.httpMethod == "POST" {
            return from.scheme == to.scheme && from.host == to.host && from.port == to.port
        }
        return true
    }
    private static let session = URLSession(configuration: .ephemeral, delegate: RedirectPolicy(), delegateQueue: nil)
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw QuillError("Your site returned a non-HTTP response.") }
        return (data, response)
    }
    /// Reads at most `limit` bytes of the body, refusing early when the server announces more.
    public static func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw QuillError("Your site returned a non-HTTP response.") }
        guard response.expectedContentLength <= Int64(limit) else { bytes.task.cancel(); throw QuillError("This page is too large.") }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { bytes.task.cancel(); break }
        }
        return (data, response)
    }
    public static func check(_ response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw QuillError("Your site returned HTTP \(response.statusCode). \([401,403].contains(response.statusCode) ? "Check your sign-in and granted permissions." : "Your draft is safe. Check the site before retrying.")", status: response.statusCode)
        }
    }
}
public struct Multipart {
    public let boundary: String
    public private(set) var data = Data()
    public init(boundary: String = "Quill-" + UUID().uuidString) { self.boundary = boundary }
    private mutating func text(_ value: String) { data.append(Data(value.utf8)) }
    public mutating func field(_ name: String, _ value: String) {
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safe(name))\"\r\n\r\n\(value)\r\n")
    }
    public mutating func file(_ name: String, _ attachment: Attachment) {
        text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(safe(name))\"; filename=\"\(safe(attachment.filename))\"\r\nContent-Type: \(safe(attachment.mimeType))\r\n\r\n")
        data.append(attachment.data); text("\r\n")
    }
    public mutating func finish() { text("--\(boundary)--\r\n") }
    private func safe(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\"", with: "_") }
}
public struct MicropubClient {
    public typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    public let endpoint: URL
    private let token: String
    private let transport: Transport
    public init(endpoint: URL, token: String, transport: @escaping Transport = Network.send) { self.endpoint = endpoint; self.token = token; self.transport = transport }
    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url); request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    public func query(_ q: String, parameters: [String: String] = [:]) async throws -> Data {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name: "q", value: q)] + parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        let (data, response) = try await transport(request(c.url!)); try Network.check(response); return data
    }
    public func configuration() async throws -> ServerConfig {
        let data = try await query("config")
        var config = try JSONDecoder().decode(ServerConfig.self, from: data)
        if config.targets.isEmpty, let data = try? await query("syndicate-to"), let more = try? JSONDecoder().decode(ServerConfig.self, from: data) { config.targets = more.targets }
        if config.channels.isEmpty, let data = try? await query("channels"), let more = try? JSONDecoder().decode(ServerConfig.self, from: data) { config.channels = more.channels }
        return config
    }
    public func latestMedia(at mediaEndpoint: URL, now: Date = Date()) async throws -> MediaItem? {
        var c = URLComponents(url:mediaEndpoint,resolvingAgainstBaseURL:false)!
        c.queryItems = (c.queryItems ?? []) + [URLQueryItem(name:"q",value:"source"),URLQueryItem(name:"limit",value:"1")]
        let (data,response) = try await transport(request(c.url!)); try Network.check(response)
        let value = try JSONDecoder().decode(JSONValue.self,from:data)
        guard let item = value.object?["items"]?.array?.first?.object, let raw = item["url"]?.string, let url = try? WebURL.parse(raw) else { return nil }
        if let published = item["published"]?.string.flatMap({ ISO8601DateFormatter().date(from:$0) }), now.timeIntervalSince(published) > 900 { return nil }
        func number(_ key: String) -> String? {
            if let s = item[key]?.string { return s }
            if case .number(let n) = item[key] { return String(n) }; return nil
        }
        let geo: String?
        if let lat = number("latitude"), let lon = number("longitude") { geo = "geo:\(lat),\(lon)" } else { geo = nil }
        return MediaItem(url:url,published:item["date_created"]?.string,location:geo)
    }
    public func upload(_ attachment: Attachment, to mediaEndpoint: URL) async throws -> URL {
        var form = Multipart(); form.file("file", attachment); form.finish()
        var req = request(mediaEndpoint, method: "POST"); req.httpBody = form.data
        req.setValue("multipart/form-data; boundary=" + form.boundary, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport(req); try Network.check(response)
        return try location(response)
    }
    public func create(_ draft: Draft, preferences: Preferences = Preferences(), formEncoded: Bool = false) async throws -> URL {
        let payload = try Payload.create(draft, preferences: preferences)
        var req = request(endpoint, method: "POST")
        let pending = draft.attachments.filter { $0.remoteURL == nil }
        if !pending.isEmpty || formEncoded {
            let properties = payload.object?["properties"]?.object ?? [:]
            var pairs: [(String, String)] = [("h", draft.kind == .event ? "event" : (draft.kind == .review ? "review" : "entry"))]
            for (key, value) in properties.sorted(by: { $0.key < $1.key }) { flatten(key, value, into: &pairs) }
            if pending.isEmpty {
                req.httpBody = Form.encodePairs(pairs); req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
            } else {
                var form = Multipart()
                for (name, value) in pairs { form.field(name, value) }
                let photos = pending.filter { !$0.isAudio }, audio = pending.filter(\.isAudio)
                for (i, attachment) in photos.enumerated() { form.file("photo[\(i)]", attachment); if !attachment.alt.isEmpty { form.field("photo-alt[\(i)]", attachment.alt) } }
                for (i, attachment) in audio.enumerated() { form.file("audio[\(i)]", attachment) }
                form.finish(); req.httpBody = form.data; req.setValue("multipart/form-data; boundary=" + form.boundary, forHTTPHeaderField:"Content-Type")
            }
        } else {
            req.httpBody = try payload.encoded(); req.setValue("application/json", forHTTPHeaderField:"Content-Type")
        }
        let (_, response) = try await transport(req); try Network.check(response)
        return try location(response)
    }
    private func flatten(_ name: String, _ value: JSONValue, into pairs: inout [(String, String)]) {
        switch value {
        case .string(let s): pairs.append((name,s))
        case .number(let n): pairs.append((name,String(n)))
        case .array(let items):
            for (index,item) in items.enumerated() { flatten(items.count == 1 ? name : name + "[\(index)]", item, into:&pairs) }
        case .object(let o): for (key,v) in o { flatten(name + "[\(key)]",v,into:&pairs) }
        default: break
        }
    }
    public func update(_ draft: Draft, preferences: Preferences = Preferences()) async throws -> URL {
        var req = request(endpoint, method: "POST"); req.httpBody = try Payload.update(draft, preferences: preferences).encoded(); req.setValue("application/json", forHTTPHeaderField:"Content-Type")
        let (_, response) = try await transport(req); try Network.check(response)
        if response.value(forHTTPHeaderField:"Location") != nil { return try location(response) }
        return draft.editURL!
    }
    private func location(_ response: HTTPURLResponse) throws -> URL {
        guard let value = response.value(forHTTPHeaderField: "Location"), let url = URL(string:value, relativeTo:response.url ?? endpoint)?.absoluteURL, (try? WebURL.parse(url.absoluteString)) != nil else { throw QuillError("The server accepted the request but returned no valid Location header. It may have published. Check your site before retrying; your draft is retained.") }
        return url
    }
    public func source(_ url: URL) async throws -> Draft {
        // p3k-content-type asks Quill-compatible servers for Markdown source instead of rendered HTML.
        let data = try await query("source", parameters: ["url": url.absoluteString, "p3k-content-type": "text/markdown"])
        return try Draft(source: JSONDecoder().decode(JSONValue.self, from: data), url: url)
    }
    public func delete(_ url: URL) async throws {
        var req = request(endpoint, method: "POST")
        req.httpBody = try JSONValue.object(["action": .string("delete"), "url": .string(url.absoluteString)]).encoded()
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await transport(req); try Network.check(response)
    }
}

public struct MediaItem: Sendable {
    public let url: URL
    public let published: String?
    public let location: String?
}
