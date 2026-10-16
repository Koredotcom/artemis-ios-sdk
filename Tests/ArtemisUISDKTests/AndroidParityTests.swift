import XCTest

@testable import ArtemisSocketSDK
@testable import ArtemisUISDK

@MainActor final class AndroidParityTests: XCTestCase {
    private func configuration(contact: Bool = false, activity: Bool = false) -> SDKConfiguration {
        SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(projectId: "p", endpoint: "https://fixture.invalid", apiKey: "public-fixture"),
            chat: ChatConfig(enableThoughts: true),
            features: FeaturesConfig(enableActivityUpdates: activity, enableContactCenter: contact))
    }
    private func fixture(redaction: Bool = false, contact: Bool = false, activity: Bool = false) -> (
        ChatClient, FixtureChatSession, ChatEventRecorder
    ) {
        let session = FixtureChatSession()
        let client = ChatClient(sessionManager: session, config: configuration(contact: contact, activity: activity))
        let recorder = ChatEventRecorder()
        client.delegate = recorder
        client.handleServerMessage(
            frame(
                "session_start", ["sessionId": "conversation", "capabilities": ["liveUserInputRedaction": redaction]]))
        return (client, session, recorder)
    }
    private func frame(_ type: String, _ raw: [String: Any] = [:]) -> TransportServerMessage {
        TransportServerMessage(type: type, raw: raw)
    }

    func testRejectedSendCreatesNoUserBubble() async {
        let (client, session, recorder) = fixture()
        session.reject = true
        do {
            _ = try await client.send(text: "Do not echo")
            XCTFail("Expected rejection")
        } catch {}
        XCTAssertTrue(client.getMessages().isEmpty)
        XCTAssertTrue(recorder.messages.isEmpty)
    }
    func testServerControlledRedactionNeverEmitsRawUserTextOrMetadata() async throws {
        let (client, session, recorder) = fixture(redaction: true)
        let id = try await client.send(
            text: "private 123", metadata: ["display_label": "private 123", "raw": "private 123"])
        XCTAssertEqual(session.sent[0]["text"] as? String, "private 123")
        XCTAssertEqual(client.getMessages()[0].content, "••••")
        XCTAssertTrue(client.getMessages()[0].pendingRender)
        XCTAssertNil(client.getMessages()[0].metadata?["raw"])
        XCTAssertFalse(recorder.messages.contains { $0.content.contains("123") })
        client.handleServerMessage(
            frame("user_message_rendered", ["messageId": id, "content": "private [REDACTED_PHONE]"]))
        XCTAssertEqual(client.getMessages()[0].content, "private ••••")
        XCTAssertFalse(client.getMessages()[0].pendingRender)
    }
    func testEarlyAndWithheldRendersReconcileAfterAcceptedSend() async throws {
        let (client, session, _) = fixture(redaction: true)
        session.onSend = { payload in
            client.handleServerMessage(
                self.frame(
                    "user_message_rendered",
                    ["messageId": payload["messageId"]!, "content": "must remain hidden", "status": "withheld"]))
        }
        _ = try await client.send(text: "secret")
        XCTAssertEqual(client.getMessages().map(\.content), ["••••"])
        XCTAssertFalse(client.getMessages()[0].pendingRender)
    }
    func testLegacySessionStillEchoesImmediately() async throws {
        let (client, _, _) = fixture()
        _ = try await client.send(text: "Hello")
        XCTAssertEqual(client.getMessages()[0].content, "Hello")
        XCTAssertFalse(client.getMessages()[0].pendingRender)
    }
    func testOwnedCancellationStopsActivityAndRejectsLateResponseFrames() async throws {
        let (client, _, recorder) = fixture()
        let request = try await client.send(text: "Hello")
        client.handleServerMessage(frame("response_start", ["messageId": "reply"]))
        client.handleServerMessage(frame("response_chunk", ["messageId": "reply", "chunk": "Partial"]))
        client.handleServerMessage(
            frame(
                "execution_cancelled", ["messageId": "reply", "requestMessageId": request, "reason": "client_cancel"]))
        client.handleServerMessage(frame("response_chunk", ["messageId": "reply", "chunk": " stale"]))
        client.handleServerMessage(frame("response_end", ["messageId": "reply", "content": "stale final"]))
        XCTAssertEqual(client.getMessages().last?.content, "Partial")
        XCTAssertEqual(client.getMessages().last?.status, .cancelled)
        XCTAssertEqual(recorder.typing.last, false)
    }
    func testUnownedPreemptionDoesNotStopNewerTyping() async throws {
        let (client, _, recorder) = fixture()
        _ = try await client.send(text: "new request")
        client.handleServerMessage(
            frame(
                "execution_cancelled", ["messageId": "old", "requestMessageId": "old-request", "reason": "preempted"]))
        XCTAssertEqual(recorder.typing.last, true)
    }
    func testCanonicalEnvelopePreservesCitationsSourcesAndCustomPayloads() {
        let message = MessageNormalizer.parse([
            "messageId": "m", "timestamp": "2026-10-15T10:00:00.123456Z", "sequence": 4,
            "contentEnvelope": [
                "text": "Answer [1]", "actions": [["id": "yes", "text": "Yes", "payload": ["answer": true]]],
                "rich_content": ["type": "card", "title": "Card", "body": "Details"],
                "renderables": [["name": "order", "payload": ["id": 7]]], "metadata": ["customKey": true],
            ],
            "citations": [["index": 1, "title": "Source", "url": "https://fixture.invalid/source"]],
            "messageSource": ["system": "integration", "provider": "provider"],
        ])
        XCTAssertEqual(message.content, "Answer [1]")
        XCTAssertEqual(message.sequence, 4)
        XCTAssertEqual(message.citations.first?.title, "Source")
        XCTAssertEqual(message.renderables.count, 1)
        XCTAssertNotNil(message.contentEnvelope)
        XCTAssertEqual(message.actions?.elements.first?.label, "Yes")
        XCTAssertTrue(message.richContent?.markdown?.contains("Card") == true)
        XCTAssertEqual(message.timestamp.timeIntervalSince1970, 1792058400.123456, accuracy: 0.01)
    }
    func testHistoryReconcilesRepeatedRepliesAndRestoresActionLocks() {
        let (client, _, _) = fixture()
        let first = MessageNormalizer.parse([
            "id": "first", "content": "same",
            "actions": ["renderId": "r", "elements": [["id": "yes", "label": "Yes"]]],
        ])
        client.mergeHistory([first])
        let second = Message(id: "second", role: .assistant, content: "same")
        let choice = Message(
            id: "choice", role: .user, content: "Yes",
            metadata: ["custom": AnySendable(["actionSubmit": ["renderId": "r", "actionId": "yes"]])])
        client.mergeHistory([first, second, choice])
        XCTAssertEqual(client.getMessages().filter { $0.content == "same" }.count, 2)
        XCTAssertEqual(client.getMessages().first { $0.id == "first" }?.actions?.submittedActionId, "yes")
    }
    func testHistoryUsesDurableSequenceAndReplacesInterimRows() {
        let (client, _, _) = fixture()
        client.handleServerMessage(frame("response_chunk", ["messageId": "m", "chunk": "interim"]))
        client.mergeHistory([
            Message(
                id: "later", role: .assistant, content: "second", timestamp: Date(timeIntervalSince1970: 0), sequence: 2
            ),
            Message(id: "m", role: .assistant, content: "final", timestamp: Date(), sequence: 1),
        ])
        XCTAssertEqual(client.getMessages().map(\.id), ["m", "later"])
        XCTAssertEqual(client.getMessages().first?.content, "final")
    }
    func testChangedSessionClearsTranscriptAndRedactionState() async throws {
        let (client, _, _) = fixture(redaction: true)
        _ = try await client.send(text: "old")
        client.handleServerMessage(frame("session_start", ["sessionId": "new"]))
        XCTAssertTrue(client.getMessages().isEmpty)
        _ = try await client.send(text: "new")
        XCTAssertEqual(client.getMessages().first?.content, "new")
    }
    func testActionsEchoValuesAndLockTheWholeRender() async throws {
        let (client, session, _) = fixture()
        client.handleServerMessage(
            frame(
                "response_end",
                ["messageId": "m", "actions": ["renderId": "r", "elements": [["id": "confirm", "label": "Confirm"]]]]))
        try await client.performAction(
            actionId: "confirm", value: "actual-value", formData: nil, renderId: "r", displayText: "Confirm")
        try await client.performAction(
            actionId: "other", value: nil, formData: nil, renderId: "r", displayText: "Other")
        XCTAssertEqual(session.sent.count, 1)
        XCTAssertEqual(session.sent[0]["value"] as? String, "actual-value")
        XCTAssertEqual(client.getMessages().last?.content, "Confirm")
        XCTAssertEqual(client.getMessages().first?.actions?.submittedActionId, "confirm")
    }
    func testFailedActionCanBeRetriedWithoutLockOrEcho() async throws {
        let (client, session, _) = fixture()
        session.reject = true
        do {
            try await client.performAction(actionId: "a", value: nil, formData: nil, renderId: "r", displayText: "A")
            XCTFail()
        } catch {}
        XCTAssertTrue(client.getMessages().isEmpty)
        session.reject = false
        try await client.performAction(actionId: "a", value: nil, formData: nil, renderId: "r", displayText: "A")
        XCTAssertEqual(client.getMessages().map(\.content), ["A"])
    }
    func testTransferOptInAndStaleTransitions() {
        let (disabled, _, _) = fixture()
        let transfer = transferFrame("agent:connected", timestamp: "2026-10-15T10:00:00Z")
        disabled.handleServerMessage(transfer)
        XCTAssertTrue(disabled.getMessages().isEmpty)
        let (client, _, recorder) = fixture(contact: true)
        client.handleServerMessage(transfer)
        client.handleServerMessage(transferFrame("agent:queued", timestamp: "2026-10-15T09:00:00Z"))
        XCTAssertEqual(recorder.transfers.last, .connected)
        XCTAssertEqual(client.getMessages().count, 1)
    }
    func testTransferSuppressesAssistantStreamAndDeduplicatesProviderDelivery() async throws {
        let (client, _, recorder) = fixture(contact: true)
        client.handleServerMessage(frame("response_start", ["messageId": "assistant"]))
        client.handleServerMessage(transferFrame("agent:connected"))
        client.handleServerMessage(frame("response_chunk", ["messageId": "assistant", "chunk": "late"]))
        let transfer = transferFrame(
            "agent:message", data: ["providerMessageId": "provider-1", "message": "Agent text"])
        client.handleServerMessage(transfer)
        client.handleServerMessage(transfer)
        _ = try await client.send(text: "Reply to agent")
        XCTAssertFalse(client.getMessages().contains { $0.id == "assistant" })
        XCTAssertEqual(client.getMessages().filter { $0.content == "Agent text" }.count, 1)
        XCTAssertEqual(recorder.typing.last, false)
    }
    func testTransferFormsAndFailedAttachmentMetadata() throws {
        let event = try XCTUnwrap(
            AgentTransfer.parse(
                transferFrame(
                    "agent:form", data: ["formUrl": "https://fixture.invalid/form", "formDisplayName": "Survey"]
                ).raw))
        XCTAssertEqual(event.messages.first?.agentLinkTitle, "Survey")
        XCTAssertEqual(event.messages.first?.agentLink?.scheme, "https")
        let message = MessageNormalizer.parse([
            "metadata": [
                "attachments": [["id": "a", "filename": "report.pdf"]], "agentTransferAttachmentFailedIds": ["a"],
            ]
        ])
        XCTAssertEqual(ChatAttachment.from(message).first?.deliveryFailed, true)
    }
    func testSurveyRequiresEligibleCloseAndUsesSeparateMatchingAcknowledgement() async throws {
        let (client, session, _) = fixture(contact: true)
        let definition: [String: Any] = [
            "triggerSurvey": true, "surveyType": "nps", "artemisSessionId": "transfer",
            "comment_visibility": "conditional", "comment_ratings": [0, 1], "submit_label": "Rate",
        ]
        client.handleServerMessage(transferFrame("agent:disconnected", data: ["survey": definition]))
        let survey = try XCTUnwrap(client.getMessages().compactMap(\.agentTransferSurvey).first)
        XCTAssertEqual(survey.submitLabel, "Rate")
        XCTAssertTrue(survey.showComment(for: 0))
        XCTAssertFalse(survey.showComment(for: 8))
        var finished = false
        let task = Task {
            let result = try await client.submitAgentTransferSurvey(survey, score: 0, comments: "Comment")
            finished = true
            return result
        }
        for _ in 0..<100 where session.sent.isEmpty { await Task.yield() }
        XCTAssertEqual(session.sent.first?["type"] as? String, "agent_transfer_survey.submit")
        client.handleServerMessage(
            frame("feedback.ack", ["messageId": "transfer", "success": true, "feedbackId": "wrong"]))
        await Task.yield()
        XCTAssertFalse(finished)
        client.handleServerMessage(
            frame(
                "agent_transfer_survey.ack", ["artemisSessionId": "transfer", "success": true, "feedbackId": "correct"])
        )
        let result = try await task.value
        XCTAssertEqual(result, "correct")
        XCTAssertNil(
            AgentTransferSurvey.parse(definition.merging(["triggerSurvey": false]) { _, new in new }, wire: true))
    }
    func testFeedbackRejectAndDisconnectAllowExplicitRetry() async throws {
        let (client, session, _) = fixture()
        let task = Task { try await client.submitFeedback(messageId: "m", ratingType: "thumbs", ratingValue: 1) }
        for _ in 0..<100 where session.sent.isEmpty { await Task.yield() }
        client.connectionLost()
        do {
            _ = try await task.value
            XCTFail()
        } catch {}
        session.onSend = { _ in
            client.handleServerMessage(
                self.frame("feedback.ack", ["messageId": "m", "success": true, "feedbackId": "ok"]))
        }
        let result = try await client.submitFeedback(messageId: "m", ratingType: "thumbs", ratingValue: 1)
        XCTAssertEqual(result, "ok")
    }
    func testActivityNeedsHostAndServerPolicyAndDoesNotPersistTyping() {
        let (client, session, recorder) = fixture(activity: true)
        client.handleServerMessage(frame("thought", ["thought": "hidden"]))
        XCTAssertTrue(client.getMessages().isEmpty)
        session.scope.showActivity = true
        client.handleServerMessage(frame("status_update", ["text": "Working"]))
        XCTAssertEqual(recorder.activities.last!, "Working")
        XCTAssertTrue(client.getMessages().isEmpty)
        client.handleServerMessage(frame("thought", ["thought": "still hidden by default"]))
        XCTAssertTrue(client.getMessages().isEmpty)
    }
    func testAttachmentAndContactFeaturesDefaultOffAndMIMELimitsAreBounded() {
        XCTAssertFalse(configuration().features.enableAttachments)
        XCTAssertFalse(configuration().features.enableContactCenter)
        let policy = AttachmentConfig(maxFileSizeBytes: 100, allowedMimeTypes: ["image/*", "text/plain"])
        XCTAssertTrue(policy.accepts(mimeType: "image/png", sizeBytes: 100))
        XCTAssertFalse(policy.accepts(mimeType: "image/png", sizeBytes: 101))
        XCTAssertFalse(policy.accepts(mimeType: "text/plain", sizeBytes: 0))
        XCTAssertFalse(policy.accepts(mimeType: "application/octet-stream", sizeBytes: 1))
    }
    func testFiveAttachmentLimitRejectsBeforeTransportSend() async {
        let (client, session, _) = fixture()
        do {
            _ = try await client.send(text: "", attachmentIds: (0..<6).map(String.init))
            XCTFail()
        } catch {}
        XCTAssertTrue(session.sent.isEmpty)
    }
    func testMinimizedHandleRetainsDraftAndPresentationStateUntilClose() {
        let handle = AgentChatHandle(configuration: configuration())
        handle.model.composeText = "Retained draft"
        handle.model.presentation.save(["email": "fixture"], for: "form")
        handle.minimize()
        XCTAssertTrue(handle.isMinimized)
        handle.reopen()
        XCTAssertFalse(handle.isMinimized)
        XCTAssertEqual(handle.model.composeText, "Retained draft")
        XCTAssertEqual(handle.model.presentation.values(for: "form")["email"], "fixture")
        handle.close()
        XCTAssertTrue(handle.model.presentation.values(for: "form").isEmpty)
    }
    func testResponseArrivingBeforeSendCompletionKeepsUserBeforeReplyAndStopsTyping() async throws {
        let (client, session, recorder) = fixture()
        session.onSend = { _ in
            client.handleServerMessage(
                self.frame("response_end", ["messageId": "early-reply", "content": "Fast reply"]))
        }
        _ = try await client.send(text: "Question")
        XCTAssertEqual(client.getMessages().map(\.content), ["Question", "Fast reply"])
        XCTAssertEqual(recorder.typing.last, false)
    }

    private func transferFrame(_ type: String, timestamp: String = "2026-10-15T10:00:00Z", data: [String: Any] = [:])
        -> TransportServerMessage
    {
        frame(
            "agent_transfer_event",
            ["sessionId": "transfer", "event": ["type": type, "timestamp": timestamp, "data": data]])
    }
}

