#if os(iOS)
import AVFoundation
import SwiftUI
import WebKit
#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

@MainActor
enum ContactCenterMediaEvent {
    case ready
    case connected
    case terminated(String?)
    case failed(String)
}

enum ContactCenterCallPresentationStatus: Equatable {
    case idle
    case incoming
    case unavailable
    case declining
    case permissionPending
    case connecting
    case inCall
    case error
}

/// Runs the same versioned AudioCodes WebRTC SIP client used by the Web SDK.
/// The bundle is fetched from the configured Runtime host instead of copied
/// into the iOS package.
@MainActor
final class ContactCenterCallMediaController: NSObject, WKScriptMessageHandler, WKUIDelegate {
    private let scriptURL: URL
    private let pageBaseURL: URL
    private var webView: WKWebView?
    private var readinessWaiters: [CheckedContinuation<Void, Error>] = []
    private var readinessTimeout: Task<Void, Never>?
    private var ready = false
    private var failed: String?
    private var mediaCaptureAllowed = false
    private var isStopping = false
    private var stopFinalized = false
    var onEvent: ((ContactCenterMediaEvent) -> Void)?

    init(endpoint: String, scriptURLOverride: String? = nil) throws {
        guard let base = URL(string: endpoint), Self.isSecureMediaURL(base),
            base.user == nil, base.password == nil
        else { throw ContactCenterCallMediaError.invalidRuntimeURL }
        let script: URL
        if let override = scriptURLOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            guard let candidate = URL(string: override), Self.isSecureMediaURL(candidate),
                candidate.user == nil, candidate.password == nil,
                base.scheme?.lowercased() != "https" || candidate.scheme?.lowercased() == "https"
            else { throw ContactCenterCallMediaError.invalidSIPStackURL }
            script = candidate
        } else {
            guard let candidate = URL(
                string: "/api/sdk/assets/contact-center/ac_webrtc-1.19.0.min.js", relativeTo: base)?.absoluteURL
            else { throw ContactCenterCallMediaError.invalidSIPStackURL }
            script = candidate
        }
        pageBaseURL = URL(string: "/", relativeTo: base)?.absoluteURL ?? base
        scriptURL = script
        super.init()
    }

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let content = WKUserContentController()
        content.add(self, name: "contactCenter")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .black
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.uiDelegate = self
        view.loadHTMLString(Self.document(scriptURL: scriptURL), baseURL: pageBaseURL)
        webView = view
        readinessTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            self?.failReadiness(ContactCenterCallMediaError.stackLoadTimedOut.localizedDescription)
        }
        return view
    }

    func waitUntilReady() async throws {
        _ = makeWebView()
        if ready { return }
        if let failed { throw ContactCenterCallMediaError.stackLoadFailed(failed) }
        try await withCheckedThrowingContinuation { continuation in
            readinessWaiters.append(continuation)
        }
    }

    func requestPermissions(for callType: ContactCenterCallType) async throws {
        guard await requestAccess(for: .audio) else { throw ContactCenterCallMediaError.microphonePermissionDenied }
        if callType == .video, !(await requestAccess(for: .video)) {
            throw ContactCenterCallMediaError.cameraPermissionDenied
        }
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(
            .playAndRecord, mode: callType == .video ? .videoChat : .voiceChat,
            options: [.allowBluetooth])
        try audio.setActive(true)
        if callType == .video { try? audio.overrideOutputAudioPort(.speaker) }
        mediaCaptureAllowed = true
    }

    func startCall(
        call: ContactCenterCall, endpoint: ContactCenterCallEndpoint,
        customer: ContactCenterCustomer, sbc: ContactCenterSbcDetails
    ) throws {
        guard ready, let webView else { throw ContactCenterCallMediaError.stackNotReady }
        let endpointUser = endpoint.sipUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = endpointUser?.isEmpty == false ? endpointUser : Self.sipTarget(endpoint.sipURI)
        guard let target, !target.isEmpty else { throw ContactCenterCallMediaError.missingSIPTarget }
        let sipUser = customer.sipUser?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? customer.userId?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sipUser, !sipUser.isEmpty,
            let password = customer.sipPassword, !password.isEmpty
        else { throw ContactCenterCallMediaError.incompleteSIPIdentity }

        let callHeaders: [String]
        if call.callType == .video {
            let conversationId = call.providerConversationId ?? call.conversationId ?? ""
            callHeaders = ["X-cId:\(conversationId)", "X-isVideoCall:true"]
        } else {
            callHeaders = []
        }
        let mediaSbc = Self.contactCenterSbc(endpoint: endpoint, fallback: sbc)
        let payload: [String: Any] = [
            "callId": call.callId,
            "addresses": mediaSbc.addresses,
            "domain": mediaSbc.domain,
            "iceServers": Self.iceServerJSON(mediaSbc.iceServers),
            "customer": [
                "sipUser": sipUser,
                "sipPassword": password,
                "sipAuthUser": customer.sipAuthUser ?? sipUser,
                "displayName": customer.displayName ?? sipUser,
            ],
            "target": target,
            "callType": call.callType.rawValue,
            "headers": callHeaders,
        ]
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else { throw ContactCenterCallMediaError.invalidCallConfiguration }
        // The JavaScript function is async and returns a Promise. WebKit's
        // evaluateJavaScript bridge cannot convert Promise values to Swift, so
        // explicitly discard the return value; call outcomes arrive by message.
        webView.evaluateJavaScript("void window.startContactCenterCall(\(json));") { [weak self] _, error in
            if let error { self?.emit(.failed(error.localizedDescription)) }
        }
    }

    func setMuted(_ muted: Bool) {
        webView?.evaluateJavaScript("window.setContactCenterMuted(\(muted));")
    }

    func setCameraEnabled(_ enabled: Bool) {
        webView?.evaluateJavaScript("window.setContactCenterCameraEnabled(\(enabled));")
    }

    func setSpeakerEnabled(_ enabled: Bool) {
        try? AVAudioSession.sharedInstance().overrideOutputAudioPort(enabled ? .speaker : .none)
    }

    func stopCall() {
        guard !isStopping else { return }
        isStopping = true
        readinessTimeout?.cancel()
        readinessTimeout = nil
        resumeReadiness(with: ContactCenterCallMediaError.stackLoadFailed("The call ended"))
        guard let webView else {
            finalizeStop()
            return
        }
        webView.evaluateJavaScript("window.stopContactCenterCall && window.stopContactCenterCall();") {
            [weak self] _, _ in
            Task { @MainActor in self?.finalizeStop() }
        }
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.finalizeStop()
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            readinessTimeout?.cancel()
            readinessTimeout = nil
            resumeReadiness()
            emit(.ready)
        case "connected": emit(.connected)
        case "terminated": emit(.terminated(body["reason"] as? String))
        case "error": emit(.failed(body["message"] as? String ?? "The call could not connect"))
        default: break
        }
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(mediaCaptureAllowed ? .grant : .deny)
    }

    private func requestAccess(for media: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: media) {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: media) { continuation.resume(returning: $0) }
            }
        default: return false
        }
    }

    private func failReadiness(_ message: String) {
        guard !ready, failed == nil else { return }
        failed = message
        resumeReadiness(with: ContactCenterCallMediaError.stackLoadFailed(message))
        emit(.failed(message))
    }

    private func finalizeStop() {
        guard !stopFinalized else { return }
        stopFinalized = true
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "contactCenter")
        webView?.uiDelegate = nil
        webView = nil
        mediaCaptureAllowed = false
        onEvent = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func resumeReadiness(with error: Error? = nil) {
        let waiters = readinessWaiters
        readinessWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func emit(_ event: ContactCenterMediaEvent) {
        guard !isStopping else { return }
        onEvent?(event)
    }

    private static func sipTarget(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.hasPrefix("sip:") { return String(value.dropFirst(4)).split(separator: "@", maxSplits: 1).first.map(String.init) ?? value }
        return value
    }

    private static func isSecureMediaURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)
    }

    private static func contactCenterSbc(
        endpoint: ContactCenterCallEndpoint, fallback: ContactCenterSbcDetails
    ) -> ContactCenterSbcDetails {
        let sipURIHost = endpoint.sipURI?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^sips?:", with: "", options: .regularExpression)
            .split(separator: "@", maxSplits: 1).dropFirst().first
            .map { String($0).split(whereSeparator: { ";:>".contains($0) }).first.map(String.init) ?? String($0) }
        let domain = endpoint.domain?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.addresses.isEmpty, let domain = (domain?.isEmpty == false ? domain : sipURIHost),
            !domain.isEmpty
        else { return fallback }
        return ContactCenterSbcDetails(
            addresses: endpoint.addresses, domain: domain, iceServers: endpoint.iceServers)
    }

    private static func iceServerJSON(_ servers: [ContactCenterIceServer]) -> [[String: Any]] {
        servers.map { server in
            var value: [String: Any] = ["urls": server.urls]
            value["username"] = server.username
            value["credential"] = server.credential
            return value
        }
    }

    private static func document(scriptURL: URL) -> String {
        let scriptLiteral = (try? JSONSerialization.data(withJSONObject: [scriptURL.absoluteString]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let literal = String(scriptLiteral.dropFirst().dropLast())
        return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
            <style>html,body{margin:0;width:100%;height:100%;background:#090d12;overflow:hidden}#stage{position:relative;width:100%;height:100%;min-height:150px;background:#090d12}video{background:#090d12}#remote{width:100%;height:100%;object-fit:contain}#local{position:absolute;right:16px;bottom:160px;width:27%;max-width:120px;max-height:35%;object-fit:cover;border:1px solid #ffffff66;border-radius:10px}#local[hidden]{display:none}</style>
            </head><body><div id="stage"><video id="remote" autoplay playsinline></video><video id="local" autoplay muted playsinline hidden></video></div>
            <script>
            (() => {
              const post = (type, value = {}) => { try { window.webkit.messageHandlers.contactCenter.postMessage({type, ...value}); } catch (_) {} };
              let phone = null, activeCall = null, loginPromise = null, loginResolve = null, loginReject = null, stopping = false;
              const remote = document.getElementById('remote'), local = document.getElementById('local');
              const script = document.createElement('script');
              script.src = \(literal);
              script.onload = () => {
                if (typeof AudioCodesUA === 'function' && typeof JsSIP !== 'undefined') post('ready');
                else post('error', {message:'AudioCodes WebRTC SDK is unavailable'});
              };
              script.onerror = () => post('error', {message:'Unable to load the AudioCodes WebRTC SDK'});
              document.head.appendChild(script);
              window.startContactCenterCall = async (input) => {
                try {
                  if (phone) window.stopContactCenterCall();
                  stopping = false;
                  phone = new AudioCodesUA();
                  loginPromise = new Promise((resolve, reject) => { loginResolve = resolve; loginReject = reject; });
                  phone.setAcLogger?.(() => {}); phone.setJsSipLogger?.(() => {});
                  phone.setServerConfig(input.addresses, input.domain, input.iceServers);
                  phone.setAccount(input.customer.sipUser, input.customer.displayName, input.customer.sipPassword, input.customer.sipAuthUser);
                  phone.setUserAgent?.('AudioCodes-WebRTC');
                  phone.setRegisterExtraHeaders?.(['X-SBC: AudioCodes Mediant']);
                  phone.setWebSocketKeepAlive?.(10, true, true, 0, false);
                  phone.setReconnectIntervals?.(2, 30); phone.setRegisterExpires?.(600); phone.setDtmfOptions?.(true, null, null);
                  phone.setEnableAddVideo?.(true);
                  phone.setListeners({
                    loginStateChanged: (_loggedIn, cause) => { if (cause === 'login' || cause === 'connected') loginResolve(); if (cause === 'login failed') loginReject(new Error('AudioCodes login failed')); },
                    callConfirmed: () => post('connected'),
                    callTerminated: (_call, _message, cause) => { activeCall = null; if (!stopping) post('terminated', {reason: typeof cause === 'string' ? cause : undefined}); },
                    callShowStreams: (_call, localStream, remoteStream) => { if (localStream instanceof MediaStream) { local.srcObject = localStream; local.hidden = input.callType !== 'video'; } if (remoteStream instanceof MediaStream) { remote.srcObject = remoteStream; } },
                    outgoingCallProgress: () => {}, incomingCall: (call) => call && call.reject && call.reject(),
                    callHoldStateChanged: () => {}, callScreenSharingEnded: () => {}
                  });
                  phone.init(true);
                  await Promise.race([loginPromise, new Promise((_resolve, reject) => setTimeout(() => reject(new Error('Timed out connecting to the Contact Center SBC')), 15000))]);
                  const mediaType = input.callType === 'video' ? phone.VIDEO : phone.AUDIO;
                  activeCall = phone.call(mediaType, input.target, input.headers);
                } catch (error) { post('error', {message: error && error.message ? error.message : String(error)}); }
              };
              window.setContactCenterMuted = (muted) => { if (activeCall && activeCall.muteAudio) activeCall.muteAudio(Boolean(muted)); };
              window.setContactCenterCameraEnabled = (enabled) => { if (activeCall && activeCall.muteVideo) activeCall.muteVideo(!enabled); };
              window.stopContactCenterCall = () => {
                stopping = true;
                try { if (activeCall && activeCall.terminate) activeCall.terminate(); } catch (_) {}
                try { if (phone && phone.logout) phone.logout(); } catch (_) {}
                try { if (phone && phone.deinit) phone.deinit(); } catch (_) {}
                activeCall = null; phone = null; loginPromise = null; loginResolve = null; loginReject = null;
                if (remote.srcObject) remote.srcObject.getTracks().forEach(track => track.stop());
                if (local.srcObject) local.srcObject.getTracks().forEach(track => track.stop());
                remote.srcObject = null; local.srcObject = null; local.hidden = true;
              };
            })();
            </script></body></html>
            """
    }
}

private enum ContactCenterCallMediaError: Error, LocalizedError {
    case invalidRuntimeURL
    case invalidSIPStackURL
    case stackLoadTimedOut
    case stackLoadFailed(String)
    case stackNotReady
    case missingSIPTarget
    case incompleteSIPIdentity
    case invalidCallConfiguration
    case microphonePermissionDenied
    case cameraPermissionDenied

    var errorDescription: String? {
        switch self {
        case .invalidRuntimeURL: return "The Contact Center Runtime URL is invalid"
        case .invalidSIPStackURL: return "The AudioCodes WebRTC SDK URL is invalid"
        case .stackLoadTimedOut: return "Timed out loading the AudioCodes WebRTC SDK"
        case .stackLoadFailed(let message): return message
        case .stackNotReady: return "The AudioCodes WebRTC SDK is not ready"
        case .missingSIPTarget: return "The Contact Center call endpoint is missing a SIP target"
        case .incompleteSIPIdentity: return "The Contact Center customer SIP identity is incomplete"
        case .invalidCallConfiguration: return "The Contact Center call configuration is invalid"
        case .microphonePermissionDenied: return "Microphone access is required for agent calls"
        case .cameraPermissionDenied: return "Camera access is required for video calls"
        }
    }
}

struct ContactCenterCallWebView: UIViewRepresentable {
    let controller: ContactCenterCallMediaController

    func makeUIView(context: Context) -> WKWebView { controller.makeWebView() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct ContactCenterCallPanel: View {
    @ObservedObject var model: AgentChatViewModel
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatStrings) private var strings
    @State private var connectedAt: Date?

    private var call: ContactCenterCall? { model.contactCenterCall }
    private var callerName: String? {
        guard let value = call?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }
    private var callerDisplayName: String { callerName ?? strings("Agent") }
    private var callKind: String { call?.callType == .video ? strings("video") : strings("audio") }
    private var callIcon: String { call?.callType == .video ? "video.fill" : "phone.fill" }
    private var accentColor: Color { Color(hexString: theme?.primaryColor ?? "#2563EB") }
    private var stateTitle: String {
        switch model.contactCenterCallStatus {
        case .idle: return ""
        case .incoming: return strings("Incoming call")
        case .unavailable: return strings("Unavailable")
        case .declining: return strings("Declining…")
        case .permissionPending: return strings("Preparing call…")
        case .connecting: return strings("Connecting…")
        case .inCall: return strings("Connected")
        case .error: return strings("Call failed")
        }
    }
    private var participantSubtitle: String {
        switch model.contactCenterCallStatus {
        case .incoming:
            return callerName.map {
                strings.format("{name} is calling you.", ["name": $0])
            } ?? strings("An agent is calling you.")
        case .unavailable:
            return model.contactCenterError ?? strings("Contact Center calling is unavailable for this session.")
        case .declining:
            return strings("Declining call…")
        case .permissionPending:
            return strings.format("Preparing {type} call…", ["type": callKind])
        case .connecting:
            return callerName.map {
                strings.format("Connecting to {name}…", ["name": $0])
            } ?? strings("Connecting to an agent…")
        case .inCall:
            return strings("Connected")
        case .error:
            return model.contactCenterError ?? strings("The call could not be connected.")
        case .idle:
            return ""
        }
    }

    var body: some View {
        if let call {
            ZStack {
                callBackground
                if call.callType == .video,
                    model.contactCenterCallStatus == .inCall,
                    let controller = model.contactCenterMediaController
                {
                    videoStage(controller: controller)
                        .ignoresSafeArea()
                    videoScrim.ignoresSafeArea()
                }
                VStack(spacing: 0) {
                    callTopBar(call)
                    Spacer(minLength: 24)
                    if call.callType == .audio || model.contactCenterCallStatus != .inCall {
                        participantArtwork
                        VStack(spacing: 8) {
                            Text(callerDisplayName)
                                .font(.system(size: 30, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                            Text(participantSubtitle)
                                .font(.system(size: 16))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                        }
                        .padding(.top, 24)
                    }
                    Spacer(minLength: 28)
                    callActions(for: call)
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 18)

                if model.contactCenterMediaController != nil,
                    !(call.callType == .video && model.contactCenterCallStatus == .inCall)
                {
                    hiddenMediaHost
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .onAppear {
                if model.contactCenterCallStatus == .inCall { connectedAt = Date() }
            }
            .onChange(of: model.contactCenterCallStatus) { status in
                connectedAt = status == .inCall ? Date() : nil
            }
            .onChange(of: call.callId) { _ in connectedAt = nil }
            .animation(.easeInOut(duration: 0.24), value: model.contactCenterCallStatus)
        }
    }

    private var callBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.09, blue: 0.16),
                    Color(red: 0.035, green: 0.05, blue: 0.09),
                    Color(red: 0.015, green: 0.025, blue: 0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(accentColor.opacity(0.22))
                .frame(width: 300, height: 300)
                .blur(radius: 82)
                .offset(y: -150)
            Circle()
                .fill(Color.blue.opacity(0.12))
                .frame(width: 250, height: 250)
                .blur(radius: 84)
                .offset(x: 160, y: 240)
        }
        .ignoresSafeArea()
    }

    private var videoScrim: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.66), location: 0),
                .init(color: .black.opacity(0.28), location: 0.24),
                .init(color: .clear, location: 0.48),
                .init(color: .black.opacity(0.28), location: 0.68),
                .init(color: .black.opacity(0.82), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func callTopBar(_ call: ContactCenterCall) -> some View {
        HStack(spacing: 12) {
            Image(systemName: callIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(accentColor.opacity(0.8), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(strings(call.callType == .video ? "Video call" : "Audio call"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .textCase(.uppercase)
                Text(callerDisplayName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.contactCenterCallStatus == .inCall {
                connectedBadge
            } else {
                Text(stateTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(.white.opacity(0.12), in: Capsule())
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var connectedBadge: some View {
        HStack(spacing: 7) {
            Circle().fill(Color.green).frame(width: 8, height: 8)
            if let connectedAt {
                TimelineView(.periodic(from: connectedAt, by: 1)) { timeline in
                    Text(elapsedTime(since: connectedAt, now: timeline.date))
                        .monospacedDigit()
                }
            } else {
                Text("00:00").monospacedDigit()
            }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.12), in: Capsule())
        .accessibilityLabel(strings("Connected"))
    }

    private func elapsedTime(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var participantArtwork: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.08), lineWidth: 1)
                .frame(width: 204, height: 204)
            Circle()
                .fill(accentColor.opacity(0.14))
                .frame(width: 172, height: 172)
            Circle()
                .fill(
                    LinearGradient(
                        colors: [accentColor, accentColor.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 136, height: 136)
                .shadow(color: accentColor.opacity(0.35), radius: 28, y: 10)
            Image(systemName: "person.fill")
                .font(.system(size: 54, weight: .medium))
                .foregroundStyle(.white)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }

    private var hiddenMediaHost: some View {
        Group {
            if let controller = model.contactCenterMediaController {
                ContactCenterCallWebView(controller: controller)
                    .frame(width: 1, height: 1)
                    .clipped()
                    .accessibilityHidden(true)
            }
        }
        .allowsHitTesting(false)
    }

    private func videoStage(controller: ContactCenterCallMediaController) -> some View {
        ContactCenterCallWebView(controller: controller)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .accessibilityLabel(
                strings.format("Video call with {name}", ["name": callerDisplayName]))
    }

    @ViewBuilder
    private func callActions(for call: ContactCenterCall) -> some View {
        switch model.contactCenterCallStatus {
        case .incoming:
            HStack(spacing: 46) {
                incomingAction(
                    strings("Decline"), icon: "phone.down.fill",
                    color: Color(red: 0.88, green: 0.22, blue: 0.25)
                ) {
                    Task { await model.rejectContactCenterCall() }
                }
                incomingAction(
                    strings("Accept"), icon: callIcon,
                    color: Color(red: 0.12, green: 0.72, blue: 0.4)
                ) {
                    Task { await model.acceptContactCenterCall() }
                }
            }
            .frame(maxWidth: .infinity)
        case .unavailable:
            callActionButton(
                strings("Decline"), icon: "phone.down.fill",
                color: Color(red: 0.88, green: 0.22, blue: 0.25)
            ) {
                Task { await model.rejectContactCenterCall() }
            }
        case .declining:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(strings("Declining call…"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }
            .padding(.vertical, 18)
        case .permissionPending, .connecting:
            callActionButton(
                strings("Cancel"), icon: "phone.down.fill",
                color: Color(red: 0.88, green: 0.22, blue: 0.25)
            ) {
                model.endContactCenterCall()
            }
        case .inCall:
            liveCallControls(for: call)
        case .error:
            callActionButton(strings("Dismiss"), icon: "xmark", color: .white.opacity(0.16)) {
                model.dismissContactCenterCall()
            }
        case .idle:
            EmptyView()
        }
    }

    private func incomingAction(
        _ title: String, icon: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(color, in: Circle())
                    .shadow(color: color.opacity(0.28), radius: 16, y: 7)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(width: 104)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func liveCallControls(for call: ContactCenterCall) -> some View {
        HStack(spacing: 4) {
            roundCallControl(
                model.isContactCenterMuted ? "mic.slash.fill" : "mic.fill",
                title: strings(model.isContactCenterMuted ? "Unmute" : "Mute"),
                selected: model.isContactCenterMuted
            ) {
                model.setContactCenterMuted(!model.isContactCenterMuted)
            }
            roundCallControl(
                model.isContactCenterSpeakerEnabled ? "speaker.wave.2.fill" : "speaker.fill",
                title: strings(model.isContactCenterSpeakerEnabled ? "Speaker on" : "Speaker"),
                selected: model.isContactCenterSpeakerEnabled
            ) {
                model.setContactCenterSpeakerEnabled(!model.isContactCenterSpeakerEnabled)
            }
            if call.callType == .video {
                roundCallControl(
                    model.isContactCenterCameraEnabled ? "video.fill" : "video.slash.fill",
                    title: strings(model.isContactCenterCameraEnabled ? "Camera off" : "Camera on"),
                    selected: !model.isContactCenterCameraEnabled
                ) {
                    model.setContactCenterCameraEnabled(!model.isContactCenterCameraEnabled)
                }
            }
            roundCallControl(
                "phone.down.fill", title: strings("End call"),
                danger: true
            ) {
                model.endContactCenterCall()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func callActionButton(
        _ title: String, icon: String, color: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(color, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func roundCallControl(
        _ icon: String, title: String, selected: Bool = false, danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        danger
                            ? Color(red: 0.88, green: 0.22, blue: 0.25)
                            : (selected ? accentColor : Color.white.opacity(0.13)),
                        in: Circle()
                    )
                    .overlay(Circle().stroke(.white.opacity(0.14), lineWidth: 1))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

#endif
