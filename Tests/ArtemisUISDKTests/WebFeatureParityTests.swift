import XCTest

@testable import ArtemisSocketSDK
@testable import ArtemisUISDK

final class WebFeatureParityTests: XCTestCase {
    @MainActor func testFeedbackWaitsForAckAndRejectsConcurrentOrRepeatedSubmission() async {
        let state = MessageFeedbackState()
        var ack: CheckedContinuation<Void, Error>?
        var calls = 0
        let task = Task {
            await state.submit(rating: 0, comment: "  Missing detail  ") { rating, comment in
                calls += 1
                XCTAssertEqual(rating, 0)
                XCTAssertEqual(comment, "Missing detail")
                try await withCheckedThrowingContinuation { ack = $0 }
            }
        }
        while ack == nil { await Task.yield() }
        XCTAssertEqual(state.status, .pending)
        await state.submit(rating: 1, comment: nil) { _, _ in calls += 1 }
        XCTAssertEqual(calls, 1)
        ack?.resume()
        await task.value
        XCTAssertEqual(state.status, .submitted)
        await state.submit(rating: 1, comment: nil) { _, _ in calls += 1 }
        XCTAssertEqual(calls, 1)
    }
    @MainActor func testFeedbackRetryPreservesTheSubmittedPayloadAndPresentationIsSessionScoped()
        async
    {
        enum Failure: Error { case rejected }
        let presentation = ChatPresentationState()
        let state = presentation.feedback(for: "m1")
        state.comment = "draft that was skipped"
        await state.submit(rating: 0, comment: nil) { _, _ in throw Failure.rejected }
        XCTAssertEqual(state.status, .failed)
        XCTAssertEqual(state.comment, "draft that was skipped")
        XCTAssertTrue(presentation.feedback(for: "m1") === state)
        XCTAssertFalse(presentation.feedback(for: "m2") === state)
        await state.retry { rating, comment in
            XCTAssertEqual(rating, 0)
            XCTAssertNil(comment)
        }
        XCTAssertEqual(state.status, .submitted)
        presentation.clear()
        XCTAssertFalse(presentation.feedback(for: "m1") === state)
    }
    func testTimestampRuntimeSettingsAndLocaleTimezoneFormatting() throws {
        let settings = MessageTimestampSettings(runtime: [
            "messageTimestampEnabled": false, "messageTimestampVisibility": "interaction",
            "messageTimestampPosition": "above", "messageTimestampTimeFormat": "24h",
            "messageTimestampDateFormat": "dd-mm-yy",
        ])
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.visibility, .interaction)
        XCTAssertEqual(settings.position, .above)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-02T13:05:00Z"))
        XCTAssertEqual(
            settings.format(
                date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!),
            "02/01/26 • 13:05")
        XCTAssertTrue(
            settings.format(
                date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 7200)!
            ).hasSuffix("15:05"))
        let twelve = MessageTimestampSettings(timeFormat: .twelveHour, dateFormat: .monthDayYear)
        XCTAssertTrue(
            twelve.format(
                date, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!
            ).contains("1:05 PM"))
        XCTAssertEqual(
            MessageTimestampSettings(runtime: ["messageTimestampPosition": "invalid"]), .init())
    }
    func testTypedFormValidationRejectsMalformedValuesAndPreservesOptionalFields() {
        for value in ["", "not-an-email", "a@", "a@-bad.com", "a b@example.com"] {
            XCTAssertNotNil(FormFieldValidation.error(value: value, required: true, inputType: "email"))
        }
        XCTAssertNil(FormFieldValidation.error(value: "", required: false, inputType: "email"))
        XCTAssertNil(
            FormFieldValidation.error(value: "a+b@example.com", required: true, inputType: "email"))
        for value in ["NaN", "inf", "1.2.3", "1e999"] {
            XCTAssertNotNil(FormFieldValidation.error(value: value, required: true, inputType: "number"))
        }
        XCTAssertNil(FormFieldValidation.error(value: "-1.25e2", required: true, inputType: "number"))
        XCTAssertNotNil(
            FormFieldValidation.error(value: "2026-02-30", required: true, inputType: "date"))
        XCTAssertNil(FormFieldValidation.error(value: "2028-02-29", required: true, inputType: "date"))
        XCTAssertNotNil(FormFieldValidation.error(value: "24:00", required: true, inputType: "time"))
        XCTAssertNil(FormFieldValidation.error(value: "23:59", required: true, inputType: "time"))
        XCTAssertNotNil(
            FormFieldValidation.error(
                value: "unknown", required: true, inputType: nil, allowedOptions: ["known"]))
    }
    func testMarkdownRetainsNestedListsCodeAndQuotedBlocks() {
        let blocks = ChatMarkdownParser.parse(
            """
            # Heading

            3. Parent
               - Child
                 - Grandchild
            4. Next

            > Quote
            >
            > **Still quoted**

            ```swift
            # Not a heading
            | not | a table |
            ```
            """)
        XCTAssertEqual(blocks.first, .heading(1, "Heading"))
        guard case .list(true, 3, let items) = blocks[1] else {
            return XCTFail("Expected ordered list")
        }
        XCTAssertEqual(items.count, 2)
        guard case .list(false, _, let children) = items[0][1] else {
            return XCTFail("Expected nested unordered list")
        }
        XCTAssertEqual(children[0][0], .paragraph("Child"))
        XCTAssertEqual(blocks[2], .quote([.paragraph("Quote"), .paragraph("**Still quoted**")]))
        XCTAssertEqual(blocks.last, .code("# Not a heading\n| not | a table |", "swift"))
    }
    func testMarkdownTablesHandleEscapedPipesAndIncompleteStreamingFences() {
        XCTAssertEqual(ChatMarkdownParser.cells(#"| a\|b | `x|y` |"#), ["a|b", "`x|y`"])
        XCTAssertEqual(
            ChatMarkdownParser.parse("| A | B |\n| --- | :---: |\n| 1 | 2 |"),
            [.table(["A", "B"], [["1", "2"]])])
        XCTAssertEqual(
            ChatMarkdownParser.parse("~~~text\n<unsafe>\n# literal"),
            [.code("<unsafe>\n# literal", "text")])
    }
    @MainActor func testUnsafeMarkdownLinksCannotBecomeNavigable() {
        for source in [
            "[click](javascript:alert)", "[click](file:///private/file)", "[click](data:text/html,bad)",
        ] {
            XCTAssertTrue(ChatMarkdownCache.text(source).runs.allSatisfy { $0.link == nil })
        }
        XCTAssertTrue(
            ChatMarkdownCache.text("[safe](https://example.com)").runs.contains {
                $0.link?.host == "example.com"
            })
    }
    func testStringOverridesFallbackAndPlaceholdersDoNotRewriteUserData() {
        let strings = ChatStrings(
            localeIdentifier: "fr",
            overrides: ["Send message": "Envoyer", "Open {filename}": "Ouvrir {filename}"])
        XCTAssertEqual(strings("Send message"), "Envoyer")
        XCTAssertEqual(strings("validation.required"), "This field is required.")
        XCTAssertEqual(
            strings.format("Open {filename}", ["filename": "{count}.pdf", "count": "changed"]),
            "Ouvrir {count}.pdf")
    }
    func testSafeHTMLKeepsFormattingAndRejectsActiveContent() {
        let input =
            #"<h2>Title</h2><script>alert(1)</script><iframe src="https://evil.test"></iframe><p onclick="bad()">Safe <strong>bold</strong></p><img src="javascript:bad" onerror="bad()"><a href="jav&#x61;script:bad">blocked</a><a href="https://example.com/?a=1&amp;b=2">safe</a>"#
        let output = ChatHTMLSanitizer.sanitize(input)
        XCTAssertTrue(output.contains("<h2>Title</h2>"))
        XCTAssertTrue(output.contains("<strong>bold</strong>"))
        for fragment in ["<script", "<iframe", "onclick", "onerror", "javascript:", "alert(1)"] {
            XCTAssertFalse(output.contains(fragment), fragment)
        }
        XCTAssertTrue(output.contains(#"href="https://example.com/?a=1&amp;b=2""#))
        XCTAssertEqual(
            ChatHTMLSanitizer.sanitize(#"<p style="background:url(javascript:bad)">hello</p>"#),
            "<p>hello</p>")
        XCTAssertEqual(
            ChatHTMLSanitizer.sanitize(#"<svg><a href="https://evil.test">hidden</a></svg><p>end</p>"#),
            "<p>end</p>")
    }
    func testHTMLDocumentCannotBeBrokenByThemeValues() {
        let theme = theme([
            "fontFamily": "</style><script>bad</script>", "textColor": "</style><script>bad</script>",
        ])
        let document = ChatHTMLSanitizer.document("<p>Text</p>", theme: theme)
        XCTAssertFalse(document.contains("<script>"))
        XCTAssertTrue(document.contains("script-src 'none'"))
        XCTAssertTrue(document.contains("form-action 'none'"))
    }
    func testThemeAppliesNumericAndNamedRadiiDensityAndSafeBackgrounds() {
        let result = theme([
            "baseFontSize": 21, "density": "spacious", "messageBubbleRadius": "xl",
            "fontFamily": "Avenir", "backgroundImage": "https://example.com/background.png",
        ])
        XCTAssertEqual(result.baseFontSize, 21)
        XCTAssertEqual(result.messageBubbleRadius, 24)
        XCTAssertEqual(result.spacingScale, 1.2)
        XCTAssertEqual(result.fontFamily, "Avenir")
        XCTAssertEqual(result.backgroundImageURL?.host, "example.com")
        XCTAssertEqual(theme(["messageBubbleRadius": 9]).messageBubbleRadius, 9)
        XCTAssertEqual(theme(["baseFontSize": "20"]).baseFontSize, 20)
        XCTAssertNil(theme(["backgroundImage": "file:///private/file"]).backgroundImageURL)
        XCTAssertEqual(theme(["baseFontSize": Double.infinity]).baseFontSize, 16)
    }
    @MainActor func testMediaRejectsNonWebURLsAndDisposesFailedState() {
        for value in [
            "javascript:bad()", "file:///private/file", "data:audio/wav,AA",
            "https://user:password@example.com/a",
        ] {
            XCTAssertNil(ChatMediaPlayer.safeURL(value))
        }
        XCTAssertNotNil(ChatMediaPlayer.safeURL("https://example.com/audio.mp3"))
        let player = ChatMediaPlayer()
        player.load("file:///private/file")
        XCTAssertTrue(player.failed)
        XCTAssertNil(player.player)
        player.dispose()
        XCTAssertFalse(player.playing)
        XCTAssertNil(player.player)
    }
    @MainActor func testThoughtSummariesRespectVisibilityAndNamePolicies() {
        let session = ThoughtSession()
        let config = SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(
                projectId: "p", endpoint: "https://fixture.invalid", apiKey: "fixture"),
            chat: ChatConfig(enableThoughts: true), features: FeaturesConfig(enableActivityUpdates: true))
        let client = ChatClient(sessionManager: session, config: config)
        client.handleServerMessage(TransportServerMessage(type: "thought", raw: ["thought": "hidden"]))
        XCTAssertTrue(client.getMessages().isEmpty)
        session.policy = ["enabled": true, "thoughtSummaries": true]
        client.handleServerMessage(
            TransportServerMessage(type: "thought", raw: ["reasoning": "private fallback"]))
        XCTAssertTrue(client.getMessages().isEmpty)
        client.handleServerMessage(
            TransportServerMessage(
                type: "thought", raw: ["thought": "Permitted summary", "toolName": "hidden tool"]))
        XCTAssertEqual(client.getMessages().last?.content, "Permitted summary")
        XCTAssertNil(client.getMessages().last?.metadata?["toolName"])
        session.policy["exposeToolNames"] = true
        client.handleServerMessage(
            TransportServerMessage(
                type: "thought", raw: ["thought": "Another summary", "toolName": "Visible tool"]))
        XCTAssertEqual(
            client.getMessages().last?.metadata?["toolName"]?.value as? String, "Visible tool")
    }
    private func theme(_ raw: [String: Any]) -> ChatTheme {
        ChatTheme(
            configuration: SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(
                    projectId: "p", endpoint: "https://example.com", apiKey: "fixture")),
            widgetConfig: WidgetConfig(raw: ["theme": raw]))
    }
}

@MainActor private final class ThoughtSession: ChatSession {
    var policy: [String: Any] = [:]
    func isConnected() -> Bool { true }
    func getSessionId() -> String? { "fixture" }
    func getProjectId() -> String { "p" }
    func getEndpoint() -> String { "https://fixture.invalid" }
    func getAuthToken() async throws -> String { "fixture" }
    func send(_ message: TransportClientMessage) throws {}
    func sendAsync(_ message: TransportClientMessage) async throws {}
    func getScope() -> SDKSessionScope? {
        var scope = SDKSessionScope(
            tenantId: "t", projectId: "p", channelId: "c", deploymentId: nil, permissions: ["chat:write"],
            showActivityUpdates: true)
        scope.activityVisibilityPolicy = policy.mapValues(AnySendable.init)
        return scope
    }
}
