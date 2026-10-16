// Host apps need the socket module's initializers even with MemberImportVisibility enabled.
// Public aliases alone expose the type names but not their members.
#if canImport(ArtemisSocketSDK)
@_exported import ArtemisSocketSDK
public typealias SDKConfiguration = ArtemisSocketSDK.SDKConfiguration
public typealias ConnectionConfig = ArtemisSocketSDK.ConnectionConfig
public typealias ChannelConfig = ArtemisSocketSDK.ChannelConfig
public typealias Message = ArtemisSocketSDK.Message
#endif
import Combine
import Foundation
import SwiftUI
#if canImport(UIKit)
    import UIKit
#endif

public struct ChatHeaderContext {
    public let title: String
    public let theme: ChatTheme?
    public let onMinimize: () -> Void
    public let onClose: () -> Void
    public let statusText: String
    public let canMinimize: Bool
    public init(
        title: String, theme: ChatTheme?, onMinimize: @escaping () -> Void, onClose: @escaping () -> Void,
        statusText: String = "", canMinimize: Bool = false
    ) {
        self.title = title
        self.theme = theme
        self.onMinimize = onMinimize
        self.onClose = onClose
        self.statusText = statusText
        self.canMinimize = canMinimize
    }
}
public typealias ChatHeaderBuilder = @MainActor (ChatHeaderContext) -> AnyView

public struct ChatFooterContext {
    public let text: Binding<String>
    public let enabled: Bool
    public let placeholder: String
    public let theme: ChatTheme?
    public let onSend: () -> Void
    public let onAttach: (() -> Void)?
    public let canSend: Bool
    public let isUploading: Bool
    public let pendingAttachments: [ChatAttachment]
    public init(
        text: Binding<String>, enabled: Bool, placeholder: String, theme: ChatTheme?, onSend: @escaping () -> Void,
        onAttach: (() -> Void)? = nil, canSend: Bool? = nil, isUploading: Bool = false,
        pendingAttachments: [ChatAttachment] = []
    ) {
        self.text = text
        self.enabled = enabled
        self.placeholder = placeholder
        self.theme = theme
        self.onSend = onSend
        self.onAttach = onAttach
        self.canSend =
            canSend ?? (enabled && !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        self.isUploading = isUploading
        self.pendingAttachments = pendingAttachments
    }
}
public typealias ChatFooterBuilder = @MainActor (ChatFooterContext) -> AnyView

public enum RichTemplateTypes {
    public static let image = "image"
    public static let html = "html"
    public static let video = "video"
    public static let audio = "audio"
    public static let file = "file"
    public static let list = "list"
    public static let kpi = "kpi"
    public static let table = "table"
    public static let chart = "chart"
    public static let form = "form"
    public static let progress = "progress"
    public static let feedback = "feedback"
    public static let actions = "actions"
    public static let quickReplies = "quick_replies"
    public static let channelFallback = "channel_fallback"
}

public struct RichTemplateContext {
    public let message: Message
    public let theme: ChatTheme?
    public let accentColor: Color
    public let submitAction:
        (_ actionId: String, _ value: String?, _ formData: [String: String]?, _ renderId: String?) -> Void
    public let performAction: ((String, String?, [String: String]?, String?, String?) async throws -> Void)?
    public let sendFeedback: ((String, String, Int, String?) async throws -> Void)?
    public let presentation: ChatPresentationState?
    public let submitFeedback:
        (_ messageId: String, _ ratingType: String, _ ratingValue: Int, _ actionRenderId: String?) -> Void
    public init(
        message: Message, theme: ChatTheme?, accentColor: Color,
        submitAction: @escaping (String, String?, [String: String]?, String?) -> Void,
        submitFeedback: @escaping (String, String, Int, String?) -> Void = { _, _, _, _ in },
        performAction: ((String, String?, [String: String]?, String?, String?) async throws -> Void)? = nil,
        sendFeedback: ((String, String, Int, String?) async throws -> Void)? = nil,
        presentation: ChatPresentationState? = nil
    ) {
        self.message = message
        self.theme = theme
        self.accentColor = accentColor
        self.submitAction = submitAction
        self.submitFeedback = submitFeedback
        self.performAction = performAction
        self.sendFeedback = sendFeedback
        self.presentation = presentation
    }
}

public struct RichTemplateRenderer {
    public let type: String
    public let matches: (_ message: Message) -> Bool
    public let build: @MainActor (_ message: Message, _ context: RichTemplateContext) -> AnyView
    public init(
        type: String, matches: @escaping (Message) -> Bool,
        build: @escaping @MainActor (Message, RichTemplateContext) -> AnyView
    ) {
        self.type = type
        self.matches = matches
        self.build = build
    }
}

public struct RichTemplateRegistry {
    private var renderers: [String: RichTemplateRenderer] = [:]
    private var order: [String] = []
    public init() {}
    public mutating func register(_ renderer: RichTemplateRenderer, override: Bool = false) {
        if renderers[renderer.type] != nil && !override { return }
        if renderers[renderer.type] == nil { order.append(renderer.type) }
        renderers[renderer.type] = renderer
    }
    var registeredTypes: Set<String> { Set(order) }
    func renderer(for message: Message) -> RichTemplateRenderer? {
        order.lazy.compactMap { renderers[$0] }.first { $0.matches(message) }
    }
    func renderers(for message: Message) -> [RichTemplateRenderer] {
        order.compactMap { renderers[$0] }.filter { $0.matches(message) }
    }
}

public struct ChatFonts: Sendable {
    public var family: String?
    public var monospaceFamily: String?
    public init(family: String? = nil, monospaceFamily: String? = nil) {
        self.family = family
        self.monospaceFamily = monospaceFamily
    }
}

public struct ChatTheme: Sendable {
    public let primaryColor: String
    public let backgroundColor: String
    public let surfaceColor: String
    public let textColor: String
    public let mutedTextColor: String
    public let headerBackgroundColor: String
    public let headerTextColor: String
    public let userBubbleColor: String
    public let userBubbleTextColor: String
    public let assistantBubbleColor: String
    public let assistantBubbleTextColor: String
    public let composeBarBackgroundColor: String
    public let borderColor: String
    public let borderRadius: Double

