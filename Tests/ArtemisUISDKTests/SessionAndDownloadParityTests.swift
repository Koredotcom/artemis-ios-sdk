import XCTest

@testable import ArtemisSocketSDK
@testable import ArtemisUISDK

final class SessionAndDownloadParityTests: XCTestCase {
    private func session(_ responses: [[String: Any]]) -> URLSession {
        ParityHTTPProtocol.state.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ParityHTTPProtocol.self]
        return URLSession(configuration: configuration)
    }
    private func tokenPayload(
        expires: Int = 3600, branding: Any = true, permissions: [String] = ["chat:write", "attachment:write"]
    ) -> [String: Any] {
        [
            "token": "fixture-token", "expiresIn": expires, "tenantId": "t", "projectId": "p", "channelId": "c",
            "permissions": permissions,
            "showActivityUpdates": false, "widgetConfig": ["theme": ["attachmentButtonEnabled": branding]],
        ]
    }
    @MainActor func testBootstrapProviderOmitsPublicKeyAndClientScope() async throws {
        let http = session([tokenPayload()])
        defer { http.invalidateAndCancel() }
        let config = SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(
                projectId: "p", endpoint: "https://fixture.invalid", bootstrapTokenProvider: { "bootstrap-fixture" }))
        let manager = TokenManager(config: config, urlSession: http)
        _ = try await manager.getToken()
        let request = try XCTUnwrap(ParityHTTPProtocol.state.requests.first)
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Public-Key"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["bootstrapToken"] as? String, "bootstrap-fixture")
        XCTAssertNil(body["channelId"])
        XCTAssertNil(body["userContext"])
    }
    @MainActor func testRefreshCanChangePermissionAndBrandingWithoutChangingIdentity() async throws {
        let http = session([tokenPayload(expires: 1), tokenPayload(branding: false, permissions: ["chat:write"])])
        defer { http.invalidateAndCancel() }
        let manager = TokenManager(
            config: SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(
                    projectId: "p", endpoint: "https://fixture.invalid", apiKey: "public-fixture")), urlSession: http)
        var scopes: [SDKSessionScope] = []
        manager.onScopeChanged = { scopes.append($0) }
        _ = try await manager.getToken()
        _ = try await manager.getToken()
        XCTAssertEqual(scopes.count, 2)
        XCTAssertEqual(scopes[0].widgetConfig?.theme?.attachmentButtonEnabled, true)
        XCTAssertEqual(scopes[1].widgetConfig?.theme?.attachmentButtonEnabled, false)
        XCTAssertFalse(scopes[1].permissions.contains("attachment:write"))
        XCTAssertTrue(ParityHTTPProtocol.state.requests[1].url!.path.hasSuffix("/refresh"))
        XCTAssertEqual(ParityHTTPProtocol.state.requests[1].value(forHTTPHeaderField: "X-SDK-Token"), "fixture-token")
    }
    @MainActor func testRefreshPreservesOmittedBrandingAndHonorsExplicitNull() async throws {
        var omitted = tokenPayload(expires: 1)
        omitted.removeValue(forKey: "widgetConfig")
        var cleared = tokenPayload()
        cleared["widgetConfig"] = NSNull()
        let http = session([tokenPayload(expires: 1), omitted, cleared])
        defer { http.invalidateAndCancel() }
        let manager = TokenManager(
            config: SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(
                    projectId: "p", endpoint: "https://fixture.invalid", apiKey: "public-fixture")), urlSession: http)
        _ = try await manager.getToken()
        _ = try await manager.getToken()
        XCTAssertEqual(manager.getWidgetConfig()?.theme?.attachmentButtonEnabled, true)
        _ = try await manager.getToken()
        XCTAssertNil(manager.getWidgetConfig())
    }
    @MainActor func testScopeMismatchRejectsTokenAndDoesNotPublishChangedScope() async throws {
        var changed = tokenPayload()
        changed["channelId"] = "different"
        let http = session([tokenPayload(expires: 1), changed])
        defer { http.invalidateAndCancel() }
        let manager = TokenManager(
            config: SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(
                    projectId: "p", endpoint: "https://fixture.invalid", apiKey: "public-fixture")), urlSession: http)
        var published = 0
        manager.onScopeChanged = { _ in published += 1 }
        _ = try await manager.getToken()
        do {
            _ = try await manager.getToken()
            XCTFail("Scope drift must fail")
        } catch {}
        XCTAssertEqual(published, 1)
    }
    @MainActor func testExplicitEndRequestsNewSessionOnNextInitialization() async throws {
        let http = session([tokenPayload(), tokenPayload()])
        defer { http.invalidateAndCancel() }
        let manager = TokenManager(
            config: SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(
                    projectId: "p", endpoint: "https://fixture.invalid", apiKey: "public-fixture",
                    sessionMetadata: ["origin": AnySendable("mobile")])), urlSession: http)
        _ = try await manager.getToken()
        manager.requestNewSession()
        _ = try await manager.getToken()
        let requests = ParityHTTPProtocol.state.requests
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(body["sessionIntent"] as? String, "new")
        XCTAssertEqual((body["sessionMetadata"] as? [String: String])?["origin"], "mobile")
        XCTAssertTrue(requests.allSatisfy { $0.url!.path.hasSuffix("/init") })
    }
    func testServerLocalDownloadUsesAuthenticatedDeliveryMintAndResolvesRelativeURL() async throws {
        let http = session([
            ["url": "file:///server/private/report.pdf"],
            ["data": ["download": ["available": true, "url": "/delivery/opaque"]]],
        ])
        defer { http.invalidateAndCancel() }
        let url = try await AttachmentHTTP.resolve(
            endpoint: "https://fixture.invalid", projectId: "p", sessionId: "s", attachmentId: "a",
            token: "fixture-token", urlSession: http)
        XCTAssertEqual(url.absoluteString, "https://fixture.invalid/delivery/opaque")
        let requests = ParityHTTPProtocol.state.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(requests[0].url?.query, "disposition=attachment")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(requests[1].url?.path, "/api/projects/p/sessions/s/attachments/a/delivery-url")
        XCTAssertNil(requests[1].url?.query)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-SDK-Token") == "fixture-token" })
    }
    func testUnsafeDownloadURLsAreRejected() async throws {
        for value in ["javascript:alert(1)", "https://user:password@fixture.invalid/file", "data:text/plain,test"] {
            let http = session([["url": value]])
            defer { http.invalidateAndCancel() }
            do {
                _ = try await AttachmentHTTP.resolve(
                    endpoint: "https://fixture.invalid", projectId: "p", sessionId: "s", attachmentId: "a",
                    token: "fixture-token", urlSession: http)
                XCTFail("Unsafe URL accepted")
            } catch {}
        }
    }
    func testMultipartBoundsActualBytesAndRejectsEmptyFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertThrowsError(
            try AttachmentHTTP.multipartFile(
                source: file, contentType: "text/plain", boundary: "test", maxFileSizeBytes: 3))
        try Data().write(to: file)
        XCTAssertThrowsError(
            try AttachmentHTTP.multipartFile(source: file, contentType: "text/plain", boundary: "test"))
    }
    func testYAMLParsesAndroidParityFlagsAndKeepsLegacyDefaults() throws {
        let config = try ArtemisSocketSDK.SDKConfigurationLoader.load(
            yaml: """
                artemis_sdk:
                  connection:
                    project_id: p
                    endpoint: https://fixture.invalid
                    api_key: fixture
                    deployment_slug: mobile
                    user_context:
                      user_id: customer
                  features:
                    enable_attachments: true
                    enable_contact_center: true
                    enable_history: false
                  websocket:
                    reconnection:
                      unlimited_transient_retries: true
                  session:
                    idle_disconnect_timeout_ms: 2000
                    end_session_on_close: true
                  attachments:
                    max_file_size_bytes: 100
                    allowed_mime_types: [text/plain]
                """)
        XCTAssertEqual(config.channel?.deploymentSlug, "mobile")
        XCTAssertEqual(config.userContext?.userId, "customer")
        XCTAssertTrue(config.features.enableAttachments)
        XCTAssertTrue(config.features.enableContactCenter)
        XCTAssertFalse(config.features.enableHistory)
        XCTAssertTrue(config.websocket.reconnection.unlimitedTransientRetries)
        XCTAssertEqual(config.session.idleDisconnectTimeoutMs, 2000)
        XCTAssertTrue(config.session.endSessionOnClose)
        XCTAssertEqual(config.attachments.maxFileSizeBytes, 100)
    }
    func testUserContextRejectsNestedValuesAndOversizedPrimitiveArrays() throws {
        func config(_ attributes: [String: AnySendable]) -> SDKConfiguration {
            SDKConfiguration(
                environment: "dev",
                connection: ConnectionConfig(projectId: "p", endpoint: "https://fixture.invalid", apiKey: "fixture"),
                userContext: UserContextConfig(userId: "customer", customAttributes: attributes))
        }
        XCTAssertNoThrow(
            try ArtemisSocketSDK.SDKConfigurationLoader.validate(
                config(["tags": AnySendable(["one", "two"]), "active": AnySendable(true)])))
        XCTAssertThrowsError(
            try ArtemisSocketSDK.SDKConfigurationLoader.validate(config(["nested": AnySendable(["secret": "value"])])))
        XCTAssertThrowsError(
            try ArtemisSocketSDK.SDKConfigurationLoader.validate(
                config(["tags": AnySendable(Array(repeating: "value", count: 17))])))
    }

    func testBrandingAcceptsOnlyExplicitBooleanOrTrueString() {
        for value: Any in [true, " true ", "TRUE"] {
            XCTAssertTrue(
                WidgetConfig(raw: ["theme": ["attachmentButtonEnabled": value]]).theme!.attachmentButtonEnabled)
        }
        for value: Any in [false, "false", "yes", 7, NSNumber(value: 1), NSNull()] {
            XCTAssertFalse(
                WidgetConfig(raw: ["theme": ["attachmentButtonEnabled": value]]).theme!.attachmentButtonEnabled)
        }
        XCTAssertFalse(WidgetConfig(raw: ["theme": [:]]).theme!.attachmentButtonEnabled)
    }
}

private final class ParityHTTPState: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [[String: Any]] = []
    private var captured: [URLRequest] = []
    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }
    func reset(_ payloads: [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        self.payloads = payloads
        captured = []
    }
    func next(_ request: URLRequest) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        var capturedRequest = request
        if capturedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            capturedRequest.httpBody = data
        }
        captured.append(capturedRequest)
        guard !payloads.isEmpty else { throw URLError(.resourceUnavailable) }
        return try JSONSerialization.data(withJSONObject: payloads.removeFirst())
    }
}
private final class ParityHTTPProtocol: URLProtocol {
    static let state = ParityHTTPState()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data = try Self.state.next(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
