import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct QuickRepliesTemplate: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var theme
    let replies: [QuickReply]
    let messageId: String
    let context: RichTemplateContext
    @State private var selected: String?
    @State private var pending = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * (theme?.spacingScale ?? 1)) {
            TemplateFlowRow(replies, spacing: 8 * (theme?.spacingScale ?? 1)) { reply in
                Button {
                    guard !pending, selected == nil, context.submittedActionId == nil else { return }
                    pending = true
                    error = nil
                    Task {
                        defer { pending = false }
                        do {
                            try await context.perform(
                                reply.id, value: reply.label, renderId: messageId, displayText: reply.label)
                            selected = reply.id
                        } catch { self.error = strings("Reply could not be sent. Please retry.") }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if let value = reply.iconURL, let url = URL(string: value), url.isHTTP,
                            url.user == nil, url.password == nil
                        {
                            TemplateRemoteImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.clear
                            }
                            .frame(width: 16, height: 16).clipShape(Circle()).accessibilityHidden(true)
                        }
                        Text(verbatim: reply.label)
                    }
                }.buttonStyle(
                    TemplateControlButtonStyle(
                        accentColor: context.accentColor,
                        variant: .quickReply,
                        isSelected: (selected ?? context.submittedActionId) == reply.id)
                )
                .disabled(pending || selected != nil || context.submittedActionId != nil)
                .accessibilityLabel(reply.label)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings("Quick replies"))
    }
}
