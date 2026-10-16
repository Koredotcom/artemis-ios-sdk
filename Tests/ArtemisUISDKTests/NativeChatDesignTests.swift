#if canImport(UIKit)
    import XCTest
    import SwiftUI
    import UIKit
    @testable import ArtemisUISDK
    import ArtemisSocketSDK

    final class NativeChatDesignTests: XCTestCase {
        @MainActor func testHeaderComposerAndAttachmentDesignInLightAndDarkMode() async throws {
            for dark in [false, true] {
                let controller = UIHostingController(rootView: DesignFixture(dark: dark))
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer {
                    window.isHidden = true
                    window.rootViewController = nil
                }
                try await Task.sleep(nanoseconds: 250_000_000)
                let input = try XCTUnwrap(findTextView(in: controller.view))
                XCTAssertEqual(input.bounds.height, 40, accuracy: 1)
                XCTAssertTrue(input.isEditable)
                XCTAssertEqual(input.accessibilityLabel, "Message")
                if #available(iOS 16.0, *) {
                    let header = UIHostingController(
                        rootView: ChatHeaderView(
                            title: "Support", theme: nil, onClose: {}, statusText: "Connected", onMinimize: {}))
                    XCTAssertEqual(header.sizeThatFits(in: CGSize(width: 390, height: 200)).height, 64, accuracy: 1)
                }
            }
        }
        @MainActor func testComposerGrowsForLongDraftWithoutLosingText() async throws {
            let state = ComposerFixtureState()
            let controller = UIHostingController(rootView: ComposerFixture(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            let initial = try XCTUnwrap(findTextView(in: controller.view))
            XCTAssertEqual(initial.bounds.height, 40, accuracy: 1)
            state.text = String(repeating: "Long draft wraps across several lines. ", count: 20)
            try await Task.sleep(nanoseconds: 200_000_000)
            let expanded = try XCTUnwrap(findTextView(in: controller.view))
            XCTAssertGreaterThan(expanded.bounds.height, 40)
            XCTAssertLessThanOrEqual(expanded.bounds.height, 120)
            XCTAssertEqual(expanded.text, state.text)
        }
        @MainActor private func findTextView(in view: UIView) -> UITextView? {
            if let view = view as? UITextView { return view }
            return view.subviews.lazy.compactMap { self.findTextView(in: $0) }.first
        }
    }

    @MainActor private struct DesignFixture: View {
        let dark: Bool
        @State private var text = ""
        private var theme: ChatTheme {
            ChatTheme(
                configuration: SDKConfiguration(
                    environment: "dev",
                    connection: ConnectionConfig(
                        projectId: "fixture", endpoint: "https://fixture.invalid", apiKey: "fixture"),
                    theme: ThemeConfig(
                        primaryColor: "#2563EB", textColor: dark ? "#E2E8F0" : "#1E293B",
                        backgroundColor: dark ? "#0F172A" : "#FFFFFF", surfaceColor: dark ? "#1E293B" : "#F1F5F9",
                        darkMode: dark)))
        }
        var body: some View {
            VStack(spacing: 0) {
                ChatHeaderView(title: "Agent Chat", theme: theme, onClose: {}, statusText: "Connected", onMinimize: {})
                ScrollView {
                    VStack(spacing: 16) {
                        MessageBubble(
                            message: Message(
                                id: "assistant", role: .assistant, content: "Hello! How can I help you today?"),
                            rowWidth: 358, fonts: nil, theme: theme,
                            templateRegistry: nil, onSubmitAction: { _, _, _, _ in },
                            onSubmitFeedback: { _, _, _, _ in }, attachments: [], resolveAttachment: { _ in nil })
                        MessageBubble(
                            message: Message(id: "user", role: .user, content: "Please review these documents."),
                            rowWidth: 358, fonts: nil, theme: theme,
                            templateRegistry: nil, onSubmitAction: { _, _, _, _ in },
                            onSubmitFeedback: { _, _, _, _ in },
                            attachments: [
                                ChatAttachment(
                                    id: "a", filename: "Project overview.pdf", mimeType: "application/pdf",
                                    sizeBytes: 2048),
                                ChatAttachment(id: "b", filename: "Details.docx", sizeBytes: 1024),
                            ], resolveAttachment: { _ in nil })
                        MessageBubble(
                            message: Message(
                                id: "reply", role: .assistant, content: "I have received your attachments."),
                            rowWidth: 358, fonts: nil, theme: theme,
                            templateRegistry: nil, onSubmitAction: { _, _, _, _ in },
                            onSubmitFeedback: { _, _, _, _ in }, attachments: [], resolveAttachment: { _ in nil })
                    }.padding(16)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("2 of 5 attachments").font(.caption).foregroundStyle(.secondary)
                    AttachmentDraftCard(
                        draft: AttachmentDraft(
                            id: "draft",
                            attachment: ChatAttachment(
                                id: "ready", filename: "Notes.txt", mimeType: "text/plain", sizeBytes: 71),
                            status: .ready,
                            source: URL(fileURLWithPath: "/offline-fixture"), sessionId: "fixture", removesSource: false
                        ), canRetry: true, canRemove: true, onCancel: {}, onRetry: {}, onRemove: {})
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                ChatFooterView(
                    text: $text, enabled: true, canSend: true, placeholder: "Type a message...", font: nil,
                    theme: theme, onSend: {}, onAttach: {}, showAttachment: true)
            }.background(Color(hexString: theme.backgroundColor)).environment(\.colorScheme, dark ? .dark : .light)
        }
    }
    @MainActor private final class ComposerFixtureState: ObservableObject { @Published var text = "" }
    private struct ComposerFixture: View {
        @ObservedObject var state: ComposerFixtureState
        var body: some View {
            ChatFooterView(
                text: $state.text, enabled: true, canSend: true, placeholder: "Message", font: nil, theme: nil,
                onSend: {}, onAttach: {}, showAttachment: true
            ).frame(width: 390)
        }
    }
#endif
