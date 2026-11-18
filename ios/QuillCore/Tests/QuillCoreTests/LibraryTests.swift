import XCTest
@testable import QuillCore

final class LibraryTests: XCTestCase {
    private func ok(_ url: URL, _ body: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    func testListingFollowsPagingUntilTheEnd() async throws {
        let endpoint = URL(string: "https://example.com/micropub")!
        let client = MicropubClient(endpoint: endpoint, token: "t", transport: { req in
            let query = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertTrue(query.contains(URLQueryItem(name: "q", value: "source")))
            if query.contains(where: { $0.name == "after" }) {
                return self.ok(req.url!, #"{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/2"],"content":["Second"],"published":["2026-11-01T10:00:00Z"]}}]}"#)
            }
            return self.ok(req.url!, #"{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/1"],"name":["Hello"],"content":[{"html":"<p>Body</p>","value":"Body"}],"published":["2026-11-02T10:00:00Z"]}}],"paging":{"after":"abc"}}"#)
        })
        let result = try await LibrarySync.fetch(client: client, me: URL(string: "https://example.com/")!)
        XCTAssertEqual(result.source, .micropub)
        XCTAssertEqual(result.posts.map(\.url.absoluteString), ["https://example.com/1", "https://example.com/2"])
        XCTAssertEqual(result.posts[0].kind, .article)
        XCTAssertEqual(result.posts[1].kind, .note)
    }

    func testRefreshStopsAtPostsAlreadyOnDevice() async throws {
        let endpoint = URL(string: "https://example.com/micropub")!
        let pages = Counter()
        let client = MicropubClient(endpoint: endpoint, token: "t", transport: { req in
            pages.add()
            let after = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }?.value
            let n = Int(after ?? "0")!
            return self.ok(req.url!, #"{"items":[{"type":["h-entry"],"properties":{"url":["https://example.com/\#(n)"],"content":["Post \#(n)"]}}],"paging":{"after":"\#(n + 1)"}}"#)
        })
        let result = try await LibrarySync.fetch(client: client, me: URL(string: "https://example.com/")!, known: ["https://example.com/2"])
        XCTAssertEqual(result.posts.map(\.url.absoluteString), ["https://example.com/0", "https://example.com/1", "https://example.com/2"])
        XCTAssertTrue(result.finished)
        XCTAssertEqual(pages.value, 3)
    }

    func testRefreshKeepsOlderPostsAndCompletion() {
        var library = Library()
        let old = Post(url: URL(string: "https://example.com/old")!, kind: .note)
        library.replace(with: [old], source: .micropub, complete: false)
        XCTAssertFalse(library.isComplete)
        var new = Post(url: URL(string: "https://example.com/new")!, kind: .note); new.published = Date()
        library.replace(with: [new], source: .micropub, keeping: true)
        XCTAssertEqual(library.posts.map(\.url.lastPathComponent), ["new", "old"])
        XCTAssertTrue(library.isComplete)
    }

    func testLibrariesSavedBeforeCompletionWasKeptCountAsComplete() throws {
        let library = try JSONDecoder().decode(Library.self, from: Data(#"{"posts":[],"synced":0}"#.utf8))
        XCTAssertTrue(library.isComplete)
        XCTAssertFalse(Library().isComplete)
    }

    func testFallsBackToJSONFeedWhenListingIsUnsupported() async throws {
        let endpoint = URL(string: "https://example.com/micropub")!
        let client = MicropubClient(endpoint: endpoint, token: "t", transport: { req in self.ok(req.url!, #"{"error":"invalid_request"}"#, status: 400) })
        let result = try await LibrarySync.fetch(client: client, me: URL(string: "https://example.com/")!, fetch: { req in
            if req.url!.path == "/" { return self.ok(req.url!, #"<link rel="alternate" type="application/rss+xml" href="/feed.xml"><link rel="alternate" type="application/feed+json" href="/feed.json">"#) }
            XCTAssertEqual(req.url!.path, "/feed.json")
            return self.ok(req.url!, #"{"version":"https://jsonfeed.org/version/1.1","items":[{"id":"1","url":"https://example.com/p/1","content_html":"<p><img src=\"https://example.com/a.jpg\" alt=\"A heron\"></p>","date_published":"2026-11-15T15:30:53.000Z"}]}"#)
        })
        XCTAssertEqual(result.source, .feed)
        XCTAssertEqual(result.posts.first?.kind, .photo)
        XCTAssertEqual(result.posts.first?.photo?.absoluteString, "https://example.com/a.jpg")
        XCTAssertEqual(result.posts.first?.displayTitle, "A heron")
        XCTAssertNotNil(result.posts.first?.published)
    }

    func testRSSEntriesParse() {
        let rss = #"<rss><channel><item><title>Post</title><link>https://example.com/a</link><description><![CDATA[<p>Words here</p>]]></description><pubDate>Sat, 14 Nov 2026 20:24:13 +0000</pubDate></item></channel></rss>"#
        let posts = Feed.parse(Data(rss.utf8)).posts
        XCTAssertEqual(posts.first?.url.absoluteString, "https://example.com/a")
        XCTAssertEqual(posts.first?.text, "Words here")
        XCTAssertNotNil(posts.first?.published)
    }

    func testPhotoPostsUseBodyThenAltForTitle() {
        let item = JSONValue.object(["type": .array([.string("h-entry")]), "properties": .object([
            "url": .array([.string("https://example.com/p")]),
            "photo": .array([.object(["value": .string("https://example.com/p.jpg"), "alt": .string("Sunset over the river")])]),
        ])])
        let post = Post(mf2: item)!
        XCTAssertEqual(post.kind, .photo)
        XCTAssertEqual(post.displayTitle, "Sunset over the river")
        var draft = Draft(kind: .photo)
        draft.attachments = [Attachment(data: Data(), filename: "a.jpg", mimeType: "image/jpeg", alt: "A dog")]
        XCTAssertEqual(draft.displayTitle, "A dog")
    }

    func testSearchMatchesEveryTermAcrossFields() {
        var post = Post(url: URL(string: "https://example.com/1")!, kind: .note)
        post.text = "Walked to the café"; post.categories = ["brooklyn"]
        XCTAssertTrue(post.matches("cafe brooklyn"))
        XCTAssertFalse(post.matches("cafe queens"))
    }

    func testFeedSyncKeepsOlderPostsAndSortsNewestFirst() {
        var library = Library()
        var old = Post(url: URL(string: "https://example.com/old")!, kind: .note); old.published = Date(timeIntervalSince1970: 1)
        library.replace(with: [old], source: .feed)
        var new = Post(url: URL(string: "https://example.com/new")!, kind: .note); new.published = Date(timeIntervalSince1970: 2)
        library.replace(with: [new], source: .feed)
        XCTAssertEqual(library.posts.map(\.url.lastPathComponent), ["new", "old"])
        library.replace(with: [new], source: .micropub)
        XCTAssertEqual(library.posts.count, 1)
    }

    func testEditingSendsOnlyChangedProperties() throws {
        let source = JSONValue.object(["type": .array([.string("h-entry")]), "properties": .object([
            "content": .array([.string("First *draft*")]),
            "category": .array([.string("one")]),
            "p3k-content-type": .array([.string("text/markdown")]),
        ])])
        var draft = try Draft(source: source, url: URL(string: "https://example.com/1")!)
        XCTAssertEqual(draft.kind, .note)
        XCTAssertThrowsError(try Payload.update(draft))
        draft.content = "Second"
        draft.tags = ""
        let body = try Payload.update(draft).object!
        XCTAssertEqual(body["replace"]?.object?["content"], .array([.string("Second")]))
        XCTAssertEqual(body["replace"]?.object?["p3k-content-type"], .array([.string("text/markdown")]))
        XCTAssertEqual(body["delete"], .array([.string("category")]))
        XCTAssertNil(body["replace"]?.object?["name"])
    }

    func testEditingKeepsPhotosAndSendsTheirNewOrderAndDescriptions() throws {
        let source = JSONValue.object(["type": .array([.string("h-entry")]), "properties": .object([
            "content": .array([.string("Two photos")]),
            "photo": .array([.string("https://example.com/a.jpg"), .object(["value": .string("https://example.com/b.jpg"), "alt": .string("A dog")])]),
        ])])
        var draft = try Draft(source: source, url: URL(string: "https://example.com/1")!)
        XCTAssertEqual(draft.attachments.map(\.remoteURL?.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertEqual(draft.attachments.map(\.alt), ["", "A dog"])
        XCTAssertThrowsError(try Payload.update(draft), "Nothing has changed yet")

        draft.attachments.reverse()
        draft.attachments[1].alt = "A cat\nasleep on a chair"
        let body = try Payload.update(draft).object!
        XCTAssertEqual(body["replace"]?.object?["photo"], .array([
            .object(["value": .string("https://example.com/b.jpg"), "alt": .string("A dog")]),
            .object(["value": .string("https://example.com/a.jpg"), "alt": .string("A cat\nasleep on a chair")]),
        ]))
        XCTAssertNil(body["replace"]?.object?["content"])

        draft.attachments.removeAll()
        XCTAssertEqual(try Payload.update(draft).object?["delete"], .array([.string("photo")]))
    }

    func testAddedPhotoNeedsUploadingBeforeAnUpdate() throws {
        let source = JSONValue.object(["properties": .object(["content": .array([.string("Hi")])])])
        var draft = try Draft(source: source, url: URL(string: "https://example.com/1")!)
        draft.attachments.append(Attachment(data: Data([1]), filename: "new.jpg", mimeType: "image/jpeg"))
        XCTAssertThrowsError(try Payload.update(draft))
        draft.attachments[0].remoteURL = URL(string: "https://example.com/media/new.jpg")
        XCTAssertEqual(try Payload.update(draft).object?["replace"]?.object?["photo"], .array([.string("https://example.com/media/new.jpg")]))
    }

    func testRichHTMLStaysHTMLWhenEditing() throws {
        let source = JSONValue.object(["properties": .object(["content": .array([.object(["html": .string("<blockquote>Quote</blockquote>")])])])])
        let draft = try Draft(source: source, url: URL(string: "https://example.com/1")!)
        XCTAssertTrue(draft.isHTML)
        let plain = try Draft(source: .object(["properties": .object(["content": .array([.object(["html": .string("<p>Just words</p>")])])])]), url: URL(string: "https://example.com/2")!)
        XCTAssertFalse(plain.isHTML)
        XCTAssertEqual(plain.content, "Just words")
    }

    func testStructuredPostsAreNotEditedHere() {
        XCTAssertThrowsError(try Draft(source: .object(["type": .array([.string("h-event")]), "properties": .object([:])]), url: URL(string: "https://example.com/e")!))
    }
}

final class MarkdownTests: XCTestCase {
    func testMarkdownNoteIsMarkedForTheServer() throws {
        var draft = Draft(kind: .note); draft.content = "Hello *there*"; draft.fields["p3k-content-type"] = "text/markdown"
        let p = try Payload.create(draft).object?["properties"]?.object
        XCTAssertEqual(p?["content"], .array([.string("Hello *there*")]))
        XCTAssertEqual(p?["p3k-content-type"], .array([.string("text/markdown")]))
    }
    func testMarkdownArticleAppendsImagesAsMarkdown() throws {
        var draft = Draft(kind: .article); draft.title = "T"; draft.content = "# Heading"; draft.fields["p3k-content-type"] = "text/markdown"
        var photo = Attachment(data: Data(), filename: "a.jpg", mimeType: "image/jpeg", alt: "A cat"); photo.remoteURL = URL(string: "https://example.com/a.jpg")
        draft.attachments = [photo]
        let p = try Payload.create(draft).object?["properties"]?.object
        XCTAssertEqual(p?["content"], .array([.string("# Heading\n\n![A cat](https://example.com/a.jpg)")]))
    }
    func testHTMLDraftsIgnoreMarkdownMarker() throws {
        var draft = Draft(kind: .article); draft.content = "<p>x</p>"; draft.isHTML = true
        XCTAssertNil(try Payload.create(draft).object?["properties"]?.object?["p3k-content-type"])
    }
    func testOldPreferencesStillLoad() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"weightUnit":"kg"}"#.utf8))
        XCTAssertEqual(prefs.weightUnit, "kg")
        XCTAssertEqual(prefs.format, .plain)
        XCTAssertEqual(prefs.visibleKinds.count, PostKind.allCases.count)
    }
    func testOldMarkdownSwitchBecomesTheDefaultFormat() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(#"{"markdown":true}"#.utf8))
        XCTAssertEqual(prefs.format, .markdown)
        XCTAssertEqual(prefs.format(for: .note), .markdown)
        XCTAssertEqual(prefs.format(for: .review), .plain)
        XCTAssertNil(prefs.format(for: .like))
    }
    func testFormatOverridesRoundTrip() throws {
        var prefs = Preferences(); prefs.format = .markdown; prefs.formatOverrides[.article] = .html
        let again = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(prefs))
        XCTAssertEqual(again, prefs)
        XCTAssertEqual(again.format(for: .article), .html)
        XCTAssertEqual(again.format(for: .note), .markdown)
    }
    func testPlainDefaultWritesArticlesInMarkdown() {
        var draft = Draft(kind: .note)
        draft.prepare(for: .article, preferences: Preferences())
        XCTAssertEqual(draft.format, .markdown)
        draft.prepare(for: .note, preferences: Preferences())
        XCTAssertEqual(draft.format, .plain)
    }
    func testDraftFormatSetsMarkers() {
        var draft = Draft(kind: .note)
        draft.format = .markdown
        XCTAssertEqual(draft.fields["p3k-content-type"], "text/markdown"); XCTAssertFalse(draft.isHTML)
        draft.format = .html
        XCTAssertNil(draft.fields["p3k-content-type"]); XCTAssertTrue(draft.isHTML)
        draft.format = .plain
        XCTAssertEqual(draft.format, .plain)
    }
    func testRecordingsGoInTheAudioProperty() throws {
        var draft = Draft(kind: .note); draft.content = "Said aloud"
        var audio = Attachment(data: Data(), filename: "v.m4a", mimeType: "audio/mp4"); audio.remoteURL = URL(string: "https://example.com/v.m4a")
        var photo = Attachment(data: Data(), filename: "a.jpg", mimeType: "image/jpeg"); photo.remoteURL = URL(string: "https://example.com/a.jpg")
        draft.attachments = [audio, photo]
        let p = try Payload.create(draft).object?["properties"]?.object
        XCTAssertEqual(p?["audio"], .array([.string("https://example.com/v.m4a")]))
        XCTAssertEqual(p?["photo"], .array([.string("https://example.com/a.jpg")]))
    }
    func testARecordingAloneIsNotAPhoto() {
        var draft = Draft(kind: .photo); draft.attachments = [Attachment(data: Data(), filename: "v.m4a", mimeType: "audio/mp4")]
        XCTAssertThrowsError(try Payload.validate(draft))
    }
    func testRecordingsUploadAsAudioInMultipart() async throws {
        let body = Box()
        let client = MicropubClient(endpoint: URL(string: "https://example.com/micropub")!, token: "t", transport: { req in
            body.value = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: ["Location": "https://example.com/1"])!)
        })
        var draft = Draft(kind: .note); draft.content = "Hi"
        draft.attachments = [Attachment(data: Data("x".utf8), filename: "v.m4a", mimeType: "audio/mp4")]
        _ = try await client.create(draft)
        XCTAssertTrue(body.value.contains(#"name="audio[0]""#) || body.value.contains(#"name="audio""#), body.value)
        XCTAssertFalse(body.value.contains("photo["))
    }
    func testHTMLNoteSendsHTMLContent() throws {
        var draft = Draft(kind: .note); draft.content = "<p>Hi</p>"; draft.format = .html
        let p = try Payload.create(draft).object?["properties"]?.object
        XCTAssertEqual(p?["content"], .array([.object(["html": .string("<p>Hi</p>")])]))
    }
    func testMarkdownTextForRows() {
        XCTAssertEqual(Markdown.text("Happy bday to [@shannon](https://bsky.app/x) **today**"), "Happy bday to @shannon today")
    }
}

final class CiteTests: XCTestCase {
    func testOpenGraphGivesAuthorAndText() {
        let html = #"<head><title>@vruba.bsky.social on Bluesky</title><meta property="og:title" content="Charlie Loyd (@vruba.bsky.social)"><meta property="og:description" content="(We&#39;ve got to solve this &amp; that)"></head>"#
        let summary = PageSummary.parse(html: html)
        XCTAssertEqual(summary.author, "Charlie Loyd (@vruba.bsky.social)")
        XCTAssertEqual(summary.text, "(We've got to solve this & that)")
        var post = Post(url: URL(string: "https://example.com/like")!, kind: .like)
        post.target = "https://bsky.app/profile/x/post/1"
        XCTAssertTrue(post.needsCite)
        post.citeAuthor = summary.author; post.citeText = summary.text
        XCTAssertEqual(post.displayTitle, "(We've got to solve this & that)")
        XCTAssertEqual(post.citeName, "Charlie Loyd")
        XCTAssertTrue(post.matches("solve loyd"))
    }
    func testHCiteTargetsNeedNoFetch() {
        let item = JSONValue.object(["type": .array([.string("h-entry")]), "properties": .object([
            "url": .array([.string("https://example.com/l")]),
            "like-of": .array([.object(["type": .array([.string("h-cite")]), "properties": .object([
                "url": .array([.string("https://social.example/@a/1")]),
                "author": .array([.string("Ada")]),
                "content": .array([.string("Hello world")]),
            ])])]),
        ])])
        let post = Post(mf2: item)!
        XCTAssertEqual(post.kind, .like)
        XCTAssertEqual(post.target, "https://social.example/@a/1")
        XCTAssertFalse(post.needsCite)
        XCTAssertEqual(post.displayTitle, "Hello world")
    }
    func testSyncKeepsFetchedCites() {
        var library = Library()
        var post = Post(url: URL(string: "https://example.com/l")!, kind: .like); post.target = "https://b.example/1"
        library.replace(with: [post], source: .micropub)
        library.posts[0].citeAuthor = "Ada"; library.posts[0].citeText = "Hi"
        library.replace(with: [post], source: .micropub)
        XCTAssertEqual(library.posts[0].citeText, "Hi")
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class Box: @unchecked Sendable { var value = "" }
