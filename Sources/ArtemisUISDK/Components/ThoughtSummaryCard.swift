import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct ThoughtSummaryCard: View {
    let message: Message
    let presentation: ChatPresentationState?
    var showToolNames = false
    @Environment(\.chatStrings) private var strings
    @State private var expanded = false
    private var toolLabel: String? { showToolNames ? message.metadata?["toolName"]?.value as? String : nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                expanded.toggle()
                presentation?.save(["expanded": expanded ? "true" : "false"], for: "thought:" + message.id)
            } label: {
                HStack {
                    Image(systemName: "sparkles")
                    Text(toolLabel ?? strings("Thought summary"))
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(
                    strings(expanded ? "Collapse thought summary" : "Expand thought summary")
                )
                .accessibilityValue(strings(expanded ? "Expanded" : "Collapsed"))
            if expanded { Text(message.content).templateBody().textSelection(.enabled) }
        }.templateCard()
            .onAppear {
                expanded = presentation?.values(for: "thought:" + message.id)["expanded"] == "true"
            }
    }
}
