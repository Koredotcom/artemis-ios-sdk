import SwiftUI
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

struct ChatFooterView: View {
    private static let defaultBorderRadius: Double = 16

    @Environment(\.chatStrings) private var strings
    @Binding var text: String
    let enabled: Bool
    let canSend: Bool
    let placeholder: String
    let font: String?
    let theme: ChatTheme?
    let onSend: () -> Void
    let onAttach: () -> Void
    var showAttachment: Bool = false
    var canAttach: Bool = true

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if showAttachment {
                control(
                    "paperclip", label: "Add attachment", enabled: enabled && canAttach,
                    action: onAttach)
            }
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(composerFont)
                        .foregroundStyle(placeholderColor)
                        .padding(.leading, 0)
                        .allowsHitTesting(false)
                }
                #if canImport(UIKit)
                    GrowingChatInput(
                        text: $text, enabled: enabled, font: font ?? theme?.fontFamily,
                        color: UIColor(composerTextColor),
                        onSend: onSend,
                        accessibilityLabel: strings("Message"), fontSize: theme?.baseFontSize ?? 16
                    )
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .fixedSize(horizontal: false, vertical: true)
                #else
                    TextEditor(text: $text)
                        .disabled(!enabled)
                        .font(composerFont)
                        .frame(height: 40)
                #endif
            }
            .frame(maxWidth: .infinity)
            control("paperplane", label: "Send message", enabled: canSend, action: onSend)
        }
        .padding(.horizontal, composerPaddingX)
        .padding(.vertical, composerPaddingY)
        .background(Color(hexString: theme?.composeBarBackgroundColor ?? "#FFFFFF"))
        .overlay(
            RoundedRectangle(cornerRadius: 40)
                .stroke(Color(hexString: theme?.borderColor ?? "#E2E8F0"), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 40))
        .padding(.horizontal, composerMargin)
        .padding(.vertical, 5)
        .background(Color(hexString: theme?.backgroundColor ?? "#FFFFFF"))
    }

    private func control(_ icon: String, label: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        let isAttachment = icon == "paperclip"
        let iconColor = isAttachment ? attachmentIconColor : sendButtonForeground
        let buttonBackground = isAttachment ? Color.clear : sendButtonBackground
        let iconSize: CGFloat = isAttachment ? 16 : 14
        return Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .frame(width: 32, height: 32)
                .foregroundStyle(iconColor)
                .background(buttonBackground, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityLabel(strings(label))
        .fixedSize()
    }

    private var composerFont: Font {
        if let font, !font.isEmpty {
            return .custom(font, size: theme?.baseFontSize ?? 16)
        }
        return theme?.font() ?? .system(size: 16)
    }

    private var composerTextColor: Color {
        Color(hexString: theme?.composeBarTextColor ?? theme?.textColor ?? "#1F2937")
    }

    private var placeholderColor: Color {
        Color(hexString: theme?.composeBarPlaceholderColor ?? theme?.mutedTextColor ?? "#6B7280")
    }

    private var attachmentIconColor: Color {
        Color(hexString: theme?.mutedTextColor ?? "#6B7280")
    }

    private var composerMargin: CGFloat {
        switch theme?.density {
        case "compact": return 14
        case "spacious": return 18
        default: return 16
        }
    }

    private var composerPaddingX: CGFloat {
        switch theme?.density {
        case "compact": return 14
        case "spacious": return 18
        default: return 16
        }
    }

    private var composerPaddingY: CGFloat {
        switch theme?.density {
        case "compact": return 8
        case "spacious": return 13
        default: return 10
        }
    }

    private var baseBorderRadius: CGFloat {
        let configuredRadius = theme?.borderRadius ?? Self.defaultBorderRadius
        let radius = configuredRadius.isFinite
            ? min(40, max(0, configuredRadius))
            : Self.defaultBorderRadius
        return CGFloat(radius)
    }

    private var composerRadius: CGFloat { baseBorderRadius + 6 }

    private var sendButtonBackground: Color {
        Color(hexString: theme?.headerBackgroundColor ?? theme?.primaryColor ?? "#0066FF")
    }

    private var sendButtonForeground: Color {
        readableTextColor(on: theme?.headerBackgroundColor ?? theme?.primaryColor ?? "#0066FF")
    }

    private func readableTextColor(on background: String) -> Color {
        let hex = background.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard hex.count == 3 || hex.count == 6 else { return .white }
        let normalizedHex: String
        if hex.count == 3 {
            normalizedHex = hex.map { "\($0)\($0)" }.joined()
        } else {
            normalizedHex = hex
        }
        guard let value = UInt64(normalizedHex, radix: 16) else {
            return .white
        }
        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        let darkContrast = (luminance + 0.05) / (0.005 + 0.05)
        let whiteContrast = 1.05 / (luminance + 0.05)
        return darkContrast >= whiteContrast ? Color(hexString: "#111827") : .white
    }
}

#if canImport(UIKit)
    private struct GrowingChatInput: UIViewRepresentable {
        @Binding var text: String
        let enabled: Bool
        let font: String?
        let color: UIColor
        let onSend: () -> Void
        var accessibilityLabel: String = "Message"
        var fontSize: Double = 16
        func makeCoordinator() -> Coordinator { Coordinator(self) }
        func makeUIView(context: Context) -> ComposerTextView {
            let view = ComposerTextView()
            view.backgroundColor = .clear
            view.delegate = context.coordinator
            view.textContainerInset = UIEdgeInsets(top: 5, left: 0, bottom: 5, right: 0)
            view.textContainer.lineFragmentPadding = 0
            view.returnKeyType = .send
            view.accessibilityLabel = accessibilityLabel
            view.isScrollEnabled = true
            view.showsVerticalScrollIndicator = false
            view.isEditable = enabled
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            return view
        }
        func updateUIView(_ view: ComposerTextView, context: Context) {
            context.coordinator.parent = self
            view.accessibilityLabel = accessibilityLabel
            var sizeChanged = false
            if view.text != text {
                view.text = text
                sizeChanged = true
            }
            context.coordinator.updateEditingAvailability(of: view)
            if view.textColor != color { view.textColor = color }
            let resolvedFont =
                font.flatMap { UIFont(name: $0, size: fontSize) } ?? .systemFont(ofSize: fontSize)
            if view.font != resolvedFont {
                view.font = resolvedFont
                sizeChanged = true
            }
            if sizeChanged { view.invalidateIntrinsicContentSize() }
        }
        @available(iOS 16.0, *)
        func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerTextView, context: Context)
            -> CGSize?
        {
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
            func textView(
                _ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String
            ) -> Bool {
                if text == "\n" {
                    view.resignFirstResponder()
                    if parent.enabled { parent.onSend() }
                    return false
                }
                return parent.enabled
            }
        }
    }
    private final class ComposerTextView: UITextView {
        private var lastWidth: CGFloat = 0
        func measuredHeight(for width: CGFloat) -> CGFloat {
            guard width.isFinite, width > 0 else { return 40 }
            return min(
                120,
                max(
                    30,
                    ceil(super.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)))
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
