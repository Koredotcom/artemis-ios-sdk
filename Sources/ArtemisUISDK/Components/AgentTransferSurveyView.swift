import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

@MainActor struct AgentTransferSurveyView: View {
    @Environment(\.chatStrings) private var strings
    let survey: AgentTransferSurvey
    @ObservedObject var state: SurveyPresentation
    let enabled: Bool
    let onSubmit: (SurveyPresentation) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(survey.prompt).font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44))], spacing: 8) {
                ForEach(Array(survey.choices), id: \.self) { score in
                    Button {
                        state.score = score
                        if !survey.showComment(for: score) { state.comments = "" }
                    } label: {
                        Text(
                            survey.surveyType == "likeDislike"
                                ? strings(score == 1 ? "Like" : "Dislike") : "\(score)"
                        )
                        .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                        .background(
                            state.score == score ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                            in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(locked).accessibilityAddTraits(
                        state.score == score ? .isSelected : [])
                }
            }
            if survey.showComment(for: state.score) {
                Text(survey.commentPrompt ?? survey.commentPlaceholder).font(.caption)
                TextEditor(text: $state.comments).frame(height: 70).overlay(
                    RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4))
                )
                .disabled(locked).accessibilityLabel(survey.commentPlaceholder)
                .onChange(of: state.comments) { value in
                    if value.count > 4000 { state.comments = String(value.prefix(4000)) }
                }
            }
            if state.status == .submitted {
                Text(survey.successMessage).font(.subheadline).foregroundStyle(.secondary)
            } else {
                Button {
                    onSubmit(state)
                } label: {
                    HStack {
                        if state.status == .pending { ProgressView().controlSize(.small) }
                        Text(state.status == .pending ? survey.pendingMessage : survey.submitLabel)
                    }.frame(minHeight: 44)
                }.disabled(locked || state.score == nil || !enabled)
                if state.status == .failed {
                    Text(survey.errorMessage).font(.caption).foregroundStyle(.red)
                }
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
    private var locked: Bool { state.status == .pending || state.status == .submitted }
}
