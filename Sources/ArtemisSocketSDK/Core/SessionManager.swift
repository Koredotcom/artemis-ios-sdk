import Foundation

@MainActor protocol SessionManagerDelegate: AnyObject {
    func sessionManagerDidConnect(_ manager: SessionManager)
    func sessionManagerDidDisconnect(_ manager: SessionManager, reason: String?)
    func sessionManager(_ manager: SessionManager, didReceive message: TransportServerMessage)
    func sessionManager(_ manager: SessionManager, didChangeState state: ConnectionState)
    func sessionManager(_ manager: SessionManager, didEncounterError error: Error)
    func sessionManagerDidStartReconnecting(_ manager: SessionManager, attempt: Int, maxAttempts: Int)
    func sessionManager(_ manager: SessionManager, didUpdateScope scope: SDKSessionScope)
}

@MainActor protocol ChatSession: AnyObject {
    func isConnected() -> Bool
    func getSessionId() -> String?
    func getProjectId() -> String
    func getEndpoint() -> String
    func getScope() -> SDKSessionScope?
    func getAuthToken() async throws -> String
    func send(_ message: TransportClientMessage) throws
    func sendAsync(_ message: TransportClientMessage) async throws
}

/// State is serialized on the main actor; network I/O suspends without blocking it.
@MainActor final class SessionManager: ChatSession {
    private let config: SDKConfiguration
    private let tokenManager: TokenManager
    private let urlSession: URLSession
    private let httpEndpoint: String
    private let wsEndpoint: String
    private var webSocketTask: URLSessionWebSocketTask?
    private var sessionId: String?
    private var resolvedProjectId: String?
    private var isSessionReady = false
    private var generation = 0
    private var reconnectAttempts = 0
    private var cappedAttempts = 0
    private var shouldReconnect = false
    private var disposed = false
    private var ending = false
    private var connectTask: Task<Void, Error>?
    private var receiveTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var readyTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var endTask: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?
    private(set) var lastActivity = Date()
    weak var delegate: SessionManagerDelegate?

    init(config: SDKConfiguration, tokenManager: TokenManager, urlSession: URLSession = .shared) {
        self.config = config
        self.tokenManager = tokenManager
        self.urlSession = urlSession
        httpEndpoint = EndpointNormalizer.normalizeHttpEndpoint(config.connection.endpoint)
        wsEndpoint = EndpointNormalizer.normalizeWebSocketEndpoint(config.connection.endpoint)
        tokenManager.onScopeChanged = { [weak self] scope in
            guard let self, !self.disposed else { return }
            self.delegate?.sessionManager(self, didUpdateScope: scope)
        }
    }

    func connect() async throws {
        guard !disposed else { throw SessionManagerError.clientDisconnected }
        if isConnected() { return }
        if let connectTask { return try await connectTask.value }
        shouldReconnect = true
        ending = false
        generation += 1
        let epoch = generation
        let task = Task { try await self.openConnection(epoch: epoch) }
        connectTask = task
        do {
            try await task.value
            if epoch == generation { connectTask = nil }
        } catch {
            if epoch == generation {
                connectTask = nil
                closeSocket(error: error, reason: "Connection failed", code: nil)
            }
            throw error
        }
    }

    func disconnect() {
        shouldReconnect = false
        reconnectAttempts = 0
        cappedAttempts = 0
        generation += 1
        connectTask?.cancel()
        connectTask = nil
        retryTask?.cancel()
        retryTask = nil
        endTask?.cancel()
        endTask = nil
        closeSocket(error: SessionManagerError.clientDisconnected, reason: "Client disconnect", code: nil)
    }