@MainActor private final class FixtureChatSession: ChatSession {
    struct Scope { var showActivity = false }
    var scope = Scope()
    var reject = false
    var sent: [[String: Any]] = []
    var onSend: (([String: Any]) -> Void)?
    func isConnected() -> Bool { true }
    func getSessionId() -> String? { "conversation" }
    func getProjectId() -> String { "p" }
    func getEndpoint() -> String { "https://fixture.invalid" }
    func getScope() -> SDKSessionScope? {
        SDKSessionScope(
            tenantId: "t", projectId: "p", channelId: "c", deploymentId: nil, permissions: ["chat:write"],
            showActivityUpdates: scope.showActivity)
    }
    func getAuthToken() async throws -> String { "fixture-token" }
    func send(_ message: TransportClientMessage) throws {
        if reject { throw AttachmentError("Rejected") }
        let payload = message.toDictionary()
        sent.append(payload)
        onSend?(payload)
    }
    func sendAsync(_ message: TransportClientMessage) async throws { try send(message) }
}
@MainActor private final class ChatEventRecorder: ChatClientDelegate {
    var messages: [Message] = []
    var typing: [Bool] = []
    var transfers: [AgentTransferStatus] = []
    var activities: [String?] = []
    func chatClient(_ client: ChatClient, didReceive event: ChatEvent) {
        switch event {
        case .messageReceived(let message): messages.append(message)
        case .typingIndicator(let value): typing.append(value)
        case .agentTransferChanged(let value): transfers.append(value)
        case .activity(let value): activities.append(value)
        default: break
        }
    }
    func chatClient(_ client: ChatClient, didFailHistoryHydration error: Error) { XCTFail(error.localizedDescription) }
}
