import XCTest
@testable import QuillCore

final class CoreTests: XCTestCase {
    func testPrivateVisibilityCannotSyndicate() throws {
        var draft = Draft(kind: .note)
        draft.content = "Private words"
        draft.visibility = "private"
        draft.syndication = ["https://social.example/"]
        let properties = try Payload.create(draft).object?["properties"]?.object
        XCTAssertNil(properties?["mp-syndicate-to"])
        XCTAssertEqual(properties?["visibility"], .array([.string("private")]))
    }
    func testWorkoutUsesSecondsAndNestedMeasures() throws {
        var draft = Draft(kind: .exercise)
        draft.fields = ["activity": "running", "minutes": "25", "heartrate": "132"]
        let body = try Payload.create(draft)
        let workout = body.object?["properties"]?.object?["workout"]?.array?.first?.object?["properties"]?.object
        XCTAssertEqual(workout?["duration"]?.array?.first?.object?["properties"]?.object?["num"], .array([.number(1500)]))
    }
    func testItineraryRetainsIndependentTimeZones() throws {
        var draft = Draft(kind: .itinerary)
        draft.legs = [Leg(origin: "JFK", destination: "LHR", departure: "2026-12-01T20:00:00-05:00", arrival: "2026-12-02T08:00:00+00:00")]
        let legs = try Payload.create(draft).object?["properties"]?.object?["itinerary"]?.array
        XCTAssertEqual(legs?.first?.object?["type"], .array([.string("h-leg")]))
        XCTAssertEqual(legs?.first?.object?["properties"]?.object?["arrival"], .array([.string(draft.legs[0].arrival)]))
    }
    func testReviewIsHReviewWithProduct() throws {
        var draft = Draft(kind: .review)
        draft.fields = ["item-name": "Book", "item-url": "https://example.com/book", "rating": "4"]
        let body = try Payload.create(draft)
        XCTAssertEqual(body.object?["type"], .array([.string("h-review")]))
        XCTAssertEqual(body.object?["properties"]?.object?["item"]?.array?.first?.object?["type"], .array([.string("h-product")]))
    }
    func testBlankAndMalformedTargetsAreRejected() {
        XCTAssertThrowsError(try Payload.create(Draft(kind: .note)))
        var draft = Draft(kind: .like); draft.target = "javascript:alert(1)"
        XCTAssertThrowsError(try Payload.create(draft))
    }
    func testRSVPAndLegacyFieldNames() throws {
        var draft = Draft(kind: .reply); draft.content = "See you"; draft.target = "https://example.com/event"
        draft.fields["rsvp"] = "yes"; draft.slug = "party"
        var prefs = Preferences(); prefs.slugField = "slug"
        let props = try Payload.create(draft, preferences: prefs).object?["properties"]?.object
        XCTAssertEqual(props?["rsvp"], .array([.string("yes")]))
        XCTAssertEqual(props?["slug"], .array([.string("party")]))
    }
    func testDraftAndAttachmentRoundTripAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DraftStore(directory: root)
        var draft = Draft(kind: .photo); draft.content = "Image"
        draft.attachments = [Attachment(data: Data([0,1,2]), filename: "photo.jpg", mimeType: "image/jpeg", alt: "A tree")]
        try store.save(draft)
        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.attachments.first?.data, Data([0,1,2]))
        XCTAssertEqual(loaded.first?.id, draft.id)
        try store.delete(draft.id)
        XCTAssertTrue(try store.load().isEmpty)
    }
}

