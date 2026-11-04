import SwiftUI

struct FileDownloadCard: View {
    @Environment(\.chatTheme) private var chatTheme
    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    @Environment(\.chatStrings) private var strings
    let title: String
    let subtitle: String
    let url: String
    let accentColor: Color

    var body: some View {
        if let target = URL(string: url), target.isHTTP {
            Link(destination: target) { content }
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(templateStyle.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.templateTrimmed.isEmpty {
                    Text(subtitle)
                        .templateBody()
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Spacer(minLength: 12)
            Text(strings("Download"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .frame(minWidth: 96)
                .background(accentColor.opacity(0.1))
                .clipShape(Capsule())
        }
        .templateCard(padding: 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
