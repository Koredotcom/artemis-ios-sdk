import Foundation
#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

/// JSON object data forwarded from Runtime event payloads.
public typealias ArtemisUiEventPayload = [String: AnySendable]

/// Receives typed UI lifecycle and chat events from an `AgentChatHandle`.
public typealias ArtemisUiListener = @MainActor (ArtemisUiEvent) -> Void

/// The native iOS counterpart to Android's `ArtemisUiEvent` sealed interface.
/// Events are delivered on the main actor through `AgentChatHandle.addListener(_:)`.
public enum ArtemisUiEvent: Sendable {
    case connectionChanged(status: String, detail: String? = nil)
    case messageChanged(messageId: String, role: String)
    case message(Message)
    case messageChunk(messageId: String, chunk: String)
    case messagesReplaced([Message])
    case messageSent(messageId: String)
    case attachmentError(filename: String, error: String)
    case typing(isTyping: Bool)
    case statusUpdate(text: String, operation: String = "", fillerId: String? = nil, turnId: String? = nil)
    case statusClear
    case error(code: String, message: String, recoverable: Bool)
    case sessionStarted(sessionId: String, scope: SDKSessionScope?)
    case sessionEnded(reason: String? = nil)
    case idleTimeout(timeoutMs: Int64, behavior: String)
    case initialAssistantMessageStatus(
        source: String?, expected: Bool, pending: Bool, rendered: Bool, failed: Bool)
    case attachmentUploaded(attachmentId: String, filename: String)
    case authRequired(
        sessionId: String, pending: [ArtemisUiEventPayload], satisfied: [ArtemisUiEventPayload],
        payload: ArtemisUiEventPayload? = nil)
    case authChallenge(payload: ArtemisUiEventPayload)
    case messageQueued(sessionId: String?, reason: String, payload: ArtemisUiEventPayload? = nil)
    case authGateSatisfied(sessionId: String, payload: ArtemisUiEventPayload? = nil)
    case authChallengeResolved(
        sessionId: String, toolCallId: String, outcome: String?, payload: ArtemisUiEventPayload? = nil)
    case feedbackAck(
        messageId: String, success: Bool, feedbackId: String? = nil, actionRenderId: String? = nil,
        errorCode: String? = nil, errorMessage: String? = nil, payload: ArtemisUiEventPayload? = nil)
    case agentTransferSurveyAck(
        artemisSessionId: String, success: Bool, feedbackId: String? = nil, errorCode: String? = nil,
        errorMessage: String? = nil, payload: ArtemisUiEventPayload? = nil)
    case agentTransferChanged(status: String)
    case agentJoined(sessionId: String, payload: ArtemisUiEventPayload? = nil, timestamp: Int64? = nil)
    case agentExited(sessionId: String, payload: ArtemisUiEventPayload? = nil, timestamp: Int64? = nil)
    case agentNotice(sessionId: String, payload: ArtemisUiEventPayload? = nil, timestamp: Int64? = nil)
    case agentConnected(
        sessionId: String, timestamp: Int64, transferred: Bool, agentName: String? = nil,
        agentAvatarUrl: String? = nil)
    case agentTransferred(sessionId: String, timestamp: Int64, initiatedBy: String)
    case agentDisconnected(sessionId: String, timestamp: Int64, reason: String)
    case authTokenRefreshed(
        sessionId: String?, profile: String, reason: String, issuedAt: String, refreshAfter: String)
    case authContextRefreshRequested(
        sessionId: String?, profile: String, refreshTicket: String, expiresAt: String)
    case agentMediaInvite(
        callType: String, conversationId: String?, providerConversationId: String?,
        providerAccountId: String?, mediaSessionId: String?, idempotencyKey: String?,
        callId: String? = nil, displayName: String? = nil)
    case agentMediaEndpointReleased(
        callId: String, endpoint: ContactCenterCallEndpoint, customer: ContactCenterCustomer)
    case agentMediaSbcDetailsChanged(ContactCenterSbcDetails)
    case agentMediaCallTerminated(callId: String?, reason: String?)
    case contactCenterStateChanged(state: String, reason: String? = nil, callId: String? = nil)
    case contactCenterReady(ContactCenterSbcDetails)
    case contactCenterUnsupported(reason: String, capabilities: ContactCenterSessionCapabilities? = nil)
    case contactCenterIncomingCall(ContactCenterCall)
    case contactCenterCallAccepted(callId: String, callType: String, endpoint: ContactCenterCallEndpoint?)
    case contactCenterCallRejected(callId: String, reason: String? = nil)
    case contactCenterCallEnded(callId: String? = nil, reason: String? = nil)
    case contactCenterLocalStream(callId: String? = nil, callType: String? = nil)
    case contactCenterRemoteStream(callId: String? = nil, callType: String? = nil)
    case contactCenterError(message: String, recoverable: Bool = true)
    case responseCancelled(messageId: String?, reason: String)
    case deepLinkClicked(url: String, title: String? = nil, messageId: String? = nil)
    case minimized
    case closed(reason: String)
}

/// A cancellable registration returned by `AgentChatHandle.addListener(_:)`.
@MainActor public final class ArtemisUiEventRegistration {
    private var cancellation: (() -> Void)?

    init(cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        cancellation?()
        cancellation = nil
    }
}
