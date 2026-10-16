import SwiftUI

enum TemplateStyle {
    static let sectionSpacing: CGFloat = 14
    static let cardRadius: CGFloat = 18
    static let smallRadius: CGFloat = 12
    static let imageRadius: CGFloat = 14

    static let text = Color(red: 0.12, green: 0.13, blue: 0.16)
    static let mutedText = Color(red: 0.43, green: 0.50, blue: 0.61)
    static let border = Color(red: 0.88, green: 0.90, blue: 0.93)
    static let placeholder = Color(red: 0.90, green: 0.93, blue: 0.96)
    static let kpiBackground = Color(red: 0.94, green: 0.97, blue: 1.0)
    static let progressTrack = Color(red: 0.40, green: 0.47, blue: 0.57)
    static let success = Color(red: 0.10, green: 0.62, blue: 0.38)
}

struct TemplatePalette {
    let theme: ChatTheme?
    var sectionSpacing: CGFloat { 14 * (theme?.spacingScale ?? 1) }
    var cardRadius: CGFloat { theme.map { CGFloat($0.borderRadius) } ?? 18 }
    var smallRadius: CGFloat { min(cardRadius, 12) }
    var imageRadius: CGFloat { min(cardRadius, 14) }
    var text: Color { theme.map { Color(hexString: $0.textColor) } ?? TemplateStyle.text }
    var mutedText: Color {
        theme.map { Color(hexString: $0.mutedTextColor) } ?? TemplateStyle.mutedText
    }
    var border: Color { theme.map { Color(hexString: $0.borderColor) } ?? TemplateStyle.border }
    var placeholder: Color {
        theme.map { Color(hexString: $0.surfaceColor) } ?? TemplateStyle.placeholder
    }
    var kpiBackground: Color {
        theme.map { Color(hexString: $0.surfaceColor) } ?? TemplateStyle.kpiBackground
    }
    var progressTrack: Color { border }
    var success: Color { TemplateStyle.success }
}

/// Compact controls used by the WebSDK's quick-reply and action renderers.
struct TemplateControlButtonStyle: ButtonStyle {
    enum Variant { case quickReply, action, submit }
    @Environment(\.chatTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false
    let accentColor: Color
    let variant: Variant
    var isSelected = false

    private var palette: TemplatePalette { TemplatePalette(theme: theme) }
    private var scale: CGFloat { theme?.spacingScale ?? 1 }

    func makeBody(configuration: Configuration) -> some View {
        let active = isEnabled && (isHovered || configuration.isPressed)
        configuration.label
            .font(
                theme?.font(size: 13, weight: variant == .quickReply ? .medium : .regular)
                    ?? .system(size: 13, weight: variant == .quickReply ? .medium : .regular)
            )
            .foregroundStyle(
                variant == .submit && !isEnabled
                    ? palette.text.opacity(0.72)
                    : (variant == .submit || (variant == .action && active) ? Color.white : accentColor)
            )
            .lineLimit(variant == .quickReply ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14 * scale)
            .padding(.vertical, (variant == .quickReply ? 8 : 7) * scale)
            .frame(minHeight: (variant == .quickReply ? 36 : 40) * scale)
            .frame(maxWidth: variant == .submit ? .infinity : nil)
            .background {
                if variant == .quickReply {
                    Color(hexString: "#6366F1").opacity(active ? 0.14 : 0.08)
                } else if variant == .submit, !isEnabled {
                    Color(hexString: theme?.backgroundColor ?? "#FFFFFF")
                    palette.text.opacity(0.18)
                } else if variant == .submit || active {
                    accentColor.opacity(configuration.isPressed ? 0.85 : 1)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: variant == .quickReply ? 999 : 18))
            .overlay {
                RoundedRectangle(cornerRadius: variant == .quickReply ? 999 : 18)
                    .stroke(
                        variant == .quickReply
                            ? Color(hexString: "#6366F1").opacity(active ? 0.28 : 0.18)
                            : (variant == .submit && !isEnabled ? palette.border : accentColor),
                        lineWidth: 1)
            }
            .opacity(variant == .submit || (isEnabled && !isSelected) ? 1 : 0.5)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .onHover { isHovered = $0 }
    }
}

/// Content-sized wrapping rows, including a measured fallback for iOS 15/macOS 12.
struct TemplateFlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let verticalSpacing: CGFloat
    let content: (Item) -> Content

    init(
        _ items: [Item], spacing: CGFloat, verticalSpacing: CGFloat? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) {
        self.items = items
        self.spacing = spacing
        self.verticalSpacing = verticalSpacing ?? spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 16.0, macOS 13.0, *) {
            TemplateWrappingLayout(spacing: spacing, verticalSpacing: verticalSpacing) {
                ForEach(items, content: content)
            }
        } else {
            LegacyTemplateFlowRow(items: items, spacing: spacing, verticalSpacing: verticalSpacing, content: content)
        }
    }
}

