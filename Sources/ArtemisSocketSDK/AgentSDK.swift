import Combine
import Foundation

/// Main Artemis iOS SDK entry point.
///
/// The SDK loads configuration from a YAML/JSON file in the app bundle or from
/// a programmatic `SDKConfiguration`. All behavior is controlled by configuration.
///
/// ```swift
/// let sdk = try AgentSDK.initialize(fromBundle: .main)
/// try await sdk.connect()
/// ```
@MainActor
public final class AgentSDK {
    private var config: SDKConfiguration
    private let tokenManager: TokenManager
    private let sessionManager: SessionManager
    private let chatClient: ChatClient

    private let sdkEventSubject = PassthroughSubject<SDKEvent, Never>()
    private let chatEventSubject = PassthroughSubject<ChatEvent, Never>()

    /// Delegate for receiving SDK and chat events on the main actor.
    public weak var delegate: AgentSDKDelegate?

    /// Combine publisher for SDK-level events.
    public var sdkEvents: AnyPublisher<SDKEvent, Never> {
        sdkEventSubject.eraseToAnyPublisher()
    }

    /// Combine publisher for chat events.
    public var chatEvents: AnyPublisher<ChatEvent, Never> {
        chatEventSubject.eraseToAnyPublisher()
    }

    /// Loaded configuration (read-only).
    public var configuration: SDKConfiguration { config }

    private init(config: SDKConfiguration) {
        self.config = config
        self.tokenManager = TokenManager(config: config)
        self.sessionManager = SessionManager(config: config, tokenManager: tokenManager)
        self.chatClient = ChatClient(sessionManager: sessionManager, config: config)

        ArtemisLogger.configure(
            enabled: config.debug.enabled,
            logLevel: config.debug.logLevel,
            printToConsole: config.debug.printLogs
        )

        sessionManager.delegate = self
        chatClient.delegate = self
    }

    // MARK: - Factory Methods

    /// Initialize SDK by loading configuration from the app bundle.
    public static func initialize(
        fromBundle bundle: Bundle = .main,
        resourceName: String = "sdk_configurations",
        resourceExtension: String = "yaml",
        environment: String? = nil,
        runtimeUserContext: SDKUserContext? = nil
    ) throws -> AgentSDK {
        let config = try SDKConfigurationLoader.load(
            fromBundle: bundle,
            resourceName: resourceName,
            resourceExtension: resourceExtension,
            environment: environment,
            runtimeUserContext: runtimeUserContext
        )
        let sdk = AgentSDK(config: config)
        ArtemisLogger.info(
            "AgentSDK initialized successfully",
            metadata: [
                "environment": config.environment,
                "endpoint": config.connection.endpoint,
                "project_id": config.connection.projectId,
            ])
        return sdk
    }

    /// Initialize SDK from a configuration file URL.
    public static func initialize(
        from url: URL,
        environment: String? = nil,
        environmentOverrideURL: URL? = nil,
        runtimeUserContext: SDKUserContext? = nil
    ) throws -> AgentSDK {
        var config = try SDKConfigurationLoader.load(
            from: url,
            environment: environment,
            environmentOverrideURL: environmentOverrideURL
        )
        if let runtimeUserContext {
            config = config.copyWithUserContext(runtimeUserContext)
        }
        return AgentSDK(config: config)
    }

    /// Initialize SDK from a YAML string.
    public static func initialize(
        yaml: String,
        environment: String? = nil,
        runtimeUserContext: SDKUserContext? = nil
    ) throws -> AgentSDK {
        let config = try SDKConfigurationLoader.load(
            yaml: yaml,
            environment: environment,
            runtimeUserContext: runtimeUserContext
        )
        return AgentSDK(config: config)
    }

    /// Create SDK with explicit configuration (for testing).
    public static func create(with config: SDKConfiguration) -> AgentSDK {
        AgentSDK(config: config)
    }

    // MARK: - Connection

    /// Connect to the Artemis platform. Returns the session ID.
    @discardableResult
    public func connect() async throws -> String {
        do {
            ArtemisLogger.info(
                "Connecting to Artemis...",
                metadata: [
                    "endpoint": config.connection.endpoint
                ])

            try await sessionManager.connect()

            guard let sessionId = sessionManager.getSessionId(), !sessionId.isEmpty else {
                throw AgentSDKError.missingSessionId
            }

            ArtemisLogger.info("Connected successfully", metadata: ["session_id": sessionId])
            return sessionId
        } catch {
            ArtemisLogger.error("Connection failed", error)
            emitSDK(.error(error: unwrapStageError(error), code: errorCode(for: error)))
            throw error
        }
    }

