import XCTest
@testable import QuillCore

final class SyndicationThreadTests: XCTestCase {
    func testReadsThreadSupportFromConfig() throws {
        let json = #"{"syndicate-to":[{"uid":"https://example.com/syndication/bluesky","name":"Bluesky"}],"syndication-thread":{"property":"syndication-thread","photo-property":"syndication-photo-post","max-posts":20,"max-photos-per-post":4,"limits":{"bluesky":{"characters":300,"link-length":"actual"},"mastodon":{"characters":500,"link-length":23}}}}"#
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        let support = try XCTUnwrap(config.thread)
        XCTAssertEqual(support.maxPosts, 20)
        XCTAssertEqual(support.limit(for: .bluesky), 300)
        XCTAssertEqual(support.limit(for: .mastodon), 500)
        XCTAssertNil(try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"syndicate-to":[]}"#.utf8)).thread)
    }

    func testSplitsAtParagraphsThenSentencesThenWords() {
        let fits: (String) -> Bool = { $0.count <= 40 }
        XCTAssertEqual(ThreadSplitter.split("Short one.\n\nShort two.", fits: fits), ["Short one.\n\nShort two."])
        XCTAssertEqual(ThreadSplitter.split("First paragraph is here.\n\nSecond paragraph is here too.", fits: fits),
                       ["First paragraph is here.", "Second paragraph is here too."])
        let sentences = ThreadSplitter.split("One sentence that is long. Another sentence that is long.", fits: fits)
        XCTAssertEqual(sentences, ["One sentence that is long.", "Another sentence that is long."])
        let words = ThreadSplitter.split(String(repeating: "word ", count: 30), fits: fits)
        XCTAssertTrue(words.allSatisfy(fits))
        XCTAssertEqual(words.joined(separator: " ").split(separator: " ").count, 30)
        XCTAssertTrue(ThreadSplitter.split(String(repeating: "x", count: 100), fits: fits).allSatisfy(fits))
    }

    func testLinkEndsTheLastPostOrStandsAlone() {
        let fits: (String) -> Bool = { $0.count <= 40 }
        XCTAssertEqual(ThreadSplitter.split("Hello", link: "https://e.com/p", fits: fits), ["Hello\n\nhttps://e.com/p"])
        XCTAssertEqual(ThreadSplitter.split("A sentence of exactly forty characters!!", link: "https://e.com/p", fits: fits),
                       ["A sentence of exactly forty characters!!", "https://e.com/p"])
    }

    func testEveryPostFitsBothNetworks() {
        let text = (1...12).map { "Paragraph \($0) says something with a link https://example.com/\($0) and goes on for a while longer than you'd think." }.joined(separator: "\n\n")
        let fits: (String) -> Bool = { SocialText.count($0, for: .bluesky) <= 300 && SocialText.count($0, for: .mastodon) <= 500 }
        let posts = ThreadSplitter.split(text, link: "https://example.com/post", fits: fits)
        XCTAssertGreaterThan(posts.count, 1)
        XCTAssertTrue(posts.allSatisfy(fits))
        XCTAssertTrue(posts.last!.hasSuffix("https://example.com/post"))
    }

    func testThreadPayloadSavesThenSends() throws {
        var support = ThreadSupport(); support.maxPosts = 3
        let body = try Payload.syndicate(URL(string: "https://example.com/1")!, to: ["bsky"], thread: ["One", " Two "], support: support).object
        XCTAssertEqual(body?["mp-syndicate-to"]?.array?.compactMap(\.string), ["bsky"])
        XCTAssertEqual(body?["replace"]?.object?["syndication-thread"]?.array?.compactMap(\.string), ["One", "Two"])
        XCTAssertThrowsError(try Payload.syndicate(URL(string: "https://example.com/1")!, to: ["bsky"], thread: ["One", ""], support: support))
        XCTAssertThrowsError(try Payload.syndicate(URL(string: "https://example.com/1")!, to: ["bsky"], thread: ["1", "2", "3", "4"], support: support))
    }

    func testSinglePostCanClearASavedThread() throws {
        let body = try Payload.syndicate(URL(string: "https://example.com/1")!, to: ["bsky"], texts: ["bsky": "Hi"], clearing: "syndication-thread").object
        XCTAssertEqual(body?["delete"]?.array?.compactMap(\.string), ["syndication-thread"])
    }

    func testReadsASavedThreadAndShowsOneLinkPerNetwork() throws {
        let json = #"{"type":["h-entry"],"properties":{"url":["https://example.com/1"],"content":["Hi"],"syndication-thread":["One","Two"],"syndication":["https://bsky.app/profile/me.example/post/a","https://bsky.app/profile/me.example/post/b","https://social.coop/@me/1","https://social.coop/@me/2"]}}"#
        let post = try XCTUnwrap(Post(mf2: JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))))
        XCTAssertEqual(post.thread, ["One", "Two"])
        XCTAssertEqual(post.syndicatedCopies.map(\.url.absoluteString), ["https://bsky.app/profile/me.example/post/a", "https://social.coop/@me/1"])
    }
}
