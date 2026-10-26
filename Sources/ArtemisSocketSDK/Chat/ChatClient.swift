import Foundation

@MainActor protocol ChatClientDelegate: AnyObject {
    func chatClient(_ client: ChatClient, didReceive event: ChatEvent)
    func chatClient(_ client: ChatClient, didReceive contactCenterEvent: ContactCenterEvent)
    func chatClient(_ client: ChatClient, didFailHistoryHydration error: Error)
}

extension ChatClientDelegate {
    func chatClient(_ client: ChatClient, didReceive contactCenterEvent: ContactCenterEvent) {}
}

/// Owns transcript state independently of its SwiftUI presentation.
@MainActor final class ChatClient {
    private let sessionManager: ChatSession
    private let config: SDKConfiguration
    private let httpSession: URLSession
    private var messages: [Message] = []
    private var customData: [String: Any] = [:]
    private var pendingFeedback: [String: PendingFeedback] = [:]
    private var pendingSurveys: [String: PendingFeedback] = [:]
    private var historyTask: Task<Void, Never>?
    private var historyRefreshRequested = false
    private var historyGeneration = 0
    private var currentSessionId: String?
    private var redaction = false
    private var parkedRenders: [String: (String, Bool)] = [:]
    private var cancelled: [String] = []
    private var activeResponse: String?
    private var activeRequest: String?
    private var lastTerminalActivity = Date.distantPast
    private var transferStatus: AgentTransferStatus = .none
    private var transferSessionId: String?
    private var lastTransferTransition = Date.distantPast
    private var transferRevision = 0
    private var activityText: String?
    private var pendingActionRenders = Set<String>()
    weak var delegate: ChatClientDelegate?

    init(sessionManager: ChatSession, config: SDKConfiguration, httpSession: URLSession = .shared) {
        self.sessionManager = sessionManager
        self.config = config
        self.httpSession = httpSession
    }
    var customDataSnapshot: [String: AnySendable] { customData.mapValues(AnySendable.init) }
    func updateCustomData(_ data: [String: Any]) { customData.merge(data) { _, new in new } }
    func clearCustomData() { customData.removeAll() }
    func getMessages() -> [Message] { messages }
    func clearPending() {}  // Never replay a potentially accepted turn after reconnect.
    func resendPending() {}

    func send(text: String, metadata: [String: Any]? = nil, attachmentIds: [String]? = nil)
        async throws -> String
    {
        guard sessionManager.isConnected() else { throw ChatClientError.notConnected }
        guard (attachmentIds?.count ?? 0) <= AttachmentConfig.maxFilesPerMessage,
            attachmentIds?.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                ?? true
        else { throw AttachmentError("A message can contain at most five attachments") }
        guard
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || attachmentIds?.isEmpty == false
        else {
            throw AttachmentError("Enter a message or attach a file")
        }
        guard text.count <= 10_000 else {
            throw AttachmentError("Messages must be 10,000 characters or fewer")
        }
        let id = UUID().uuidString
        let acceptedAt = Date()
        try await sessionManager.sendAsync(
            .chatMessage(
                text: text, messageId: id, sessionId: sessionManager.getSessionId(),
                attachmentIds: attachmentIds, metadata: metadata,
                customData: customData.isEmpty ? nil : customData))
        acceptedUser(
            id: id, text: text, metadata: metadata, attachmentIds: attachmentIds, timestamp: acceptedAt)
        return id
    }

    private func acceptedUser(
        id: String, text: String, metadata: [String: Any]?, attachmentIds: [String]? = nil,
        timestamp: Date = Date()
    ) {
        var safeMetadata = redaction ? [:] : metadata ?? [:]
        if redaction { safeMetadata.removeValue(forKey: "display_label") }
        let message = Message(
            id: id, role: .user, content: redaction ? "••••" : text, timestamp: timestamp,
            metadata: safeMetadata.mapValues(AnySendable.init), attachmentIds: attachmentIds,
            pendingRender: redaction,
            status: .accepted)
        upsert(message)
        emit(.messageReceived(message))
        let completedEarly = lastTerminalActivity >= timestamp
        activeRequest = completedEarly ? nil : id
        if let early = parkedRenders.removeValue(forKey: id) {
            applyRender(id: id, text: early.0, withheld: early.1)
        }
        setTyping(!completedEarly && transferStatus != .queued && transferStatus != .connected)
    }

