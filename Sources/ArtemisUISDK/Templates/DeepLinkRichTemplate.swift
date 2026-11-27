import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

private struct ResolvedDeepLink: Identifiable {
    let index: Int
    let element: DeepLinkElement
    let url: URL

    var id: Int { index }
}

struct DeepLinkRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    @Environment(\.openURL) private var openURL

    let deepLink: DeepLinkTemplate
    let context: RichTemplateContext

    private var scale: CGFloat { chatTheme?.spacingScale ?? 1 }
    private var resolvedLinks: [ResolvedDeepLink] {
        deepLink.elements.enumerated().compactMap { index, element in
            guard let url = resolve(element.url) else { return nil }
            return ResolvedDeepLink(index: index, element: element, url: url)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            if let text = deepLink.text {
                Text(verbatim: text)
                    .templateTitle()
                    .padding(.horizontal, 4 * scale)
                    .padding(.vertical, 3 * scale)
            }

            ForEach(Array(resolvedLinks.enumerated()), id: \.offset) { index, link in
                Button {
                    switch link.element.navigation {
                    case .internalLink:
                        if let onInternalDeepLink = context.onInternalDeepLinkDetails {
                            onInternalDeepLink(link.element.url, link.element.title, context.message.id)
                        } else if let onInternalDeepLink = context.onInternalDeepLink {
                            onInternalDeepLink(link.element.url)
                        } else {
                            openURL(link.url)
                        }
                    case .external:
                        openURL(link.url)
                    }
                } label: {
                    Text(verbatim: link.element.title)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .buttonStyle(DeepLinkOutlinedButtonStyle(accentColor: context.accentColor))
                .accessibilityLabel(link.element.title)
                .padding(.top, index == 0 ? 2 * scale : 5 * scale)
            }
        }
        .padding(12 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hexString: chatTheme?.backgroundColor ?? "#FFFFFF"))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hexString: chatTheme?.borderColor ?? "#E2E8F0"), lineWidth: 1)
        }
        .padding(.top, 1 * scale)
    }

    private func resolve(_ rawURL: String) -> URL? {
        let baseURL = context.deepLinkBaseURL.flatMap(URL.init(string:))
        guard let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL, url.isHTTP else { return nil }
        return url
    }
}

private struct DeepLinkOutlinedButtonStyle: ButtonStyle {
    @Environment(\.chatTheme) private var chatTheme

    let accentColor: Color

    func makeBody(configuration: Configuration) -> some View {
        let radius = RoundedRectangle(cornerRadius: 12)
        let scale = chatTheme?.spacingScale ?? 1

        return configuration.label
            .font(
                chatTheme?.font(size: 14, weight: .medium) ?? .system(size: 13, weight: .medium)
            )
            .foregroundStyle(accentColor)
            .padding(.horizontal, 12 * scale)
            .frame(maxWidth: .infinity, minHeight: 48 * scale, alignment: .center)
            .background(Color(hexString: chatTheme?.backgroundColor ?? "#FFFFFF"))
            .clipShape(radius)
            .overlay(radius.stroke(Color(hexString: chatTheme?.borderColor ?? "#E2E8F0"), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