    public let darkMode: Bool
    public init(configuration: SDKConfiguration, widgetConfig: WidgetConfig? = nil, systemDarkMode: Bool = false) {
        let base = configuration.theme
        let server = widgetConfig?.theme
        let dark = server?.darkMode ?? (base.darkMode || systemDarkMode)
        darkMode = dark
        func pick(_ serverValue: String?, _ fallback: String) -> String {
            serverValue?.isEmpty == false ? serverValue! : fallback
        }
        func adaptive(_ value: String, lightDefaults: [String], darkValue: String) -> String {
            dark && lightDefaults.contains(value.uppercased()) ? darkValue : value
        }
        primaryColor = pick(server?.primaryColor, base.primaryColor)
        backgroundColor = pick(
            server?.backgroundColor, adaptive(base.backgroundColor, lightDefaults: ["#FFFFFF"], darkValue: "#0F172A"))
        surfaceColor = pick(
            server?.surfaceColor,
            adaptive(base.surfaceColor, lightDefaults: ["#F5F5F5", "#F8FAFC"], darkValue: "#1E293B"))
        textColor = pick(
            server?.textColor, adaptive(base.textColor, lightDefaults: ["#1A1A1A", "#1E293B"], darkValue: "#E2E8F0"))
        mutedTextColor = pick(server?.textMutedColor, dark ? "#94A3B8" : "#64748B")
        headerBackgroundColor = pick(server?.headerBackgroundColor, primaryColor)
        headerTextColor = pick(server?.headerTextColor, "#FFFFFF")
        userBubbleColor = pick(server?.userBubbleColor, primaryColor)
        userBubbleTextColor = pick(server?.userBubbleTextColor, "#FFFFFF")
        assistantBubbleColor = pick(server?.assistantBubbleColor, dark ? surfaceColor : "#F1F5F9")
        assistantBubbleTextColor = pick(server?.assistantBubbleTextColor, textColor)
        composeBarBackgroundColor = pick(server?.composeBarBackgroundColor, dark ? "#1E293B" : "#FFFFFF")
        borderColor = pick(server?.borderColor, dark ? "#334155" : "#E2E8F0")
        borderRadius = Double(server?.borderRadius ?? Int(base.borderRadius))

    }
}

public enum ConnectionStatus: String, Sendable { case notConnected, connecting, connected }
public struct UIConfigurationError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

#if canImport(ArtemisSocketSDK)
public enum SDKConfigurationLoader {
    public static func createDefault(
        projectId: String, endpoint: String, apiKey: String? = nil,
        bootstrapToken: String? = nil, channelId: String? = nil,
        channelName: String? = nil
    ) throws -> SDKConfiguration {
        guard !projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UIConfigurationError("projectId is required")
        }
        guard let url = URL(string: endpoint), ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw UIConfigurationError("endpoint must be an HTTP(S) URL")
        }
        guard (apiKey != nil) != (bootstrapToken != nil) else {
            throw UIConfigurationError("Provide exactly one of apiKey or bootstrapToken")
        }
        return SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(
                projectId: projectId, endpoint: endpoint, apiKey: apiKey, bootstrapToken: bootstrapToken),
            channel: ChannelConfig(channelId: channelId, channelName: channelName))
    }
    @MainActor public static func load(
        fromBundle bundle: Bundle = .main, resourceName: String = "sdk_configurations", environment: String? = nil,
        runtimeUserContext: SDKUserContext? = nil
    ) throws -> SDKConfiguration {
        try AgentSDK.initialize(
            fromBundle: bundle, resourceName: resourceName, environment: environment,
            runtimeUserContext: runtimeUserContext
        ).configuration
    }
}
#endif

