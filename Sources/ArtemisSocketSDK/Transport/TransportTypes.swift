import Foundation

enum TransportClientMessage {
    case raw([String: Any])
    case chatMessage(
        text: String,
        messageId: String?,
        sessionId: String?,
        attachmentIds: [String]?,
        metadata: [String: Any]?,
        customData: [String: Any]?
    )
    case endSession
    case actionSubmit(
        actionId: String,
        value: String?,
        formData: [String: String]?,
        renderId: String?
    )
    case feedbackSubmit(
        messageId: String,
        ratingType: String,
        ratingValue: Int,
        feedbackText: String?,
        actionRenderId: String?,
        followUpRating: Int?,
        followUpText: String?
    )

    func toJSON() throws -> String {
        let dict = toDictionary()
        let data = try JSONSerialization.data(withJSONObject: dict)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "ArtemisSocketSDK", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Failed to encode transport message"
                ])
        }
        return json
    }

    func toDictionary() -> [String: Any] {
        switch self {
        case .raw(let payload): return payload
        case .chatMessage(let text, let messageId, let sessionId, let attachmentIds, let metadata, let customData):
            var dict: [String: Any] = ["type": "chat_message", "text": text]
            if let messageId { dict["messageId"] = messageId }
            if let sessionId { dict["sessionId"] = sessionId }
            if let attachmentIds { dict["attachmentIds"] = attachmentIds }
            if let metadata { dict["metadata"] = metadata }
            if let customData, !customData.isEmpty { dict["customData"] = customData }
            return dict

        case .endSession:
            return ["type": "end_session"]

        case .actionSubmit(let actionId, let value, let formData, let renderId):
            var dict: [String: Any] = ["type": "action_submit", "actionId": actionId]
            if let value { dict["value"] = value }
            if let formData { dict["formData"] = formData }
            if let renderId { dict["renderId"] = renderId }
            return dict

        case .feedbackSubmit(
            let messageId, let ratingType, let ratingValue, let feedbackText, let actionRenderId,
            let followUpRating, let followUpText):
            var dict: [String: Any] = [
                "type": "feedback.submit",
                "messageId": messageId,
                "ratingType": ratingType,
                "ratingValue": ratingValue,
            ]
            if let feedbackText { dict["feedbackText"] = feedbackText }
            if let actionRenderId { dict["actionRenderId"] = actionRenderId }
            if let followUpRating { dict["followUpRating"] = followUpRating }
            if let followUpText { dict["followUpText"] = followUpText }
            return dict
        }
    }
}

struct TransportServerMessage {
    let type: String
    let raw: [String: Any]

    static func fromJSONData(_ data: Data) throws -> TransportServerMessage {
        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "ArtemisSocketSDK", code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Invalid WebSocket message JSON"
                ])
        }
        if let richContentOrder = RichContentKeyOrderScanner.order(in: data, raw: json) {
            json["_sdkRichContentOrder"] = richContentOrder
        }
        return TransportServerMessage(
            type: json["type"] as? String ?? "unknown",
            raw: json
        )
    }
}

/// JSONSerialization gives us unordered dictionaries. Keep the incoming order
/// of richContent component keys so the UI can render components in wire order.
enum RichContentKeyOrderScanner {
    private struct Candidate {
        let path: [String]
        let keys: [String]
        var messageId: String?
    }

    static func order(in data: Data, raw: [String: Any]) -> [String]? {
        let candidates = candidates(in: data)
        let preferredPaths = preferredPaths(in: raw)
        for path in preferredPaths {
            if let candidate = candidates.first(where: { $0.path == path }) {
                return candidate.keys
            }
        }
        let messageId = raw["messageId"] as? String ?? raw["id"] as? String
        if let messageId, let candidate = candidates.first(where: { $0.messageId == messageId }) {
            return candidate.keys
        }
        if candidates.count == 1 { return candidates.first?.keys }
        return nil
    }

    static func orders(in data: Data) -> [String: [String]] {
        candidates(in: data).reduce(into: [:]) { result, candidate in
            if let messageId = candidate.messageId { result[messageId] = candidate.keys }
        }
    }

    private static func candidates(in data: Data) -> [Candidate] {
        var scanner = Scanner(bytes: Array(data))
        return scanner.scan()
    }

