import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

/// Retain this handle in the host to preserve the conversation and drafts while minimized.
@MainActor public final class AgentChatHandle: ObservableObject {
    let model: AgentChatViewModel
    @Published public private(set) var isMinimized = false
    public init(
        configuration: SDKConfiguration? = nil, environment: String? = nil,
        configResource: String = "sdk_configurations", runtimeUserContext: SDKUserContext? = nil
    ) {
        model = AgentChatViewModel(
            configuration: configuration, environment: environment, configResource: configResource,
            runtimeUserContext: runtimeUserContext)
    }
    func minimize() { isMinimized = true }
    func reopen() { isMinimized = false }
    public func close() {
        isMinimized = false
        model.stop()
    }
    public func endSession() {
        isMinimized = false
        model.stop(endingSession: true)
    }
}

extension AgentChatUI {
    @MainActor public static func initialize(
        configuration: SDKConfiguration? = nil, environment: String? = nil,
        runtimeUserContext: SDKUserContext? = nil
    ) -> AgentChatHandle {
        AgentChatHandle(configuration: configuration, environment: environment, runtimeUserContext: runtimeUserContext)
    }
    @MainActor public static func view(
        handle: AgentChatHandle, title: String = "Chat", fonts: ChatFonts? = nil,
        headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
        templateRegistry: RichTemplateRegistry? = nil, onClose: (() -> Void)? = nil
    ) -> AgentChatView {
        AgentChatView(
            handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder, footerBuilder: footerBuilder,
            templateRegistry: templateRegistry, onClose: onClose)
    }
    #if canImport(UIKit)
        @MainActor @discardableResult
        public static func show(
            in controller: UIViewController, handle: AgentChatHandle, title: String = "Chat",
            fonts: ChatFonts? = nil, headerBuilder: ChatHeaderBuilder? = nil, footerBuilder: ChatFooterBuilder? = nil,
            templateRegistry: RichTemplateRegistry? = nil, hidesBottomBarWhenPushed: Bool = true, animated: Bool = true
        ) -> Bool {
            guard let navigation = (controller as? UINavigationController) ?? controller.navigationController,
                let source = navigation.topViewController, !(source is ChatNavigationHostingController<AgentChatView>)
            else { return false }
            handle.reopen()
            let chat = view(
                handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder, footerBuilder: footerBuilder,
                templateRegistry: templateRegistry
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
            footerBuilder: ChatFooterBuilder? = nil, templateRegistry: RichTemplateRegistry? = nil
        ) {
            handle.reopen()
            let chat = view(
                handle: handle, title: title, fonts: fonts, headerBuilder: headerBuilder, footerBuilder: footerBuilder,
                templateRegistry: templateRegistry
            ) { [weak controller] in controller?.dismiss(animated: true) }
            let host = UIHostingController(rootView: chat)
            let navigation = UINavigationController(rootViewController: host)
            navigation.setNavigationBarHidden(true, animated: false)
            navigation.modalPresentationStyle = .fullScreen
            controller.present(navigation, animated: true)
        }
    #endif
}
