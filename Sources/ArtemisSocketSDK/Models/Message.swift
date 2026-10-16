import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
    case system
    case thought
}

/// A message in a chat conversation with the AI agent.
public struct Message: Identifiable, Sendable {
    public let id: String
    public let role: MessageRole
    public let content: String
    public let timestamp: Date
    public let metadata: [String: AnySendable]?
    public let attachmentIds: [String]?
    public let sequence: Int?
    public let pendingRender: Bool
    public let status: MessageStatus
    public let citations: [Citation]
    public let messageSource: [String: AnySendable]?
    public let contentEnvelope: [String: AnySendable]?
    public let renderables: [[String: AnySendable]]

    public init(
        id: String,
        role: MessageRole,
        content: String,
        timestamp: Date = Date(),
        metadata: [String: AnySendable]? = nil,
        attachmentIds: [String]? = nil,
        sequence: Int? = nil, pendingRender: Bool = false, status: MessageStatus = .complete,
        citations: [Citation] = [], messageSource: [String: AnySendable]? = nil,
        contentEnvelope: [String: AnySendable]? = nil, renderables: [[String: AnySendable]] = []
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.metadata = metadata
        self.attachmentIds = attachmentIds
        self.sequence = sequence
        self.pendingRender = pendingRender
        self.status = status
        self.citations = citations
        self.messageSource = messageSource
        self.contentEnvelope = contentEnvelope
        self.renderables = renderables
    }

    public func replacing(
        content: String? = nil, metadata: [String: AnySendable]? = nil,
        pendingRender: Bool? = nil, status: MessageStatus? = nil
    ) -> Message {
        Message(
            id: id, role: role, content: content ?? self.content, timestamp: timestamp,
            metadata: metadata ?? self.metadata, attachmentIds: attachmentIds, sequence: sequence,
            pendingRender: pendingRender ?? self.pendingRender, status: status ?? self.status,
            citations: citations, messageSource: messageSource, contentEnvelope: contentEnvelope,
            renderables: renderables)
    }
}

public enum MessageStatus: String, Sendable { case accepted, streaming, complete, cancelled }

public struct Citation: Sendable {
    public let index: Int
    public let title: String
    public let url: URL
    public let sourceType: String
}

/// Runtime user context override for SDK initialization.
public struct SDKUserContext: Sendable {
    public let userId: String?
    public let customAttributes: [String: AnySendable]?

    public init(userId: String? = nil, customAttributes: [String: AnySendable]? = nil) {
        self.userId = userId
        self.customAttributes = customAttributes
    }
}

/// Type-erased Sendable wrapper for dynamic JSON values in metadata.
public struct AnySendable: @unchecked Sendable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }
}

/// Raised when the runtime rejects a feedback submission.
public struct FeedbackSubmitError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public var errorDescription: String? { "\(code): \(message)" }
}

/// Configuration loading or validation failure.
public struct SDKConfigurationError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
}

/// HTTP token request failure.
public struct TokenRequestError: Error, LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public var errorDescription: String? { "TokenRequestError(\(status)): \(message)" }
}

/// Malformed token response from the runtime.
public struct TokenResponseValidationError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { "TokenResponseValidationError: \(message)" }
}

/// Internal exception tagging an error with its originating SDK stage.
struct SdkStageError: Error, LocalizedError {
    let code: SDKErrorCode
    let cause: Error

    var errorDescription: String? { "SdkStageError(\(code.rawValue)): \(cause.localizedDescription)" }
}
