import CryptoKit
import Foundation

public enum AgentTransferStatus: String, Sendable { case none, queued, connected, disconnected }

public struct AgentTransferSurvey: Sendable {
    public let surveyType: String
    public let artemisSessionId: String
    public let smartAssistSessionId: String?
    public let prompt: String
    public let max: Int
    public let submitLabel: String
    public let pendingMessage: String
    public let successMessage: String
    public let errorMessage: String
    public let commentPrompt: String?
    public let commentPlaceholder: String
    public let commentVisibility: String?
    public let commentRatings: [Int]

    public var choices: ClosedRange<Int> { (surveyType == "csat" ? 1 : 0)...max }
    public func validScore(_ score: Int) -> Bool { choices.contains(score) }
    public func showComment(for score: Int?) -> Bool {
        switch commentVisibility {
        case "always": return true
        case "never": return false
        case "conditional":
            return score.map { commentRatings.isEmpty || commentRatings.contains($0) } ?? false
        default: return score != nil
        }
    }
    static func parse(_ raw: [String: Any]?, wire: Bool = false) -> AgentTransferSurvey? {
        guard let raw, !wire || raw["triggerSurvey"] as? Bool == true,
            let type = raw["surveyType"] as? String, ["nps", "csat", "likeDislike"].contains(type),
            let session = raw["artemisSessionId"] as? String,
            !session.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        func label(_ camel: String, _ snake: String, _ fallback: String) -> String {
            let value = (raw[camel] ?? raw[snake]) as? String
            return value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? value! : fallback
        }
        let cap = type == "nps" ? 10 : type == "csat" ? 5 : 1
        return AgentTransferSurvey(
            surveyType: type, artemisSessionId: session,
            smartAssistSessionId: raw["smartAssistSessionId"] as? String,
            prompt: label("prompt", "prompt", "How would you rate your experience?"),
            max: min(cap, Swift.max(1, raw["max"] as? Int ?? cap)),
            submitLabel: label("submitLabel", "submit_label", "Submit"),
            pendingMessage: label("pendingMessage", "pending_message", "Submitting your feedback…"),
            successMessage: label("successMessage", "success_message", "Thanks for your feedback."),
            errorMessage: label(
                "errorMessage", "error_message", "We could not submit your feedback. Please try again."),
            commentPrompt: (raw["commentPrompt"] ?? raw["comment_prompt"]) as? String,
            commentPlaceholder: label(
                "commentPlaceholder", "comment_placeholder", "Additional comments (optional)"),
            commentVisibility: (raw["commentVisibility"] ?? raw["comment_visibility"]) as? String,
            commentRatings: (raw["commentRatings"] ?? raw["comment_ratings"]) as? [Int] ?? [])
    }
}

extension Message {
    public var agentTransferSurvey: AgentTransferSurvey? {
        AgentTransferSurvey.parse(metadata?["agentTransferSurvey"]?.value as? [String: Any])
    }
    public var agentLink: URL? {
        let raw = metadata?.mapValues(\.value) ?? [:]
        return MessageNormalizer.string(
            raw, ["agentTransferFormUrl", "smartAssistFormUrl", "agentTransferLinkUrl"]
        )
        .flatMap { MessageNormalizer.safeWebURL($0) }
    }
    public var agentLinkTitle: String {
        MessageNormalizer.string(
            metadata?.mapValues(\.value) ?? [:],
            [
                "agentTransferFormDisplayName", "smartAssistFormDisplayName", "agentTransferFormTitle",
                "agentTransferLinkTitle",
            ]) ?? "Open form"
    }
}

