import SwiftUI
import ArtemisUISDK

@main
struct ArtemisUIExampleApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var presentedChat: ChatPresentation?
    @State private var chatHandle: AgentChatHandle?
    @State private var eventRegistration: ArtemisUiEventRegistration?
    @State private var bootstrapToken: String?
    @State private var bootstrapConfiguration: SDKConfiguration?
    
    // Set to false to skip token generation and use API Key Authentication.
    private let isGeneratingBootstrapToken = false
    @State private var isPreparingAuthentication = true
    
    private let projectID = "your-project-id"
    private let endpoint = "https://runtime.example.com"
    private let channelID = "your-channel-id"
    private let sdkEnvironment = "dev"
    
    // Replace these values with the host application's runtime configuration.
    private let apiKey = "pk_your_public_key"
    
    // Replace these values with the host application's runtime configuration for bootstrapToken and bootstrapConfiguration.
    private let tenantID = "your-tenant-id"
    private let channelSecret = "sk_channel_secret_key"
    private let verifiedUserID = "sample_verified_user-id"
    private let chatTitle = "chat_title"
    private let customerSessionCustomAttributes: [String: Any] = [:]

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Button("Open Agent Chat") {
                    let handle = chatHandle ?? AgentChatUI.initialize(
                        configuration: configuration
                    )
                    if eventRegistration == nil {
                        eventRegistration = handle.addListener { event in
                            switch event {
                            case .connectionChanged(let status, let detail):
                                print("Chat connection:", status, detail ?? "")
                            case .messageSent(let messageId):
                                print("Message accepted:", messageId)
                            case .deepLinkClicked(let url, let title, let messageId):
                                print("Deep link tapped:", url, title ?? "", messageId ?? "")
                            case .minimized:
                                print("Chat minimized by user")
                            case .closed(let reason):
                                print("Chat closed:", reason)
                            default:
                                break
                            }
                        }
                    }
                    chatHandle = handle
                    presentedChat = ChatPresentation(handle: handle)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPreparingAuthentication)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("")
            .fullScreenCover(item: $presentedChat) { presentation in
                NavigationView {
                    AgentChatUI.view(
                        handle: presentation.handle,
                        title: "PhoneStore SDK",
                        fonts: ChatFonts(family: nil, monospaceFamily: "Menlo"),
//                        headerBuilder: { header in AnyView(ExampleChatHeader(context: header)) },
//                        footerBuilder: { footer in AnyView(ExampleChatFooter(context: footer)) },
//                        templateRegistry: exampleTemplateRegistry,
                        onClose: { presentedChat = nil }
                    )
                }
                .navigationViewStyle(.stack)
            }
        }
        .navigationViewStyle(.stack)
        .task {
            await prepareAuthentication()
        }
    }

    private var configuration: SDKConfiguration {
        let token = bootstrapToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isGeneratingBootstrapToken, !token.isEmpty, let bootstrapConfiguration {
            return SDKConfiguration(
                environment: bootstrapConfiguration.environment,
                connection: ConnectionConfig(
                    projectId: bootstrapConfiguration.connection.projectId,
                    endpoint: bootstrapConfiguration.connection.endpoint,
                    bootstrapToken: token,
                    bootstrapTokenProvider: bootstrapConfiguration.connection.bootstrapTokenProvider
                )
            )
        }

        return SDKConfiguration(
            environment: "dev",
            connection: ConnectionConfig(
                projectId: projectID,
                endpoint: endpoint,
                apiKey: apiKey
            ),
            channel: ChannelConfig(channelId: channelID),
            // Optional host-app settings:
            // theme: ThemeConfig(messageTimestampFormat: "EE, MMM dd yyyy 'at' hh:mm:ss a"),
            // debug: DebugConfig(enabled: true, logLevel: "debug", logWebsocketMessages: true, printLogs: true),
            // features: FeaturesConfig(sendAllDeepLink: true)
        )
    }

    @MainActor
    private func prepareAuthentication() async {
        guard isGeneratingBootstrapToken else {
            bootstrapToken = nil
            bootstrapConfiguration = nil
            isPreparingAuthentication = false
            return
        }

        defer { isPreparingAuthentication = false }

        do {
            let generatedConfiguration = try await CustomerSessionBootstrapProvider.makeSDKConfigurationFromEnvironment(
                environment: sdkEnvironment,
                projectID: projectID,
                endpoint: endpoint,
                tenantID: tenantID,
                channelSecret: channelSecret,
                verifiedUserID: verifiedUserID,
                channelID: channelID,
                channelName: chatTitle,
                customAttributes: customerSessionCustomAttributes
            )
            bootstrapToken = generatedConfiguration.connection.bootstrapToken
            bootstrapConfiguration = generatedConfiguration
        } catch {
            bootstrapToken = nil
            bootstrapConfiguration = nil
            print("Bootstrap token generation failed; using API Key Authentication: \(error.localizedDescription)")
        }
    }

    private var exampleTemplateRegistry: RichTemplateRegistry {
        var registry = RichTemplateRegistry()
        registry.register(RichTemplateRenderer(
            type: "order_card",
            matches: { message in
                guard let metadata = message.metadata else { return false }
                let directType = metadata["template"]?.value as? String
                let richContent = metadata["richContent"]?.value as? [String: Any]
                    ?? metadata["rich_content"]?.value as? [String: Any]
                let nestedType = richContent?["template"] as? String
                return directType == "order_card" || nestedType == "order_card"
            },
            build: { message, context in
                AnyView(ExampleOrderCard(message: message, context: context))
            }
        ))
        return registry
    }
}

private struct ChatPresentation: Identifiable {
    let id = UUID()
    let handle: AgentChatHandle
}

private struct ExampleOrderCard: View {
    let message: Message
    let context: RichTemplateContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Order card", systemImage: "shippingbox.fill")
                .font(.headline)
            Text("This template is rendered by the parent app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Confirm order") {
                context.submitAction("confirm-order", "confirmed", nil, message.id)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(context.accentColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// Example parent-app header injected into the SDK.
private struct ExampleChatHeader: View {
    let context: ChatHeaderContext

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.2))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(context.title).font(.headline).foregroundStyle(.white)
                Text("Provided by the parent app").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Button(action: context.onClose) {
                Image(systemName: "xmark").foregroundStyle(.white).padding(8)
            }
            .accessibilityLabel("Close chat")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(Color.accentColor)
    }
}

/// Example parent-app footer injected into the SDK.
private struct ExampleChatFooter: View {
    let context: ChatFooterContext

    var body: some View {
        HStack(spacing: 8) {
            if let onAttach = context.onAttach {
                Button(action: onAttach) { Image(systemName: "paperclip") }
                    .disabled(!context.enabled)
            }
            TextField(context.placeholder, text: context.text)
                .textFieldStyle(.roundedBorder)
                .disabled(!context.enabled)
                .onSubmit(context.onSend)
            Button(action: context.onSend) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!context.canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background)
    }
}
