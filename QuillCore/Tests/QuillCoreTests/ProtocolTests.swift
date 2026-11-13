import XCTest
@testable import QuillCore

final class ProtocolTests: XCTestCase {
    func testDiscoveryAcceptsAttributeOrderAndRelativeLinks() throws {
        let links = Discovery.parse(html: "<LINK href='/mp' rel='micropub alternate'><link rel=\"token_endpoint\" href=\"/token?a=1&amp;b=2\">", linkHeader: "</auth>; rel=\"authorization_endpoint\"", baseURL: URL(string: "https://example.com/profile")!)
        XCTAssertEqual(links["micropub"]?.absoluteString, "https://example.com/mp")
        XCTAssertEqual(links["token_endpoint"]?.absoluteString, "https://example.com/token?a=1&b=2")
        XCTAssertEqual(links["authorization_endpoint"]?.absoluteString, "https://example.com/auth")
    }
    func testCallbackRejectsWrongStateAndMissingCode() {
        XCTAssertThrowsError(try OAuth.callback(URL(string:"quill-native://oauth?state=wrong&code=abc")!, expectedState:"expected"))
        XCTAssertThrowsError(try OAuth.callback(URL(string:"quill-native://oauth?state=expected")!, expectedState:"expected"))
    }
    func testFormEncodingProtectsAmpersandsAndPlus() {
        let data = Form.encode(["content":"a+b & c"])
        XCTAssertEqual(String(data:data,encoding:.utf8), "content=a%2Bb%20%26%20c")
    }
    func testCreateMissingLocationNeverClaimsSuccess() async throws {
        let endpoint = URL(string: "https://example.com/mp")!
        let client = MicropubClient(endpoint: endpoint, token: "secret", transport: { request in
            (Data(), HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        var d = Draft(kind: .note); d.content = "A thought"
        do { _ = try await client.create(d); XCTFail("Missing location must be ambiguous") } catch { XCTAssertTrue(error.localizedDescription.contains("Location")) }
    }
    func testCreateResolvesRelativeLocationAndSendsAuthorization() async throws {
        let endpoint = URL(string: "https://example.com/mp")!
        let client = MicropubClient(endpoint: endpoint, token: "secret", transport: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField:"Content-Type"), "application/json")
            return (Data(), HTTPURLResponse(url: endpoint, statusCode: 201, httpVersion: nil, headerFields: ["Location":"/posts/1"])!)
        })
        var d = Draft(kind: .note); d.content = "A thought"
        let result = try await client.create(d)
        XCTAssertEqual(result.absoluteString, "https://example.com/posts/1")
    }
    func testUnauthorizedErrorDoesNotEchoTokenOrResponseBody() async throws {
        let endpoint = URL(string: "https://example.com/mp")!
        let client = MicropubClient(endpoint: endpoint, token: "secret", transport: { _ in
            (Data("secret debug response".utf8), HTTPURLResponse(url: endpoint,statusCode:401,httpVersion:nil,headerFields:nil)!)
        })
        do { _ = try await client.query("config"); XCTFail() } catch { XCTAssertFalse(error.localizedDescription.contains("secret")); XCTAssertTrue(error.localizedDescription.contains("401")) }
    }
    func testMultipartFallbackContainsPhotoAndContent() async throws {
        let endpoint = URL(string: "https://example.com/mp")!
        let client = MicropubClient(endpoint: endpoint, token: "secret", transport: { req in
            XCTAssertTrue(req.value(forHTTPHeaderField:"Content-Type")?.hasPrefix("multipart/form-data") == true)
            let body = String(decoding:req.httpBody!,as:UTF8.self)
            XCTAssertTrue(body.contains("name=\"photo[0]\"; filename=\"image.jpg\""))
            XCTAssertTrue(body.contains("A photo"))
            return (Data(), HTTPURLResponse(url:endpoint,statusCode:201,httpVersion:nil,headerFields:["Location":"/1"])!)
        })
        var d = Draft(kind:.photo); d.content = "A photo"; d.attachments = [Attachment(data:Data("image".utf8),filename:"image.jpg",mimeType:"image/jpeg")]
        _ = try await client.create(d)
    }
    func testConfigParsesCapabilities() throws {
        let config = try JSONDecoder().decode(ServerConfig.self,from: Data(#"{"media-endpoint":"https://example.com/media","syndicate-to":[{"uid":"social","name":"Social"}],"channels":["events"],"visibility":["public","private"],"post-types":[{"type":"note","name":"Note"}]}"#.utf8))
        XCTAssertEqual(config.targets.first?.name,"Social")
        XCTAssertEqual(config.channels,["events"])
        XCTAssertEqual(config.postTypes,["note"])
    }
}

extension ProtocolTests {
    func testIssuerMismatchIsRejected() {
        XCTAssertThrowsError(try OAuth.callback(URL(string:"quill-native://oauth?state=ok&code=abc&iss=https%3A%2F%2Fevil.example%2F")!,expectedState:"ok",expectedIssuer:"https://example.com/"))
    }
    func testDuplicateStateIsRejected() {
        XCTAssertThrowsError(try OAuth.callback(URL(string:"quill-native://oauth?state=ok&state=evil&code=abc")!,expectedState:"ok"))
    }
    func testLatestMediaCarriesPhotoTimeAndLocation() async throws {
        let endpoint = URL(string:"https://example.com/media")!
        let client = MicropubClient(endpoint:endpoint,token:"secret",transport:{ req in
            XCTAssertTrue(req.url!.absoluteString.contains("q=source"))
            return (Data(#"{"items":[{"url":"https://example.com/photo.jpg","published":"2026-11-13T14:30:00Z","latitude":40.7,"longitude":-74.0,"date_created":"2026-11-13T12:00:00Z"}]}"#.utf8),HTTPURLResponse(url:endpoint,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        let item = try await client.latestMedia(at:endpoint,now:ISO8601DateFormatter().date(from:"2026-11-13T14:35:00Z")!)
        XCTAssertEqual(item?.url.absoluteString,"https://example.com/photo.jpg")
        XCTAssertEqual(item?.location,"geo:40.7,-74.0")
    }
    func testCodeUpdateOnlyReplacesEditableFields() throws {
        var d = Draft(kind:.code); d.content = "print(1)"; d.editURL = URL(string:"https://example.com/1")!
        let value = try Payload.update(d)
        XCTAssertEqual(Set(value.object?["replace"]?.object?.keys.map{$0} ?? []),Set(["content"]))
    }
}

extension ProtocolTests {
    func testRedirectPolicyAllowsPublicCanonicalizationButProtectsTokens() {
        let original = URLRequest(url:URL(string:"http://example.com/")!)
        let target = URLRequest(url:URL(string:"https://www.example.com/")!)
        XCTAssertTrue(Network.allowsRedirect(original:original,redirect:target))
        var authenticated = original; authenticated.setValue("Bearer secret",forHTTPHeaderField:"Authorization")
        XCTAssertFalse(Network.allowsRedirect(original:authenticated,redirect:target))
        XCTAssertFalse(Network.allowsRedirect(original:target,redirect:original))
    }
}

extension ProtocolTests {
    func testScopeNegotiationDoesNotRequestUnadvertisedDraftScope() {
        XCTAssertEqual(OAuth.requestedScopes(supported:nil),"create update media")
        XCTAssertEqual(OAuth.requestedScopes(supported:["create","update","draft"]),"create update draft")
    }
}

extension ProtocolTests {
    func testHTTPLinkDiscoveryAllowsParametersBeforeRelAndQuotedCommas() {
        let links = Discovery.parse(html:"",linkHeader:#"</auth>; type="application/json"; title="Auth, sign in"; rel="authorization_endpoint", </token>; type="application/json"; rel="token_endpoint""#,baseURL:URL(string:"https://example.com/")!)
        XCTAssertEqual(links["authorization_endpoint"]?.absoluteString,"https://example.com/auth")
        XCTAssertEqual(links["token_endpoint"]?.absoluteString,"https://example.com/token")
    }
}