extension CoreTests {
    func testEnablingPublicationDatePreservesSavedDate() {
        var d = Draft(kind:.note); d.published = "2030-12-01T12:00:00-05:00"
        d.setPublicationDateEnabled(true)
        XCTAssertEqual(d.published,"2030-12-01T12:00:00-05:00")
    }
    func testReceiptComparesInstantsAcrossOffsets() {
        var d = Draft(kind:.note); d.content = "Hello"; d.published = "2026-11-13T20:00:00+14:00"
        let receipt = Receipt(draft:d,url:URL(string:"https://example.com/1")!,now:ISO8601DateFormatter().date(from:"2026-11-13T15:00:00Z")!)
        XCTAssertEqual(receipt.status,"Published")
    }
    func testArticleMediaUsesCurrentAltAndRemovesDeletedImageTokens() throws {
        var d = Draft(kind:.article); d.isHTML = true; d.content = "<p>A story</p><img src=\"quill-attachment:deleted\">"
        var photo = Attachment(data:Data([1,2]),filename:"photo.jpg",mimeType:"image/jpeg",alt:"Two <trees>")
        photo.remoteURL = URL(string:"https://example.com/photo.jpg")!
        d.attachments = [photo]
        let html = try Payload.create(d).object?["properties"]?.object?["content"]?.array?.first?.object?["html"]?.string ?? ""
        XCTAssertTrue(html.contains("https://example.com/photo.jpg"))
        XCTAssertTrue(html.contains("Two &lt;trees&gt;"))
        XCTAssertFalse(html.contains("quill-attachment:"))
    }
    func testBlankDraftsAreNotWorthKeeping() {
        var review = Draft(kind:.review); review.fields["rating"] = "5"
        XCTAssertTrue(review.isBlank)
        var trip = Draft(kind:.itinerary); trip.legs = [Leg(departure:"2030-01-01T00:00:00Z")]
        XCTAssertTrue(trip.isBlank)
        var note = Draft(kind:.note); note.content = "  \n"
        XCTAssertTrue(note.isBlank)
        note.content = "Hello"
        XCTAssertFalse(note.isBlank)
        var like = Draft(kind:.like); like.target = "https://example.com/post"
        XCTAssertFalse(like.isBlank)
    }
    func testCanonicalSiteAddsRootPath() throws {
        XCTAssertEqual(try WebURL.site("example.com").absoluteString,"https://example.com/")
    }
}

extension CoreTests {
    func testEveryKindProducesExpectedVocabulary() throws {
        let expected: [PostKind:String] = [.note:"content",.photo:"photo",.reply:"in-reply-to",.article:"content",.bookmark:"bookmark-of",.like:"like-of",.repost:"repost-of",.event:"start",.review:"item",.itinerary:"itinerary",.code:"p3k-content-type",.weight:"weight",.exercise:"workout"]
        for kind in PostKind.allCases {
            var d = Draft(kind:kind); d.content = "Test content"; d.title = "Test title"; d.target = "https://example.com/post"
            d.fields = ["photo-url":"https://example.com/photo.jpg","start":"2030-01-01T12:00:00Z","item-name":"A book","item-url":"https://example.com/book","rating":"5","weight":"140","activity":"running","minutes":"20"]
            d.legs = [Leg(origin:"JFK",destination:"LHR",departure:"2030-01-01T12:00:00Z",arrival:"2030-01-01T20:00:00Z")]
            let payload = try Payload.create(d)
            XCTAssertNotNil(payload.object?["properties"]?.object?[expected[kind]!],kind.rawValue)
        }
    }
}

extension CoreTests {
    func testLegacyArticleRepresentationRetainsAttachedImages() throws {
        var d = Draft(kind:.article); d.content = "<p>Story</p>"; d.isHTML = true
        d.attachments = [Attachment(data:Data([1]),filename:"a.jpg",mimeType:"image/jpeg")]
        var prefs = Preferences(); prefs.htmlContent = false
        let text = try Payload.create(d,preferences:prefs).object?["properties"]?.object?["content"]?.array?.first?.string
        XCTAssertTrue(text?.contains("data:image/jpeg;base64,AQ==") == true)
    }
    func testPhotoOnlyArticleAndExternalPhotoAreIncluded() throws {
        var d = Draft(kind:.article); d.isHTML = true; d.fields["photo-url"] = "https://example.com/photo.jpg"
        let text = try Payload.create(d).object?["properties"]?.object?["content"]?.array?.first?.object?["html"]?.string
        XCTAssertTrue(text?.contains("https://example.com/photo.jpg") == true)
    }
}