public enum AgentChatUI {
    public static func view(
        configuration: SDKConfiguration? = nil, title: String = "Chat", fonts: ChatFonts? = nil,
        environment: String? = nil, configResource: String = "sdk_configurations",
        runtimeUserContext: SDKUserContext? = nil, headerBuilder: ChatHeaderBuilder? = nil,
        footerBuilder: ChatFooterBuilder? = nil, templateRegistry: RichTemplateRegistry? = nil,
        onClose: (() -> Void)? = nil
    ) -> AgentChatView {
        AgentChatView(
            configuration: configuration, title: title, fonts: fonts, environment: environment,
            configResource: configResource, runtimeUserContext: runtimeUserContext, headerBuilder: headerBuilder,
            footerBuilder: footerBuilder, templateRegistry: templateRegistry, onClose: onClose)
    }

    #if canImport(UIKit)
        /// Pushes chat onto an existing navigation stack. Returns false if no stack
        /// is available or chat is already its top screen.
        @MainActor @discardableResult
        public static func show(
            in controller: UIViewController, configuration: SDKConfiguration? = nil,
            title: String = "Chat", fonts: ChatFonts? = nil, environment: String? = nil,
            configResource: String = "sdk_configurations", runtimeUserContext: SDKUserContext? = nil,
            headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
            templateRegistry: RichTemplateRegistry? = nil,
            hidesBottomBarWhenPushed: Bool = true, animated: Bool = true
        ) -> Bool {
            guard let navigationController = (controller as? UINavigationController) ?? controller.navigationController,
                let source = navigationController.topViewController,
                !(source is ChatNavigationHostingController<AgentChatView>)
            else { return false }

            let chat = view(
                configuration: configuration, title: title, fonts: fonts, environment: environment,
                configResource: configResource, runtimeUserContext: runtimeUserContext,
                headerBuilder: headerBuilder, footerBuilder: footerBuilder, templateRegistry: templateRegistry
            ) { [weak navigationController, weak source] in
                guard let navigationController, let source,
                    navigationController.topViewController is ChatNavigationHostingController<AgentChatView>,
                    navigationController.viewControllers.contains(where: { $0 === source })
                else { return }
                navigationController.popToViewController(source, animated: animated)
            }
            let host = ChatNavigationHostingController(rootView: chat)
            host.title = title
            host.hidesBottomBarWhenPushed = hidesBottomBarWhenPushed
            navigationController.pushViewController(host, animated: animated)
            return true
        }

        @MainActor public static func present(
            from controller: UIViewController, configuration: SDKConfiguration? = nil,
            title: String = "Chat", fonts: ChatFonts? = nil, environment: String? = nil,
            configResource: String = "sdk_configurations", runtimeUserContext: SDKUserContext? = nil,
            headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
            templateRegistry: RichTemplateRegistry? = nil
        ) {
            let chat = view(
                configuration: configuration, title: title, fonts: fonts, environment: environment,
                configResource: configResource, runtimeUserContext: runtimeUserContext, headerBuilder: headerBuilder,
                footerBuilder: footerBuilder, templateRegistry: templateRegistry
            ) { [weak controller] in
                controller?.dismiss(animated: true)
            }
            let host = UIHostingController(rootView: chat)
            let navigationController = UINavigationController(rootViewController: host)
            // AgentChatView provides its own header and close action.
            navigationController.setNavigationBarHidden(true, animated: false)
            navigationController.modalPresentationStyle = .fullScreen
            controller.present(navigationController, animated: true)
        }
    #endif
}

