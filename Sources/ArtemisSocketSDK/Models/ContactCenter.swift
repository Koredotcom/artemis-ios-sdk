import Foundation

public enum ContactCenterCallType: String, Sendable, Equatable {
    case audio
    case video
}

public struct ContactCenterIceServer: Sendable, Equatable {
    public let urls: [String]
    public let username: String?
    public let credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct ContactCenterSbcDetails: Sendable, Equatable {
    public let addresses: [String]
    public let domain: String
    public let iceServers: [ContactCenterIceServer]

    public init(addresses: [String], domain: String, iceServers: [ContactCenterIceServer] = []) {
        self.addresses = addresses
        self.domain = domain
        self.iceServers = iceServers
    }
}

public struct ContactCenterCall: Identifiable, Sendable, Equatable {
    public let callId: String
    public let conversationId: String?
    public let providerConversationId: String?
    public let mediaSessionId: String
    public let callType: ContactCenterCallType
    public let displayName: String?

    public var id: String { callId }

    public init(
        callId: String, conversationId: String? = nil, providerConversationId: String? = nil,
        mediaSessionId: String? = nil, callType: ContactCenterCallType = .audio,
        displayName: String? = nil
    ) {
        self.callId = callId
        self.conversationId = conversationId
        self.providerConversationId = providerConversationId
        self.mediaSessionId = mediaSessionId ?? callId
        self.callType = callType
        self.displayName = displayName
    }
}

/// Temporary SIP details released by Runtime after the customer accepts a call.
/// Treat these values as credentials and keep them only for the active call.
public struct ContactCenterCallEndpoint: Sendable, Equatable {
    public let sipURI: String?
    public let sipUser: String?
    public let sipPassword: String?
    public let addresses: [String]
    public let domain: String?
    public let iceServers: [ContactCenterIceServer]

    public init(
        sipURI: String? = nil, sipUser: String? = nil, sipPassword: String? = nil,
        addresses: [String] = [], domain: String? = nil,
        iceServers: [ContactCenterIceServer] = []
    ) {
        self.sipURI = sipURI
        self.sipUser = sipUser
        self.sipPassword = sipPassword
        self.addresses = addresses
        self.domain = domain
        self.iceServers = iceServers
    }
}

public struct ContactCenterCustomer: Sendable, Equatable {
    public let userId: String?
    public let sipUser: String?
    public let sipPassword: String?
    public let sipAuthUser: String?
    public let displayName: String?

    public init(
        userId: String? = nil, sipUser: String? = nil, sipPassword: String? = nil,
        sipAuthUser: String? = nil, displayName: String? = nil
    ) {
        self.userId = userId
        self.sipUser = sipUser
        self.sipPassword = sipPassword
        self.sipAuthUser = sipAuthUser
        self.displayName = displayName
    }
}

public struct ContactCenterSessionCapabilities: Sendable, Equatable {
    public let enabled: Bool
    public let sbcDetails: Bool
    public let agentWebrtc: Bool
    public let agentVideo: Bool
    public let disabledReason: String?

    public init(
        enabled: Bool, sbcDetails: Bool = false, agentWebrtc: Bool = false,
        agentVideo: Bool = false, disabledReason: String? = nil
    ) {
        self.enabled = enabled
        self.sbcDetails = sbcDetails
        self.agentWebrtc = agentWebrtc
        self.agentVideo = agentVideo
        self.disabledReason = disabledReason
    }
}

public enum ContactCenterCallDecision: String, Sendable {
    case accepted
    case rejected
    case terminated
}

public enum ContactCenterEvent: Sendable {
    case capabilities(ContactCenterSessionCapabilities)
    case sbcDetails(requestId: String?, ready: Bool, details: ContactCenterSbcDetails?)
    case incomingCall(ContactCenterCall)
    case endpointReleased(callId: String, endpoint: ContactCenterCallEndpoint, customer: ContactCenterCustomer)
    case callTerminated(callId: String?, reason: String?)
}
