import Foundation

public struct SignInConfiguration: Equatable, Sendable {
    public let inputURL: URL
    public let me: URL
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let micropub: URL
    public let issuer: String?
    public let scopes: String
}

public enum SignInDiscovery {
    /// Discover endpoints from a fully qualified website URL.
    public static func discover(site: String, transport: @escaping MicropubClient.Transport = Network.send) async throws -> SignInConfiguration {
        let inputURL = try WebURL.parse(site)
        var request = URLRequest(url:inputURL)
        request.timeoutInterval = 20
        let (data,response) = try await transport(request)
        try Network.check(response)
        let me = try WebURL.site((response.url ?? inputURL).absoluteString)
        let links = Discovery.parse(html:String(decoding:data,as:UTF8.self),linkHeader:response.value(forHTTPHeaderField:"Link"),baseURL:me)
        var issuer: String?
        var scopes = OAuth.requestedScopes(supported:nil)
        var authorization = links["authorization_endpoint"]
        var token = links["token_endpoint"]
        if let metadata = links["indieauth-metadata"] {
            guard metadata.scheme == "https" else { throw QuillError("Sign-in metadata must use HTTPS.") }
            var request = URLRequest(url:metadata); request.timeoutInterval = 20
            let (data,response) = try await transport(request)
            try Network.check(response)
            guard let value = try JSONDecoder().decode(JSONValue.self,from:data).object else { throw QuillError("Your site returned invalid sign-in metadata.") }
            issuer = value["issuer"]?.string
            guard let issuer, let url = URL(string:issuer), url.scheme == "https", url.host == metadata.host, url.port == metadata.port, url.query == nil, url.fragment == nil, metadata.path.hasPrefix(url.path) else { throw QuillError("The discovered authorization server metadata has an invalid issuer.") }
            scopes = OAuth.requestedScopes(supported:value["scopes_supported"]?.array?.compactMap(\.string))
            authorization = value["authorization_endpoint"]?.string.flatMap { try? WebURL.parse($0) } ?? authorization
            token = value["token_endpoint"]?.string.flatMap { try? WebURL.parse($0) } ?? token
        }
        guard let authorization, let token, let micropub = links["micropub"] else { throw QuillError("Your site must advertise IndieAuth sign-in and token endpoints and a Micropub endpoint.") }
        guard authorization.scheme == "https", token.scheme == "https", micropub.scheme == "https" else { throw QuillError("Sign-in requires HTTPS endpoints.") }
        return SignInConfiguration(inputURL:inputURL,me:me,authorizationEndpoint:authorization,tokenEndpoint:token,micropub:micropub,issuer:issuer,scopes:scopes)
    }
}