    private static func preferredPaths(in raw: [String: Any]) -> [[String]] {
        if raw["richContent"] != nil { return [["richContent"]] }
        if raw["rich_content"] != nil { return [["rich_content"]] }

        let envelope = raw["contentEnvelope"] as? [String: Any]
            ?? raw["content_envelope"] as? [String: Any]
            ?? [:]
        if envelope["richContent"] != nil {
            return [["contentEnvelope", "richContent"], ["content_envelope", "richContent"]]
        }
        if envelope["rich_content"] != nil {
            return [["contentEnvelope", "rich_content"], ["content_envelope", "rich_content"]]
        }

        let metadata = raw["metadata"] as? [String: Any] ?? [:]
        let envelopeMetadata = envelope["metadata"] as? [String: Any] ?? [:]
        if metadata["richContent"] != nil { return [["metadata", "richContent"]] }
        if metadata["rich_content"] != nil { return [["metadata", "rich_content"]] }
        if envelopeMetadata["richContent"] != nil {
            return [["contentEnvelope", "metadata", "richContent"], ["content_envelope", "metadata", "richContent"]]
        }
        if envelopeMetadata["rich_content"] != nil {
            return [["contentEnvelope", "metadata", "rich_content"], ["content_envelope", "metadata", "rich_content"]]
        }
        return []
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0
        var candidates: [Candidate] = []

        mutating func scan() -> [Candidate] {
            do { _ = try scanValue(path: []) } catch { return [] }
            return candidates
        }

        mutating func scanValue(path: [String]) throws -> String? {
            skipWhitespace()
            guard index < bytes.count else { throw ScanError.invalidJSON }
            switch bytes[index] {
            case 0x7B:
                try scanObject(path: path)
                return nil
            case 0x5B:
                try scanArray(path: path)
                return nil
            case 0x22:
                return try readString()
            default:
                skipPrimitive()
                return nil
            }
        }

        mutating func scanObject(path: [String]) throws {
            let firstCandidateIndex = candidates.count
            index += 1 // {
            skipWhitespace()
            var keys: [String] = []
            var messageId: String?
            if consume(0x7D) {
                finishObject(path: path, keys: keys, messageId: messageId, firstCandidateIndex: firstCandidateIndex)
                return
            }
            while index < bytes.count {
                skipWhitespace()
                let key = try readString()
                keys.append(key)
                skipWhitespace()
                guard consume(0x3A) else { throw ScanError.invalidJSON }
                let stringValue = try scanValue(path: path + [key])
                if ["messageId", "id"].contains(key), let stringValue, !stringValue.isEmpty {
                    messageId = stringValue
                }
                skipWhitespace()
                if consume(0x7D) {
                    finishObject(path: path, keys: keys, messageId: messageId, firstCandidateIndex: firstCandidateIndex)
                    return
                }
                guard consume(0x2C) else { throw ScanError.invalidJSON }
            }
            throw ScanError.invalidJSON
        }

        mutating func scanArray(path: [String]) throws {
            index += 1 // [
            skipWhitespace()
            if consume(0x5D) { return }
            while index < bytes.count {
                _ = try scanValue(path: path)
                skipWhitespace()
                if consume(0x5D) { return }
                guard consume(0x2C) else { throw ScanError.invalidJSON }
            }
            throw ScanError.invalidJSON
        }

        mutating func readString() throws -> String {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else { throw ScanError.invalidJSON }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    let token = Data(bytes[start..<index])
                    guard let string = try JSONSerialization.jsonObject(with: token, options: .fragmentsAllowed) as? String
                    else { throw ScanError.invalidJSON }
                    return string
                }
            }
            throw ScanError.invalidJSON
        }

        mutating func skipPrimitive() {
            while index < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
                index += 1
            }
        }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        mutating func finishObject(
            path: [String], keys: [String], messageId: String?, firstCandidateIndex: Int
        ) {
            if let last = path.last, ["richContent", "rich_content"].contains(last) {
                candidates.append(Candidate(path: path, keys: keys, messageId: nil))
            }
            guard let messageId else { return }
            for index in firstCandidateIndex..<candidates.count where candidates[index].messageId == nil {
                candidates[index].messageId = messageId
            }
        }
    }

    private enum ScanError: Error { case invalidJSON }
}
