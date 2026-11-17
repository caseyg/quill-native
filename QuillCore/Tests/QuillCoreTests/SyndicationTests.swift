import XCTest
@testable import QuillCore

final class SyndicationTests: XCTestCase {
    private func post(_ properties: String) throws -> Post {
        let json = #"{"type":["h-entry"],"properties":{"url":["https://example.com/1"],"content":["Hi"],"# + properties + "}}"
        return try XCTUnwrap(Post(mf2: try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
    }

    func testReadsSyndicationLinksAndNamesTheirServices() throws {
        let p = try post(#""syndication":["https://bsky.app/profile/me.example/post/3k","https://hachyderm.io/@me/1131","https://mastodon.example/users/me/statuses/9","https://www.flickr.com/photos/me/1","https://notes.example/x"]"#)
        XCTAssertEqual(p.syndicatedCopies.map(\.service), ["Bluesky", "Mastodon", "Mastodon", "Flickr", "notes.example"])
    }

    func testPostsWithoutSyndicationHaveNoCopies() throws {
        XCTAssertNil(try post(#""name":[""]"#).syndication)
        XCTAssertEqual(try post(#""name":[""]"#).syndicatedCopies, [])
    }

    func testLibrariesSavedBeforeSyndicationWasKeptStillLoad() throws {
        let saved = #"{"posts":[{"url":"https://example.com/1","kind":"note","name":"","text":"Hi","target":"","categories":[],"photoAlt":"","isDraft":false}]}"#
        let library = try JSONDecoder().decode(Library.self, from: Data(saved.utf8))
        XCTAssertEqual(library.posts.first?.syndication, nil)
    }

    func testOffersOnlyTargetsWithoutACopy() throws {
        let p = try post(#""syndication":["https://bsky.app/profile/me.example/post/3k"]"#)
        let targets = [SyndicationTarget(uid: "https://bsky.app/profile/me.example", name: "@me.example on Bluesky"),
                       SyndicationTarget(uid: "bluesky", name: "Bluesky"),
                       SyndicationTarget(uid: "https://hachyderm.io/@me", name: "@me@hachyderm.io"),
                       SyndicationTarget(uid: "x", name: "X")]
        XCTAssertEqual(p.unsyndicated(targets).map(\.uid), ["https://hachyderm.io/@me", "x"])
    }

    func testSyndicateSendsAnUpdateAddingTargets() async throws {
        let endpoint = URL(string: "https://example.com/mp")!
        let client = MicropubClient(endpoint: endpoint, token: "t", transport: { request in
            let body = try JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data()).object
            XCTAssertEqual(body?["action"]?.string, "update")
            XCTAssertEqual(body?["url"]?.string, "https://example.com/1")
            XCTAssertEqual(body?["add"]?.object?["mp-syndicate-to"]?.array?.compactMap(\.string), ["https://hachyderm.io/@me"])
            return (Data(), HTTPURLResponse(url: endpoint, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        try await client.syndicate(URL(string: "https://example.com/1")!, to: ["https://hachyderm.io/@me"])
    }

    func testSyndicateUsesTheChosenField() throws {
        var preferences = Preferences(); preferences.syndicationField = "syndicate-to"
        let body = try Payload.syndicate(URL(string: "https://example.com/1")!, to: ["a"], preferences: preferences).object
        XCTAssertNotNil(body?["add"]?.object?["syndicate-to"])
    }

    func testDraftLinksToItsFileOnGitHub() {
        let id = UUID()
        var mirror = DraftMirror(repository: "me/notes", folder: "drafts")
        XCTAssertNil(mirror.markdownPath(for: id))
        mirror.wrote("drafts/media/abc.jpg", sha: "1", for: id)
        mirror.wrote("drafts/my post-abc.md", sha: "2", for: id)
        let path = mirror.markdownPath(for: id)
        XCTAssertEqual(path, "drafts/my post-abc.md")
        XCTAssertEqual(GitHubRepository(fullName: "me/notes", isPrivate: true).webURL(for: path!)?.absoluteString,
                       "https://github.com/me/notes/blob/HEAD/drafts/my%20post-abc.md")
    }
}