    func endSession() {
        shouldReconnect = false
        tokenManager.requestNewSession()
        guard isConnected() else {
            disconnect()
            return
        }
        // The frame is enqueued before marking the session as ending.
        try? send(.endSession(sessionId: sessionId))
        ending = true
        endTask?.cancel()
        endTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            self?.disconnect()
        }
    }

    func send(_ message: TransportClientMessage) throws {
        guard isConnected(), let socket = webSocketTask else { throw SessionManagerError.notConnected }
        let json = try message.toJSON()
        let epoch = generation
        noteActivity()
        socket.send(.string(json)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                guard let self, self.generation == epoch else { return }
                self.delegate?.sessionManager(self, didEncounterError: error)
            }
        }
    }

    func sendAsync(_ message: TransportClientMessage) async throws {
        guard isConnected(), let socket = webSocketTask else { throw SessionManagerError.notConnected }
        let epoch = generation
        try await socket.send(.string(message.toJSON()))
        guard epoch == generation, webSocketTask === socket, isConnected() else {
            throw SessionManagerError.clientDisconnected
        }
        noteActivity()
    }

    func isConnected() -> Bool { webSocketTask != nil && isSessionReady && !ending }
    func getSessionId() -> String? { sessionId }
    func getProjectId() -> String { resolvedProjectId ?? config.connection.projectId }
    func getChannelId() -> String? { tokenManager.getScope()?.channelId }
    func getScope() -> SDKSessionScope? { tokenManager.getScope() }
    func getWidgetConfig() -> WidgetConfig? { tokenManager.getWidgetConfig() }
    func getEndpoint() -> String { httpEndpoint }
    func getAuthToken() async throws -> String { try await tokenManager.getToken() }
    func dispose() {
        disposed = true
        disconnect()
        tokenManager.onScopeChanged = nil
    }

    func noteActivity() {
        lastActivity = Date()
        idleTask?.cancel()
        let legacy = config.websocket.idleDisconnect
        let timeout =
            config.session.idleDisconnectTimeoutMs > 0
            ? config.session.idleDisconnectTimeoutMs : legacy.enabled ? legacy.timeoutMs : 0
        guard timeout > 0, isConnected() else { return }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000) } catch { return }
            guard let self else { return }
            self.delegate?.sessionManager(
                self, didReceive: TransportServerMessage(type: "idle_timeout", raw: ["timeoutMs": timeout]))
            if self.config.session.endSessionOnIdle || legacy.behavior == "end_session" {
                self.endSession()
            } else {
                self.disconnect()
            }
        }
    }

    private func openConnection(epoch: Int) async throws {
        delegate?.sessionManager(self, didChangeState: .connecting)
        let token = try await tokenManager.getToken()
        let protocols = try await resolveWebSocketProtocols(authToken: token)
        try Task.checkCancellation()
        guard epoch == generation, shouldReconnect else { throw SessionManagerError.clientDisconnected }
        guard let url = URL(string: "\(wsEndpoint)/ws/sdk") else { throw SessionManagerError.invalidTicketResponse }
        var request = URLRequest(url: url)
        request.setValue(WebSocketAuth.protocolHeaderValue(protocols), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = urlSession.webSocketTask(with: request)
        webSocketTask = socket
        isSessionReady = false
        try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
            continuation = pending
            readyTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, self.generation == epoch, !self.isSessionReady else { return }
                self.closeSocket(
                    error: SdkStageError(code: .sessionStartTimeout, cause: SessionManagerError.sessionStartTimeout),
                    reason: "Session start timeout", code: nil)
            }
            socket.resume()
            receiveTask = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        let frame = try await socket.receive()
                        guard let self, self.generation == epoch, self.webSocketTask === socket else { return }
                        let data: Data
                        switch frame {
                        case .data(let value): data = value
                        case .string(let value): data = Data(value.utf8)
                        @unknown default: continue
                        }
                        guard let message = try? TransportServerMessage.fromJSONData(data) else { continue }
                        self.handle(message)
                    } catch {
                        guard let self, self.generation == epoch, self.webSocketTask === socket else { return }
                        self.closeSocket(
                            error: error, reason: "Connection closed", code: Int(socket.closeCode.rawValue))
                        return
                    }
                }
            }
        }
    }

    private func handle(_ message: TransportServerMessage) {
        if message.type == "session_start" {
            guard let id = message.raw["sessionId"] as? String, !id.isEmpty else { return }
            sessionId = id
            resolvedProjectId = message.raw["projectId"] as? String ?? tokenManager.getScope()?.projectId
            isSessionReady = true
            reconnectAttempts = 0
            cappedAttempts = 0
            readyTask?.cancel()
            readyTask = nil
            continuation?.resume()
            continuation = nil
            // The capability frame must reach ChatClient before connected consumers can send.
            delegate?.sessionManager(self, didReceive: message)
            delegate?.sessionManager(self, didChangeState: .connected)
            delegate?.sessionManagerDidConnect(self)
            scheduleRefresh()
            noteActivity()
            return
        }
        delegate?.sessionManager(self, didReceive: message)
        if message.type == "session_end" {
            shouldReconnect = false
            disconnect()
        }
    }

    private func closeSocket(error: Error, reason: String, code: Int?) {
        let hadSocket = webSocketTask != nil || continuation != nil || isSessionReady
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isSessionReady = false
        receiveTask?.cancel()
        receiveTask = nil
        readyTask?.cancel()
        readyTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        idleTask?.cancel()
        idleTask = nil
        continuation?.resume(throwing: error)
        continuation = nil
        if hadSocket { delegate?.sessionManagerDidDisconnect(self, reason: reason) }
        delegate?.sessionManager(self, didChangeState: .disconnected)
        guard shouldReconnect, !disposed, code != 4000 else { return }
        let status: Int?
        if let tokenError = error as? TokenRequestError {
            status = tokenError.status
        } else if let staged = error as? SdkStageError, let cause = staged.cause as? TokenRequestError {
            status = cause.status
        } else if case SessionManagerError.ticketRequestFailed(let value) = error {
            status = value
        } else {
            status = nil
        }
        let auth = [4001, 4003, 4008, 4010].contains(code ?? 0) || status == 401 || status == 403
        if auth { tokenManager.invalidateToken() }
        scheduleReconnect(capped: auth || !config.websocket.reconnection.unlimitedTransientRetries)
    }

    private func scheduleReconnect(capped: Bool) {
        let policy = config.websocket.reconnection
        guard policy.enabled, retryTask == nil else { return }
        if capped {
            guard cappedAttempts < policy.maxAttempts else { return }
            cappedAttempts += 1
        }
        let factor = policy.exponentialBackoff ? pow(2.0, Double(min(reconnectAttempts, 20))) : 1
        let delay =
            min(Double(policy.baseDelayMs) * factor, Double(policy.maxDelayMs))
            * (policy.unlimitedTransientRetries ? Double.random(in: 0.5...1) : 1)
        reconnectAttempts += 1
        delegate?.sessionManagerDidStartReconnecting(
            self, attempt: reconnectAttempts, maxAttempts: capped ? policy.maxAttempts : 0)
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(1, delay)) * 1_000_000) } catch { return }
            guard let self, self.shouldReconnect else { return }
            self.retryTask = nil
            do { try await self.connect() } catch { self.delegate?.sessionManager(self, didEncounterError: error) }
        }
    }

    private func scheduleRefresh() {
        refreshTask?.cancel()
        guard let delay = tokenManager.refreshDelay, isConnected() else { return }
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
            guard let self, self.isConnected() else { return }
            do { _ = try await self.tokenManager.getToken() } catch {
                self.delegate?.sessionManager(self, didEncounterError: error)
            }
            if !Task.isCancelled { self.scheduleRefresh() }
        }
    }

    private func resolveWebSocketProtocols(authToken: String) async throws -> [String] {
        guard let url = URL(string: "\(httpEndpoint)/api/v1/sdk/ws-ticket") else {
            throw SessionManagerError.invalidTicketResponse
        }
        for attempt in 0...3 {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(authToken, forHTTPHeaderField: "X-SDK-Token")
            request.httpBody = Data("{}".utf8)
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SessionManagerError.invalidTicketResponse }
            if [404, 405, 501].contains(http.statusCode) { return WebSocketAuth.buildTokenProtocols(authToken) }
            if http.statusCode == 429, attempt < 3 {
                let seconds = min(30, max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "1") ?? 1))
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                throw SessionManagerError.ticketRequestFailed(status: http.statusCode)
            }
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard let ticket = payload?["ticket"] as? String,
                !ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw SessionManagerError.missingTicket }
            return WebSocketAuth.buildTicketProtocols(ticket)
        }
        throw SessionManagerError.invalidTicketResponse
    }
}

enum SessionManagerError: Error, LocalizedError {
    case notConnected, clientDisconnected, sessionStartTimeout, invalidTicketResponse, missingTicket
    case ticketRequestFailed(status: Int)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .clientDisconnected: return "Connection changed or closed"
        case .sessionStartTimeout: return "Timed out waiting for session_start"
        case .invalidTicketResponse, .missingTicket: return "Invalid WebSocket ticket response"
        case .ticketRequestFailed(let status): return "WebSocket ticket request failed (\(status))"
        }
    }
}