@MainActor public final class AgentChatViewModel: ObservableObject {
    @Published public private(set) var messages: [Message] = []
    @Published public private(set) var status: ConnectionStatus = .notConnected
    @Published public private(set) var isTyping = false
    @Published public private(set) var activityText: String?
    @Published public private(set) var transferStatus: AgentTransferStatus = .none
    @Published private(set) var scrollToBottomRequest = 0
    @Published private(set) var forceScrollRequest = 0
    @Published public private(set) var theme: ChatTheme?
    @Published public var errorMessage: String?
    @Published public var composeText = ""
    @Published public internal(set) var pendingAttachments: [ChatAttachment] = []
    @Published public internal(set) var attachmentDrafts: [AttachmentDraft] = []
    @Published public internal(set) var isUploadingAttachment = false
    @Published public internal(set) var uploadingFilename: String?
    @Published public internal(set) var isSending = false
    @Published public internal(set) var attachmentsAllowed = false
    @Published var sentAttachments: [String: [ChatAttachment]] = [:]
    public private(set) var sdk: AgentSDK?
    public let presentation = ChatPresentationState()
    var attachmentSessionId: String?
    var uploadTask: Task<Void, Never>?
    var attachmentsUnavailable = false
    private var connectionTask: Task<Void, Never>?
    private var presenceTask: Task<Void, Never>?
    private var sdkCancellable: AnyCancellable?
    private var chatCancellable: AnyCancellable?
    private let configuration: SDKConfiguration?
    private let environment: String?
    private let configResource: String
    private let runtimeUserContext: SDKUserContext?
    private var surveys: [String: SurveyPresentation] = [:]
    private var systemDarkMode = false
    public func updateAppearance(isDark: Bool) {
        systemDarkMode = isDark
        updatePolicy()
    }
    public var placeholder: String { sdk?.getWidgetConfig()?.placeholderText ?? "Type a message..." }
    public var statusText: String {
        if status == .connecting { return sdk?.getWidgetConfig()?.connectingStatusText ?? "Connecting…" }
        if status != .connected { return "Disconnected" }
        switch transferStatus {
        case .queued: return "Waiting for a human agent…"
        case .connected: return "Connected to a human agent"
        default: return "Connected"
        }
    }
    public var contactCenterEnabled: Bool {
        sdk?.configuration.features.enableContactCenter ?? configuration?.features.enableContactCenter ?? false
    }
    public var citationsEnabled: Bool {
        sdk?.configuration.features.enableCitations ?? configuration?.features.enableCitations ?? true
    }

