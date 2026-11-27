import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Retain this handle in the host to preserve the conversation and drafts while minimized.
@MainActor public final class AgentChatHandle: ObservableObject {
    let model: AgentChatViewModel
    @Published public private(set) var isMinimized = false
    /// Receives typed UI events from this chat instance.
    public var onEvent: ArtemisUiListener?
    private var uiEventListeners: [(id: UUID, listener: ArtemisUiListener)] = []
    private var isClosed = false

    public init(
        configuration: SDKConfiguration? = nil, environment: String? = nil,
        configResource: String = "sdk_configurations", runtimeUserContext: SDKUserContext? = nil,
        onEvent: ArtemisUiListener? = nil
    ) {
        model = AgentChatViewModel(
            configuration: configuration, environment: environment, configResource: configResource,
            runtimeUserContext: runtimeUserContext)
        self.onEvent = onEvent
        model.uiEventHandler = { [weak self] event in self?.emit(event) }
    }
    /// Register for typed UI events. Keep the returned token and cancel it when the listener is no longer needed.
    @discardableResult
    public func addListener(_ listener: @escaping ArtemisUiListener) -> ArtemisUiEventRegistration {
        precondition(!isClosed, "Artemis UI handle is closed")
        let id = UUID()
        uiEventListeners.append((id, listener))
        return ArtemisUiEventRegistration { [weak self] in
            self?.uiEventListeners.removeAll { $0.id == id }
        }
    }

    private func emit(_ event: ArtemisUiEvent) {
        onEvent?(event)
        for entry in Array(uiEventListeners) { entry.listener(event) }
    }

    public func minimize() {
        guard !isClosed, !isMinimized else { return }
        isMinimized = true
        emit(.minimized)
    }
    public func reopen() {
        guard !isClosed else { return }
        isMinimized = false
    }
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        emit(.closed(reason: "HANDLE_CLOSED"))
        isMinimized = false
        model.stop()
        uiEventListeners.removeAll()
    }
    public func endSession() {
        guard !isClosed else { return }
        emit(.sessionEnded(reason: "END_SESSION"))
        emit(.closed(reason: "END_SESSION"))
        isMinimized = false
        model.stop(endingSession: true)
    }
}

extension AgentChatUI {
    @MainActor public static func initialize(
        configuration: SDKConfiguration? = nil, environment: String? = nil,
        runtimeUserContext: SDKUserContext? = nil, onEvent: ArtemisUiListener? = nil
    ) -> AgentChatHandle {
        AgentChatHandle(
            configuration: configuration, environment: environment, runtimeUserContext: runtimeUserContext,
            onEvent: onEvent
        )
    }
    @MainActor public static func view(
        handle: AgentChatHandle, title: String = "Chat", fonts: ChatFonts? = nil,
        headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
        templateRegistry: RichTemplateRegistry? = nil, uiOptions: ChatUIOptions? = nil,
        onClose: (() -> Void)? = nil
    ) -> AgentChatView {
        AgentChatView(
            handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder,
            footerBuilder: footerBuilder,
            templateRegistry: templateRegistry, uiOptions: uiOptions, onClose: onClose)
    }
    #if canImport(UIKit)
        @MainActor @discardableResult
        public static func show(
            in controller: UIViewController, handle: AgentChatHandle, title: String = "Chat",
            fonts: ChatFonts? = nil, headerBuilder: ChatHeaderBuilder? = nil,
            footerBuilder: ChatFooterBuilder? = nil,
            templateRegistry: RichTemplateRegistry? = nil, uiOptions: ChatUIOptions? = nil,
            hidesBottomBarWhenPushed: Bool = true, animated: Bool = true
        ) -> Bool {
            guard
                let navigation = (controller as? UINavigationController) ?? controller.navigationController,
                let source = navigation.topViewController,
                !(source is ChatNavigationHostingController<AgentChatView>)
            else { return false }
            handle.reopen()
            let chat = view(
                handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder,
                footerBuilder: footerBuilder,
                templateRegistry: templateRegistry, uiOptions: uiOptions
            ) { [weak navigation, weak source] in
                guard let navigation, let source,
                    navigation.topViewController is ChatNavigationHostingController<AgentChatView>
                else { return }
                navigation.popToViewController(source, animated: animated)
            }
            let host = ChatNavigationHostingController(rootView: chat)
            host.hidesBottomBarWhenPushed = hidesBottomBarWhenPushed
            navigation.pushViewController(host, animated: animated)
            return true
        }
        @MainActor public static func present(
            from controller: UIViewController, handle: AgentChatHandle, title: String = "Chat",
            fonts: ChatFonts? = nil, headerBuilder: ChatHeaderBuilder? = nil,
            footerBuilder: ChatFooterBuilder? = nil, templateRegistry: RichTemplateRegistry? = nil,
            uiOptions: ChatUIOptions? = nil
        ) {
            handle.reopen()
            let chat = view(
                handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder,
                footerBuilder: footerBuilder,
                templateRegistry: templateRegistry, uiOptions: uiOptions
            ) { [weak controller] in controller?.dismiss(animated: true) }
            let host = UIHostingController(rootView: chat)
            let navigation = UINavigationController(rootViewController: host)
            navigation.setNavigationBarHidden(true, animated: false)
            navigation.modalPresentationStyle = .fullScreen
            controller.present(navigation, animated: true)
        }
    #endif
}