enum AgentTransfer {
    struct Event {
        let sessionId: String
        let type: String
        let timestamp: Date
        let timestampText: String?
        let deliveryId: String?
        let data: [String: Any]
        let messages: [Message]
    }
    static func normalizeMetadata(_ raw: [String: Any]) -> [String: Any] {
        var result = raw
        guard let custom = raw["custom"] as? [String: Any],
            custom["source"] as? String == "agent-transfer"
        else {
            return result
        }
        result["agentTransferEventType"] = custom["eventType"]
        result["agentTransferSessionId"] = custom["transferSessionId"]
        result["contentFormat"] = "plain_text"
        let data = custom["providerEventData"] as? [String: Any] ?? [:]
        copyLinks(data, into: &result)
        if custom["eventType"] as? String == "agent:disconnected",
            let survey = data["survey"] as? [String: Any],
            AgentTransferSurvey.parse(survey, wire: true) != nil
        {
            result["restoredAgentTransferSurvey"] = survey
        }
        return result
    }
    static func copyLinks(_ data: [String: Any], into metadata: inout [String: Any]) {
        for (from, to) in [
            "linkUrl": "agentTransferLinkUrl", "linkTitle": "agentTransferLinkTitle",
            "linkType": "agentTransferLinkType",
            "formUrl": "agentTransferFormUrl", "formTitle": "agentTransferFormTitle",
            "formRenderType": "agentTransferFormRenderType",
            "formName": "agentTransferFormName",
            "formDisplayName": "agentTransferFormDisplayName",
        ] {
            if let value = data[from] as? String { metadata[to] = value }
        }
    }
    private static func stableHash(_ value: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for codeUnit in value.utf16 {
            hash = (hash ^ UInt32(codeUnit)) &* 16_777_619
        }
        return String(hash, radix: 36)
    }
    static func disconnectStatus(_ data: [String: Any]) -> (text: String, stringKey: String)? {
        let reason = data["disconnectReason"] as? String
        guard data["suppressDisconnectNotice"] as? Bool != true, reason != "transfer_to_email" else {
            return nil
        }
        if ["wait_timeout", "long_wait", "no_agents"].contains(reason ?? "") {
            let text = "No agent is available right now. You are back with the AI assistant."
            return (text, text)
        }
        let text = "Human agent has disconnected. You are now back with the AI assistant."
        return (text, text)
    }
    static func lifecycleEvent(
        _ event: Event, lifecycleSessionId: String
    ) -> AgentTransferLifecycleEvent? {
        let agentInfo = event.data["agentInfo"] as? [String: Any]
        let components = [agentInfo?["firstName"] as? String, agentInfo?["lastName"] as? String]
            .compactMap { $0 }.compactMap(nonEmpty)
        let combinedName = components.joined(separator: " ")
        let name = (agentInfo?["fullName"] as? String).flatMap(nonEmpty)
            ?? (combinedName.isEmpty ? nil : combinedName)
        let avatarURL = (agentInfo?["profImageUrl"] as? String)
            .flatMap { MessageNormalizer.safeWebURL($0) }
        let agent = (name != nil || avatarURL != nil)
            ? AgentTransferAgent(name: name, avatarURL: avatarURL) : nil
        let timestamp = event.timestampText
            ?? ISO8601DateFormatter().string(from: event.timestamp)
        switch event.type {
        case "agent:connected":
            if event.data["syntheticConnected"] as? Bool == true { return nil }
            return AgentTransferLifecycleEvent(
                kind: .connected, sessionId: lifecycleSessionId, timestamp: timestamp,
                transferred: event.data["transferred"] as? Bool == true, agent: agent)
        case "agent:transferred":
            let initiatedBy = (event.data["initiatedBy"] as? String).flatMap(nonEmpty) ?? "unknown"
            return AgentTransferLifecycleEvent(
                kind: .transferred, sessionId: lifecycleSessionId, timestamp: timestamp,
                initiatedBy: initiatedBy)
        case "agent:disconnected":
            let reason = (event.data["disconnectReason"] as? String).flatMap(nonEmpty) ?? "unknown"
            return AgentTransferLifecycleEvent(
                kind: .disconnected, sessionId: lifecycleSessionId, timestamp: timestamp,
                reason: reason)
        default: return nil
        }
    }
    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    static func parse(_ raw: [String: Any]) -> Event? {
        guard let session = raw["sessionId"] as? String, !session.isEmpty,
            let event = raw["event"] as? [String: Any], let type = event["type"] as? String,
            [
                "agent:message", "agent:form", "agent.attachment", "agent:queued", "agent:waiting_message",
                "agent:connected", "agent:disconnected", "agent:transferred", "agent:media", "agent:joined",
                "agent:exited", "agent:notice", "agent:typing", "agent:typing_stop",
            ].contains(type)
        else { return nil }
        let data = event["data"] as? [String: Any] ?? [:]
        func firstNonEmpty(_ keys: [String]) -> String? {
            keys.lazy.compactMap { data[$0] as? String }.first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
        let timestampText = event["timestamp"] as? String
        let date = MessageNormalizer.timestamp(event["timestamp"])
        let providerID = firstNonEmpty(
            [
                "providerMessageId", "idempotencyKey", "messageId", "msgId", "eventId", "requestId",
                "attachmentId",
                "_id", "id",
            ])
        let fallbackFingerprint = [
            session, type, timestampText ?? "",
            firstNonEmpty(["closeMessage", "message", "text", "body"]) ?? "",
            data["linkUrl"] as? String ?? "", data["formUrl"] as? String ?? "",
        ].joined(separator: "|")
        let stable = providerID ?? stableHash(fallbackFingerprint)
        var metadata: [String: Any] = [
            "agentTransferEventType": type, "agentTransferSessionId": session,
            "contentFormat": "plain_text",
            "custom": [
                "source": "agent-transfer", "transferSessionId": session, "eventType": type,
                "providerMessageId": providerID ?? stable,
            ],
        ]
        copyLinks(data, into: &metadata)
        if let timestampText { metadata["agentTransferTimestamp"] = timestampText }
        if let agentInfo = data["agentInfo"] { metadata["agentInfo"] = agentInfo }
        let source = (raw["messageSource"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 }
            ?? ["system": "integration", "provider": "smartassist"]
        let sourceProvider = source["provider"] as? String ?? "smartassist"
        func message(
            _ text: String, role: MessageRole = .assistant, suffix: String = "",
            extra: [String: Any] = [:]
        )
            -> Message
        {
            let fingerprint = [
                session, type, timestampText ?? "", text,
                data["linkUrl"] as? String ?? "", data["formUrl"] as? String ?? "",
            ].joined(separator: "|")
            let messageId = providerID.map { "agent-transfer:\(session):\(type):\($0)" }
                ?? "agent-transfer:\(stableHash(fingerprint))"
            return Message(
                id: messageId + suffix, role: role, content: text, timestamp: date,
                metadata: metadata.merging([
                    "participantType": role == .assistant ? "human_agent" : "system",
                    "agentTransferSource": sourceProvider,
                ]) { _, new in new }.merging(extra) { _, new in new }.mapValues(AnySendable.init),
                messageSource: source.mapValues(AnySendable.init))
        }
        func text(_ keys: [String]) -> String { firstNonEmpty(keys) ?? "" }
        var messages: [Message] = []
        switch type {
        case "agent:message": messages = [message(text(["message", "text", "body"]))]
        case "agent:form":
            messages = [message(text(["formText", "formTitle", "linkTitle", "message"]))]
        case "agent.attachment":
            if let attachmentID = data["attachmentId"] as? String,
                let runtimeSessionId = data["runtimeSessionId"] as? String,
                !attachmentID.isEmpty, !runtimeSessionId.isEmpty
            {
                let fileName = firstNonEmpty(["fileName"]) ?? "Attachment"
                let mimeType = firstNonEmpty(["mimeType"]) ?? "application/octet-stream"
                let sizeBytes = (data["sizeBytes"] as? NSNumber)?.int64Value ?? 0
                messages = [
                    message(
                        fileName,
                        extra: [
                            "agentTransferEventType": "attachment",
                            "agentTransferAttachmentId": attachmentID,
                            "agentTransferRuntimeSessionId": runtimeSessionId,
                            "agentTransferLinkTitle": fileName,
                            "agentTransferLinkType": "agent_attachment",
                            "attachmentIds": [attachmentID],
                            "attachmentFilenames": [fileName],
                            "attachmentMimeTypes": [mimeType],
                            "attachmentSizeBytes": [sizeBytes],
                        ])
                ]
            }
        case "agent:queued":
            let value = "Waiting for a human agent."
            messages = [message(value, role: .system, extra: ["sdkStringKey": value])]
        case "agent:waiting_message":
            let value = text(["message", "text", "body"])
            messages = [
                message(
                    value.isEmpty ? "Waiting for a human agent." : value, role: .system,
                    extra: value.isEmpty ? ["sdkStringKey": "Waiting for a human agent."] : [:])
            ]
        case "agent:connected":
            let notice = firstNonEmpty(["noticeText"])
            var extra: [String: Any] = notice == nil
                ? ["sdkStringKey": "Connected to a human agent."] : [:]
            if let agentInfo = data["agentInfo"] { extra["agentInfo"] = agentInfo }
            messages = [
                message(
                    notice ?? "Connected to a human agent.", role: .system, extra: extra)
            ]
        case "agent:joined", "agent:exited", "agent:notice":
            if let notice = firstNonEmpty(["noticeText"]) {
                messages = [message(notice, role: .system)]
            }
        case "agent:disconnected":
            let close = text(["closeMessage", "message", "text", "body"])
            if !close.isEmpty { messages.append(message(close, suffix: ":close")) }
            if let status = disconnectStatus(data) {
                messages.append(
                    message(status.text, role: .system, suffix: ":status",
                        extra: ["sdkStringKey": status.stringKey]))
            }
            if let survey = data["survey"] as? [String: Any],
                let parsed = AgentTransferSurvey.parse(survey, wire: true)
            {
                messages.append(
                    Message(
                        id: "agent-transfer-survey-\(parsed.artemisSessionId)", role: .assistant,
                        content: parsed.prompt, timestamp: date,
                        metadata: ["agentTransferSurvey": AnySendable(survey)],
                        messageSource: source.mapValues(AnySendable.init)))
            }
        default: break
        }
        return Event(
            sessionId: session, type: type, timestamp: date, timestampText: timestampText,
            deliveryId: firstNonEmpty(["deliveryId"]), data: data, messages: messages)
    }
    static func status(_ message: Message) -> AgentTransferStatus? {
        let custom = message.metadata?["custom"]?.value as? [String: Any] ?? [:]
        switch custom["transferState"] as? String {
        case "ended": return .disconnected
        case "connected": return .connected
        case "queued": return .queued
        default: break
        }
        switch message.metadata?["agentTransferEventType"]?.value as? String {
        case "transfer_active", "agent:queued", "agent:waiting_message": return .queued
        case "agent:connected", "agent:message", "agent:form", "agent.attachment", "attachment": return .connected
        case "agent:disconnected": return .disconnected
        default: return nil
        }
    }
    static func identity(_ message: Message) -> String? {
        guard let custom = message.metadata?["custom"]?.value as? [String: Any],
            custom["source"] as? String == "agent-transfer",
            let provider = custom["providerMessageId"] as? String
        else { return nil }
        return
            "\(custom["transferSessionId"] ?? "")|\(custom["eventType"] ?? "")|\(provider)|\(message.content)|\(message.agentLink?.absoluteString ?? "")"
    }
    static func replayIdentity(_ message: Message) -> String? {
        guard let custom = message.metadata?["custom"]?.value as? [String: Any],
            custom["source"] as? String == "agent-transfer",
            let session = custom["transferSessionId"] as? String,
            let eventType = custom["eventType"] as? String
        else { return nil }
        let timestamp = Int64((message.timestamp.timeIntervalSince1970 * 1_000).rounded(.down))
        let attachments = message.metadata?["attachments"]?.value ?? NSNull()
        return [
            session, eventType, String(timestamp), message.role.rawValue, message.content,
            message.agentLink?.absoluteString ?? "", MessageNormalizer.jsonString(attachments),
        ].joined(separator: "|")
    }
}
