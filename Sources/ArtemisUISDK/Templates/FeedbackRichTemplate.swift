#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import SwiftUI

struct FeedbackRichTemplate: View {
    let feedback: FeedbackTemplate
    let messageId: String
    let context: RichTemplateContext
    @State private var selected: Int?
    @State private var pending = false
    @State private var submitted = false
    @State private var error: String?
    private var supported: Bool { ["thumbs", "star", "stars"].contains(feedback.type) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(feedback.prompt).templateTitle()
            if !supported {
                Text("This feedback type is not available yet").templateBody()
            } else if submitted {
                Text("Thanks for your feedback.").font(.subheadline)
            } else {
                HStack(spacing: 8) {
                    if feedback.type == "thumbs" {
                        option(1, icon: "hand.thumbsup", label: "Thumbs up")
                        option(0, icon: "hand.thumbsdown", label: "Thumbs down")
                    } else {
                        ForEach(1...min(20, max(1, feedback.max)), id: \.self) { rating in
                            Button {
                                selected = rating
                            } label: {
                                Image(systemName: (selected ?? 0) >= rating ? "star.fill" : "star").font(
                                    .system(size: 22)
                                ).frame(minWidth: 36, minHeight: 44)
                            }.buttonStyle(.plain).disabled(pending).accessibilityLabel("\(rating) stars")
                        }
                    }
                }.foregroundStyle(context.accentColor)
                if feedback.type != "thumbs" {
                    Button("Submit", action: submitSelected).buttonStyle(
                        FilledCapsuleButtonStyle(accentColor: context.accentColor)
                    ).disabled(selected == nil || pending)
                }
                if pending { ProgressView("Submitting your feedback…").font(.caption) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
        }.templateCard()
            .onAppear { submitted = context.presentation?.values(for: messageId + ":feedback")["submitted"] == "true" }
    }
    private func option(_ value: Int, icon: String, label: String) -> some View {
        Button {
            selected = value
            submitSelected()
        } label: {
            Label(label, systemImage: icon).frame(minHeight: 44)
        }
        .buttonStyle(OutlinedPillButtonStyle(accentColor: context.accentColor, isSelected: selected == value)).disabled(
            pending)
    }
    private func submitSelected() {
        guard let selected, !pending, !submitted else { return }
        pending = true
        error = nil
        Task {
            defer { pending = false }
            do {
                let type = feedback.type == "thumbs" ? "thumbs" : "star"
                if let send = context.sendFeedback {
                    try await send(messageId, type, selected, messageId)
                } else {
                    context.submitFeedback(messageId, type, selected, messageId)
                }
                submitted = true
                context.presentation?.save(["submitted": "true"], for: messageId + ":feedback")
            } catch { self.error = "Feedback could not be submitted. Please retry." }
        }
    }
}
