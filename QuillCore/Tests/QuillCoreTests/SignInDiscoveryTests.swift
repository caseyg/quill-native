import XCTest
@testable import QuillCore

final class SignInDiscoveryTests: XCTestCase {
    func testFullURLDiscoversEverythingNeededForLogin() async throws {
        let connection = try await SignInDiscovery.discover(site:"  https://caseyagollan.com/  ",transport:{ request in
            XCTAssertEqual(request.url?.scheme,"https")
            if request.url!.path == "/" {
                let html = #"<link rel="micropub" href="/micropub"><link rel="indieauth-metadata" href="/.well-known/oauth-authorization-server">"#
                return (Data(html.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            }
            let metadata = #"{"issuer":"https://caseyagollan.com/","authorization_endpoint":"https://caseyagollan.com/auth","token_endpoint":"https://caseyagollan.com/auth/token","scopes_supported":["create","update","media","draft"]}"#
            return (Data(metadata.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        })
        XCTAssertEqual(connection.me.absoluteString,"https://caseyagollan.com/")
        XCTAssertEqual(connection.authorizationEndpoint.absoluteString,"https://caseyagollan.com/auth")
        XCTAssertEqual(connection.tokenEndpoint.absoluteString,"https://caseyagollan.com/auth/token")
        XCTAssertEqual(connection.micropub.absoluteString,"https://caseyagollan.com/micropub")
        XCTAssertEqual(connection.scopes,"create update media draft")
    }
    func testBareDomainIsRejectedUntilSchemeIsProvided() async {
        do {
            _ = try await SignInDiscovery.discover(site:"caseyagollan.com",transport:{ _ in
                XCTFail("Invalid input must be rejected before any request")
                throw QuillError("Unexpected request")
            })
            XCTFail("A full URL is required")
        } catch { XCTAssertTrue(error.localizedDescription.contains("URL")) }
    }
    func testLegacyEndpointDiscoveryNeedsNoNameOrMetadataInput() async throws {
        let connection = try await SignInDiscovery.discover(site:"https://example.com/",transport:{ request in
            let header = "</auth>; rel=authorization_endpoint, </token>; rel=token_endpoint, </mp>; rel=micropub"
            return (Data(),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Link":header])!)
        })
        XCTAssertEqual(connection.tokenEndpoint.absoluteString,"https://example.com/token")
        XCTAssertNil(connection.issuer)
    }
    func testMissingEndpointsGiveActionableError() async {
        do {
            _ = try await SignInDiscovery.discover(site:"https://example.com/",transport:{ request in
                (Data("<html></html>".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            XCTFail("A site without sign-in endpoints must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("advertise")) }
    }
    func testRejectsMetadataIssuerFromAnotherHost() async {
        do {
            _ = try await SignInDiscovery.discover(site:"https://example.com/",transport:{ request in
                let body = request.url!.path == "/" ? #"<link rel="micropub" href="/mp"><link rel="indieauth-metadata" href="/metadata">"# : #"{"issuer":"https://evil.example/","authorization_endpoint":"https://example.com/auth","token_endpoint":"https://example.com/token"}"#
                return (Data(body.utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
            })
            XCTFail("Wrong issuer must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("issuer")) }
    }
}
