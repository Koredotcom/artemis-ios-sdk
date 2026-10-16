import SwiftUI
import UniformTypeIdentifiers

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

#if os(iOS)
    import UIKit
#endif

public struct AgentChatView: View {
    @StateObject private var model: AgentChatViewModel
    @Environment(\.artemisChatOptions) private var environmentOptions
    private let providedOptions: ChatUIOptions?
    private var options: ChatUIOptions { providedOptions ?? environmentOptions }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAttachmentOptions = false
    @State private var showFilePicker = false
    @State private var showPhotoPicker = false
    @State private var showCameraPicker = false
    private var strings: ChatStrings { options.strings ?? model.strings }
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
        uiOptions: ChatUIOptions? = nil,
        onClose: (() -> Void)? = nil
    ) {
        _model = StateObject(
            wrappedValue: AgentChatViewModel(
                configuration: configuration, environment: environment, configResource: configResource,
                runtimeUserContext: runtimeUserContext, headerBuilder: headerBuilder,
                footerBuilder: footerBuilder,
                templateRegistry: templateRegistry))
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
        VStack(spacing: 0) {
            headerView
            if model.status == .notConnected {
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
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
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
            model.configureStrings(options.strings)
            model.start()
            model.updateAppearance(isDark: colorScheme == .dark)
        }
        .onDisappear { if handle?.isMinimized != true { model.stop() } }
        .onChange(of: colorScheme) { model.updateAppearance(isDark: $0 == .dark) }
        .background(Color(hexString: model.theme?.backgroundColor ?? "#FFFFFF"))
        .onChange(of: model.composeText) { _ in model.composerChanged() }
        .font(
            fonts?.family.map { .custom($0, size: model.theme?.baseFontSize ?? 16) }
                ?? model.theme?.font())
    }
    @ViewBuilder private var headerView: some View {
        if let headerBuilder {
            headerBuilder(
                ChatHeaderContext(
                    title: title, theme: model.theme, onMinimize: minimizeChat, onClose: closeChat,
                    statusText: model.statusText, canMinimize: handle != nil))
        } else {
            ChatHeaderView(
                title: title, theme: model.theme, onClose: closeChat, statusText: model.statusText,
                onMinimize: handle == nil ? nil : minimizeChat)
        }
    }
    private var closeChat: () -> Void {
        {
            handle?.close()
            model.stop()
            (onClose ?? { dismiss() })()
        }
    }
    private var minimizeChat: () -> Void {
        {
            handle?.minimize()
            (onClose ?? { dismiss() })()
        }
    }
    @ViewBuilder private var footerView: some View {
        if let footerBuilder {
            footerBuilder(
                ChatFooterContext(
                    text: $model.composeText, enabled: model.status == .connected && !model.isSending,
                    placeholder: model.placeholder, theme: model.theme, onSend: model.sendComposedText,
                    onAttach: model.attachmentsAllowed ? { showAttachmentOptions = true } : nil,
                    canSend: model.canSend,
                    isUploading: model.isUploadingAttachment, pendingAttachments: model.pendingAttachments))
        } else {
            ChatFooterView(
                text: $model.composeText, enabled: model.status == .connected && !model.isSending,
                canSend: model.canSend, placeholder: model.placeholder, font: fonts?.family,
                theme: model.theme,
                onSend: model.sendComposedText, onAttach: { showAttachmentOptions = true },
                showAttachment: model.attachmentsAllowed)
        }
    }
    @ViewBuilder private var attachmentTray: some View {
        if !model.attachmentDrafts.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    strings.format(
                        "{count} of {max} attachments",
                        ["count": String(model.attachmentDrafts.count), "max": "5"])
                ).font(.caption).foregroundStyle(.secondary)
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
    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if effectiveTimestamps.position == .above { timestampView }
            if hasBubbleContent {
                ZStack(alignment: isUser ? .trailing : .leading) {
                    bubble
                        .frame(
                            maxWidth: max(1, rowWidth - (isUser ? 0 : 40)), alignment: isUser ? .trailing : .leading
                        )
                        .simultaneousGesture(TapGesture().onEnded { timestampInteracting.toggle() })
                }
                .frame(width: rowWidth, alignment: isUser ? .trailing : .leading)
            }
            if separatesActions, let actions = message.actions {
                ActionsRichTemplate(actions: actions, context: templateContext)
                    .frame(width: max(1, rowWidth - 40), alignment: .leading)
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
                    ChatMarkdownView(content: message.content, fillsAvailableWidth: !isUser && !separatesActions)
                        .textSelection(.enabled)
                }
            }
            if !attachments.isEmpty {
                AttachmentMessageGroup(attachments: attachments, isUser: isUser, resolve: resolveAttachment)
            }
            if showAgentLinks, let url = message.agentLink {
                Link(message.agentLinkTitle, destination: url).font(.subheadline.weight(.semibold))
            }
            if showCitations, !message.citations.isEmpty {
                ForEach(Array(message.citations.enumerated()), id: \.offset) { _, citation in
                    Link("[\(citation.index)] \(citation.title)", destination: citation.url).font(.caption)
                }
            }
            if message.messageSource?["system"]?.value as? String == "integration" {
                Text(message.messageSource?["provider"]?.value as? String ?? "Support agent").font(
                    .caption2
                )
                .foregroundStyle(.secondary)
            }
            RichContentTemplatesView(
                message: message, context: templateContext,
                suppressedTypes: suppressedTemplateTypes,
                fillsAvailableWidth: !isUser && !separatesActions)
            ForEach(Array((templateRegistry?.renderers(for: message) ?? []).enumerated()), id: \.offset) {
                _, renderer in
                renderer.build(message, templateContext)
            }
        }
        .padding(.horizontal, 16 * (theme?.spacingScale ?? 1))
        .padding(.vertical, 12 * (theme?.spacingScale ?? 1))
        .foregroundStyle(
            isUser
                ? Color(hexString: theme?.userBubbleTextColor)
                : Color(hexString: theme?.assistantBubbleTextColor)
        )
        .background(
            isUser
                ? Color(hexString: theme?.userBubbleColor) : Color(hexString: theme?.assistantBubbleColor)
        )
        .clipShape(RoundedRectangle(cornerRadius: theme?.messageBubbleRadius ?? 16))
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
        .clipShape(RoundedRectangle(cornerRadius: theme?.messageBubbleRadius ?? 16))
        .frame(maxWidth: .infinity, alignment: .leading)
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
