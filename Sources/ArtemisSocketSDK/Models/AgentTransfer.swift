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
            "formDisplayName": "agentTransferFormDisplayName",
        ] {
            if let value = data[from] as? String { metadata[to] = value }
        }
    }
    static func parse(_ raw: [String: Any]) -> Event? {
        guard let session = raw["sessionId"] as? String, !session.isEmpty,
            let event = raw["event"] as? [String: Any], let type = event["type"] as? String,
            [
                "agent:message", "agent:form", "agent.attachment", "agent:queued", "agent:waiting_message",
                "agent:connected", "agent:disconnected", "agent:typing", "agent:typing_stop",
            ].contains(type)
        else { return nil }
        let data = event["data"] as? [String: Any] ?? [:]
        let date = MessageNormalizer.timestamp(event["timestamp"])
        let providerID = MessageNormalizer.string(
            data,
            [
                "providerMessageId", "idempotencyKey", "messageId", "msgId", "eventId", "requestId",
                "attachmentId",
                "_id", "id",
            ])
        let fingerprint = [
            session, type, event["timestamp"] as? String ?? "",
            MessageNormalizer.string(data, ["message", "text", "body", "closeMessage"]) ?? "",
            data["linkUrl"] as? String ?? "", data["formUrl"] as? String ?? "",
        ].joined(separator: "|")
        let stable =
            providerID
            ?? SHA256.hash(data: Data(fingerprint.utf8)).prefix(12).map { String(format: "%02x", $0) }
            .joined()
        let id = "agent-transfer:\(session):\(type):\(stable)"
        var metadata: [String: Any] = [
            "agentTransferEventType": type, "agentTransferSessionId": session,
            "contentFormat": "plain_text",
            "custom": [
                "source": "agent-transfer", "transferSessionId": session, "eventType": type,
                "providerMessageId": providerID ?? stable,
            ],
        ]
        copyLinks(data, into: &metadata)
        let source = ["system": AnySendable("integration"), "provider": AnySendable("smartassist")]
        func message(
            _ text: String, role: MessageRole = .assistant, suffix: String = "",
            extra: [String: Any] = [:]
        )
            -> Message
        {
            Message(
                id: id + suffix, role: role, content: text, timestamp: date,
                metadata: metadata.merging(extra) { _, new in new }.mapValues(AnySendable.init),
                messageSource: source)
        }
        func text(_ keys: [String]) -> String { MessageNormalizer.string(data, keys) ?? "" }
        var messages: [Message] = []
        switch type {
        case "agent:message": messages = [message(text(["message", "text", "body"]))]
        case "agent:form":
            messages = [message(text(["formText", "formTitle", "linkTitle", "message"]))]
        case "agent.attachment":
            if let attachmentID = data["attachmentId"] as? String,
                data["runtimeSessionId"] as? String != nil
            {
                messages = [
                    message(
                        "",
                        extra: [
                            "attachments": [
                                [
                                    "id": attachmentID, "filename": data["fileName"] ?? "Attachment",
                                    "mimeType": data["mimeType"] ?? "application/octet-stream",
                                    "sizeBytes": data["sizeBytes"] ?? 0,
                                ]
                            ]
                        ])
                ]
            }
        case "agent:queued", "agent:waiting_message":
            let value = text(["message", "text", "body"])
            messages = [
                message(
                    value.isEmpty ? "Waiting for a human agent…" : value, role: .system,
                    extra: value.isEmpty ? ["sdkStringKey": "Waiting for a human agent…"] : [:])
            ]
        case "agent:connected":
            messages = [
                message(
                    "Connected to a human agent.", role: .system,
                    extra: ["sdkStringKey": "Connected to a human agent."])
            ]
        case "agent:disconnected":
            let close = text(["closeMessage", "message", "text", "body"])
            if !close.isEmpty { messages.append(message(close, suffix: ":close")) }
            messages.append(
                message(
                    "The human agent has left the conversation.", role: .system, suffix: ":status",
                    extra: ["sdkStringKey": "The human agent has left the conversation."]))
            if let survey = data["survey"] as? [String: Any],
                let parsed = AgentTransferSurvey.parse(survey, wire: true)
            {
                messages.append(
                    Message(
                        id: "agent-transfer-survey-\(parsed.artemisSessionId)", role: .assistant,
                        content: parsed.prompt, timestamp: date,
                        metadata: ["agentTransferSurvey": AnySendable(survey)], messageSource: source))
            }
        default: break
        }
        return Event(sessionId: session, type: type, timestamp: date, messages: messages)
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
        case "agent:connected", "agent:message", "agent:form", "agent.attachment": return .connected
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
}