    func submitAction(
        actionId: String, value: String? = nil, formData: [String: String]? = nil,
        renderId: String? = nil
    ) throws {
        guard !actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatClientError.emptyActionId
        }
        if alreadySubmitted(renderId) { return }
        try sessionManager.send(
            .actionSubmit(actionId: actionId, value: value, formData: formData, renderId: renderId))
        recordAction(actionId, value: value, renderId: renderId)
    }
    func performAction(
        actionId: String, value: String?, formData: [String: String]?, renderId: String?,
        displayText: String?
    ) async throws {
        guard !actionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ChatClientError.emptyActionId
        }
        if alreadySubmitted(renderId) { return }
        if let renderId {
            guard pendingActionRenders.insert(renderId).inserted else {
                throw AttachmentError("This action is already pending")
            }
        }
        defer { if let renderId { pendingActionRenders.remove(renderId) } }
        var payload: [String: Any] = ["type": "action_submit", "actionId": actionId]
        payload["value"] = value
        payload["formData"] = formData
        payload["renderId"] = renderId
        let id = UUID().uuidString
        let acceptedAt = Date()
        if let displayText, !displayText.isEmpty {
            payload["messageId"] = id
            payload["displayText"] = String(displayText.prefix(500))
        }
        try await sessionManager.sendAsync(.raw(payload))
        recordAction(actionId, value: value, renderId: renderId)
        if let displayText, !displayText.isEmpty {
            acceptedUser(id: id, text: displayText, metadata: nil, timestamp: acceptedAt)
        }
    }
    private func alreadySubmitted(_ renderId: String?) -> Bool {
        guard let renderId else { return false }
        return messages.contains { message in
            let actions = message.metadata?["actions"]?.value as? [String: Any] ?? [:]
            return (actions["renderId"] as? String ?? message.id) == renderId
                && actions["submitted"] != nil
        }
    }
    private func recordAction(_ action: String, value: String?, renderId: String?) {
        guard let renderId else { return }
        let selection: [String: Any] = [
            "actionId": action, "value": value ?? "", "status": "submitted",
        ]
        messages = messages.map { message in
            var metadata = message.metadata?.mapValues(\.value) ?? [:]
            var actions = metadata["actions"] as? [String: Any] ?? [:]
            guard (actions["renderId"] as? String ?? message.id) == renderId else { return message }
            actions["submitted"] = selection
            metadata["actions"] = actions
            return message.replacing(metadata: metadata.mapValues(AnySendable.init))
        }
        emit(.historyLoaded(messages: messages))
    }

    func submitFeedback(
        messageId: String, ratingType: String, ratingValue: Int, feedbackText: String? = nil,
        actionRenderId: String? = nil, timeout: TimeInterval = 10
    ) async throws -> String {
        guard sessionManager.isConnected() else { throw ChatClientError.notConnected }
        guard !messageId.isEmpty else { throw ChatClientError.emptyMessageId }
        let key = messageId + "|" + (actionRenderId ?? "")
        guard pendingFeedback[key] == nil else { throw ChatClientError.feedbackAlreadyPending }
        return try await waitForAck(
            key: key, survey: false, timeout: timeout,
            frame: .feedbackSubmit(
                messageId: messageId, ratingType: ratingType, ratingValue: ratingValue,
                feedbackText: feedbackText,
                actionRenderId: actionRenderId))
    }
    func submitAgentTransferSurvey(_ survey: AgentTransferSurvey, score: Int, comments: String?)
        async throws -> String
    {
        guard config.features.enableContactCenter, sessionManager.isConnected() else {
            throw ChatClientError.notConnected
        }
        guard survey.validScore(score) else { throw AttachmentError("Invalid survey score") }
        guard pendingSurveys[survey.artemisSessionId] == nil else {
            throw ChatClientError.feedbackAlreadyPending
        }
        var payload: [String: Any] = [
            "type": "agent_transfer_survey.submit", "artemisSessionId": survey.artemisSessionId,
            "surveyType": survey.surveyType, "score": score,
        ]
        payload["smartAssistSessionId"] = survey.smartAssistSessionId
        if survey.showComment(for: score), let comments {
            payload["comments"] = String(comments.prefix(4000))
        }
        return try await waitForAck(
            key: survey.artemisSessionId, survey: true, timeout: 10, frame: .raw(payload))
    }
    private func waitForAck(
        key: String, survey: Bool, timeout: TimeInterval, frame: TransportClientMessage
    )
        async throws -> String
    {
        try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000)) } catch {
                    return
                }
                self?.finishAck(
                    key: key, survey: survey, result: .failure(ChatClientError.feedbackTimeout(timeout)))
            }
            let pending = PendingFeedback(continuation: continuation, timer: timer)
            if survey { pendingSurveys[key] = pending } else { pendingFeedback[key] = pending }
            Task { [weak self] in
                do { try await self?.sessionManager.sendAsync(frame) } catch {
                    self?.finishAck(key: key, survey: survey, result: .failure(error))
                }
            }
        }
    }
    private func finishAck(key: String, survey: Bool, result: Result<String, Error>) {
        let pending =
            survey ? pendingSurveys.removeValue(forKey: key) : pendingFeedback.removeValue(forKey: key)
        pending?.timer.cancel()
        pending?.continuation.resume(with: result)
    }
    func connectionLost() {
        historyGeneration += 1
        historyTask?.cancel()
        historyTask = nil
        historyRefreshRequested = false
        for key in Array(pendingFeedback.keys) {
            finishAck(key: key, survey: false, result: .failure(ChatClientError.notConnected))
        }
        for key in Array(pendingSurveys.keys) {
            finishAck(key: key, survey: true, result: .failure(ChatClientError.notConnected))
        }
        setTyping(false)
        activityText = nil
        emit(.activity(text: nil))
    }
    func clearMessages() {
        connectionLost()
        messages.removeAll()
        parkedRenders.removeAll()
        cancelled.removeAll()
        activeRequest = nil
        activeResponse = nil
        emit(.historyLoaded(messages: []))
    }

    func handleServerMessage(_ message: TransportServerMessage) {
        let raw = message.raw
        let id = raw["messageId"] as? String
        if config.features.enableContactCenter,
            let event = ContactCenterEventNormalizer.normalize(message)
        {
            delegate?.chatClient(self, didReceive: event)
        }
        switch message.type {
        case "session_start":
            guard let session = raw["sessionId"] as? String, !session.isEmpty else { return }
            if let previous = currentSessionId, previous != session {
                clearMessages()
                transferStatus = .none
                transferSessionId = nil
                lastTransferTransition = .distantPast
                transferRevision = 0
                emit(.agentTransferChanged(.none))
            }
            currentSessionId = session
            redaction =
                (raw["capabilities"] as? [String: Any])?["liveUserInputRedaction"] as? Bool == true
            activeResponse = nil
            activeRequest = nil
            if (raw["initialAssistantMessage"] as? [String: Any])?["expected"] as? Bool == true {
                setTyping(true)
            }
        case "response_start":
            guard let id, !cancelled.contains(id) else { return }
            activeResponse = id
            if !messages.contains(where: { $0.id == id }) {
                let item = Message(id: id, role: .assistant, content: "", status: .streaming)
                upsert(item)
                emit(.messageReceived(item))
            }
            emit(.messageStart(messageId: id))
            setTyping(true)
        case "response_chunk":
            guard let id, !cancelled.contains(id),
                let chunk = MessageNormalizer.string(raw, ["chunk", "content", "text"])
            else { return }
            activeResponse = id
            let old = messages.first { $0.id == id } ?? Message(id: id, role: .assistant, content: "")
            let item = old.replacing(content: old.content + chunk, status: .streaming)
            upsert(item)
            emit(.messageReceived(item))
            emit(.messageChunk(messageId: id, chunk: chunk))
        case "response_end":
            let responseID = id ?? UUID().uuidString
            guard !cancelled.contains(responseID) else { return }
            lastTerminalActivity = Date()
            var normalizedRaw = raw
            let old = messages.first { $0.id == responseID }
            if raw["timestamp"] == nil, let old {
                normalizedRaw["timestamp"] = old.timestamp.timeIntervalSince1970 * 1000
            }
            var item = MessageNormalizer.parse(normalizedRaw, id: responseID)
            if item.content.isEmpty, let old { item = item.replacing(content: old.content) }
            let hasPayload =
                !item.content.isEmpty || item.metadata?["richContent"] != nil
                || item.metadata?["actions"] != nil
                || !item.renderables.isEmpty || item.agentLink != nil || item.agentTransferSurvey != nil
                || item.metadata?["attachments"] != nil
            if hasPayload {
                upsert(item)
                emit(.messageEnd(messageId: responseID, message: item))
                emit(.messageReceived(item))
            } else {
                messages.removeAll { $0.id == responseID }
                emit(.historyLoaded(messages: messages))
            }
            if AgentTransfer.status(item) == .queued,
                transferStatus != .connected
            {
                setTransfer(.queued)
            }
            if activeResponse == nil || activeResponse == responseID {
                activeResponse = nil
                activeRequest = nil
                setTyping(false)
                emit(.activity(text: nil))
            }
        case "user_message_rendered":
            guard let id else { return }
            applyRender(
                id: id, text: MessageNormalizer.string(raw, ["content", "text"]) ?? "",
                withheld: raw["status"] as? String == "withheld")
        case "typing_update": setTyping(raw["isTyping"] as? Bool == true)
        case "execution_cancelled":
            let request = raw["requestMessageId"] as? String
            let reason = raw["reason"] as? String ?? "client_cancel"
            let owns =
                request != nil
                ? request == activeRequest || (activeRequest == nil && id == activeResponse)
                : id != nil ? id == activeResponse : reason != "preempted"
            if let id { cancelResponse(id) }
            if owns {
                lastTerminalActivity = Date()
                activeRequest = nil
                activeResponse = nil
                setTyping(false)
                emit(.activity(text: nil))
            }
            emit(.responseCancelled(messageId: id, reason: reason))
        case "agent_transfer_event": handleTransfer(raw)
        case "feedback.ack", "agent_transfer_survey.ack":
            let survey = message.type == "agent_transfer_survey.ack"
            let key =
                survey
                ? raw["artemisSessionId"] as? String ?? ""
                : (raw["messageId"] as? String ?? "") + "|" + (raw["actionRenderId"] as? String ?? "")
            if raw["success"] as? Bool == true {
                finishAck(key: key, survey: survey, result: .success(raw["feedbackId"] as? String ?? key))
            } else {
                let error = raw["error"] as? [String: Any] ?? [:]
                finishAck(
                    key: key, survey: survey,
                    result: .failure(
                        FeedbackSubmitError(
                            code: error["code"] as? String ?? "REJECTED",
                            message: "Feedback could not be submitted. Please retry.")))
            }
        case "trace_event":
            let event = raw["event"] as? [String: Any] ?? raw
            let type = MessageNormalizer.string(event, ["type", "eventType"]) ?? ""
            activity(
                type == "tool_thought" ? "thought" : type,
                raw: event["data"] as? [String: Any] ?? event["payload"] as? [String: Any] ?? event)
        case "status_update", "status_clear", "thought", "handoff", "tool_warnings", "session_health":
            activity(message.type, raw: raw)
        case "error":
            lastTerminalActivity = Date()
            setTyping(false)
            emit(.activity(text: nil))
            emit(
                .error(
                    error: ChatClientError.serverError(
                        MessageNormalizer.string(raw, ["message", "content"])
                            ?? "The assistant could not complete the response")))
        default: break
        }
    }

    private func applyRender(id: String, text: String, withheld: Bool) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.role == .user }) else {
            parkedRenders[id] = (text, withheld)
            if parkedRenders.count > 100, let first = parkedRenders.keys.first {
                parkedRenders.removeValue(forKey: first)
            }
            return
        }
        guard messages[index].pendingRender else { return }
        let item = messages[index].replacing(
            content: withheld ? "••••" : MessageNormalizer.displayText(text), pendingRender: false)
        messages[index] = item
        emit(.messageReceived(item))
    }
    private func cancelResponse(_ id: String) {
        if !cancelled.contains(id) {
            cancelled.append(id)
            cancelled = Array(cancelled.suffix(100))
        }
        messages = messages.compactMap { message in
            guard message.id == id, message.status == .streaming else { return message }
            return message.content.isEmpty ? nil : message.replacing(status: .cancelled)
        }
        emit(.historyLoaded(messages: messages))
    }
    private func handleTransfer(_ raw: [String: Any]) {
        // Human-agent replies are part of the active transcript, as in the WebSDK.
        // Optional contact-center UI configuration must not discard delivered messages.
        guard currentSessionId != nil,
            let event = AgentTransfer.parse(raw)
        else {
            return
        }
        let transitions = [
            "agent:queued", "agent:waiting_message", "agent:connected", "agent:disconnected",
        ]
        guard !transitions.contains(event.type) || event.timestamp >= lastTransferTransition else {
            return
        }
        for item in event.messages {
            guard
                !item.content.isEmpty || item.agentLink != nil || item.agentTransferSurvey != nil
                    || item.metadata?["attachments"] != nil
            else { continue }
            let identity = AgentTransfer.identity(item)
            let replayIdentity = AgentTransfer.replayIdentity(item)
            if let old = messages.first(where: { existing in
                existing.id == item.id
                    || (identity != nil && AgentTransfer.identity(existing) == identity)
                    || (replayIdentity != nil && AgentTransfer.replayIdentity(existing) == replayIdentity)
            }) {
                upsert(old.replacing(content: item.content, metadata: item.metadata))
            } else {
                upsert(item)
                emit(.messageReceived(item))
            }
        }
        var next: AgentTransferStatus?
        switch event.type {
        case "agent:queued": next = .queued
        case "agent:waiting_message":
            if transferStatus != .connected || transferSessionId != event.sessionId { next = .queued }
        case "agent:connected": next = .connected
        case "agent:message", "agent:form", "agent.attachment":
            if transferStatus != .disconnected { next = .connected }
        case "agent:disconnected": next = .disconnected
        default: break
        }
        if let next, event.timestamp >= lastTransferTransition {
            lastTransferTransition = event.timestamp
            transferRevision += 1
            transferSessionId = event.sessionId
            if let activeResponse { cancelResponse(activeResponse) }
            activeResponse = nil
            activeRequest = nil
            setTransfer(next)
            setTyping(false)
            emit(.activity(text: nil))
        }
        if ["agent:typing", "agent:typing_stop", "agent:message"].contains(event.type),
            transferSessionId == nil || transferSessionId == event.sessionId,
            transferStatus != .disconnected
        {
            setTyping(event.type == "agent:typing")
        }
        emit(.historyLoaded(messages: messages))
    }
    private func setTransfer(_ value: AgentTransferStatus) {
        transferStatus = value
        emit(.agentTransferChanged(value))
    }
    private func activity(_ type: String, raw: [String: Any]) {
        if type == "status_clear" {
            activityText = nil
            emit(.activity(text: nil))
            setTyping(false)
            return
        }
        guard config.features.enableActivityUpdates, let scope = sessionManager.getScope(),
            scope.showActivityUpdates
        else { return }
        let policy = scope.activityVisibilityPolicy.mapValues(\.value)
        guard policy["enabled"] as? Bool != false else { return }
        let category =
            type == "thought" ? "thoughtSummaries" : type == "status_update" ? "fillers" : "systemNotices"
        guard policy[category] as? Bool ?? (category != "thoughtSummaries") else { return }
        if type == "thought", !config.chat.enableThoughts { return }
        let value: String?
        switch type {
        case "thought":
            value =
                MessageNormalizer.string(raw, ["thought", "content"])
                ?? (policy["includeReasonFallback"] as? Bool == true
                    ? MessageNormalizer.string(raw, ["reasoning"]) : nil)
        case "status_update": value = MessageNormalizer.string(raw, ["text", "content"])
        case "handoff":
            value =
                policy["exposeAgentNames"] as? Bool == true
                ? "Transferring to \(MessageNormalizer.string(raw, ["toAgent", "to"]) ?? "another assistant")"
                : "Transferring to another assistant"
        case "tool_warnings": value = "Some tools could not complete their work"
        case "session_health": value = "The conversation needs attention"
        default: return
        }
        guard let value, !value.isEmpty else { return }
        let text = String(value.prefix(min(2000, max(1, policy["maxTextChars"] as? Int ?? 240))))
        if type == "status_update" {
            activityText = text
            emit(.activity(text: text))
            setTyping(true)
        } else {
            var metadata: [String: AnySendable] = [:]
            if type == "thought", policy["exposeToolNames"] as? Bool == true,
                let name = MessageNormalizer.string(raw, ["toolName"])
            {
                metadata["toolName"] = AnySendable(name)
            }
            if type == "thought", policy["exposeAgentNames"] as? Bool == true,
                let name = MessageNormalizer.string(raw, ["agentName", "agent"])
            {
                metadata["agentName"] = AnySendable(name)
            }
            let message = Message(
                id: raw["messageId"] as? String ?? UUID().uuidString,
                role: type == "thought" ? .thought : .system,
                content: text, metadata: metadata.isEmpty ? nil : metadata)
            upsert(message)
            emit(.messageReceived(message))
        }
    }
    private func setTyping(_ value: Bool) {
        if config.chat.enableTypingIndicator { emit(.typingIndicator(isTyping: value)) }
    }
    private func upsert(_ item: Message) {
        if let i = messages.firstIndex(where: { $0.id == item.id }) {
            messages[i] = item
        } else if item.role == .user,
            let index = messages.firstIndex(where: { $0.timestamp > item.timestamp })
        {
            messages.insert(item, at: index)
        } else {
            messages.append(item)
        }
        messages = Array(messages.suffix(max(1, config.chat.maxMessagesLocal)))
    }
    private func emit(_ event: ChatEvent) { delegate?.chatClient(self, didReceive: event) }

    func hydratePersistedHistory() {
        guard config.features.enableHistory, let id = sessionManager.getSessionId() else { return }
        guard historyTask == nil else {
            historyRefreshRequested = true
            return
        }
        let epoch = historyGeneration
        let transferAtRequest = transferRevision
        historyTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if epoch == self.historyGeneration {
                    self.historyTask = nil
                    if self.historyRefreshRequested {
                        self.historyRefreshRequested = false
                        self.hydratePersistedHistory()
                    }
                }
            }
            do {
                let fetched = try await self.fetchHistory(sessionId: id)
                guard !Task.isCancelled, epoch == self.historyGeneration,
                    id == self.sessionManager.getSessionId()
                else { return }
                self.mergeHistory(fetched, transferAtRequest: transferAtRequest)
            } catch {
                if !Task.isCancelled { self.delegate?.chatClient(self, didFailHistoryHydration: error) }
            }
        }
    }
    private func fetchHistory(sessionId: String) async throws -> [Message] {
        let token = try await sessionManager.getAuthToken()
        var result: [Message] = []
        var cursor: String?
        for _ in 0..<max(1, config.chat.maxHistoryPages) {
            var url = URLComponents(string: sessionManager.getEndpoint())!
            url.path += "/api/projects/\(sessionManager.getProjectId())/sessions/\(sessionId)/messages"
            url.queryItems = [
                URLQueryItem(name: "direction", value: "asc"),
                URLQueryItem(name: "limit", value: String(max(1, config.chat.historyPageSize))),
            ]
            if let cursor { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 20
            request.setValue(token, forHTTPHeaderField: "X-SDK-Token")
            let (data, response) = try await httpSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw ChatClientError.historyRequestFailed(
                    status: (response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let records = body["messages"] as? [[String: Any]] ?? []
            result += records.compactMap { raw in
                guard let id = raw["id"] as? String, let roleString = raw["role"] as? String,
                    let role = MessageRole(rawValue: roleString)
                else { return nil }
                return MessageNormalizer.parse(raw, role: role, id: id)
            }
            guard body["hasMore"] as? Bool == true, let next = body["nextCursor"] as? String,
                !next.isEmpty,
                next != cursor
            else { break }
            cursor = next
        }
        return result
    }
    func mergeHistory(_ incoming: [Message], transferAtRequest: Int? = nil) {
        var unique = Set<String>()
        var uniqueTransferIdentities = Set<String>()
        var uniqueTransferReplayIdentities = Set<String>()
        let expanded = incoming.flatMap { message -> [Message] in
            guard config.features.enableContactCenter,
                let raw = message.metadata?["restoredAgentTransferSurvey"]?.value as? [String: Any],
                let survey = AgentTransferSurvey.parse(raw, wire: true)
            else { return [message] }
            return [
                message,
                Message(
                    id: "agent-transfer-survey-\(survey.artemisSessionId)", role: .assistant,
                    content: survey.prompt, timestamp: message.timestamp,
                    metadata: ["agentTransferSurvey": AnySendable(raw)]),
            ]
        }
        let history = expanded.filter { message in
            guard unique.insert(message.id).inserted else { return false }
            if let identity = AgentTransfer.identity(message),
                !uniqueTransferIdentities.insert(identity).inserted
            { return false }
            if let replayIdentity = AgentTransfer.replayIdentity(message),
                !uniqueTransferReplayIdentities.insert(replayIdentity).inserted
            { return false }
            return true
        }
        let ids = Set(history.map(\.id))
        let identities = Set(history.compactMap(AgentTransfer.identity))
        let replayIdentities = Set(history.compactMap(AgentTransfer.replayIdentity))
        let localIDs = Set(messages.map(\.id))
        var pool: [String: Int] = [:]
        for item in history where !localIDs.contains(item.id) {
            pool[fingerprint(item), default: 0] += 1
        }
        let locals = messages.filter { item in
            if ids.contains(item.id)
                || AgentTransfer.identity(item).map({ identities.contains($0) }) == true
                || AgentTransfer.replayIdentity(item).map({ replayIdentities.contains($0) }) == true
            {
                return false
            }
            if item.status == .streaming || item.pendingRender { return true }
            let key = fingerprint(item)
            let count = pool[key] ?? 0
            if count > 0 {
                pool[key] = count - 1
                return false
            }
            return true
        }
        if !history.isEmpty && history.allSatisfy({ $0.sequence != nil }) {
            messages =
                history.sorted { $0.sequence! < $1.sequence! }
                + locals.sorted { $0.timestamp < $1.timestamp }
        } else {
            messages = (history + locals).sorted { $0.timestamp < $1.timestamp }
        }
        let selections = messages.compactMap {
            ($0.metadata?["custom"]?.value as? [String: Any])?["actionSubmit"] as? [String: Any]
        }
        for selection in selections {
            if let render = selection["renderId"] as? String,
                let action = selection["actionId"] as? String
            {
                recordAction(action, value: selection["value"] as? String, renderId: render)
            }
        }
        messages = Array(messages.suffix(max(1, config.chat.maxMessagesLocal)))
        if transferAtRequest == nil || transferAtRequest == transferRevision,
            let latest = messages.last(where: { AgentTransfer.status($0) != nil }),
            latest.timestamp >= lastTransferTransition
        {
            lastTransferTransition = latest.timestamp
            transferSessionId = latest.metadata?["agentTransferSessionId"]?.value as? String
            setTransfer(AgentTransfer.status(latest)!)
        }
        emit(.historyLoaded(messages: messages))
    }
    private func fingerprint(_ message: Message) -> String {
        let raw = message.metadata?.mapValues(\.value) ?? [:]
        return MessageNormalizer.jsonString([
            "role": message.role.rawValue, "text": message.content,
            "richContent": raw["richContent"] ?? NSNull(),
            "actions": raw["actions"] ?? NSNull(), "attachments": raw["attachments"] ?? NSNull(),
        ])
    }
}

private struct PendingFeedback {
    let continuation: CheckedContinuation<String, Error>
    let timer: Task<Void, Never>
}

enum ChatClientError: Error, LocalizedError {
    case notConnected, emptyActionId, emptyMessageId, feedbackAlreadyPending
    case feedbackTimeout(TimeInterval)
    case serverError(String)
    case historyRequestFailed(status: Int)
    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to the platform"
        case .emptyActionId: return "actionId must not be empty"
        case .emptyMessageId: return "messageId must not be empty"
        case .feedbackAlreadyPending: return "Feedback is already pending"
        case .feedbackTimeout: return "The server did not respond. Please retry."
        case .serverError(let text): return text
        case .historyRequestFailed(let status): return "History request failed (\(status))"
        }
    }
}
