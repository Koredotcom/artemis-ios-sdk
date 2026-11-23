import SwiftUI
import UniformTypeIdentifiers

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

#if os(iOS)
    import UIKit
    import SafariServices
#endif

public struct AgentChatView: View {
    @StateObject private var model: AgentChatViewModel
    @Environment(\.artemisChatOptions) private var environmentOptions
    @Environment(\.openURL) private var hostOpenURL
    private let providedOptions: ChatUIOptions?
    private var options: ChatUIOptions { providedOptions ?? environmentOptions }
    private var preferredChatColorScheme: ColorScheme? {
        switch options.appearance {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showAttachmentOptions = false
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    @State private var isCloseOrMinimizePopupPresented = false
    #if os(iOS)
        @State private var safariPresentation: ChatSafariPresentation?
    #endif
    private var strings: ChatStrings { options.strings ?? model.strings }
    private var isOfflineConnectionError: Bool {
        guard let message = model.errorMessage?.lowercased() else { return false }
        let describesNetworkFailure = message.contains("internet") || message.contains("network")
        let describesUnavailableConnection =
            message.contains("offline") || message.contains("not connected")
            || message.contains("unavailable") || message.contains("unreachable")
            || message.contains("connection was lost")
        return describesNetworkFailure && describesUnavailableConnection
    }
    private let title: String
    private let fonts: ChatFonts?
    private let headerBuilder: ChatHeaderBuilder?
    private let footerBuilder: ChatFooterBuilder?
    private let templateRegistry: RichTemplateRegistry?
    private let onClose: (() -> Void)?
    private let handle: AgentChatHandle?

    public init(
        configuration: SDKConfiguration? = nil, title: String = "Chat", fonts: ChatFonts? = nil,
        environment: String? = nil, configResource: String = "sdk_configurations",
        runtimeUserContext: SDKUserContext? = nil, headerBuilder: ChatHeaderBuilder? = nil,
        footerBuilder: ChatFooterBuilder? = nil, templateRegistry: RichTemplateRegistry? = nil,
        uiOptions: ChatUIOptions? = nil, onEvent: AgentChatEventHandler? = nil,
        onClose: (() -> Void)? = nil
    ) {
        let model = AgentChatViewModel(
            configuration: configuration, environment: environment, configResource: configResource,
            runtimeUserContext: runtimeUserContext, headerBuilder: headerBuilder,
            footerBuilder: footerBuilder, templateRegistry: templateRegistry,
            appearance: uiOptions?.appearance ?? .light)
        model.eventHandler = onEvent
        _model = StateObject(wrappedValue: model)
        self.title = title
        self.fonts = fonts
        self.headerBuilder = headerBuilder
        self.footerBuilder = footerBuilder
        self.templateRegistry = templateRegistry
        self.providedOptions = uiOptions
        self.onClose = onClose
        self.handle = nil
    }

    @MainActor public init(
        handle: AgentChatHandle, title: String = "Chat", fonts: ChatFonts? = nil,
        headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
        templateRegistry: RichTemplateRegistry? = nil, uiOptions: ChatUIOptions? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _model = StateObject(wrappedValue: handle.model)
        handle.model.configureAppearance(uiOptions?.appearance ?? .light, systemIsDark: false)
        self.handle = handle
        self.title = title
        self.fonts = fonts
        self.headerBuilder = headerBuilder
        self.footerBuilder = footerBuilder
        self.templateRegistry = templateRegistry
        self.providedOptions = uiOptions
        self.onClose = onClose
    }

    public var body: some View {
        chatContent
            .environment(\.openURL, OpenURLAction { url in
                if url.isHTTP {
                    #if os(iOS)
                        safariPresentation = ChatSafariPresentation(url: url)
                        return .handled
                    #else
                        hostOpenURL(url)
                        return .handled
                    #endif
                }

                // Preserve the host app's handling for non-web URLs such as tel: and mailto:.
                hostOpenURL(url)
                return .handled
            })
            .overlay(alignment: .center) { closeOrMinimizePopupOverlay }
            .animation(.easeOut(duration: 0.2), value: isCloseOrMinimizePopupPresented)
            #if os(iOS)
                .sheet(item: $safariPresentation) { presentation in
                    ChatSafariViewController(url: presentation.url)
                }
            #endif
    }

    private var chatContent: some View {
        VStack(spacing: 0) {
            headerView
            if !model.isInternetAvailable {
                HStack(spacing: 8) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 13, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(strings("No internet connection"))
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .accessibilityElement(children: .combine)
            } else if model.status == .notConnected {
                Button(strings("Reconnect"), action: model.reconnect).font(.caption).padding(8)
            }
            ChatHistoryScrollView(
                request: ChatHistoryScrollRequest(
                    messageCount: model.messages.count,
                    isTyping: model.isTyping,
                    revision: model.scrollToBottomRequest,
                    forceScrollRevision: model.forceScrollRequest
                )
            ) { rowWidth in
                if model.messages.isEmpty && !model.isTyping {
                    EmptyState(
                        title: strings("No messages yet"),
                        subtitle: strings("Start a conversation with your AI assistant"),
                        theme: model.theme)
                }
                ForEach(model.messages) { message in
                    if model.contactCenterEnabled, let survey = message.agentTransferSurvey {
                        AgentTransferSurveyView(
                            survey: survey, state: model.surveyPresentation(for: message),
                            enabled: model.status == .connected
                        ) { state in
                            model.submitSurvey(survey, state: state)
                        }.id(message.id)
                    } else if message.role == .thought {
                        if model.thoughtsEnabled {
                            ThoughtSummaryCard(
                                message: message, presentation: model.presentation,
                                showToolNames: model.thoughtToolNamesVisible
                            ).id(message.id)
                        }
                    } else {
                        MessageBubble(
                            message: message, rowWidth: rowWidth, fonts: fonts, theme: model.theme,
                            templateRegistry: templateRegistry, onSubmitAction: model.submitAction,
                            onSubmitFeedback: model.submitFeedback,
                            attachments: model.attachments(for: message),
                            resolveAttachment: model.attachmentDownloadURL,
                            performAction: {
                                try await model.performAction(
                                    $0, value: $1, formData: $2, renderId: $3, displayText: $4)
                            },
                            sendFeedback: {
                                try await model.sendFeedback(
                                    $0, ratingType: $1, ratingValue: $2, actionRenderId: $3)
                            },
                            presentation: model.presentation, showCitations: model.citationsEnabled,
                            showAgentLinks: model.contactCenterEnabled,
                            enableMessageFeedback: options.enableMessageFeedback && model.feedbackEnabled,
                            feedbackState: options.enableMessageFeedback && message.role == .assistant
                                ? model.presentation.feedback(for: message.id) : nil,
                            feedbackEnabled: model.status == .connected,
                            feedbackCommentMaxLength: options.feedbackCommentMaxLength,
                            timestampSettings: options.timestamps,
                            submitMessageFeedback: { rating, comment in
                                try await model.sendMessageFeedback(message.id, rating: rating, comment: comment)
                            }
                        )
                        .id(message.id)
                    }
                }
                if model.isTyping {
                    if let text = model.activityText {
                        Text(text).font(.caption).foregroundStyle(.secondary)
                    } else {
                        TypingBubble(theme: model.theme)
                    }
                }
            }
            .background { ChatTranscriptBackground(theme: model.theme) }
            attachmentTray
            footerView
        }
        .overlay {
            #if os(iOS)
                if model.shouldShowContactCenterCall {
                    ContactCenterCallPanel(model: model)
                        .background { IncomingCallKeyboardDismissal() }
                        .transition(.opacity)
                        .zIndex(1)
                }
            #endif
        }
        .environment(\.chatTheme, model.theme)
        .environment(\.chatStrings, strings)
        .environment(\.locale, Locale(identifier: strings.localeIdentifier))
        .onChange(of: options.strings) { model.configureStrings($0) }
        .navigationTitle("")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            strings("Chat error"),
            isPresented: Binding(
                get: { model.errorMessage != nil && !isOfflineConnectionError },
                set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button(strings("OK")) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("", isPresented: $showAttachmentOptions, titleVisibility: .visible) {
            #if os(iOS)
                Button(strings("Camera")) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCameraPicker = true
                    } else {
                        model.errorMessage = strings("Camera is not available on this device.")
                    }
                }
                Button(strings("Photos and videos")) { showPhotoPicker = true }
            #endif
            Button(strings("Choose files")) { showFilePicker = true }
            Button(strings("Cancel"), role: .cancel) {}
        }
        .fileImporter(
            isPresented: $showFilePicker, allowedContentTypes: model.allowedAttachmentContentTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): model.uploadAttachments(urls)
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        #if os(iOS)
            .sheet(isPresented: $showPhotoPicker) {
                AttachmentPhotoPicker { urls, error in
                    showPhotoPicker = false
                    if let error { model.errorMessage = error }
                    model.uploadAttachments(urls, removeTemporaryFiles: true)
                }
            }
            #if os(iOS)
                .sheet(isPresented: $showCameraPicker) {
                    AttachmentCameraPicker { url, error in
                        showCameraPicker = false
                        if let error {
                            model.errorMessage = error
                        } else if let url {
                            model.uploadAttachments([url], removeTemporaryFiles: true)
                        }
                    }
                }
            #endif
        #endif
        .task {
            handle?.reopen()
            model.configureAppearance(options.appearance, systemIsDark: colorScheme == .dark)
            model.configureStrings(options.strings)
            model.start()
        }
        .onDisappear {
            if handle?.isMinimized != true, !model.presentation.isVideoFullscreenPresented {
                model.stop()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refreshAfterForeground() }
        }
        .onChange(of: colorScheme) { model.updateAppearance(isDark: $0 == .dark) }
        .onChange(of: options.appearance) {
            model.configureAppearance($0, systemIsDark: colorScheme == .dark)
        }
        .background {
            Color(hexString: model.theme?.backgroundColor ?? "#FFFFFF").ignoresSafeArea()
        }
        .preferredColorScheme(preferredChatColorScheme)
        .onChange(of: model.composeText) { _ in model.composerChanged() }
        .font(
            fonts?.family.map { .custom($0, size: model.theme?.baseFontSize ?? 16) }
                ?? model.theme?.font())
    }
    @ViewBuilder private var closeOrMinimizePopupOverlay: some View {
        if isCloseOrMinimizePopupPresented {
            CloseOrMinimizePopup(
                canMinimize: handle != nil,
                localeIdentifier: strings.localeIdentifier,
                fallbackLocaleIdentifier: strings.fallbackLocaleIdentifier,
                onCancel: dismissCloseOrMinimizePopup,
                onClose: confirmCloseChat,
                onMinimize: confirmMinimizeChat
            )
            .transition(.opacity)
            .zIndex(1)
        }
    }

    private func dismissCloseOrMinimizePopup() {
        isCloseOrMinimizePopupPresented = false
    }

    private func confirmCloseChat() {
        dismissCloseOrMinimizePopup()
        performCloseChat()
    }

    @MainActor private func dismissChatKeyboard() {
        #if os(iOS)
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func confirmMinimizeChat() {
        dismissCloseOrMinimizePopup()
        minimizeChat()
    }

    @ViewBuilder private var headerView: some View {
        if let headerBuilder {
            headerBuilder(
                ChatHeaderContext(
                    title: title, theme: model.theme, onMinimize: minimizeChat, onClose: closeChat,
                    statusText: headerStatusText, canMinimize: handle != nil))
        } else {
            ChatHeaderView(
                title: title, theme: model.theme, onClose: closeChat, statusText: headerStatusText,
                onMinimize: handle == nil ? nil : minimizeChat)
        }
    }
    private var headerStatusText: String {
        switch model.status {
        case .connected: return ""
        case .connecting, .notConnected: return model.statusText
        }
    }
    private var closeChat: () -> Void {
        {
            dismissChatKeyboard()
            if options.closeOrMinimizePopup.isShow {
                isCloseOrMinimizePopupPresented = true
            } else {
                performCloseChat()
            }
        }
    }
    private func performCloseChat() {
        dismissChatKeyboard()
        model.emitHostEvent(
            AgentChatEvent(
                eventCode: "BotClosed", eventMessage: "Bot closed by the user", eventReason: 3))
        if let handle = handle {
            handle.endSession()
        } else {
            model.stop(endingSession: true)
        }
        (onClose ?? { dismiss() })()
    }
    private var minimizeChat: () -> Void {
        {
            guard handle != nil else { return }
            model.emitHostEvent(
                AgentChatEvent(
                    eventCode: "BotMinimized", eventMessage: "Bot minimized by the user", eventReason: 4))
            handle?.minimize()
            (onClose ?? { dismiss() })()
        }
    }
    @ViewBuilder private var footerView: some View {
        if let footerBuilder {
            footerBuilder(
                ChatFooterContext(
                    text: $model.composeText,
                    enabled: model.status == .connected && model.isInternetAvailable,
                    placeholder: model.placeholder, theme: model.theme, onSend: model.sendComposedText,
                    onAttach: model.attachmentsAllowed && !model.isSending ? { showAttachmentOptions = true } : nil,
                    canSend: model.canSend,
                    isUploading: model.isUploadingAttachment, pendingAttachments: model.pendingAttachments))
        } else {
            ChatFooterView(
                text: $model.composeText,
                enabled: model.status == .connected && model.isInternetAvailable,
                canSend: model.canSend, placeholder: model.placeholder, font: fonts?.family,
                theme: model.theme,
                onSend: model.sendComposedText, onAttach: { showAttachmentOptions = true },
                showAttachment: model.attachmentsAllowed, canAttach: !model.isSending)
        }
    }
    @ViewBuilder private var attachmentTray: some View {
        if !model.attachmentDrafts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    strings.format(
                        "{count} of {max} attachments",
                        ["count": String(model.attachmentDrafts.count), "max": "5"])
                ).font(.caption).foregroundStyle(Color(hexString: model.theme?.mutedTextColor ?? "#64748B"))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.attachmentDrafts) { draft in
                            AttachmentDraftCard(
                                draft: draft, canRetry: model.canAttach, canRemove: !model.isSending,
                                onCancel: { model.cancelAttachment(draft.id) },
                                onRetry: { model.retryAttachment(draft.id) },
                                onRemove: { model.removeAttachment(draft.id) })
                        }
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

#if os(iOS)
    private struct ChatSafariPresentation: Identifiable {
        let id = UUID()
        let url: URL
    }

    private struct ChatSafariViewController: UIViewControllerRepresentable {
        let url: URL

        func makeUIViewController(context: Context) -> SFSafariViewController {
            SFSafariViewController(url: url)
        }

        func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
    }

    /// Resign the focused composer or form field in this chat's window when a call appears.
    struct IncomingCallKeyboardDismissal: UIViewRepresentable {
        func makeUIView(context: Context) -> KeyboardDismissalView { KeyboardDismissalView() }
        func updateUIView(_ view: KeyboardDismissalView, context: Context) {}

        final class KeyboardDismissalView: UIView {
            override func didMoveToWindow() {
                super.didMoveToWindow()
                guard let window else { return }
                // Resigning synchronously can reenter SwiftUI while it is updating the view hierarchy.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, self.window === window else { return }
                    window.endEditing(true)
                }
            }
        }
    }
#endif

private struct StatusBar: View {
    @Environment(\.chatStrings) private var strings
    let status: ConnectionStatus
    let error: String?
    var body: some View {
        HStack(spacing: 8) {
            if status == .connecting {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.arrow.circlepath").font(.caption).foregroundStyle(
                    status.color)
            }
            Text(error ?? status.label).font(.caption).bold()
            Spacer()
        }.padding(.horizontal, 16).padding(.vertical, 8).foregroundStyle(
            status.color == .orange ? Color.orange.opacity(0.85) : Color.blue
        ).background(status.color.opacity(0.14))
    }
}
extension ConnectionStatus {
    fileprivate var label: String {
        switch self {
        case .notConnected: "Disconnected from agent"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        }
    }
    fileprivate var color: Color {
        switch self {
        case .notConnected: .orange
        case .connecting: .blue
        case .connected: .green
        }
    }
}