@available(iOS 16.0, macOS 13.0, *)
private struct TemplateWrappingLayout: Layout {
    let spacing: CGFloat
    let verticalSpacing: CGFloat

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let ideal = view.sizeThatFits(.unspecified)
            let size = view.sizeThatFits(ProposedViewSize(width: min(ideal.width, width), height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
        let frames = frames(width: width ?? .greatestFiniteMagnitude, subviews: subviews)
        return CGSize(
            width: width ?? frames.map(\.maxX).max() ?? 0,
            height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct TemplateFlowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
private struct TemplateFlowSizeKey<ID: Hashable>: PreferenceKey {
    static var defaultValue: [ID: CGSize] { [:] }
    static func reduce(value: inout [ID: CGSize], nextValue: () -> [ID: CGSize]) {
        value.merge(nextValue()) { _, new in new }
    }
}
private struct LegacyTemplateFlowRow<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let spacing: CGFloat
    let verticalSpacing: CGFloat
    let content: (Item) -> Content
    @State private var width: CGFloat = 0
    @State private var sizes: [Item.ID: CGSize] = [:]

    private var rows: [[Item]] {
        guard width > 0, !sizes.isEmpty else { return items.map { [$0] } }
        var rows: [[Item]] = []
        var row: [Item] = []
        var used: CGFloat = 0
        for item in items {
            let itemWidth = min(sizes[item.id]?.width ?? width, width)
            let gap = row.isEmpty ? 0 : spacing
            if !row.isEmpty, used + gap + itemWidth > width {
                rows.append(row)
                row = []
                used = 0
            }
            used += (row.isEmpty ? 0 : spacing) + itemWidth
            row.append(item)
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: verticalSpacing) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: spacing) {
                    ForEach(row, content: content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear.preference(key: TemplateFlowWidthKey.self, value: proxy.size.width)
            }
        }
        .overlay(alignment: .topLeading) {
            ZStack {
                ForEach(items) { item in
                    content(item).fixedSize().background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: TemplateFlowSizeKey<Item.ID>.self, value: [item.id: proxy.size])
                        }
                    }
                }
            }
            .hidden().allowsHitTesting(false).accessibilityHidden(true)
        }
        .onPreferenceChange(TemplateFlowWidthKey.self) { width = $0 }
        .onPreferenceChange(TemplateFlowSizeKey<Item.ID>.self) { sizes = $0 }
    }
}

private struct TemplateCardModifier: ViewModifier {
    @Environment(\.chatTheme) private var theme
    let padding: CGFloat
    func body(content: Content) -> some View {
        content.padding(padding * (theme?.spacingScale ?? 1)).frame(
            maxWidth: .infinity, alignment: .leading
        )
        .background(Color(hexString: theme?.surfaceColor ?? "#FFFFFF"))
        .clipShape(RoundedRectangle(cornerRadius: theme?.borderRadius ?? 18))
        .overlay(
            RoundedRectangle(cornerRadius: theme?.borderRadius ?? 18).stroke(
                Color(hexString: theme?.borderColor ?? "#E2E8F0"), lineWidth: 1))
    }
}
private struct TemplateTextModifier: ViewModifier {
    @Environment(\.chatTheme) private var theme
    let size: CGFloat
    let weight: Font.Weight
    let muted: Bool
    func body(content: Content) -> some View {
        content.font(theme?.font(size: size, weight: weight) ?? .system(size: size, weight: weight))
            .foregroundStyle(
                Color(hexString: muted ? theme?.mutedTextColor ?? "#64748B" : theme?.textColor ?? "#1E293B")
            )
    }
}
extension View {
    func templateCard(padding: CGFloat = 14) -> some View {
        modifier(TemplateCardModifier(padding: padding))
    }
    func templateTitle() -> some View {
        modifier(TemplateTextModifier(size: 17, weight: .bold, muted: false))
    }
    func templateBody() -> some View {
        modifier(TemplateTextModifier(size: 15, weight: .regular, muted: true))
    }
    func templateSectionLabel() -> some View {
        modifier(TemplateTextModifier(size: 14, weight: .bold, muted: true))
    }
    func outlinedPill(accentColor: Color) -> some View {
        templateTitle().foregroundStyle(accentColor).padding(.horizontal, 16).frame(minHeight: 44)
            .overlay(Capsule().stroke(accentColor, lineWidth: 1.5)).clipShape(Capsule())
    }
    func templateInputBorder(accentColor: Color, focused: Bool) -> some View {
        templateCard(padding: 14)
    }
    func templateTextField(accentColor: Color) -> some View {
        templateBody().templateCard(padding: 14).frame(minHeight: 44)
    }
    @ViewBuilder func formKeyboardType(_ inputType: String?) -> some View {
        #if os(iOS)
            switch inputType {
            case "number": keyboardType(.decimalPad)
            case "email": keyboardType(.emailAddress)
            case "phone": keyboardType(.phonePad)
            default: self
            }
        #else
            self
        #endif
    }
}
