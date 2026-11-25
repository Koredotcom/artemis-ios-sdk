import Foundation
import os
import ArtemisUISDK

/// Mints a fresh hosted bootstrap token for each SDK init attempt.
///
/// This sample calls the customer-session endpoint directly to demonstrate the flow. A production
/// app should keep its channel secret on its own backend and have this provider call that backend.
final class CustomerSessionBootstrapProvider: @unchecked Sendable {
    enum ProviderError: LocalizedError {
        case invalidEndpoint
        case missingChannelSecret
        case missingTenantID
        case missingProjectID
        case missingChannel
        case missingVerifiedUserID
        case invalidCustomAttributes
        case requestEncodingFailed
        case networkFailure
        case invalidHTTPResponse
        case requestFailed(statusCode: Int)
        case invalidJSONResponse
        case missingBootstrapToken

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "The customer-session endpoint must be an absolute HTTP(S) or WS(S) URL."
            case .missingChannelSecret:
                return "ARTEMIS_SAMPLE_CHANNEL_SECRET is required for hosted bootstrap."
            case .missingTenantID:
                return "ARTEMIS_SAMPLE_TENANT_ID is required for hosted bootstrap."
            case .missingProjectID:
                return "ARTEMIS_SAMPLE_PROJECT_ID is required for hosted bootstrap."
            case .missingChannel:
                return "Set ARTEMIS_SAMPLE_CHANNEL_ID or ARTEMIS_SAMPLE_CHANNEL_NAME."
            case .missingVerifiedUserID:
                return "ARTEMIS_SAMPLE_VERIFIED_USER_ID is required for hosted bootstrap."
            case .invalidCustomAttributes:
                return "ARTEMIS_SAMPLE_CUSTOM_ATTRIBUTES_JSON must be a JSON object."
            case .requestEncodingFailed:
                return "The customer-session request could not be encoded."
            case .networkFailure:
                return "The customer-session request could not be completed."
            case .invalidHTTPResponse:
                return "The customer-session endpoint returned an invalid response."
            case .requestFailed(let statusCode):
                return "Customer session request failed (HTTP \(statusCode))."
            case .invalidJSONResponse:
                return "The customer-session response was not valid JSON."
            case .missingBootstrapToken:
                return "The customer-session response did not contain a bootstrap token."
            }
        }
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "ArtemisUIExample",
        category: "CustomerSessionBootstrap"
    )
    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    private let customerSessionsURL: URL
    private let channelSecret: String
    private let tenantID: String
    private let projectID: String
    private let channelID: String?
    private let channelName: String?
    private let verifiedUserID: String
    private let customAttributesData: Data?
    private let session: URLSession
    private let counterLock = NSLock()
    private var requestCount = 0
    private var mintCount = 0

    /// Matches the Android sample's mode selection: a configured channel secret enables hosted bootstrap.
    static func isBootstrapAuthenticationConfigured() -> Bool {
        configuredValue("ARTEMIS_SAMPLE_CHANNEL_SECRET", in: ProcessInfo.processInfo.environment) != nil
    }

    /// Builds the sample's hosted-bootstrap configuration, mints its first token, and adapts the
    /// one-time initial token to the iOS SDK's async token-provider interface.
    static func makeSDKConfigurationFromEnvironment() async throws -> SDKConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let endpoint = configuredValue("ARTEMIS_SAMPLE_ENDPOINT", in: environment)
            ?? "https://agents-dev.kore.ai"
        let projectID = configuredValue("ARTEMIS_SAMPLE_PROJECT_ID", in: environment) ?? ""
        let tenantID = configuredValue("ARTEMIS_SAMPLE_TENANT_ID", in: environment) ?? ""
        let channelSecret = configuredValue("ARTEMIS_SAMPLE_CHANNEL_SECRET", in: environment) ?? ""
        let verifiedUserID = configuredValue("ARTEMIS_SAMPLE_VERIFIED_USER_ID", in: environment) ?? ""
        let channelID = environment["ARTEMIS_SAMPLE_CHANNEL_ID"].flatMap(nonEmpty)
        let channelName = configuredValue("ARTEMIS_SAMPLE_CHANNEL_NAME", in: environment) ?? "Support"
        let customAttributes = try parseCustomAttributes(
            environment["ARTEMIS_SAMPLE_CUSTOM_ATTRIBUTES_JSON"]
        )

        let provider = try CustomerSessionBootstrapProvider(
            endpoint: endpoint,
            channelSecret: channelSecret,
            tenantID: tenantID,
            projectID: projectID,
            channelID: channelID,
            channelName: channelName,
            verifiedUserID: verifiedUserID,
            customAttributes: customAttributes
        )
        let sdkEndpoint = try httpEndpoint(from: endpoint)
        let initialToken = try await provider.getToken()

        return SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(
                projectId: projectID,
                endpoint: sdkEndpoint,
                bootstrapTokenProvider: provider.sdkTokenProvider(initialToken: initialToken)
            )
        )
    }

    init(
        endpoint: String,
        channelSecret: String,
        tenantID: String,
        projectID: String,
        channelID: String?,
        channelName: String?,
        verifiedUserID: String,
        customAttributes: [String: Any]?,
        session: URLSession? = nil
    ) throws {
        self.customerSessionsURL = try Self.customerSessionsURL(from: endpoint)
        self.channelSecret = channelSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tenantID = tenantID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectID = projectID.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannelID = channelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedChannelName = channelName?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.channelID = resolvedChannelID?.isEmpty == false ? resolvedChannelID : nil
        self.channelName = resolvedChannelName?.isEmpty == false ? resolvedChannelName : nil
        self.verifiedUserID = verifiedUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session ?? Self.defaultSession

        guard !self.channelSecret.isEmpty else { throw ProviderError.missingChannelSecret }
        guard !self.tenantID.isEmpty else { throw ProviderError.missingTenantID }
        guard !self.projectID.isEmpty else { throw ProviderError.missingProjectID }
        guard self.channelID != nil || self.channelName != nil else { throw ProviderError.missingChannel }
        guard !self.verifiedUserID.isEmpty else { throw ProviderError.missingVerifiedUserID }

        if let customAttributes {
            guard JSONSerialization.isValidJSONObject(customAttributes),
                let data = try? JSONSerialization.data(withJSONObject: customAttributes)
            else {
                throw ProviderError.invalidCustomAttributes
            }
            self.customAttributesData = data
        } else {
            self.customAttributesData = nil
        }
    }

    /// Always performs a new request. Customer bootstrap tokens are single-use and are never cached.
    func getToken() async throws -> String {
        #if DEBUG
            let call = nextRequestCount()
        #endif
        let startedAt = ProcessInfo.processInfo.systemUptime
        var request = URLRequest(url: customerSessionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(channelSecret, forHTTPHeaderField: "X-SDK-Channel-Secret")

        do {
            request.httpBody = try requestBody()
        } catch {
            throw ProviderError.requestEncodingFailed
        }

        #if DEBUG
            Self.logger.info("[\(call, privacy: .public)] --> POST /api/v1/sdk/customer-sessions")
        #endif

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            #if DEBUG
                Self.logger.error("[\(call, privacy: .public)] <-- customer-session request failed")
            #endif
            throw ProviderError.networkFailure
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidHTTPResponse
        }
        #if DEBUG
            let elapsedMs = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
            Self.logger.info(
                "[\(call, privacy: .public)] <-- HTTP \(httpResponse.statusCode, privacy: .public) in \(elapsedMs, privacy: .public)ms"
            )
        #endif
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProviderError.requestFailed(statusCode: httpResponse.statusCode)
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.invalidJSONResponse
        }
        guard let token = Self.extractToken(from: payload) else {
            throw ProviderError.missingBootstrapToken
        }
        #if DEBUG
            let minted = nextMintCount()
            Self.logger.info("Minted customer bootstrap token #\(minted, privacy: .public)")
        #endif
        return token
    }

    /// Adapts Android's initial-token-plus-provider flow to the iOS SDK's async provider API.
    /// The SDK consumes the already-minted token once; every later init call mints a new token.
    func sdkTokenProvider(initialToken: String) -> @Sendable () async throws -> String {
        let pendingInitialToken = OneShotBootstrapToken(initialToken)
        return { [self, pendingInitialToken] in
            if let initialToken = pendingInitialToken.take() {
                return initialToken
            }
            return try await getToken()
        }
    }

    private func requestBody() throws -> Data {
        var body: [String: Any] = [
            "tenantId": tenantID,
            "projectId": projectID,
            "verifiedUserId": verifiedUserID,
        ]
        if let channelID {
            body["channelId"] = channelID
        } else if let channelName {
            body["channelName"] = channelName
        }
        if let customAttributesData {
            guard let attributes = try? JSONSerialization.jsonObject(with: customAttributesData) else {
                throw ProviderError.invalidCustomAttributes
            }
            body["customAttributes"] = attributes
        }
        guard JSONSerialization.isValidJSONObject(body),
            let data = try? JSONSerialization.data(withJSONObject: body)
        else {
            throw ProviderError.requestEncodingFailed
        }
        return data
    }

    private func nextRequestCount() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        requestCount += 1
        return requestCount
    }

    private func nextMintCount() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        mintCount += 1
        return mintCount
    }

    private static func configuredValue(_ key: String, in environment: [String: String]) -> String? {
        environment[key].flatMap(nonEmpty)
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseCustomAttributes(_ json: String?) throws -> [String: Any]? {
        guard let json = json.flatMap(nonEmpty) else { return nil }
        guard let data = json.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let attributes = object as? [String: Any]
        else {
            throw ProviderError.invalidCustomAttributes
        }
        return attributes
    }

    static func httpEndpoint(from endpoint: String) throws -> String {
        var value = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        if value.lowercased().hasPrefix("wss://") {
            value = "https://" + String(value.dropFirst("wss://".count))
        } else if value.lowercased().hasPrefix("ws://") {
            value = "http://" + String(value.dropFirst("ws://".count))
        }

        guard var components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            components.host != nil, components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else {
            throw ProviderError.invalidEndpoint
        }
        components.scheme = scheme
        guard let url = components.url else { throw ProviderError.invalidEndpoint }
        return url.absoluteString
    }

    private static func customerSessionsURL(from endpoint: String) throws -> URL {
        guard var components = URLComponents(string: try httpEndpoint(from: endpoint)) else {
            throw ProviderError.invalidEndpoint
        }
        let basePath = components.path.split(separator: "/").map(String.init)
        components.path = "/" + (basePath + ["api", "v1", "sdk", "customer-sessions"]).joined(separator: "/")
        guard let url = components.url else { throw ProviderError.invalidEndpoint }
        return url
    }

    private static func extractToken(from payload: Any) -> String? {
        guard let root = payload as? [String: Any] else { return nil }
        var objects = [root]
        if let nested = root["data"] as? [String: Any] { objects.append(nested) }
        for object in objects {
            for key in ["bootstrapToken", "token"] {
                guard let value = object[key] as? String else { continue }
                let token = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }
        }
        return nil
    }
}

private final class OneShotBootstrapToken: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?

    init(_ token: String) { self.token = token }

    func take() -> String? {
        lock.lock()
        defer { lock.unlock() }
        defer { token = nil }
        return token
    }
}
