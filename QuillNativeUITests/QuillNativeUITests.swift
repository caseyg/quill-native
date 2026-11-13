import XCTest

final class QuillNativeUITests: XCTestCase {
    func testSaveResumeDraftAndValidation() {
        let app = XCUIApplication(); app.launch()
        app.buttons["compose.note"].tap()
        let content = app.textViews["composer.content"].exists ? app.textViews["composer.content"] : app.textFields["composer.content"]
        content.tap(); content.typeText("A thought saved on this device")
        app.buttons["save.close"].tap()
        tapTab("Drafts",app:app)
        XCTAssertTrue(app.buttons.containing(.staticText,identifier:"A thought saved on this device").firstMatch.waitForExistence(timeout:5))
        app.buttons.containing(.staticText,identifier:"A thought saved on this device").firstMatch.tap()
        let resumed = app.textFields["composer.content"]
        XCTAssertTrue(resumed.waitForExistence(timeout:5))
        XCTAssertEqual(resumed.value as? String, "A thought saved on this device")
    }
    func testBlankNoteCannotPublish() {
        let app = XCUIApplication(); app.launch(); app.buttons["compose.note"].tap()
        app.swipeUp(); app.buttons["publish"].tap()
        XCTAssertTrue(app.staticTexts["Write something before publishing."].waitForExistence(timeout:3))
    }
}


extension QuillNativeUITests {
    func testEveryComposerOpens() {
        let app = XCUIApplication()
        for kind in ["note","photo","reply","article","bookmark","like","repost","event","review","itinerary","code","weight","exercise"] {
            app.launchArguments = ["--route","quill-native://" + kind]
            app.launch()
            XCTAssertTrue(app.buttons["save.close"].waitForExistence(timeout:5),"Missing composer: " + kind)
            XCTAssertTrue(app.navigationBars[kind.capitalized].exists,"Missing title: " + kind)
            app.buttons["save.close"].tap()
            app.terminate()
        }
    }
    func testFixturePublicationAndReceipt() {
        let app = XCUIApplication()
        app.launchArguments = ["--fixture","--route","quill-native://note?text=Local%20fixture%20publishing%20check"]
        app.launch()
        XCTAssertTrue(app.buttons["save.close"].waitForExistence(timeout:5))
        app.swipeUp()
        app.buttons["publish"].tap()
        let send = app.buttons["Send to site"]
        XCTAssertTrue(send.waitForExistence(timeout:3)); send.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","Published: http://localhost:8765/posts/test")).firstMatch.waitForExistence(timeout:15))
    }
}


extension QuillNativeUITests {
    func testAppIntentPreservesTextWithExistingStore() {
        let app = XCUIApplication(); app.launchArguments = ["--run-note-intent"]; app.launch()
        let content = app.textFields["composer.content"]
        XCTAssertTrue(content.waitForExistence(timeout:5))
        XCTAssertEqual(content.value as? String,"Intent handoff with preserved text")
    }
    func testDatedDraftSurvivesResume() {
        let app = XCUIApplication()
        app.launchArguments = ["--route","quill-native://note?text=Dated%20draft%20regression&published=2030-12-01T12%3A00%3A00-05%3A00"]
        app.launch(); XCTAssertTrue(app.buttons["save.close"].waitForExistence(timeout:5)); app.buttons["save.close"].tap()
        tapTab("Drafts",app:app)
        let saved = app.buttons.containing(.staticText,identifier:"Dated draft regression").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout:5)); saved.tap()
        app.buttons["Preview"].tap()
        app.swipeUp()
        let request = app.buttons["Micropub request"]
        XCTAssertTrue(request.waitForExistence(timeout:3)); request.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format:"label CONTAINS %@","2030-12-01T12:00:00-05:00")).firstMatch.waitForExistence(timeout:3))
    }
}

