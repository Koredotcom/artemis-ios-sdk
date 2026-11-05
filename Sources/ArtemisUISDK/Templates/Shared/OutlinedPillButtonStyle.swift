import SwiftUI

struct OutlinedPillButtonStyle: ButtonStyle {
    @Environment(\.chatTheme) private var theme
    let accentColor: Color
    var isSelected = false
    var expandsToFullWidth = true
    var horizontalPadding: CGFloat = 16
    var minHeight: CGFloat = 42

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(accentColor)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .frame(maxWidth: expandsToFullWidth ? .infinity : nil)
            .background(
                (isSelected ? accentColor.opacity(0.18) : Color.clear).opacity(
                    configuration.isPressed ? 0.8 : 1)
            )
            .overlay(Capsule().stroke(accentColor, lineWidth: 1.5))
            .clipShape(Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
