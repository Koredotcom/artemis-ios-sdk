import SwiftUI

struct FilledCapsuleButtonStyle: ButtonStyle {
    @Environment(\.chatTheme) private var theme
    let accentColor: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme?.font(size: 16, weight: .semibold) ?? .system(size: 16, weight: .semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 20)
            .frame(minHeight: 50 * (theme?.spacingScale ?? 1))
            .frame(maxWidth: .infinity)
            .background(
                (isEnabled ? accentColor : accentColor.opacity(0.45)).opacity(
                    configuration.isPressed ? 0.78 : 1)
            )
            .clipShape(Capsule())
    }
}
