import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct CarouselRichTemplate: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var chatTheme
    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    let carousel: CarouselTemplate
    let accentColor: Color
    let submitAction: (String, String?, [String: String]?, String?) -> Void
    let renderId: String?
    var context: RichTemplateContext? = nil
    @State private var localSelectedCardIndex: Int?
    @State private var error: String?
    @State private var maxCardHeight: CGFloat = 0
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var cardLayoutKey: String {
        let fontKey = "\(chatTheme?.fontFamily ?? "System")-\(chatTheme?.baseFontSize ?? 16)-\(dynamicTypeSize)"
        return carousel.cards.map { card in
            var components = [
                fontKey, card.title, card.subtitle ?? "", card.imageURL ?? "", card.defaultActionURL ?? "",
            ]
            for button in card.buttons {
                components.append(contentsOf: [button.id, button.label, button.value ?? "", button.url ?? ""])
            }
            return components.joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(carousel.cards.enumerated()), id: \.offset) { cardIndex, card in
                        let isSelectedCard = effectiveSelectedCardIndex == cardIndex
                        VStack(alignment: .leading, spacing: 0) {
                            if let image = card.imageURL, let url = URL(string: image) {
                                TemplateRemoteImage(url: url) { loaded in
                                    loaded.resizable().scaledToFill()
                                } placeholder: {
                                    templateStyle.placeholder
                                }
                                .frame(width: 220, height: 130)
                                .clipped()
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(card.title)
                                        .templateTitle()
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let subtitle = card.subtitle, !subtitle.templateTrimmed.isEmpty {
                                        Text(subtitle)
                                            .templateBody()
                                            .lineLimit(3)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .leading, spacing: 10) {
                                    if let rawURL = card.defaultActionURL, let url = URL(string: rawURL), url.isHTTP {
                                        Link("Open", destination: url).outlinedPill(accentColor: accentColor)
                                    }
                                    ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                                        Button(button.label) {
                                            if let raw = button.url, let url = URL(string: raw), url.isHTTP {
                                                openURL(url)
                                            } else {
                                                guard effectiveSelectedCardIndex == nil else { return }
                                                localSelectedCardIndex = cardIndex
                                                error = nil
                                                let displayFallback = button.value.flatMap { $0.isEmpty ? nil : $0 }
                                                    ?? button.id
                                                let displayText = button.label.templateTrimmed.isEmpty
                                                    ? displayFallback : button.label.templateTrimmed
                                                Task {
                                                    do {
                                                        if let context {
                                                            try await context.perform(
                                                                button.id, value: button.value ?? button.id,
                                                                renderId: renderId, displayText: displayText)
                                                        } else {
                                                            submitAction(button.id, button.value ?? button.id, nil, renderId)
                                                        }
                                                    } catch {
                                                        localSelectedCardIndex = nil
                                                        self.error = strings("Action could not be sent. Please retry.")
                                                    }
                                                }
                                            }
                                        }
                                        .buttonStyle(
                                            OutlinedPillButtonStyle(
                                                accentColor: accentColor,
                                                expandsToFullWidth: false,
                                                horizontalPadding: 12,
                                                minHeight: 34)
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                            .padding(.top, 14)
                            .padding(.bottom, 8)
                        }
                        .frame(
                            width: 220, height: maxCardHeight > 0 ? maxCardHeight : nil,
                            alignment: .topLeading)
                        .templateCard(padding: 0)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: CarouselCardHeightPreferenceKey.self, value: geometry.size.height)
                            }
                        }
                        .disabled(effectiveSelectedCardIndex != nil)
                        .opacity(isSelectedCard ? 0.5 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isSelectedCard)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(CarouselCardHeightPreferenceKey.self) { height in
            guard height > 0, abs(maxCardHeight - height) > 0.5 else { return }
            maxCardHeight = height
        }
        .onChange(of: cardLayoutKey) { _ in
            maxCardHeight = 0
        }
    }

    private var submittedCardIndex: Int? {
        let submittedIds = Set(context?.submittedActionIds ?? [])
        return carousel.cards.firstIndex { card in
            card.buttons.contains { submittedIds.contains($0.id) }
        }
    }

    private var effectiveSelectedCardIndex: Int? {
        localSelectedCardIndex ?? submittedCardIndex
    }
}

private struct CarouselCardHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
