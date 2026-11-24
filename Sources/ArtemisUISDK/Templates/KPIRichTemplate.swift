import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct KPIRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    let kpi: KPITemplate

    private let cardRadius: CGFloat = 16

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let iconURL {
                TemplateRemoteImage(url: iconURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            }

            Text(kpi.label.uppercased())
                .font(webFont(size: 12, weight: .semibold))
                .tracking(0.24)
                .foregroundStyle(Color(hexString: chatTheme?.mutedTextColor ?? "#6B7280"))

            Text(kpi.displayValue)
                .font(webFont(size: 28, weight: .bold))
                .tracking(-0.84)
                .lineSpacing(-2)
                .foregroundStyle(Color(hexString: chatTheme?.textColor ?? "#1F2937"))
                .fixedSize(horizontal: false, vertical: true)

            if let trend = trendValue {
                Text(trendArrow(for: trend))
                    .font(webFont(size: 12, weight: .semibold))
                    .foregroundStyle(trendForeground(for: trend))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(trendBackground(for: trend), in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius)
                .stroke(cardBorder, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius))
        .padding(.top, 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kpi.label): \(kpi.displayValue)")
    }

    private var iconURL: URL? {
        guard let rawURL = kpi.iconURL,
            let url = URL(string: rawURL), url.isHTTP, url.user == nil, url.password == nil
        else { return nil }
        return url
    }

    private var trendValue: String? {
        guard let trend = kpi.trend?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trend.isEmpty
        else { return nil }
        return trend
    }

    private var primaryHex: String { chatTheme?.primaryColor ?? "#6366F1" }
    private var backgroundHex: String { chatTheme?.backgroundColor ?? "#FFFFFF" }
    private var surfaceHex: String { chatTheme?.surfaceColor ?? "#F3F4F6" }
    private var borderHex: String { chatTheme?.borderColor ?? "#E5E7EB" }

    private var cardBackground: LinearGradient {
        LinearGradient(
            colors: [
                mixedColor(primaryHex, weight: 0.08, with: backgroundHex),
                mixedColor(surfaceHex, weight: 0.94, with: backgroundHex),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var cardBorder: Color {
        mixedColor(borderHex, weight: 0.70, with: primaryHex)
    }

    private func webFont(size: CGFloat, weight: Font.Weight) -> Font {
        guard let family = chatTheme?.fontFamily, family != "System", !family.isEmpty else {
            return .system(size: size, weight: weight)
        }
        return .custom(family, size: size).weight(weight)
    }

    private func trendArrow(for trend: String) -> String {
        switch trend {
        case "up": return "↑"
        case "down": return "↓"
        case "flat": return "→"
        default: return ""
        }
    }

    private func trendForeground(for trend: String) -> Color {
        switch trend {
        case "up": return Color(hexString: "#15803D")
        case "down": return Color(hexString: "#DC2626")
        case "flat": return Color(hexString: chatTheme?.mutedTextColor ?? "#6B7280")
        default: return Color(hexString: chatTheme?.textColor ?? "#1F2937")
        }
    }

    private func trendBackground(for trend: String) -> Color {
        switch trend {
        case "up":
            return Color(
                red: 34.0 / 255, green: 197.0 / 255, blue: 94.0 / 255
            ).opacity(0.12)
        case "down":
            return Color(
                red: 239.0 / 255, green: 68.0 / 255, blue: 68.0 / 255
            ).opacity(0.12)
        case "flat":
            return Color(
                red: 148.0 / 255, green: 163.0 / 255, blue: 184.0 / 255
            ).opacity(0.16)
        default: return .clear
        }
    }

    private func mixedColor(_ firstHex: String, weight: Double, with secondHex: String) -> Color {
        let first = rgb(firstHex) ?? (1, 1, 1)
        let second = rgb(secondHex) ?? (1, 1, 1)
        return Color(
            red: first.0 * weight + second.0 * (1 - weight),
            green: first.1 * weight + second.1 * (1 - weight),
            blue: first.2 * weight + second.2 * (1 - weight)
        )
    }

    private func rgb(_ color: String) -> (Double, Double, Double)? {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        let expandedHex: String
        if hex.count == 3 {
            expandedHex = hex.map { "\($0)\($0)" }.joined()
        } else if hex.count == 6 {
            expandedHex = hex
        } else if hex.count == 8 {
            expandedHex = String(hex.suffix(6))
        } else {
            return nil
        }
        guard let value = UInt64(expandedHex, radix: 16) else { return nil }
        return (
            Double((value >> 16) & 0xFF) / 255,
            Double((value >> 8) & 0xFF) / 255,
            Double(value & 0xFF) / 255
        )
    }
}
