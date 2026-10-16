import Foundation

/// One normalization boundary for live responses and persisted transcript rows.
enum MessageNormalizer {
    static func parse(_ raw: [String: Any], role: MessageRole = .assistant, id: String? = nil) -> Message {
        let envelope = raw["contentEnvelope"] as? [String: Any] ?? raw["content_envelope"] as? [String: Any] ?? [:]
        var metadata = envelope["metadata"] as? [String: Any] ?? [:]
        metadata.merge(raw["metadata"] as? [String: Any] ?? [:]) { _, new in new }
        if let localization = envelope["localization"] ?? raw["localization"] {
            metadata["localization"] = localization
        }
        if let rich = raw["richContent"] ?? raw["rich_content"] ?? envelope["richContent"] ?? envelope["rich_content"] {
            metadata["richContent"] = normalizeRich(rich)
        }
        if let actions = normalizeActions(raw["actions"] ?? envelope["actions"]) { metadata["actions"] = actions }
        if let attachments = raw["attachments"] { metadata["attachments"] = attachments }
        metadata = AgentTransfer.normalizeMetadata(metadata)
        var text = string(raw, ["fullText", "text", "content"]) ?? string(envelope, ["text", "content"]) ?? ""
        if role == .user { text = displayText(text) }
        let citations = (raw["citations"] as? [[String: Any]] ?? envelope["citations"] as? [[String: Any]] ?? [])
            .compactMap { item -> Citation? in
                guard let value = item["url"] as? String, let url = safeWebURL(value) else { return nil }
                return Citation(
                    index: item["index"] as? Int ?? 0, title: item["title"] as? String ?? "Source", url: url,
                    sourceType: item["sourceType"] as? String ?? "")
            }
        let custom = metadata["custom"] as? [String: Any] ?? [:]
        let source =
            raw["messageSource"] as? [String: Any] ?? [
                "system": custom["source"] as? String == "agent-transfer" ? "integration" : "artemis",
                "provider": custom["provider"] as? String ?? "smartassist",
            ]
        let renderables = (raw["renderables"] as? [[String: Any]] ?? envelope["renderables"] as? [[String: Any]] ?? [])
            .filter {
                ($0["name"] as? String)?.isEmpty == false && $0["payload"] != nil
            }
        return Message(
            id: id ?? string(raw, ["id", "messageId"]) ?? UUID().uuidString, role: role,
            content: text, timestamp: timestamp(raw["timestamp"]),
            metadata: JSONValue.anySendableDictionary(from: metadata),
            attachmentIds: raw["attachmentIds"] as? [String], sequence: raw["sequence"] as? Int,
            citations: citations, messageSource: JSONValue.anySendableDictionary(from: source),
            contentEnvelope: envelope.isEmpty ? nil : JSONValue.anySendableDictionary(from: envelope),
            renderables: renderables.map { $0.mapValues(AnySendable.init) })
    }

    static func string(_ raw: [String: Any], _ keys: [String]) -> String? {
        keys.compactMap { raw[$0] as? String }.first
    }
    static func timestamp(_ value: Any?) -> Date {
        if let number = value as? Double { return Date(timeIntervalSince1970: number / 1000) }
        guard let value = value as? String else { return Date() }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value) ?? Date()
    }
    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\[REDACTED(?:_[A-Z0-9]+)*\\]", with: "••••", options: .regularExpression)
    }
    static func safeWebURL(_ text: String, relativeTo endpoint: String? = nil) -> URL? {
        guard
            let url = URL(
                string: text.trimmingCharacters(in: .whitespacesAndNewlines),
                relativeTo: endpoint.flatMap(URL.init(string:)))?.absoluteURL,
            ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil,
            url.user == nil, url.password == nil
        else { return nil }
        return url
    }
    static func normalizeActions(_ raw: Any?) -> [String: Any]? {
        var actions = raw as? [String: Any] ?? [:]
        let items = raw as? [[String: Any]] ?? actions["elements"] as? [[String: Any]] ?? []
        let elements = items.compactMap { item -> [String: Any]? in
            guard let id = item["id"] as? String, !id.isEmpty,
                let label = string(item, ["label", "text", "title"]), !label.isEmpty
            else { return nil }
            var result = item
            result["label"] = label
            result["type"] =
                ["button", "select", "input"].contains(item["type"] as? String ?? "") ? item["type"] : "button"
            if let value = item["payload"] ?? item["value"] {
                result["value"] = value as? String ?? jsonString(value)
            }
            return result
        }
        guard !elements.isEmpty else { return nil }
        actions["elements"] = elements
        return actions
    }
    private static func normalizeRich(_ raw: Any) -> Any {
        guard var rich = raw as? [String: Any] else { return raw }
        if rich["type"] as? String == "card", rich["markdown"] == nil {
            let fields = (rich["fields"] as? [[String: Any]] ?? []).map {
                "- **\($0["label"] ?? "Field"):** \($0["value"] ?? "")"
            }
            rich["markdown"] = ([rich["title"] as? String, rich["body"] as? String].compactMap { $0 } + fields).joined(
                separator: "\n\n")
        }
        if rich["type"] as? String == "quick_replies", rich["quick_replies"] == nil {
            rich["quick_replies"] = (rich["replies"] as? [Any] ?? []).enumerated().compactMap {
                index, value -> [String: Any]? in
                if let label = value as? String { return ["id": label, "label": label] }
                guard var reply = value as? [String: Any], reply["label"] is String else { return nil }
                if reply["id"] == nil { reply["id"] = "reply-\(index)" }
                return reply
            }
        }
        return rich
    }
    static func jsonString(_ raw: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .fragmentsAllowed])
        else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
