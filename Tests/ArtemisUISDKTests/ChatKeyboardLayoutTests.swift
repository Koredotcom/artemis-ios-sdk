#if canImport(UIKit)
    import ArtemisSocketSDK
    import SwiftUI
    import UIKit
    import XCTest
    @testable import ArtemisUISDK

    final class ChatKeyboardLayoutTests: XCTestCase {
        @MainActor func testKeyboardFocusMovesBetweenFormAndGrowingComposer() async throws {
            let state = KeyboardFixtureState()
            let controller = UIHostingController(rootView: KeyboardNavigationFixture(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.endEditing(true)
                window.isHidden = true
                window.rootViewController = nil
            }
            try await settle()
            let composer = try XCTUnwrap(find(UITextView.self, in: controller.view))
            let field = try await waitForField(in: controller.view)

            for _ in 0..<3 {
                XCTAssertTrue(field.becomeFirstResponder())
                try await settle()
                XCTAssertTrue(field.isFirstResponder)
                XCTAssertTrue(composer.becomeFirstResponder())
                try await settle()
                XCTAssertTrue(composer.isFirstResponder)

                composer.insertText(String(repeating: "A draft that wraps across lines. ", count: 12))
                try await settle()
                XCTAssertEqual(state.text, composer.text)
                XCTAssertEqual(composer.bounds.height, 120, accuracy: 1)

                state.text = ""
                try await settle()
                XCTAssertEqual(composer.text, "")
                XCTAssertEqual(composer.bounds.height, 40, accuracy: 1)
                XCTAssertTrue(composer.resignFirstResponder())
                try await settle()
            }
        }

        @MainActor func testRapidEditsAndWidthChangesPreserveDraftAndBoundHeight() async throws {
            let state = KeyboardFixtureState()
            let controller = UIHostingController(rootView: KeyboardNavigationFixture(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.endEditing(true)
                window.isHidden = true
                window.rootViewController = nil
            }
            try await settle()
            let composer = try XCTUnwrap(find(UITextView.self, in: controller.view))
            XCTAssertTrue(composer.becomeFirstResponder())

            for width in [CGFloat(390), 260, 350] {
                state.width = width
                for count in 1...20 {
                    state.text = String(repeating: "Typing ", count: count)
                    await Task.yield()
                }
                try await settle()
                XCTAssertEqual(composer.text, state.text)
                XCTAssertGreaterThan(composer.bounds.width, 0)
                XCTAssertGreaterThanOrEqual(composer.bounds.height, 40)
                XCTAssertLessThanOrEqual(composer.bounds.height, 120)
            }
            state.text = "Short"
            try await settle()
            XCTAssertEqual(composer.text, "Short")
            XCTAssertEqual(composer.bounds.height, 40, accuracy: 1)
        }

        @MainActor func testFocusedComposerCanDisableAndReenableWithoutLosingDraft() async throws {
            let state = KeyboardFixtureState()
            let controller = UIHostingController(rootView: KeyboardNavigationFixture(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.endEditing(true)
                window.isHidden = true
                window.rootViewController = nil
            }
            try await settle()
            let composer = try XCTUnwrap(find(UITextView.self, in: controller.view))
            for _ in 0..<3 {
                state.enabled = true
                try await settle()
                XCTAssertTrue(composer.becomeFirstResponder())
                composer.insertText("Draft")
                try await settle()
                let draft = state.text

                // Closing or disconnecting changes availability while the input
                // is focused. UIKit must resign outside updateUIView's render.
                state.enabled = false
                try await settle()
                XCTAssertFalse(composer.isEditable)
                XCTAssertFalse(composer.isFirstResponder)
                XCTAssertEqual(state.text, draft)
                state.enabled = true
                try await settle()
                XCTAssertTrue(composer.isEditable)
            }
        }

        @MainActor func testTallListAndTableRemainStableDuringKeyboardAndViewportChanges() async throws {
            let state = KeyboardFixtureState()
            let controller = UIHostingController(rootView: KeyboardNavigationFixture(state: state))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.endEditing(true)
                window.isHidden = true
                window.rootViewController = nil
            }
            try await settle()
            // Match Bus prices: a single tall message with six list cards and
            // a horizontally scrolling table, followed by a booking form.
            state.showRichResponse = true
            try await settle()
            let composer = try XCTUnwrap(find(UITextView.self, in: controller.view))
            let field = try await waitForField(in: controller.view)
            for width in [CGFloat(390), 280, 350] {
                state.width = width
                XCTAssertTrue(field.becomeFirstResponder())
                try await settle()
                XCTAssertTrue(composer.becomeFirstResponder())
                composer.insertText(String(repeating: "A wrapping draft. ", count: 25))
                try await settle()
                XCTAssertEqual(composer.bounds.height, 120, accuracy: 1)
                let table = try XCTUnwrap(horizontalScrollView(in: controller.view))
                let height = table.bounds.height
                XCTAssertGreaterThan(height, 200)
                XCTAssertLessThan(height, 800)
                try await settle()
                XCTAssertEqual(table.bounds.height, height, accuracy: 1)
                state.text = ""
                XCTAssertTrue(composer.resignFirstResponder())
                try await settle()
            }
        }

        @MainActor private func settle() async throws {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        @MainActor private func waitForField(in view: UIView) async throws -> UITextField {
            for _ in 0..<20 {
                if let field = find(UITextField.self, in: view) { return field }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return try XCTUnwrap(find(UITextField.self, in: view))
        }
        @MainActor private func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
            if let result = view as? T { return result }
            return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
        }
        @MainActor private func horizontalScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 50 {
                return scroll
            }
            return view.subviews.lazy.compactMap { self.horizontalScrollView(in: $0) }.first
        }
    }

    @MainActor private final class KeyboardFixtureState: ObservableObject {
        @Published var text = ""
        @Published var width: CGFloat = 390
        @Published var enabled = true
        @Published var showRichResponse = false
    }
    private struct KeyboardNavigationFixture: View {
        @ObservedObject var state: KeyboardFixtureState
        var body: some View {
            NavigationView {
                KeyboardFixture(state: state)
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
            }.navigationViewStyle(.stack)
        }
    }
    private struct KeyboardFixture: View {
        @ObservedObject var state: KeyboardFixtureState
        private let history = (0..<20).map { index in
            Message(
                id: "history-\(index)", role: index.isMultiple(of: 2) ? .user : .assistant,
                content: String(repeating: "Earlier conversation message \(index). ", count: index % 5 + 1),
                metadata: [:])
        }
        private let message = Message(
            id: "form", role: .assistant, content: "Travel details",
            metadata: [
                "richContent": AnySendable([
                    "form": [
                        "title": "Travel booking",
                        "fields": [
                            ["id": "from", "type": "input", "label": "From", "required": true],
                            ["id": "to", "type": "input", "label": "To", "required": true],
                        ],
                    ]
                ])
            ])
        private var richMessage: Message {
            let operators = ["Kaveri Express", "Orange Tours", "VRL Premium", "SRS Connect", "Morning Star", "GreenLine"]
            return Message(id: "bus-prices", role: .assistant, content: "Bus Fare List", metadata: [
                "richContent": AnySendable([
                    "list": [
                        "title": "Bus options",
                        "items": operators.map { ["title": $0, "subtitle": "Sleeper AC · 22:15 to 06:10 · INR 1,450"] },
                    ],
                    "table": [
                        "columns": [
                            ["key": "operator", "header": "Operator"], ["key": "seat", "header": "Seat"],
                            ["key": "time", "header": "Time"], ["key": "fare", "header": "Fare"],
                        ],
                        "rows": operators.map { ["operator": $0, "seat": "Sleeper AC", "time": "22:15", "fare": "INR 1,450"] },
                    ],
                ])
            ])
        }
        private var messages: [Message] { history + (state.showRichResponse ? [richMessage] : []) + [message] }
        var body: some View {
            VStack(spacing: 0) {
                ChatHeaderView(title: "Agent Chat", theme: nil, onClose: {}, statusText: "Connected")
                ChatHistoryScrollView(
                    request: ChatHistoryScrollRequest(messageCount: messages.count, isTyping: false, revision: 0)
                ) { width in
                    ForEach(messages) { earlier in
                        MessageBubble(
                            message: earlier, rowWidth: width, fonts: nil, theme: nil, templateRegistry: nil,
                            onSubmitAction: { _, _, _, _ in }, onSubmitFeedback: { _, _, _, _ in },
                            attachments: [], resolveAttachment: { _ in nil })
                    }
                }
                ChatFooterView(
                    text: $state.text, enabled: state.enabled, canSend: state.enabled && !state.text.isEmpty, placeholder: "Message", font: nil,
                    theme: nil, onSend: {}, onAttach: {}, showAttachment: true)
            }.frame(width: state.width)
        }
    }
#endif
