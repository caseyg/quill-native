import XCTest

/// Runs against the local fixture account. Start `python3 scripts/fixture_server.py` for the publishing tests.
final class QuillNativeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ arguments: [String] = [], fixture: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (fixture ? ["--fixture"] : []) + arguments
        app.launch()
        return app
    }

    private func route(_ path: String, _ items: [String: String] = [:]) -> [String] {
        var components = URLComponents(string: "quill-native://" + path)!
        if !items.isEmpty { components.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return ["--route", components.url!.absoluteString]
    }

    /// A growing text field is a text view to XCUITest on some releases and a text field on others.
    private func content(in app: XCUIApplication) -> XCUIElement {
        let view = app.textViews["composer.content"]
        return view.waitForExistence(timeout: 3) ? view : app.textFields["composer.content"]
    }

    private func row(_ text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testSignInTakesABareDomainAndNothingElse() throws {
        let app = launch(fixture: false)
        let site = app.textFields["login.site"]
        guard site.waitForExistence(timeout: 5) else { throw XCTSkip("This simulator is already signed in.") }
        XCTAssertFalse(app.buttons["login.button"].isEnabled)
        XCTAssertFalse(app.textFields["login.clientID"].exists)
        site.tap(); site.typeText("example.com")
        XCTAssertTrue(app.buttons["login.button"].isEnabled)
        app.buttons["login.mode"].tap()
        XCTAssertTrue(app.secureTextFields["login.token"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["login.button"].isEnabled)
    }

    func testDraftSavesOnCloseAndResumes() {
        let text = "A thought saved on this device \(Int(Date().timeIntervalSince1970))"
        let app = launch()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5))
        app.buttons["compose"].tap()
        let field = content(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(text)
        app.buttons["close"].tap()
        let saved = row(text, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        let resumed = content(in: app)
        XCTAssertTrue(resumed.waitForExistence(timeout: 5))
        XCTAssertEqual(resumed.value as? String, text)
    }

    func testBlankNoteCannotPostAndLeavesNoDraft() {
        let app = launch()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5))
        let before = app.cells.count
        app.buttons["compose"].tap()
        XCTAssertTrue(app.buttons["publish"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["publish"].isEnabled)
        app.buttons["close"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.cells.count, before)
    }

    func testEveryComposerOpens() {
        for kind in ["note", "photo", "reply", "article", "bookmark", "like", "repost", "event", "review", "itinerary", "code", "weight", "exercise"] {
            let app = launch(route(kind))
            XCTAssertTrue(app.buttons["close"].waitForExistence(timeout: 5), "Missing composer: " + kind)
            let bar = app.navigationBars.firstMatch
            let title = kind.capitalized
            XCTAssertTrue(app.navigationBars[title].exists || bar.buttons[title].exists || bar.staticTexts[title].exists, "Missing title: " + kind)
            app.terminate()
        }
    }

    func testPostingClosesTheComposerAndListsThePost() {
        let text = "Local fixture publishing check \(Int(Date().timeIntervalSince1970))"
        let app = launch(route("note", ["text": text]))
        XCTAssertTrue(app.buttons["publish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["publish"].isEnabled)
        app.buttons["publish"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 15), "Is scripts/fixture_server.py running?")
        XCTAssertFalse(app.buttons["publish"].exists)
        search(text, in: app)
        XCTAssertTrue(row(text, in: app).waitForExistence(timeout: 5))
    }

    func testInvalidTargetShowsInlineError() {
        let app = launch(route("like", ["url": "not a link"]))
        XCTAssertTrue(app.buttons["publish"].waitForExistence(timeout: 5))
        app.buttons["publish"].tap()
        XCTAssertTrue(app.staticTexts["composer.error"].waitForExistence(timeout: 3) || app.otherElements["composer.error"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["close"].exists)
    }

    func testAppIntentPreservesText() {
        let app = launch(["--run-note-intent"])
        let field = content(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Intent handoff with preserved text")
    }

    func testDatedDraftSurvivesResume() {
        let text = "Dated draft regression \(Int(Date().timeIntervalSince1970))"
        let app = launch(route("note", ["text": text, "published": "2030-12-01T12:00:00-05:00"]))
        XCTAssertTrue(app.buttons["close"].waitForExistence(timeout: 5))
        app.buttons["close"].tap()
        let saved = row(text, in: app)
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertTrue(app.buttons["details"].waitForExistence(timeout: 5))
        app.buttons["details"].tap()
        let request = app.buttons["details.request"]
        // Form rows are created lazily, so scroll the Details sheet until the row exists.
        XCTAssertTrue(app.navigationBars["Details"].waitForExistence(timeout: 5))
        for _ in 0..<6 where !request.exists || !request.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(request.waitForExistence(timeout: 5))
        request.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "2030-12-01T12:00:00-05:00")).firstMatch.waitForExistence(timeout: 5))
    }

    /// Opens Settings, flips a switch and returns to the list.
    /// Picks the default format in Settings.
    private func format(_ name: String, in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        let picker = app.buttons["settings.format"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        let option = app.buttons[name].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    private func setting(_ name: String, in app: XCUIApplication, postType: Bool = false, on: Bool) {
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        if postType {
            XCTAssertTrue(app.buttons["Post Types"].waitForExistence(timeout: 5))
            app.buttons["Post Types"].tap()
        }
        let toggle = app.switches[name]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if (toggle.value as? String == "1") != on { toggle.switches.firstMatch.tap() }
        XCTAssertEqual(toggle.value as? String, on ? "1" : "0")
        if postType { app.navigationBars["Post Types"].buttons.firstMatch.tap() }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    /// Filters the list, since posts sit below any drafts and lists only build rows on screen.
    private func search(_ text: String, in app: XCUIApplication) {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let value = field.value as? String, !value.isEmpty, value != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        field.typeText(text)
    }

    func testPostLibraryListsSearchesAndEdits() {
        let app = launch()
        search("heron", in: app)
        XCTAssertTrue(row("A heron on the river", in: app).waitForExistence(timeout: 15), "Is scripts/fixture_server.py running?")
        search("cafe", in: app)
        XCTAssertTrue(row("Trying the new café", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("A heron on the river", in: app).exists)
        row("Trying the new café", in: app).tap()
        let field = content(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        XCTAssertEqual(field.value as? String, "Trying the new café on Atlantic")
        app.buttons["close"].firstMatch.tap()
        // An unchanged edit leaves no draft behind, so the post is listed once.
        XCTAssertTrue(row("Trying the new café", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Trying the new café")).count, 1)
    }

    func testHiddenPostTypesLeaveTheListAndMenu() {
        let app = launch()
        setting("Like", in: app, postType: true, on: false)
        app.buttons["compose"].press(forDuration: 1)
        XCTAssertTrue(app.buttons["Repost"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Like"].exists)
        app.buttons["Repost"].tap()
        XCTAssertTrue(app.buttons["close"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["close"].firstMatch.tap()
        search("example.com/article", in: app)
        // The empty search state repeats the query, so look for the row's own label.
        let likeRow = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "https://example.com/article")).firstMatch
        XCTAssertFalse(likeRow.waitForExistence(timeout: 3))
        app.terminate()
        let again = launch()
        setting("Like", in: again, postType: true, on: true)
        search("example.com/article", in: again)
        XCTAssertTrue(row("example.com/article", in: again).waitForExistence(timeout: 15), "Is scripts/fixture_server.py running?")
    }

    func testMarkdownSettingMarksPosts() throws {
        let text = "Markdown *check* \(Int(Date().timeIntervalSince1970))"
        let app = launch()
        format("Markdown", in: app)
        defer { app.terminate(); let again = launch(); format("Plain Text", in: again) }
        app.buttons["compose"].tap()
        let field = content(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(text)
        app.buttons["publish"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 15), "Is scripts/fixture_server.py running?")
        search("Markdown check", in: app)
        XCTAssertTrue(row("Markdown check", in: app).waitForExistence(timeout: 5))
        let log = try String(contentsOfFile: "/private/tmp/quill-fixture-requests.jsonl", encoding: .utf8)
        let request = try XCTUnwrap(log.split(separator: "\n").last { $0.contains("Markdown *check*") })
        XCTAssertTrue(request.contains("p3k-content-type") && request.contains("markdown"), String(request))
    }

    func testSyncIsOptInAndTurningItOffClearsPosts() {
        let app = launch(["--sync-off"])
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        let toggle = app.switches["settings.sync"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.switches.firstMatch.tap()
        // The footer counts the posts kept on the device once the download finishes.
        let summary = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS %@", "posts on this iPhone · Updated", "Syncing")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Is scripts/fixture_server.py running?")
        XCTAssertFalse(summary.label.hasPrefix("0 "), summary.label)
        toggle.switches.firstMatch.tap()
        let delete = app.buttons["Delete Posts from iPhone"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.buttons["Done"].tap()
        search("Trying the new", in: app)
        XCTAssertFalse(row("Trying the new café", in: app).waitForExistence(timeout: 3))
    }

    func testSettingsOpensAndCloses() {
        let app = launch()
        XCTAssertTrue(app.buttons["settings"].waitForExistence(timeout: 5))
        app.buttons["settings"].tap()
        XCTAssertTrue(app.buttons["signout"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5))
    }

    func testShareExtensionSavesURLDraft() {
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.terminate()
        safari.open(URL(string: "http://localhost:8765/posts/test")!)
        let share = safari.buttons["Share"].firstMatch
        if !share.waitForExistence(timeout: 3) { safari.buttons["More"].firstMatch.tap() }
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let quill = safari.cells["Quill"].firstMatch
        if !quill.waitForExistence(timeout: 2) {
            let more = safari.cells["More"].firstMatch
            if more.exists { more.tap() }
        }
        XCTAssertTrue(quill.waitForExistence(timeout: 5)); quill.tap()
        let save = safari.buttons["Save"].firstMatch
        let post = safari.buttons["Post"].firstMatch
        let action = save.waitForExistence(timeout: 3) ? save : post
        XCTAssertTrue(action.waitForExistence(timeout: 3)); action.tap()
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
        let app = launch()
        XCTAssertTrue(row("localhost:8765/posts/test", in: app).waitForExistence(timeout: 5))
    }

    /// README screenshots. Run on a fresh install with the fixture server up; images are test attachments.
    func testScreenshots() {
        func capture(_ app: XCUIApplication, _ name: String) {
            sleep(1)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
        }
        var app = launch(route("note", ["text": "Planted the first tomatoes of the year."]))
        XCTAssertTrue(app.buttons["publish"].waitForExistence(timeout: 5)); app.buttons["publish"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 15)); app.terminate()
        for (kind, items) in [("bookmark", ["url": "https://indieweb.org/Micropub"]), ("note", ["text": "Notes on the new garden beds"])] {
            app = launch(route(kind, items))
            XCTAssertTrue(app.buttons["close"].waitForExistence(timeout: 5)); app.buttons["close"].tap()
            XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5)); app.terminate()
        }
        app = launch()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5)); capture(app, "home-light")
        app.buttons["compose"].tap()
        XCTAssertTrue(content(in: app).waitForExistence(timeout: 5)); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        capture(app, "composer-light"); app.terminate()
        app = launch(["--dark"])
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 5)); capture(app, "home-dark"); app.terminate()
        app = launch(fixture: false)
        if app.textFields["login.site"].waitForExistence(timeout: 5) { capture(app, "sign-in-light") }
        app.terminate()
    }

    /// Opt-in only: posts one real note to the signed-in site. Never retry after an ambiguous result.
    func testAuthorizedLiveNotePublication() throws {
        guard ProcessInfo.processInfo.environment["QUILL_LIVE_TEST"] == "1" else { throw XCTSkip("Posts to a real site. Set QUILL_LIVE_TEST=1 to allow one test post.") }
        let app = launch(route("note", ["text": "Test post from Quill for iOS."]), fixture: false)
        XCTAssertTrue(app.buttons["publish"].waitForExistence(timeout: 5))
        app.buttons["publish"].tap()
        XCTAssertTrue(app.buttons["compose"].waitForExistence(timeout: 60) && !app.buttons["publish"].exists, "Do not retry: check the site and the kept draft first.")
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "Live post"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
