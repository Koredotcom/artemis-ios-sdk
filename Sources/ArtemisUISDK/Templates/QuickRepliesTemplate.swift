#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import SwiftUI

struct QuickRepliesTemplate: View {
    let replies: [QuickReply]
    let messageId: String
    let context: RichTemplateContext
    @State private var selected: String?
    @State private var pending = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 118))], alignment: .leading, spacing: 8) {
                ForEach(replies) { reply in
                    Button(reply.label) {
                        pending = true
                        error = nil
                        Task {
                            defer { pending = false }
                            do {
                                try await context.perform(
                                    reply.id, value: reply.label, renderId: messageId, displayText: reply.label)
                                selected = reply.id
                            } catch { self.error = "Reply could not be sent. Please retry." }
                        }
                    }.buttonStyle(
                        OutlinedPillButtonStyle(
                            accentColor: context.accentColor,
                            isSelected: (selected ?? context.submittedActionId) == reply.id)
                    )
                    .disabled(pending || selected != nil || context.submittedActionId != nil)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