extension QuillNativeUITests {
    /// Opt-in only. Never run this automatically or retry after an ambiguous response.
    func testAuthorizedLiveNotePublication() throws {
        guard ProcessInfo.processInfo.environment["QUILL_LIVE_TEST"] == "1" else { throw XCTSkip("Requires explicit permission for one live test post and QUILL_LIVE_TEST=1.") }
        let app = XCUIApplication()
        let content = "Quill Native test post — native iOS publishing verification, November 13, 2026. This is the single authorized test post from the new SwiftUI app."
        var components = URLComponents(string:"quill-native://note")!
        components.queryItems = [URLQueryItem(name:"text",value:content)]
        app.launchArguments = ["--route",components.url!.absoluteString]
        app.launch()
        XCTAssertTrue(app.buttons["save.close"].waitForExistence(timeout:5))
        app.swipeUp(); app.buttons["publish"].tap()
        let send = app.buttons["Send to site"]
        XCTAssertTrue(send.waitForExistence(timeout:3)); send.tap()
        let receipt = app.staticTexts.containing(NSPredicate(format:"label BEGINSWITH %@","Published: https://caseyagollan.com/")).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout:60),"Do not retry: check the website and retained draft first.")
        if receipt.exists { print("LIVE_PUBLICATION_RECEIPT: " + receipt.label) }
        let screenshot = XCTAttachment(screenshot:app.screenshot()); screenshot.name = "Authorized live publication receipt"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}

extension QuillNativeUITests {
    func testShareExtensionSavesURLDraft() {
        let safari = XCUIApplication(bundleIdentifier:"com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string:"http://localhost:8765/posts/test")!)
        let share = safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout:3) { safari.buttons["More"].firstMatch.tap() }
        XCTAssertTrue(share.waitForExistence(timeout:5)); share.tap()
        let quill = safari.cells["Quill"].firstMatch
        if !quill.waitForExistence(timeout:2) {
            let more = safari.cells["More"].firstMatch
            if more.exists { more.tap() }
        }
        XCTAssertTrue(quill.waitForExistence(timeout:5)); quill.tap()
        let save = safari.buttons["Save draft"].firstMatch
        let post = safari.buttons["Post"].firstMatch
        let action = save.waitForExistence(timeout:3) ? save : post
        XCTAssertTrue(action.waitForExistence(timeout:3)); action.tap()
        let closed = XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:action)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:10),.completed)
        let app = XCUIApplication(); app.launchArguments = []; app.launch(); tapTab("Drafts",app:app)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format:"label CONTAINS %@","localhost:8765/posts/test")).firstMatch.waitForExistence(timeout:5))
    }
    func testHomeDarkLayout() {
        let app = XCUIApplication(); app.launchArguments = ["--dark"]; app.launch()
        XCTAssertTrue(app.buttons["compose.note"].waitForExistence(timeout:5))
        let capture = XCTAttachment(screenshot:app.screenshot()); capture.name = "Quill home dark"; capture.lifetime = .keepAlways; add(capture)
    }
}


private func tapTab(_ name: String, app: XCUIApplication) {
    if app.tabBars.buttons[name].exists { app.tabBars.buttons[name].tap() }
    else if app.cells[name].exists { app.cells[name].firstMatch.tap() }
    else if app.buttons[name].exists { app.buttons[name].firstMatch.tap() }
    else { app.otherElements[name].firstMatch.tap() }
}

extension QuillNativeUITests {
    func testLoginRequiresBothFullURLs() {
        let app = XCUIApplication(); app.launchArguments = ["--route","quill-native://settings"]; app.launch()
        let website = app.textFields["login.site"]
        let client = app.textFields["login.clientID"]
        XCTAssertTrue(website.waitForExistence(timeout:5))
        XCTAssertTrue(client.exists)
        website.tap(); website.typeText("caseyagollan.com")
        XCTAssertFalse(app.buttons["login.button"].isEnabled)
        website.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:"caseyagollan.com".count) + "https://caseyagollan.com/")
        XCTAssertTrue(app.buttons["login.button"].isEnabled)
        let originalClient = client.value as? String ?? ""
        client.tap(); client.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:originalClient.count) + "caseyagollan.com/clients/quill-native/")
        XCTAssertFalse(app.buttons["login.button"].isEnabled)
        let bareClient = "caseyagollan.com/clients/quill-native/"
        client.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:bareClient.count) + "https://caseyagollan.com/clients/quill-native/")
        XCTAssertTrue(app.buttons["login.button"].isEnabled)
    }
}
