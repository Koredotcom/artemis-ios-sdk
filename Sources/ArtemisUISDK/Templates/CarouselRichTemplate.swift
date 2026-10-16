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
    let renderId: String
    var context: RichTemplateContext? = nil
    @State private var selected: String?
    @State private var pending = false
    @State private var error: String?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(carousel.cards.enumerated()), id: \.offset) { _, card in
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
                        VStack(alignment: .leading, spacing: 10) {
                            Text(card.title).templateTitle().lineLimit(2)
                            if let subtitle = card.subtitle, !subtitle.templateTrimmed.isEmpty {
                                Text(subtitle).templateBody().lineLimit(3)
                            }
                            if let rawURL = card.defaultActionURL, let url = URL(string: rawURL), url.isHTTP {
                                Link("Open", destination: url).outlinedPill(accentColor: accentColor)
                            }
                            ForEach(Array(card.buttons.enumerated()), id: \.offset) { _, button in
                                Button(button.label) {
                                    if let raw = button.url, let url = URL(string: raw), url.isHTTP {
                                        openURL(url)
                                    } else {
                                        pending = true
                                        error = nil
                                        Task {
                                            defer { pending = false }
                                            do {
                                                if let context {
                                                    try await context.perform(
                                                        button.id, value: button.value ?? button.label,
                                                        renderId: renderId, displayText: button.label)
                                                } else {
                                                    submitAction(button.id, button.value ?? button.label, nil, renderId)
                                                }
                                                selected = button.id
                                            } catch { self.error = strings("Action could not be sent. Please retry.") }
                                        }
                                    }
                                }
                                .buttonStyle(
                                    OutlinedPillButtonStyle(
                                        accentColor: accentColor,
                                        isSelected: (selected ?? context?.submittedActionId) == button.id)
                                )
                                .disabled(pending || selected != nil || context?.submittedActionId != nil)
                            }
                        }
                        .padding(14)
                    }
                    .frame(width: 220, alignment: .leading)
                    .templateCard()
                }
            }
            .padding(.vertical, 2)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
