import Foundation

/// Identifies the exact stage/operation where an SDK error occurred.
public enum SDKErrorCode: String, Sendable {
    case tokenInit
    case tokenRefresh
    case wsTicket
    case socketConnection
    case sessionStartTimeout
    case sendFailed
    case historyFetch
    case unknown
}

public enum ConnectionState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case error
}

/// Safe agent identity attached to an agent lifecycle event.
public struct AgentTransferAgent: Sendable, Equatable {
    public let name: String?
    public let avatarURL: URL?

    public init(name: String? = nil, avatarURL: URL? = nil) {
        self.name = name
        self.avatarURL = avatarURL
    }
}

/// Typed lifecycle detail corresponding to the Web SDK's agent lifecycle events.
public struct AgentTransferLifecycleEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case connected, transferred, disconnected }

    public let kind: Kind
    /// Runtime chat session ID, never the internal transfer-routing session ID.
    public let sessionId: String
    public let timestamp: String
    public let transferred: Bool
    public let initiatedBy: String?
    public let reason: String?
    public let agent: AgentTransferAgent?

    public init(
        kind: Kind, sessionId: String, timestamp: String, transferred: Bool = false,
        initiatedBy: String? = nil, reason: String? = nil, agent: AgentTransferAgent? = nil
    ) {
        self.kind = kind
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.transferred = transferred
        self.initiatedBy = initiatedBy
        self.reason = reason
        self.agent = agent
    }
}

/// SDK-level events emitted by [AgentSDK].
public enum SDKEvent: Sendable {
    case connected(sessionId: String)
    case disconnected(reason: String?)
    case reconnecting(attempt: Int, maxAttempts: Int)
    case error(error: Error, code: SDKErrorCode)
    case idleTimeout(timeout: TimeInterval)
    case sessionScopeChanged(SDKSessionScope)
}

/// Chat-specific events emitted by [AgentSDK].
public enum ChatEvent: Sendable {
    case messageReceived(Message)
    case historyLoaded(messages: [Message])
    case messageStart(messageId: String)
    case messageChunk(messageId: String, chunk: String)
    case messageEnd(messageId: String, message: Message)
    case typingIndicator(isTyping: Bool)
    case thought(content: String)
    case activity(text: String?)
    case responseCancelled(messageId: String?, reason: String)
    case agentTransferChanged(AgentTransferStatus)
    case agentTransferLifecycle(AgentTransferLifecycleEvent)
    case error(error: Error)
}

/// Delegate for receiving SDK and chat events.
@MainActor
public protocol AgentSDKDelegate: AnyObject {
    func agentSDK(_ sdk: AgentSDK, didReceive event: SDKEvent)
    func agentSDK(_ sdk: AgentSDK, didReceive chatEvent: ChatEvent)
}

extension AgentSDKDelegate {
    public func agentSDK(_ sdk: AgentSDK, didReceive event: SDKEvent) {}
    public func agentSDK(_ sdk: AgentSDK, didReceive chatEvent: ChatEvent) {}
}