private struct EmptyState: View {
    @Environment(\.chatStrings) private var strings
    let title: String
    let subtitle: String
    let theme: ChatTheme?
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 64)).foregroundStyle(
                Color(hexString: theme?.mutedTextColor))
            Text(title).font(.system(size: 18, weight: .medium)).foregroundStyle(
                Color(hexString: theme?.textColor))
            Text(subtitle).foregroundStyle(Color(hexString: theme?.mutedTextColor))
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 80)
    }
}

struct MessageBubble: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.layoutDirection) private var layoutDirection
    let message: Message
    let rowWidth: CGFloat
    let fonts: ChatFonts?
    let theme: ChatTheme?
    let templateRegistry: RichTemplateRegistry?
    let onSubmitAction: (String, String?, [String: String]?, String?) -> Void
    let onSubmitFeedback: (String, String, Int, String?) -> Void
    let attachments: [ChatAttachment]
    let resolveAttachment: (ChatAttachment) async -> URL?
    var performAction: ((String, String?, [String: String]?, String?, String?) async throws -> Void)? = nil
    var sendFeedback: ((String, String, Int, String?) async throws -> Void)? = nil
    var presentation: ChatPresentationState? = nil
    var showCitations = true
    var showAgentLinks = false
    var enableMessageFeedback = false
    var feedbackState: MessageFeedbackState? = nil
    var feedbackEnabled = false
    var feedbackCommentMaxLength = 500
    @State private var timestampInteracting = false
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    var timestampSettings: MessageTimestampSettings? = nil
    var submitMessageFeedback: ((Int, String?) async throws -> Void)? = nil
    var isUser: Bool { message.role == .user }
    private var messageTextColor: Color {
        isUser
            ? Color(hexString: theme?.userBubbleTextColor)
            : Color(hexString: theme?.assistantBubbleTextColor)
    }
    private var isAgentTransferMessage: Bool {
        let custom = message.metadata?["custom"]?.value as? [String: Any] ?? [:]
        return custom["source"] as? String == "agent-transfer"
    }
    private var isAgentTransferSystemMessage: Bool {
        message.role == .system && isAgentTransferMessage
    }
    private var hasBotResponseTemplate: Bool {
        message.role == .assistant
            && (message.richContent != nil || separatesActions
                || templateRegistry?.renderers(for: message).isEmpty == false)
    }
    private var botResponseTemplateWidth: CGFloat {
        max(1, rowWidth - 32 * (theme?.spacingScale ?? 1))
    }
    private var separatesActions: Bool {
        message.role == .assistant && message.actions != nil
            && templateRegistry?.registeredTypes.contains(RichTemplateTypes.actions) != true
    }
    private var hasBubbleContent: Bool {
        !separatesActions || !message.content.isEmpty || message.richContent != nil || !attachments.isEmpty
            || (showAgentLinks && message.agentLink != nil) || (showCitations && !message.citations.isEmpty)
            || message.messageSource?["system"]?.value as? String == "integration"
            || templateRegistry?.renderers(for: message).isEmpty == false
    }
    private var suppressedTemplateTypes: Set<String> {
        var types = templateRegistry?.registeredTypes ?? []
        if separatesActions { types.insert(RichTemplateTypes.actions) }
        return types
    }
    @ViewBuilder var body: some View {
        if isAgentTransferSystemMessage {
            Text(
                message.metadata?["sdkStringKey"]?.value as? String == nil
                    ? message.content : strings(message.content)
            )
            .font(theme?.font(size: 14).weight(.regular) ?? .system(size: 14))
            .foregroundStyle(Color(hexString: theme?.mutedTextColor ?? "#64748B"))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(width: rowWidth, alignment: .center)
            .textSelection(.enabled)
        } else {
            messageContent
        }
    }

    private var messageContent: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if effectiveTimestamps.position == .above { timestampView }
            if hasBubbleContent {
                ZStack(alignment: isUser ? .trailing : .leading) {
                    bubble
                        .frame(
                            maxWidth: max(
                                1, rowWidth - (isUser || hasBotResponseTemplate ? 0 : 40)),
                            alignment: isUser ? .trailing : .leading
                        )
                        .simultaneousGesture(TapGesture().onEnded { timestampInteracting.toggle() })
                }
                .frame(width: rowWidth, alignment: isUser ? .trailing : .leading)
            }
            if separatesActions, let actions = message.actions {
                ActionsRichTemplate(actions: actions, context: templateContext)
                    .frame(
                        width: hasBotResponseTemplate ? rowWidth : max(1, rowWidth - 40),
                        alignment: .leading)
                    .padding(.top, hasBubbleContent ? 4 : 0)
                    .simultaneousGesture(TapGesture().onEnded { timestampInteracting.toggle() })
            }

            if enableMessageFeedback, message.role == .assistant, message.status == .complete,
                message.richContent?.feedback == nil, message.agentTransferSurvey == nil,
                let feedbackState, let submitMessageFeedback
            {
                MessageFeedbackControls(
                    state: feedbackState, enabled: feedbackEnabled,
                    maxLength: feedbackCommentMaxLength, send: submitMessageFeedback)
            }
            if effectiveTimestamps.position == .below { timestampView }
        }
        .frame(width: rowWidth, alignment: isUser ? .trailing : .leading)
        .onHover { timestampInteracting = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(strings("Show timestamp"))) { timestampInteracting.toggle() }
    }
    private var effectiveTimestamps: MessageTimestampSettings {
        timestampSettings ?? theme?.timestamps ?? .init()
    }
    @ViewBuilder private var timestampView: some View {
        if effectiveTimestamps.enabled, message.role == .user || message.role == .assistant,
            message.status != .streaming, message.status != .cancelled, !message.pendingRender,
            effectiveTimestamps.visibility == .always || timestampInteracting
        {
            Text(effectiveTimestamps.format(message.timestamp, locale: locale, timeZone: timeZone))
                .font(theme?.font(size: 12) ?? .caption).foregroundStyle(
                    Color(hexString: theme?.mutedTextColor)
                )
                .frame(width: rowWidth, alignment: isUser ? .trailing : .leading)
        }
    }
    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !message.content.isEmpty, message.richContent?.markdown?.templateTrimmed.isEmpty != false,
                message.richContent?.html?.templateTrimmed.isEmpty != false
            {
                if message.metadata?["contentFormat"]?.value as? String == "plain_text"
                    || message.role == .system
                    || message.role == .thought
                {
                    Text(
                        message.metadata?["sdkStringKey"]?.value as? String == nil
                            ? message.content : strings(message.content)
                    ).font(
                        theme?.font(size: message.role == .system ? 12 : 16)
                            ?? (message.role == .system ? .caption : .body)
                    ).textSelection(.enabled)
                } else {
                    ChatMarkdownView(
                        content: message.content, linkColor: messageTextColor,
                        disabledNumbersHyperlink: theme?.disabledNumbersHyperlink ?? false,
                        fillsAvailableWidth: !isUser && !separatesActions)
                        .textSelection(.enabled)
                }
            }
            if !attachments.isEmpty {
                AttachmentMessageGroup(attachments: attachments, isUser: isUser, resolve: resolveAttachment)
                    .frame(width: isUser ? max(1, rowWidth * 0.7) : nil, alignment: .leading)
            }
            if showAgentLinks, let url = message.agentLink {
                Link(message.agentLinkTitle, destination: url).font(.subheadline.weight(.semibold))
            }
            if showCitations, !message.citations.isEmpty {
                ForEach(Array(message.citations.enumerated()), id: \.offset) { _, citation in
                    Link("[\(citation.index)] \(citation.title)", destination: citation.url).font(.caption)
                }
            }
            if message.messageSource?["system"]?.value as? String == "integration",
                !isAgentTransferMessage
            {
                Text(message.messageSource?["provider"]?.value as? String ?? "Support agent").font(
                    .caption2
                )
                .foregroundStyle(.secondary)
            }
            RichContentTemplatesView(
                message: message, context: templateContext,
                suppressedTypes: suppressedTemplateTypes,
                fillsAvailableWidth: !isUser && !separatesActions)
                .frame(width: hasBotResponseTemplate ? botResponseTemplateWidth : nil, alignment: .leading)
            ForEach(Array((templateRegistry?.renderers(for: message) ?? []).enumerated()), id: \.offset) {
                _, renderer in
                renderer.build(message, templateContext)
                    .frame(width: hasBotResponseTemplate ? botResponseTemplateWidth : nil, alignment: .leading)
            }
        }
        .padding(.horizontal, 16 * (theme?.spacingScale ?? 1))
        .padding(.vertical, 12 * (theme?.spacingScale ?? 1))
        .foregroundStyle(messageTextColor)
        .background(
            isUser
                ? Color(hexString: theme?.userBubbleColor) : Color(hexString: theme?.assistantBubbleColor)
        )
        .clipShape(
            ChatMessageBubbleShape(
                radius: theme?.messageBubbleRadius ?? 16,
                tailOnLeft: isUser
                    ? layoutDirection == .rightToLeft
                    : layoutDirection == .leftToRight))
        .clipped()
    }
    private var templateContext: RichTemplateContext {
        RichTemplateContext(
            message: message, theme: theme, accentColor: Color(hexString: theme?.primaryColor),
            submitAction: onSubmitAction, submitFeedback: onSubmitFeedback, performAction: performAction,
            sendFeedback: sendFeedback, presentation: presentation)
    }
}

