import Foundation

/// A repository the signed-in person can write to.
public struct GitHubRepository: Codable, Equatable, Identifiable, Sendable {
    public var fullName: String
    public var isPrivate: Bool
    public var id: String { fullName }
    public init(fullName: String, isPrivate: Bool) { self.fullName = fullName; self.isPrivate = isPrivate }
}

/// The code a person enters on github.com to let the app write for them.
public struct GitHubDeviceCode: Equatable, Identifiable, Sendable {
    public var id: String { deviceCode }
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var interval: Int
    public var expires: Date
}

/// Sign-in with GitHub's device flow, which needs only the app's public client ID and no secret.
/// https://docs.github.com/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow
public enum GitHubDeviceFlow {
    public static func start(clientID: String, scope: String = "repo") async throws -> GitHubDeviceCode {
        let value = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": scope])
        guard let deviceCode = value["device_code"]?.string, let userCode = value["user_code"]?.string,
              let verification = value["verification_uri"]?.string.flatMap(URL.init(string:)), verification.scheme == "https" else {
            throw QuillError(value["error_description"]?.string ?? "GitHub didn’t start sign-in.")
        }
        return GitHubDeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURL: verification,
                                interval: max(5, number(value["interval"]) ?? 5),
                                expires: Date().addingTimeInterval(TimeInterval(number(value["expires_in"]) ?? 900)))
    }

    /// Waits until the person approves the code on GitHub, then returns the token.
    public static func token(clientID: String, code: GitHubDeviceCode) async throws -> String {
        var interval = code.interval
        while Date() < code.expires {
            try await Task.sleep(for: .seconds(interval))
            let value: [String: JSONValue]
            do {
                value = try await post("https://github.com/login/oauth/access_token", [
                    "client_id": clientID, "device_code": code.deviceCode, "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ])
            } catch let error as URLError where transient.contains(error.code) {
                // The app was in the background while the person approved on GitHub, which drops the connection. Ask again.
                continue
            }
            if let token = value["access_token"]?.string, !token.isEmpty { return token }
            switch value["error"]?.string {
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, number(value["interval"]) ?? 0)
            case "access_denied": throw CancellationError()
            case "expired_token": throw QuillError("The code expired. Try again.")
            default: throw QuillError(value["error_description"]?.string ?? "GitHub didn’t finish sign-in.")
            }
        }
        throw QuillError("The code expired. Try again.")
    }

    private static let transient: Set<URLError.Code> = [.networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]

    private static func number(_ value: JSONValue?) -> Int? {
        if case .number(let n) = value { return Int(n) }
        return value?.string.flatMap(Int.init)
    }

    private static func post(_ url: String, _ form: [String: String]) async throws -> [String: JSONValue] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Form.encode(form)
        let (data, response) = try await Network.send(request)
        let value = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object ?? [:]
        // Errors such as a disabled device flow come back as 4xx with a JSON body.
        guard (200..<300).contains(response.statusCode) || value["error"] != nil else { throw QuillError("GitHub returned HTTP \(response.statusCode).", status: response.statusCode) }
        return value
    }
}

/// The few REST calls that keep drafts in a repository.
public struct GitHubClient: Sendable {
    public let token: String
    public init(token: String) { self.token = token }

    public func login() async throws -> String {
        guard let login = try await call("GET", "/user").object?["login"]?.string else { throw QuillError("GitHub didn’t say who you are.") }
        return login
    }

    /// Repositories the person can push to, most recently pushed first.
    public func repositories() async throws -> [GitHubRepository] {
        var repositories: [GitHubRepository] = []
        for page in 1...5 {
            let items = try await call("GET", "/user/repos?per_page=100&sort=pushed&page=\(page)").array ?? []
            repositories += items.compactMap(GitHubRepository.init(api:))
            if items.count < 100 { break }
        }
        return repositories
    }

    public func repository(_ fullName: String) async throws -> GitHubRepository {
        guard let repository = GitHubRepository(api: try await call("GET", "/repos/\(fullName)")) else { throw QuillError("GitHub can’t find \(fullName).") }
        return repository
    }

    public func createPrivateRepository(named name: String) async throws -> GitHubRepository {
        let body: JSONValue = .object(["name": .string(name), "private": .bool(true), "auto_init": .bool(true),
                                       "description": .string("Drafts from Quill")])
        guard let repository = GitHubRepository(api: try await call("POST", "/user/repos", body: body)) else { throw QuillError("GitHub didn’t create the repository.") }
        return repository
    }

    /// The blob SHA of a file, or nil when there is none.
    public func sha(_ path: String, in repository: String) async throws -> String? {
        do { return try await call("GET", contents(path, repository)).object?["sha"]?.string }
        catch let error as QuillError where error.status == 404 { return nil }
    }

    /// Creates or replaces a file and returns its new SHA. A SHA that is out of date is looked up and the write tried once more,
    /// since the app's copy wins.
    public func put(_ path: String, _ data: Data, message: String, sha: String?, in repository: String) async throws -> String {
        func write(_ sha: String?) async throws -> String {
            var body: [String: JSONValue] = ["message": .string(message), "content": .string(data.base64EncodedString())]
            if let sha { body["sha"] = .string(sha) }
            let value = try await call("PUT", contents(path, repository), body: .object(body))
            guard let sha = value.object?["content"]?.object?["sha"]?.string else { throw QuillError("GitHub didn’t save \(path).") }
            return sha
        }
        do { return try await write(sha) }
        catch let error as QuillError where [409, 422].contains(error.status ?? 0) { return try await write(try await self.sha(path, in: repository)) }
    }

    public func delete(_ path: String, message: String, sha: String?, in repository: String) async throws {
        func remove(_ sha: String) async throws {
            _ = try await call("DELETE", contents(path, repository), body: .object(["message": .string(message), "sha": .string(sha)]))
        }
        do {
            var current = sha
            if current == nil { current = try await self.sha(path, in: repository) }
            guard let current else { return }
            try await remove(current)
        } catch let error as QuillError where error.status == 404 {
            return
        } catch let error as QuillError where [409, 422].contains(error.status ?? 0) {
            if let current = try await self.sha(path, in: repository) { try await remove(current) }
        }
    }

    private func contents(_ path: String, _ repository: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))
        return "/repos/\(repository)/contents/" + path.split(separator: "/").map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }.joined(separator: "/")
    }

    private func call(_ method: String, _ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try body.encoded()
        }
        let (data, response) = try await Network.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(JSONValue.self, from: data))?.object?["message"]?.string
            switch response.statusCode {
            case 401: throw QuillError("Your GitHub sign-in has expired. Sign in again.", status: 401)
            case 403 where response.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0": throw QuillError("GitHub’s rate limit was reached. Drafts will sync later.", status: 403)
            default: throw QuillError("GitHub returned HTTP \(response.statusCode)" + (message.map { ": \($0)" } ?? "."), status: response.statusCode)
            }
        }
        return data.isEmpty ? .null : try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension GitHubRepository {
    init?(api value: JSONValue) {
        guard let object = value.object, let name = object["full_name"]?.string else { return nil }
        // Only repositories the token can write to.
        if let push = object["permissions"]?.object?["push"], push != .bool(true) { return nil }
        self.init(fullName: name, isPrivate: object["private"] != .bool(false))
    }
}