    /// Disconnect from the platform.
    public func disconnect() {
        ArtemisLogger.info("Disconnecting from platform")
        chatClient.clearPending()
        sessionManager.disconnect()
    }

    /// End the current server session and disconnect.
    public func endSession() {
        chatClient.clearCustomData()
        chatClient.clearPending()
        sessionManager.endSession()
    }

    /// Whether the SDK has an active session.
    public func isConnected() -> Bool {
        sessionManager.isConnected()
    }

    /// Current session ID, if connected.
    public func getSessionId() -> String? {
        sessionManager.getSessionId()
    }

    /// Server-provided widget configuration from init/refresh response.
    public func getWidgetConfig() -> WidgetConfig? {
        sessionManager.getWidgetConfig()
    }

    // MARK: - Messaging

    /// Send a chat message. Returns the local message ID.
    @discardableResult
    public func sendMessage(
        _ text: String,
        metadata: [String: Any]? = nil,
        attachmentIds: [String]? = nil
    ) async throws -> String {
        guard isConnected() else {
            let error = AgentSDKError.notConnected
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }

        do {
            if config.session.staleSessionRefreshMs > 0,
                Date().timeIntervalSince(sessionManager.lastActivity) * 1000
                    > Double(config.session.staleSessionRefreshMs)
            {
                sessionManager.disconnect()
                try await sessionManager.connect()
                throw AttachmentError("The connection was refreshed. Please retry your message.")
            }
            return try await chatClient.send(
                text: text,
                metadata: metadata,
                attachmentIds: attachmentIds
            )
        } catch {
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }
    }

    /// Submit an interactive action (button click, select change, form submit).
    public func submitAction(
        _ actionId: String,
        value: String? = nil,
        formData: [String: String]? = nil,
        renderId: String? = nil
    ) throws {
        guard isConnected() else {
            let error = AgentSDKError.notConnected
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }

        do {
            try chatClient.submitAction(
                actionId: actionId,
                value: value,
                formData: formData,
                renderId: renderId
            )
        } catch {
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }
    }

    /// Submit feedback on a persisted assistant message.
    @discardableResult
    public func submitFeedback(
        messageId: String,
        ratingType: String,
        ratingValue: Int,
        feedbackText: String? = nil,
        actionRenderId: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> String {
        guard isConnected() else {
            let error = AgentSDKError.notConnected
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }

        do {
            return try await chatClient.submitFeedback(
                messageId: messageId,
                ratingType: ratingType,
                ratingValue: ratingValue,
                feedbackText: feedbackText,
                actionRenderId: actionRenderId,
                timeout: timeout
            )
        } catch {
            emitSDK(.error(error: error, code: .sendFailed))
            throw error
        }
    }

    public func getSessionScope() -> SDKSessionScope? { sessionManager.getScope() }
    public func recordActivity() { sessionManager.noteActivity() }
    public func sendUserPresence(isTyping: Bool) throws {
        try sessionManager.send(
            .raw([
                "type": "user_presence", "event": isTyping ? "typing" : "stop_typing",
                "sessionId": getSessionId() ?? "",
            ]))
    }
    public func performAction(
        _ actionId: String, value: String? = nil, formData: [String: String]? = nil,
        renderId: String? = nil, displayText: String? = nil
    ) async throws {
        try await chatClient.performAction(
            actionId: actionId, value: value, formData: formData, renderId: renderId, displayText: displayText)
    }
    public func submitAgentTransferSurvey(_ survey: AgentTransferSurvey, score: Int, comments: String? = nil)
        async throws -> String
    {
        try await chatClient.submitAgentTransferSurvey(survey, score: score, comments: comments)
    }

    /// All messages in the local store.
    public func getMessages() -> [Message] {
        chatClient.getMessages()
    }

    /// Merge session-scoped custom data into all subsequent outgoing messages.
    public func updateCustomData(_ customData: [String: Any]) {
        chatClient.updateCustomData(customData)
    }

    /// Current session-scoped custom data.
    public var customData: [String: AnySendable] {
        chatClient.customDataSnapshot
    }

    /// Clear all session-scoped custom data.
    public func clearCustomData() {
        chatClient.clearCustomData()
    }

    /// Clear local message history.
    public func clearHistory() {
        chatClient.clearMessages()
        ArtemisLogger.debug("Message history cleared")
    }

    /// Dispose and clean up resources.
    public func dispose() {
        disconnect()
        sessionManager.dispose()
        sdkEventSubject.send(completion: .finished)
        chatEventSubject.send(completion: .finished)
        ArtemisLogger.info("AgentSDK disposed")
    }

    // MARK: - Event Helpers

    private func emitSDK(_ event: SDKEvent) {
        sdkEventSubject.send(event)
        delegate?.agentSDK(self, didReceive: event)
    }

    private func emitChat(_ event: ChatEvent) {
        chatEventSubject.send(event)
        delegate?.agentSDK(self, didReceive: event)
    }

    private func unwrapStageError(_ error: Error) -> Error {
        if let staged = error as? SdkStageError {
            return staged.cause
        }
        return error
    }

    private func errorCode(for error: Error) -> SDKErrorCode {
        if let staged = error as? SdkStageError {
            return staged.code
        }
        return .unknown
    }
}

// MARK: - SessionManagerDelegate

extension AgentSDK: SessionManagerDelegate {
    func sessionManagerDidConnect(_ manager: SessionManager) {
        if let id = manager.getSessionId() { emitSDK(.connected(sessionId: id)) }
        chatClient.clearPending()
        chatClient.hydratePersistedHistory()
    }
    func sessionManagerDidDisconnect(_ manager: SessionManager, reason: String?) {
        chatClient.connectionLost()
        emitSDK(.disconnected(reason: reason))
    }
    func sessionManager(_ manager: SessionManager, didReceive message: TransportServerMessage) {
        if message.type == "idle_timeout" {
            emitSDK(.idleTimeout(timeout: Double(message.raw["timeoutMs"] as? Int ?? 0) / 1000))
        }
        chatClient.handleServerMessage(message)
    }
    func sessionManager(_ manager: SessionManager, didChangeState state: ConnectionState) {}
    func sessionManager(_ manager: SessionManager, didEncounterError error: Error) {
        emitSDK(.error(error: unwrapStageError(error), code: errorCode(for: error)))
    }
    func sessionManagerDidStartReconnecting(_ manager: SessionManager, attempt: Int, maxAttempts: Int) {
        emitSDK(.reconnecting(attempt: attempt, maxAttempts: maxAttempts))
    }
    func sessionManager(_ manager: SessionManager, didUpdateScope scope: SDKSessionScope) {
        emitSDK(.sessionScopeChanged(scope))
    }
}

extension AgentSDK: ChatClientDelegate {
    func chatClient(_ client: ChatClient, didReceive event: ChatEvent) { emitChat(event) }
    func chatClient(_ client: ChatClient, didFailHistoryHydration error: Error) {
        emitSDK(.error(error: error, code: .historyFetch))
    }
}

public enum AgentSDKError: Error, LocalizedError {
    case notInitialized
    case notConnected
    case missingSessionId

