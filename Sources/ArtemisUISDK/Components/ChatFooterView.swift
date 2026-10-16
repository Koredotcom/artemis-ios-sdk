import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct ChatFooterView: View {
    @Binding var text: String
    let enabled: Bool
    let canSend: Bool
    let placeholder: String
    let font: String?
    let theme: ChatTheme?
    let onSend: () -> Void
    let onAttach: () -> Void
    var showAttachment: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            Color(hexString: theme?.borderColor ?? "#E2E8F0").frame(height: 1)
            HStack(alignment: .bottom, spacing: 8) {
                if showAttachment { control("paperclip", label: "Add attachment", enabled: enabled, action: onAttach) }
                ZStack(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder).foregroundStyle(Color(hexString: theme?.mutedTextColor ?? "#64748B")).padding(
                            .horizontal, 14
                        ).padding(.top, 10).allowsHitTesting(false)
                    }
                    #if canImport(UIKit)
                        GrowingChatInput(
                            text: $text, enabled: enabled, font: font,
                            color: UIColor(Color(hexString: theme?.textColor)), onSend: onSend
                        )
                        .frame(maxWidth: .infinity)
                        .fixedSize(horizontal: false, vertical: true)
                    #else
                        TextEditor(text: $text).disabled(!enabled).frame(height: 60).opacity(text.isEmpty ? 0.5 : 1)
                    #endif
                }
                .font(.system(size: 16))
                .background(Color(hexString: theme?.composeBarBackgroundColor ?? "#FFFFFF"))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(hexString: theme?.borderColor ?? "#E2E8F0")))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                control("paperplane", label: "Send message", enabled: canSend, action: onSend)
            }
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .background(Color(hexString: theme?.backgroundColor ?? "#FFFFFF"))
    }
    private func control(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 40, height: 40)
                .foregroundStyle(Color(hexString: theme?.primaryColor ?? "#2563EB"))
                .background(
                    Color(hexString: theme?.composeBarBackgroundColor ?? "#FFFFFF"),
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hexString: theme?.borderColor ?? "#E2E8F0")))
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.4).accessibilityLabel(label)
    }
}

#if canImport(UIKit)
    private struct GrowingChatInput: UIViewRepresentable {
        @Binding var text: String
        let enabled: Bool
        let font: String?
        let color: UIColor
        let onSend: () -> Void
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeUIView(context: Context) -> ComposerTextView {
            let view = ComposerTextView()
            view.backgroundColor = .clear
            view.delegate = context.coordinator
            view.textContainerInset = UIEdgeInsets(top: 9, left: 10, bottom: 9, right: 10)
            view.returnKeyType = .send
            view.accessibilityLabel = "Message"
            view.isScrollEnabled = true
            view.showsVerticalScrollIndicator = false
            view.isEditable = enabled
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            return view
        }
        func updateUIView(_ view: ComposerTextView, context: Context) {
            context.coordinator.parent = self
            var sizeChanged = false
            if view.text != text {
                view.text = text
                sizeChanged = true
            }
            context.coordinator.updateEditingAvailability(of: view)
            if view.textColor != color { view.textColor = color }
            let resolvedFont = font.flatMap { UIFont(name: $0, size: 16) } ?? .systemFont(ofSize: 16)
            if view.font != resolvedFont {
                view.font = resolvedFont
                sizeChanged = true
            }
            if sizeChanged { view.invalidateIntrinsicContentSize() }
        }
        @available(iOS 16.0, *)
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context) -> CGSize? {
            guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
            return CGSize(width: width, height: uiView.measuredHeight(for: width))
        }
        final class Coordinator: NSObject, UITextViewDelegate {
            var parent: GrowingChatInput
            private var editingUpdateScheduled = false
            init(_ parent: GrowingChatInput) { self.parent = parent }
            func updateEditingAvailability(of view: UITextView) {
                guard view.isEditable != parent.enabled, !editingUpdateScheduled else { return }
                editingUpdateScheduled = true
                // setEditable(false) resigns first responder. Doing that inside
                // updateUIView reenters SwiftUI's responder/layout graph.
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self else { return }
                    self.editingUpdateScheduled = false
                    guard let view, view.isEditable != self.parent.enabled else { return }
                    view.isEditable = self.parent.enabled
                }
            }
            func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { parent.enabled }
            func textViewDidChange(_ view: UITextView) {
                if parent.text != view.text { parent.text = view.text }
                view.invalidateIntrinsicContentSize()
            }
            func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
                guard parent.enabled else { return false }
                if text == "\n" {
                    parent.onSend()
                    return false
                }
                return true
            }
        }
    }
    private final class ComposerTextView: UITextView {
        private var lastWidth: CGFloat = 0
        func measuredHeight(for width: CGFloat) -> CGFloat {
            guard width.isFinite, width > 0 else { return 40 }
            return min(
                120, max(40, ceil(super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)))
        }
        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight(for: bounds.width))
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            // iOS 16+ measures from SwiftUI's proposal. On iOS 15, invalidate
            // UIKit's intrinsic size after width changes without writing SwiftUI state.
            if #available(iOS 16.0, *) { return }
            guard bounds.width != lastWidth else { return }
            lastWidth = bounds.width
            DispatchQueue.main.async { [weak self] in self?.invalidateIntrinsicContentSize() }
        }
    }
#endif
