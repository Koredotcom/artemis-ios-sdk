import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct QuickRepliesTemplate: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var theme
    let replies: [QuickReply]
    let context: RichTemplateContext
    @State private var selected: String?
    @State private var pending = false
    @State private var error: String?
    private var presentationKey: String { context.message.id + ":quick_replies" }
    private var submittedSelection: String? {
        let replyIDs = Set(replies.map(\.id))
        return context.submittedActionIds.first(where: replyIDs.contains)
    }
    private var restoredSelection: String? {
        let replyIDs = Set(replies.map(\.id))
        let savedSelection = context.presentation?.values(for: presentationKey)["selectedActionId"]
        return submittedSelection ?? savedSelection.flatMap { replyIDs.contains($0) ? $0 : nil }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8 * (theme?.spacingScale ?? 1)) {
            TemplateFlowRow(replies, spacing: 8 * (theme?.spacingScale ?? 1)) { reply in
                Button {
                    guard !pending, selected == nil else { return }
                    pending = true
                    error = nil
                    Task {
                        defer { pending = false }
                        do {
                            try await context.perform(
                                reply.id, value: reply.label,
                                renderId: context.message.actions?.renderId ?? context.message.id,
                                displayText: reply.label)
                            selected = reply.id
                            context.presentation?.save(["selectedActionId": reply.id], for: presentationKey)
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
                        isSelected: selected == reply.id)
                )
                .disabled(pending || selected != nil)
                .accessibilityLabel(reply.label)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings("Quick replies"))
        .onAppear {
            if selected == nil { selected = restoredSelection }
        }
        .onChange(of: context.submittedActionIds) { _ in
            if selected == nil { selected = restoredSelection }
        }
    }
}