    public var errorDescription: String? {
        switch self {
        case .notInitialized: return "SDK not initialized. Call AgentSDK.initialize() first."
        case .notConnected: return "SDK not connected. Call connect() first."
        case .missingSessionId: return "Connected but session ID was not returned"
        }
    }
}

// MARK: - Session-scoped attachments

extension AgentSDK {
    /// Upload using the same multipart contract as the web SDK. Send the returned ID with sendMessage.
    public func uploadAttachment(
        fileURL: URL, contentType: String = "application/octet-stream", progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        guard isConnected(), let sessionId = getSessionId(), !sessionId.isEmpty else {
            throw AgentSDKError.notConnected
        }
        let token = try await sessionManager.getAuthToken()
        guard isConnected(), getSessionId() == sessionId else { throw AgentSDKError.notConnected }
        let endpoint = sessionManager.getEndpoint()
        let projectId = sessionManager.getProjectId()
        let id = try await AttachmentHTTP.upload(
            fileURL: fileURL, contentType: contentType, endpoint: endpoint,
            projectId: projectId, sessionId: sessionId, token: token,
            maxFileSizeBytes: config.attachments.maxFileSizeBytes, progress: progress)
        guard isConnected(), getSessionId() == sessionId else { throw AgentSDKError.notConnected }
        return id
    }

    /// Resolve a fresh URL on each open; signed download URLs are never persisted or sent in chat frames.
    public func resolveAttachmentDownloadURL(attachmentId: String) async throws -> URL {
        guard isConnected(), let sessionId = getSessionId(), !sessionId.isEmpty else {
            throw AgentSDKError.notConnected
        }
        let token = try await sessionManager.getAuthToken()
        guard isConnected(), getSessionId() == sessionId else { throw AgentSDKError.notConnected }
        let url = try await AttachmentHTTP.resolve(
            endpoint: sessionManager.getEndpoint(), projectId: sessionManager.getProjectId(),
            sessionId: sessionId, attachmentId: attachmentId, token: token)
        guard isConnected(), getSessionId() == sessionId else { throw AgentSDKError.notConnected }
        return url
    }
}

public struct AttachmentError: Error, LocalizedError {
    public let message: String
    public let status: Int?
    public init(_ message: String, status: Int? = nil) {
        self.message = message
        self.status = status
    }
    public var errorDescription: String? { message }
}

/// File-backed multipart encoding avoids loading large attachments into memory.
enum AttachmentHTTP {
    static func url(endpoint: String, projectId: String, sessionId: String, attachmentId: String? = nil) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        var path = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        path += "/api/projects/\(encode(projectId))/sessions/\(encode(sessionId))/attachments"
        if let attachmentId { path += "/\(encode(attachmentId))/url?disposition=attachment" }
        guard let url = URL(string: path), ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else {
            throw AttachmentError("Invalid attachment endpoint")
        }
        return url
    }

