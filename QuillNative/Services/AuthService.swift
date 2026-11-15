import AuthenticationServices
import CryptoKit
import UIKit
import QuillCore

@MainActor
final class AuthService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func login(site: String, clientID: String) async throws -> (Account, String) {
        let client = try WebURL.parse(clientID)
        let connection = try await SignInDiscovery.discover(site:site)
        let me = connection.me
        let auth = connection.authorizationEndpoint
        let token = connection.tokenEndpoint
        let micropub = connection.micropub
        let expectedIssuer = connection.issuer
        let requestedScopes = connection.scopes
        let state = UUID().uuidString + UUID().uuidString
        let verifier = UUID().uuidString + UUID().uuidString
        let challenge = Data(SHA256.hash(data:Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let redirect = "quill-native://oauth"
        var c = URLComponents(url:auth,resolvingAgainstBaseURL:false)!
        c.queryItems = (c.queryItems ?? []) + ["me":me.absoluteString,"client_id":client.absoluteString,"redirect_uri":redirect,"state":state,"response_type":"code","scope":requestedScopes,"code_challenge":challenge,"code_challenge_method":"S256"].map { URLQueryItem(name:$0.key,value:$0.value) }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url:c.url!,callbackURLScheme:"quill-native") { url,error in
                if let url { continuation.resume(returning:url) } else if let error, (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin { continuation.resume(throwing:error) } else { continuation.resume(throwing:CancellationError()) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing:QuillError("Could not start sign-in.")) }
        }
        defer { session = nil }
        let code = try OAuth.callback(callback,expectedState:state,expectedIssuer:expectedIssuer)
        var request = URLRequest(url:token); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type"); request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.httpBody = Form.encode(["grant_type":"authorization_code","code":code,"client_id":client.absoluteString,"redirect_uri":redirect,"me":me.absoluteString,"code_verifier":verifier])
        let (tokenData,tokenResponse) = try await Network.send(request); try Network.check(tokenResponse)
        let values: [String:String]
        if let object = try? JSONDecoder().decode(JSONValue.self,from:tokenData).object { values = object.compactMapValues(\.string) }
        else { values = Dictionary((URLComponents(string:"?" + String(decoding:tokenData,as:UTF8.self))?.queryItems ?? []).compactMap { item in item.value.map { (item.name,$0) } },uniquingKeysWith: { first,_ in first }) }
        guard let accessToken = values["access_token"], !accessToken.isEmpty, values["token_type"]?.lowercased() == "bearer", let returnedMe = values["me"].flatMap({ try? WebURL.site($0) }) else { throw QuillError("Your site didn’t return a valid token.") }
        var endpoint = micropub
        if returnedMe != me {
            // IndieAuth lets a server return a more specific profile URL, provided it names the same authorization server.
            let confirmed = try await SignInDiscovery.discover(site:returnedMe.absoluteString)
            guard confirmed.authorizationEndpoint == auth else { throw QuillError("Your site signed in a different address.") }
            endpoint = confirmed.micropub
        }
        return (Account(me:returnedMe,micropub:endpoint,tokenEndpoint:token,scope:values["scope"] ?? ""),accessToken)
    }
}