private struct RichContentView: View {
    @Environment(\.chatStrings) private var strings
    let metadata: [String: AnySendable]?
    let theme: ChatTheme?
    var cards: [[String: Any]] {
        guard
            let raw = metadata?["richContent"]?.value as? [String: Any] ?? metadata?["rich_content"]?
                .value
                as? [String: Any], let carousel = raw["carousel"] as? [String: Any],
            let cards = carousel["cards"] as? [[String: Any]]
        else { return [] }
        return cards
    }
    var body: some View {
        if !cards.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                        CarouselCard(card: card, theme: theme)
                    }
                }.padding(.vertical, 4)
            }
        }
    }
}

private struct CarouselCard: View {
    @Environment(\.chatStrings) private var strings
    let card: [String: Any]
    let theme: ChatTheme?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = card["imageUrl"] as? String, let url = URL(string: image) {
                TemplateRemoteImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.12)
                }.frame(width: 200, height: 120).clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(card["title"] as? String ?? "").font(.headline).lineLimit(2)
                Text(card["subtitle"] as? String ?? card["description"] as? String ?? "").font(.caption)
                    .foregroundStyle(Color(hexString: theme?.mutedTextColor)).lineLimit(3)
                if let url = card["defaultActionUrl"] as? String, let target = URL(string: url),
                    ["http", "https"].contains(target.scheme?.lowercased())
                {
                    Link("Open", destination: target).font(.caption.bold()).foregroundStyle(
                        Color(hexString: theme?.primaryColor)
                    ).padding(.top, 4)
                }
            }.padding(12)
        }.frame(width: 200, alignment: .leading).background(.background).clipShape(
            RoundedRectangle(cornerRadius: theme?.borderRadius ?? 12)
        ).shadow(color: .black.opacity(0.08), radius: 2)
    }
}

