import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct ChannelFallbackTemplate: View {
    @Environment(\.chatTheme) private var theme
    @Environment(\.chatStrings) private var strings
    let item: ChannelFallbackItem

    private var palette: TemplatePalette { TemplatePalette(theme: theme) }
    private var spacingScale: CGFloat { theme?.spacingScale ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * spacingScale) {
            Text(strings(channelTitle))
                .font(theme?.font(size: 13.6, weight: .semibold) ?? .system(size: 13.6, weight: .semibold))
                .foregroundStyle(palette.text)
            Text(verbatim: preview)
                .font(theme?.font(size: 12.8) ?? .system(size: 12.8))
                .foregroundStyle(palette.mutedText)
                .lineSpacing(3.2 * CGFloat((theme?.baseFontSize ?? 16) / 16))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12 * spacingScale)
        .padding(.vertical, 10 * spacingScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.text.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var preview: String {
        ChannelFallbackPreview.extract(item.payload)
            ?? strings(
                "This response includes rich content optimized for another channel and is shown here in a safe fallback view."
            )
    }

    private var channelTitle: String {
        switch item.type {
        case "adaptive_card": return "Adaptive Card payload"
        case "slack": return "Slack Block Kit payload"
        case "ag_ui": return "AG-UI payload"
        case "whatsapp": return "WhatsApp payload"
        default: return "Channel fallback payload"
        }
    }
}

/// Matches the WebSDK's structured-preview helper: up to three text fields and 160 visible characters.
enum ChannelFallbackPreview {
    private static let textKeys: Set<String> = [
        "text", "title", "subtitle", "label", "prompt", "description", "alt", "altText", "speak",
    ]
    private static let tokens = try? NSRegularExpression(
        pattern: #""(?:\\.|[^"\\])*"|[{}\[\]:,]|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|true|false|null"#)

    static func extract(_ payload: String) -> String? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return truncate(trimmed) }
        guard trimmed.utf8.count <= 100_000,
            (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) != nil,
            let tokens
        else { return nil }

        // Foundation validates JSON; reading its tokens preserves object field order,
        // which JSONSerialization's unordered dictionaries cannot guarantee.
        let pieces = tokens.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap {
            Range($0.range, in: trimmed).map { String(trimmed[$0]) }
        }
        var reader = Reader(tokens: pieces)
        reader.collect()
        return reader.segments.isEmpty ? nil : truncate(reader.segments.joined(separator: " • "))
    }

    private static func truncate(_ value: String) -> String {
        value.count <= 160 ? value : String(value.prefix(159)) + "…"
    }

    private struct Reader {
        let tokens: [String]
        var index = 0
        var segments: [String] = []
        private let decoder = JSONDecoder()

        init(tokens: [String]) { self.tokens = tokens }

        mutating func collect(allowString: Bool = false, depth: Int = 0) {
            guard segments.count < 3, index < tokens.count else { return }
            guard depth < 64 else {
                index = tokens.count
                return
            }
            let token = tokens[index]
            index += 1
            switch token {
            case "{":
                while index < tokens.count, tokens[index] != "}", segments.count < 3 {
                    let key = decode(tokens[index])
                    index += 2  // Key and colon; the JSON was already validated.
                    collect(allowString: key.map { textKeys.contains($0) } ?? false, depth: depth + 1)
                    if index < tokens.count, tokens[index] == "," { index += 1 }
                }
                if index < tokens.count, tokens[index] == "}" { index += 1 }
            case "[":
                while index < tokens.count, tokens[index] != "]", segments.count < 3 {
                    collect(allowString: allowString, depth: depth + 1)
                    if index < tokens.count, tokens[index] == "," { index += 1 }
                }
                if index < tokens.count, tokens[index] == "]" { index += 1 }
            default:
                if allowString, let text = decode(token)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !text.isEmpty
                {
                    segments.append(text)
                }
            }
        }

        private func decode(_ token: String) -> String? {
            guard token.hasPrefix("\"") else { return nil }
            return try? decoder.decode(String.self, from: Data(token.utf8))
        }
    }
}
