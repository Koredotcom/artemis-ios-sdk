import SwiftUI

struct ChatHeaderView: View {
    @Environment(\.chatStrings) private var strings
    let title: String
    let theme: ChatTheme?
    let onClose: () -> Void
    var statusText: String = ""
    var onMinimize: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            Text(String(title.trimmingCharacters(in: .whitespaces).first ?? "A"))
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .background(headerText.opacity(0.2), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(
                    theme?.font(size: 17, weight: .semibold) ?? .system(size: 17, weight: .semibold)
                ).lineLimit(1)
                Text(statusText).font(.system(size: 11)).opacity(0.85).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                if let onMinimize { control("minus", label: "Minimize chat", action: onMinimize) }
                control("xmark", label: "Close chat", action: onClose)
            }
        }
        .foregroundStyle(headerText)
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8 * (theme?.spacingScale ?? 1))
        .frame(minHeight: 64)
        .background(Color(hexString: theme?.headerBackgroundColor))
    }
    private func control(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 18)).frame(width: 48, height: 48).contentShape(
                Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(strings(label))
    }
    private var headerText: Color { Color(hexString: theme?.headerTextColor ?? "#FFFFFF") }
}