    public init(
        configuration: SDKConfiguration?, environment: String?, configResource: String,
        runtimeUserContext: SDKUserContext?,
        headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
        templateRegistry: RichTemplateRegistry? = nil
    ) {
        self.configuration = configuration
        self.environment = environment
        self.configResource = configResource
        self.runtimeUserContext = runtimeUserContext
    }
    public func start() {
        if let sdk {
            if !sdk.isConnected(), connectionTask == nil { connect(sdk) }
            return
        }
        do {
            let created: AgentSDK
            if let configuration {
                created = AgentSDK.create(
                    with: runtimeUserContext.map { configuration.copyForUI(context: $0) } ?? configuration)
            } else {
                created = try AgentSDK.initialize(
                    fromBundle: .main, resourceName: configResource, environment: environment,
                    runtimeUserContext: runtimeUserContext)
            }
            sdk = created
            theme = ChatTheme(configuration: created.configuration, widgetConfig: created.getWidgetConfig())
            sdkCancellable = created.sdkEvents.sink { [weak self] event in self?.handle(event) }
            chatCancellable = created.chatEvents.sink { [weak self] event in self?.handle(event) }
            connect(created)
        } catch {
            status = .notConnected
            errorMessage = error.localizedDescription
        }
    }
    private func connect(_ sdk: AgentSDK) {
        status = .connecting
        connectionTask = Task { [weak self, weak sdk] in
            guard let self, let sdk else { return }
            defer { self.connectionTask = nil }
            do {
                _ = try await sdk.connect()
                guard self.sdk === sdk else { return }
                self.messages = sdk.getMessages()
                self.updatePolicy()
            } catch {
                guard self.sdk === sdk else { return }
                self.status = .notConnected
                self.errorMessage = error.localizedDescription
            }
        }
    }
    public func send(_ text: String) {
        composeText = text
        sendComposedText()
    }
    public func sendComposedText() {
        guard canSend, let sdk else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard attachments.isEmpty || attachmentSessionId == sdk.getSessionId() else {
            resetAttachments()
            errorMessage = "The conversation changed. Please attach the files again."
            return
        }
        isSending = true
        scrollToBottomRequest &+= 1
        forceScrollRequest &+= 1
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSending = false }
            do {
                let metadata: [String: Any]? =
                    attachments.isEmpty
                    ? nil
                    : [
                        "attachmentIds": attachments.map(\.id), "attachmentFilenames": attachments.map(\.filename),
                        "attachmentMimeTypes": attachments.map(\.mimeType),
                        "attachmentSizeBytes": attachments.map(\.sizeBytes),
                    ]
                let id = try await sdk.sendMessage(
                    text, metadata: metadata, attachmentIds: attachments.isEmpty ? nil : attachments.map(\.id))
                guard self.sdk === sdk else { return }
                self.sentAttachments[id] = attachments
                self.composeText = ""
                self.resetAttachments()
                self.messages = sdk.getMessages()
                try? sdk.sendUserPresence(isTyping: false)
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    public func composerChanged() {
        sdk?.recordActivity()
        presenceTask?.cancel()
        try? sdk?.sendUserPresence(isTyping: !composeText.isEmpty)
        presenceTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            try? self?.sdk?.sendUserPresence(isTyping: false)
        }
    }
    public func submitAction(
        _ actionId: String, value: String? = nil, formData: [String: String]? = nil, renderId: String? = nil
    ) {
        Task { [weak self] in
            do { try await self?.performAction(actionId, value: value, formData: formData, renderId: renderId) } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }
    public func performAction(
        _ actionId: String, value: String? = nil, formData: [String: String]? = nil, renderId: String? = nil,
        displayText: String? = nil
    ) async throws {
        guard let sdk else { throw AgentSDKError.notConnected }
        try await sdk.performAction(
            actionId, value: value, formData: formData, renderId: renderId, displayText: displayText)
        messages = sdk.getMessages()
        scrollToBottomRequest &+= 1
    }
    public func submitFeedback(_ messageId: String, ratingType: String, ratingValue: Int, actionRenderId: String? = nil)
    {
        Task { [weak self] in
            do {
                try await self?.sendFeedback(
                    messageId, ratingType: ratingType, ratingValue: ratingValue, actionRenderId: actionRenderId)
            } catch { self?.errorMessage = error.localizedDescription }
        }
    }
    public func sendFeedback(_ messageId: String, ratingType: String, ratingValue: Int, actionRenderId: String?)
        async throws
    {
        guard let sdk else { throw AgentSDKError.notConnected }
        _ = try await sdk.submitFeedback(
            messageId: messageId, ratingType: ratingType, ratingValue: ratingValue, actionRenderId: actionRenderId)
    }
    func surveyPresentation(for message: Message) -> SurveyPresentation {
        if let existing = surveys[message.id] { return existing }
        let state = SurveyPresentation()
        surveys[message.id] = state
        if surveys.count > 500, let first = surveys.keys.first { surveys.removeValue(forKey: first) }
        return state
    }
    func submitSurvey(_ survey: AgentTransferSurvey, state: SurveyPresentation) {
        guard let score = state.score, state.status != .pending, state.status != .submitted else { return }
        state.status = .pending
        let session = sdk?.getSessionId()
        Task { [weak self, weak state] in
            guard let self, let state else { return }
            do {
                guard let sdk = self.sdk else { throw AgentSDKError.notConnected }
                _ = try await sdk.submitAgentTransferSurvey(survey, score: score, comments: state.comments)
                guard self.sdk === sdk, sdk.getSessionId() == session else { return }
                state.status = .submitted
            } catch { state.status = .failed }
        }
    }
    public func reconnect() {
        guard connectionTask == nil else { return }
        errorMessage = nil
        if let sdk {
            sdk.disconnect()
            connect(sdk)
        } else {
            start()
        }
    }
    public func stop() { stop(endingSession: false) }
    func stop(endingSession: Bool) {
        connectionTask?.cancel()
        connectionTask = nil
        presenceTask?.cancel()
        presenceTask = nil
        resetAttachments()
        if let sdk, endingSession || sdk.configuration.session.endSessionOnClose {
            sdk.endSession()
            Task {
                try? await Task.sleep(nanoseconds: 5_100_000_000)
                sdk.dispose()
            }
        } else {
            sdk?.dispose()
        }
        sdk = nil
        sdkCancellable = nil
        chatCancellable = nil
        status = .notConnected
        isTyping = false
        surveys.removeAll()
        presentation.clear()
        messages.removeAll()
        sentAttachments.removeAll()
        composeText = ""
    }
    private func updatePolicy() {
        guard let sdk else { return }
        theme = ChatTheme(
            configuration: sdk.configuration, widgetConfig: sdk.getWidgetConfig(), systemDarkMode: systemDarkMode)
        let allowed =
            sdk.configuration.features.enableAttachments && sdk.configuration.chat.enableFileUpload
            && sdk.configuration.features.enableFileUpload
            && sdk.getWidgetConfig()?.theme?.attachmentButtonEnabled == true
            && sdk.getSessionScope()?.permissions.contains("attachment:write") == true && !attachmentsUnavailable
        if attachmentsAllowed && !allowed { cancelAllUploads() }
        attachmentsAllowed = allowed
    }
    private func handle(_ event: SDKEvent) {
        switch event {
        case .connected(let id):
            if let previous = attachmentSessionId, previous != id {
                resetAttachments()
                surveys.removeAll()
                sentAttachments.removeAll()
                presentation.clear()
                attachmentsUnavailable = false
            }
            attachmentSessionId = id
            status = .connected
            errorMessage = nil
            updatePolicy()
        case .sessionScopeChanged: updatePolicy()
        case .reconnecting:
            status = .connecting
            cancelAllUploads()
        case .disconnected:
            status = .notConnected
            isTyping = false
            cancelAllUploads()
        case .error(let error, let code):
            if code != .historyFetch { errorMessage = error.localizedDescription }
            if sdk?.isConnected() != true { status = .notConnected }
        default: break
        }
    }
    private func handle(_ event: ChatEvent) {
        messages = sdk?.getMessages() ?? messages
        switch event {
        case .typingIndicator(let value): isTyping = value
        case .activity(let text): activityText = text
        case .agentTransferChanged(let state): transferStatus = state
        case .messageChunk:
            scrollToBottomRequest &+= 1
            isTyping = false
        case .messageEnd:
            // Final metadata can add a tall form/table after the last text chunk.
            scrollToBottomRequest &+= 1
            isTyping = false
            activityText = nil
        case .responseCancelled:
            isTyping = false
            activityText = nil
        case .error(let error):
            isTyping = false
            errorMessage = error.localizedDescription
        default: break
        }
    }
}

@MainActor public final class ChatPresentationState {
    private var forms: [String: [String: String]] = [:]
    public init() {}
    func values(for id: String) -> [String: String] { forms[id] ?? [:] }
    func save(_ values: [String: String], for id: String) {
        forms[id] = values
        if forms.count > 500, let first = forms.keys.first { forms.removeValue(forKey: first) }
    }
    func clear() { forms.removeAll() }
}

@MainActor final class SurveyPresentation: ObservableObject {
    enum Status { case ready, pending, submitted, failed }
    @Published var score: Int?
    @Published var comments = ""
    @Published var status: Status = .ready
}

extension SDKConfiguration {
    fileprivate func copyForUI(context: SDKUserContext) -> SDKConfiguration {
        SDKConfiguration(
            environment: environment, connection: connection, channel: channel,
            userContext: UserContextConfig(userId: context.userId, customAttributes: context.customAttributes),
            websocket: websocket, voice: voice, chat: chat, storage: storage, performance: performance,
            accessibility: accessibility, theme: theme, debug: debug, features: features, localization: localization,
            security: security, analytics: analytics, session: session, attachments: attachments)
    }
}
