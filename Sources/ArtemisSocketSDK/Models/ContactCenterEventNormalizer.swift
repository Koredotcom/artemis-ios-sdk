import Foundation

enum ContactCenterEventNormalizer {
    static func normalize(_ message: TransportServerMessage) -> ContactCenterEvent? {
        switch message.type {
        case "session_start":
            return capabilities(message.raw)
        case "contact_center.sbc_details_response":
            return .sbcDetails(
                requestId: string(message.raw, "requestId"),
                ready: message.raw["ready"] as? Bool == true,
                details: sbcDetails(message.raw["responseData"] as? [String: Any]))
        case "contact_center.call_agent_webrtc":
            let payload = message.raw["call"] as? [String: Any] ?? message.raw
            return call(payload).map(ContactCenterEvent.incomingCall)
        case "call_agent_webrtc":
            return call(message.raw).map(ContactCenterEvent.incomingCall)
        case "contact_center.terminate_agent_webrtc", "terminate_agent_webrtc":
            return .callTerminated(
                callId: callId(message.raw), reason: string(message.raw, "reason") ?? "terminated")
        case "agent_media":
            guard let event = message.raw["event"] as? [String: Any] else { return nil }
            return mediaEvent(event)
        case "agent_transfer_event":
            guard
                let event = message.raw["event"] as? [String: Any],
                event["type"] as? String == "agent:media",
                let data = event["data"] as? [String: Any]
            else { return nil }
            return mediaEvent(data)
        default:
            return nil
        }
    }

    private static func capabilities(_ raw: [String: Any]) -> ContactCenterEvent? {
        guard
            let all = raw["capabilities"] as? [String: Any],
            let values = all["contactCenter"] as? [String: Any]
        else { return nil }
        return .capabilities(
            ContactCenterSessionCapabilities(
                enabled: values["enabled"] as? Bool == true,
                sbcDetails: values["sbcDetails"] as? Bool == true,
                agentWebrtc: values["agentWebrtc"] as? Bool == true,
                agentVideo: values["agentVideo"] as? Bool == true,
                disabledReason: string(values, "disabledReason")))
    }

    private static func mediaEvent(_ event: [String: Any]) -> ContactCenterEvent? {
        let providerType = string(event, "providerEventType")
        let action = string(event, "action")
        let mediaKind = string(event, "mediaKind")
        guard mediaKind != "screen_share", mediaKind != "cobrowse",
            providerType?.hasPrefix("webrtc_screenshare") != true,
            providerType?.contains("cobrowse") != true
        else { return nil }

        if providerType == "call_agent_webrtc", action == "invite" {
            return call(event).map(ContactCenterEvent.incomingCall)
        }
        if providerType == "call_agent_webrtc_accepted" || action == "accepted" {
            guard
                let call = call(event),
                let endpoint = endpoint(event["endpoint"] as? [String: Any]),
                let customer = customer(event["customer"] as? [String: Any])
            else { return nil }
            return .endpointReleased(callId: call.callId, endpoint: endpoint, customer: customer)
        }
        if [
            "call_agent_webrtc_terminated", "call_agent_webrtc_rejected", "call_agent_webrtc_failed",
        ].contains(providerType ?? "") || ["terminated", "cancelled", "failed"].contains(action ?? "") {
            return .callTerminated(
                callId: callId(event), reason: string(event, "reason") ?? action ?? providerType)
        }
        return nil
    }

    private static func call(_ source: [String: Any]) -> ContactCenterCall? {
        guard let id = callId(source) else { return nil }
        let agent = source["agent"] as? [String: Any]
        let video = source["videoCall"] as? Bool == true || source["callType"] as? String == "video"
        return ContactCenterCall(
            callId: id,
            conversationId: string(source, "conversationId"),
            providerConversationId: string(source, "providerConversationId"),
            mediaSessionId: string(source, "mediaSessionId"),
            callType: video ? .video : .audio,
            displayName: string(source, "displayName") ?? string(source, "agentName")
                ?? string(source, "agentDisplayName") ?? string(agent ?? [:], "firstName"))
    }

    private static func callId(_ source: [String: Any]) -> String? {
        string(source, "callId") ?? string(source, "mediaSessionId")
            ?? string(source, "callSid") ?? string(source, "conversationId")
    }

    private static func endpoint(_ source: [String: Any]?) -> ContactCenterCallEndpoint? {
        guard let source else { return nil }
        let result = ContactCenterCallEndpoint(
            sipURI: string(source, "sipURI") ?? string(source, "sipUri"),
            sipUser: string(source, "sipUser"),
            sipPassword: string(source, "sipPassword"),
            addresses: strings(source["addresses"]),
            domain: string(source, "domain"),
            iceServers: iceServers(source["iceServers"]))
        return result.sipURI != nil || result.sipUser != nil || result.sipPassword != nil
            || !result.addresses.isEmpty || result.domain != nil ? result : nil
    }

    private static func customer(_ source: [String: Any]?) -> ContactCenterCustomer? {
        guard let source else { return nil }
        let result = ContactCenterCustomer(
            userId: string(source, "userId"), sipUser: string(source, "sipUser"),
            sipPassword: string(source, "sipPassword"), sipAuthUser: string(source, "sipAuthUser"),
            displayName: string(source, "displayName"))
        return result.userId != nil || result.sipUser != nil || result.sipPassword != nil ? result : nil
    }

    private static func sbcDetails(_ source: [String: Any]?) -> ContactCenterSbcDetails? {
        guard let source, let domain = string(source, "domain") else { return nil }
        let addresses = strings(source["addresses"])
        guard !addresses.isEmpty else { return nil }
        return ContactCenterSbcDetails(
            addresses: addresses, domain: domain, iceServers: iceServers(source["iceServers"]))
    }

    private static func iceServers(_ value: Any?) -> [ContactCenterIceServer] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            let urls: [String]
            if let url = string(entry, "urls") ?? string(entry, "url") {
                urls = [url]
            } else {
                urls = strings(entry["urls"])
            }
            guard !urls.isEmpty else { return nil }
            return ContactCenterIceServer(
                urls: urls, username: string(entry, "username"), credential: string(entry, "credential"))
        }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [String] ?? []).compactMap { item in
            let trimmed = item.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private static func string(_ source: [String: Any], _ key: String) -> String? {
        guard let value = source[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
