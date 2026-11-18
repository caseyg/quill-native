import XCTest
@testable import QuillCore

final class SocialTextTests: XCTestCase {
    func testCountsAsEachNetworkDoes() {
        let text = "Hi 👋🏽 @alice@example.social https://example.com/a/very/long/path/that/goes/on"
        XCTAssertEqual(SocialText.count(text, for: .bluesky), text.count)
        XCTAssertEqual(SocialText.count(text, for: .mastodon), "Hi 👋🏽 @alice ".count + 23)
    }

    func testFindsTheMentionBeingTyped() {
        let text = "Thanks @ali"
        XCTAssertEqual(SocialText.mentionQuery(text, cursor: text.endIndex)?.query, "ali")
        let mastodon = "cc (@alice@exa"
        XCTAssertEqual(SocialText.mentionQuery(mastodon, cursor: mastodon.endIndex)?.query, "alice@exa")
        let email = "mail me@example.com"
        XCTAssertNil(SocialText.mentionQuery(email, cursor: email.endIndex))
        let done = "@alice hi"
        XCTAssertNil(SocialText.mentionQuery(done, cursor: done.endIndex))
        XCTAssertEqual(SocialText.mentionQuery("@", cursor: "@".endIndex)?.query, "")
    }

    func testInsertsAHandleWithASpace() throws {
        let text = "Thanks @ali for this"
        let cursor = text.index(text.startIndex, offsetBy: 11)
        let mention = try XCTUnwrap(SocialText.mentionQuery(text, cursor: cursor))
        let result = SocialText.insert(FollowedAccount(service: .bluesky, handle: "alice.bsky.social", name: "Alice"), into: text, replacing: mention.range)
        XCTAssertEqual(result.text, "Thanks @alice.bsky.social for this")
        XCTAssertEqual(result.cursor, "Thanks @alice.bsky.social ".count)
        let end = "Hi @al"
        let typed = try XCTUnwrap(SocialText.mentionQuery(end, cursor: end.endIndex))
        XCTAssertEqual(SocialText.insert(FollowedAccount(service: .bluesky, handle: "al.example", name: "Al"), into: end, replacing: typed.range).text, "Hi @al.example ")
    }

    func testSuggestsMatchesOnOneNetworkPrefixFirst() {
        let accounts = [FollowedAccount(service: .bluesky, handle: "zed.example", name: "Alice Zed"),
                        FollowedAccount(service: .bluesky, handle: "alice.example", name: "Alice"),
                        FollowedAccount(service: .mastodon, handle: "alice@social.example", name: "Alice")]
        XCTAssertEqual(SocialText.suggestions("ali", in: accounts, service: .bluesky).map(\.handle), ["alice.example", "zed.example"])
    }

    func testDefaultTextFitsAndLinksBack() {
        let url = URL(string: "https://example.com/2026/11/post")!
        let short = SocialText.defaultText(title: "", text: "Hello", url: url, service: .bluesky)
        XCTAssertEqual(short, "Hello\n\nhttps://example.com/2026/11/post")
        let long = SocialText.defaultText(title: "Title", text: String(repeating: "word ", count: 200), url: url, service: .bluesky)
        XCTAssertLessThanOrEqual(long.count, 300)
        XCTAssertTrue(long.hasPrefix("Title\n\nword"))
        XCTAssertTrue(long.hasSuffix("…\n\nhttps://example.com/2026/11/post"))
    }

    func testRecognisesNetworksAndAccounts() {
        XCTAssertEqual(SocialService(SyndicationTarget(uid: "https://example.com/syndication/bluesky", name: "Bluesky")), .bluesky)
        XCTAssertEqual(SocialService(SyndicationTarget(uid: "https://example.com/syndication/mastodon", name: "Mastodon")), .mastodon)
        XCTAssertEqual(SocialService(SyndicationTarget(uid: "https://hachyderm.io/@me", name: "@me")), .mastodon)
        XCTAssertNil(SocialService(SyndicationTarget(uid: "https://www.flickr.com/", name: "Flickr")))
        XCTAssertEqual(SocialAccount(link: URL(string: "https://bsky.app/profile/me.example/post/3k")!), SocialAccount(service: .bluesky, handle: "me.example"))
        XCTAssertEqual(SocialAccount(link: URL(string: "https://social.coop/@me/1131")!), SocialAccount(service: .mastodon, handle: "me", instance: URL(string: "https://social.coop")!))
    }

    func testFindsTheAccountFromTargetsOrPosts() throws {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(#"{"syndicate-to":[{"uid":"bsky","name":"Bluesky","service":{"name":"Bluesky"},"user":{"url":"https://bsky.app/profile/me.example"}}]}"#.utf8))
        XCTAssertEqual(config.targets.first?.service, "Bluesky")
        XCTAssertEqual(config.targets.first?.user.flatMap(SocialAccount.init(link:)), SocialAccount(service: .bluesky, handle: "me.example"))
        var a = Post(url: URL(string: "https://example.com/1")!, kind: .note); a.syndication = [URL(string: "https://social.coop/@me/1")!]
        var b = a; b.syndication = [URL(string: "https://social.coop/@me/2")!, URL(string: "https://bsky.app/profile/me.example/post/x")!]
        XCTAssertEqual(SocialAccount.inferred(.mastodon, from: [a, b])?.handle, "me")
    }

    func testReadsFollowsFromBothNetworks() async throws {
        let bluesky = try await SocialFollows.fetch(SocialAccount(service: .bluesky, handle: "me.example")) { request in
            let cursor = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value
            let body = cursor == nil ? #"{"follows":[{"handle":"b.example","displayName":"Bee"}],"cursor":"c1"}"# : #"{"follows":[{"handle":"a.example","displayName":""}]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        XCTAssertEqual(bluesky, [FollowedAccount(service: .bluesky, handle: "a.example", name: "a.example"), FollowedAccount(service: .bluesky, handle: "b.example", name: "Bee")])

        let mastodon = try await SocialFollows.fetch(SocialAccount(service: .mastodon, handle: "me", instance: URL(string: "https://social.example")!)) { request in
            let url = request.url!
            if url.path.hasSuffix("lookup") { return (Data(#"{"id":"42"}"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            if url.query?.contains("max_id") == true { return (Data(#"[{"acct":"far@other.example","display_name":"Far"}]"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
            return (Data(#"[{"acct":"near","display_name":"Near"}]"#.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Link": #"<https://social.example/api/v1/accounts/42/following?max_id=7>; rel="next""#])!)
        }
        XCTAssertEqual(mastodon.map(\.handle), ["far@other.example", "near@social.example"])
    }

    func testCacheIsFreshForADay() {
        var cache = FollowCache()
        let me = SocialAccount(service: .bluesky, handle: "me.example")
        let now = Date()
        XCTAssertFalse(cache.isFresh(me, now: now))
        cache.store([FollowedAccount(service: .bluesky, handle: "a", name: "A")], for: me, now: now)
        XCTAssertTrue(cache.isFresh(me, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(cache.isFresh(me, now: now.addingTimeInterval(90_000)))
    }
}