struct TypingBubble: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.layoutDirection) private var layoutDirection
    let theme: ChatTheme?
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate * (2 * Double.pi / 1.2)
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = (sin(phase - Double(index) * 0.7) + 1) / 2
                    Circle().fill(Color(hexString: theme?.userBubbleColor))
                        .frame(width: 8, height: 8)
                        .scaleEffect(0.5 + 0.5 * wave)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Color(hexString: theme?.assistantBubbleColor))
        .clipShape(
            ChatMessageBubbleShape(
                radius: theme?.messageBubbleRadius ?? 16,
                tailOnLeft: layoutDirection == .leftToRight))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatMessageBubbleShape: Shape {
    let radius: CGFloat
    let tailOnLeft: Bool

    func path(in rect: CGRect) -> Path {
        let cornerRadius = min(max(0, radius), min(rect.width, rect.height) / 2)
        let tailRadius = min(cornerRadius, 5)
        let topLeft = cornerRadius
        let topRight = cornerRadius
        let bottomLeft = tailOnLeft ? tailRadius : cornerRadius
        let bottomRight = tailOnLeft ? cornerRadius : tailRadius

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topRight),
            control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct AttachmentMessageCard: View {
    @Environment(\.chatStrings) private var strings
    let attachment: ChatAttachment
    let resolve: (ChatAttachment) async -> URL?
    @Environment(\.openURL) private var openURL
    @State private var isOpening = false
    var body: some View {
        Button {
            guard !isOpening else { return }
            isOpening = true
            Task { @MainActor in
                defer { isOpening = false }
                if let url = await resolve(attachment) { openURL(url) }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: attachment.icon).font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(attachment.filename).font(.subheadline).lineLimit(2)
                    Text(attachment.detail).font(.caption).opacity(0.8)
                }
                if isOpening { ProgressView() } else { Image(systemName: "arrow.down.circle") }
            }.padding(10).background(Color.primary.opacity(0.08)).cornerRadius(8)
        }.buttonStyle(.plain).disabled(isOpening).accessibilityLabel(
            strings.format("Open {filename}", ["filename": attachment.filename]))
    }
}