    static func multipartFile(
        source: URL, contentType: String, boundary: String, maxFileSizeBytes: Int64 = 20 * 1024 * 1024
    ) throws -> URL {
        guard source.isFileURL else { throw AttachmentError("Select a local file to upload") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw AttachmentError("Could not prepare attachment")
        }
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            let filename = source.lastPathComponent.replacingOccurrences(of: "\r", with: "_")
                .replacingOccurrences(of: "\n", with: "_").replacingOccurrences(of: "\"", with: "_")
                .replacingOccurrences(of: "\\", with: "_")
            let mime =
                contentType.contains("\r") || contentType.contains("\n") || contentType.isEmpty
                ? "application/octet-stream" : contentType
            let header =
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            var count: Int64 = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                count += Int64(chunk.count)
                guard count <= maxFileSizeBytes else { throw AttachmentError("File exceeds the upload size limit") }
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            guard count > 0 else { throw AttachmentError("Empty files cannot be uploaded") }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func response(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else { throw AttachmentError("Invalid attachment response") }
        guard (200..<300).contains(http.statusCode) else {
            throw AttachmentError(
                http.statusCode == 409
                    ? "Attachment is not ready yet. Please retry." : "Attachment request failed (\(http.statusCode))",
                status: http.statusCode)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AttachmentError("Invalid attachment response")
        }
        return json
    }

    static func resolve(
        endpoint: String, projectId: String, sessionId: String, attachmentId: String,
        token: String, urlSession: URLSession = .shared
    ) async throws -> URL {
        let original = try url(
            endpoint: endpoint, projectId: projectId, sessionId: sessionId, attachmentId: attachmentId)
        var request = URLRequest(url: original)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(token, forHTTPHeaderField: "X-SDK-Token")
        let delegate = AttachmentRequestDelegate(progress: nil)
        let (data, response) = try await urlSession.data(for: request, delegate: delegate)
        let json = try self.response(data, response)
        var value = json["url"] as? String ?? (json["data"] as? [String: Any])?["url"] as? String
        if value?.lowercased().hasPrefix("file:") == true {
            var components = URLComponents(
                url: original.deletingLastPathComponent().appendingPathComponent("delivery-url"),
                resolvingAgainstBaseURL: false)!
            components.query = nil
            request.url = components.url
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (minted, response) = try await urlSession.data(for: request, delegate: delegate)
            let body = try self.response(minted, response)
            let download = (body["data"] as? [String: Any])?["download"] as? [String: Any]
            value = download?["available"] as? Bool == true ? download?["url"] as? String : nil
        }
        guard let value, let resolved = MessageNormalizer.safeWebURL(value, relativeTo: endpoint + "/") else {
            throw AttachmentError("A secure download link is unavailable. Please retry.")
        }
        return resolved
    }

    static func upload(
        fileURL: URL, contentType: String, endpoint: String, projectId: String, sessionId: String,
        token: String, urlSession: URLSession = .shared, maxFileSizeBytes: Int64 = 20 * 1024 * 1024,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let boundary = "Artemis-\(UUID().uuidString)"
        let preparation = Task.detached {
            try multipartFile(
                source: fileURL, contentType: contentType, boundary: boundary, maxFileSizeBytes: maxFileSizeBytes)
        }
        let body = try await withTaskCancellationHandler(
            operation: { try await preparation.value }, onCancel: { preparation.cancel() })
        defer { try? FileManager.default.removeItem(at: body) }
        try Task.checkCancellation()
        var request = URLRequest(url: try url(endpoint: endpoint, projectId: projectId, sessionId: sessionId))
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(token, forHTTPHeaderField: "X-SDK-Token")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let delegate = AttachmentRequestDelegate(progress: progress)
        let (data, response) = try await urlSession.upload(for: request, fromFile: body, delegate: delegate)
        let json = try self.response(data, response)
        guard let id = json["attachmentId"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw AttachmentError("Upload response did not include an attachment ID")
        }
        return id
    }
}

private final class AttachmentRequestDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let progress: (@Sendable (Double) -> Void)?
    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        if totalBytesExpectedToSend > 0 { progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
}
