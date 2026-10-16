import SwiftUI

@MainActor final class MessageFeedbackState: ObservableObject {
    enum Status { case idle, pending, submitted, failed }
    @Published var rating: Int?
    @Published var comment = ""
    @Published var showsComment = false
    @Published private(set) var status = Status.idle
    private(set) var lastComment: String?

    func chooseNegative() {
        guard status != .pending, status != .submitted else { return }
        rating = 0
        showsComment = true
        status = .idle
    }
    func retry(send: (Int, String?) async throws -> Void) async {
        guard let rating, status == .failed else { return }
        await submit(rating: rating, comment: lastComment, send: send)
    }

    func submit(rating: Int, comment: String?, send: (Int, String?) async throws -> Void) async {
        guard status != .pending, status != .submitted else { return }
        self.rating = rating
        status = .pending
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        lastComment = trimmed?.isEmpty == false ? trimmed : nil
        do {
            try await send(rating, lastComment)
            showsComment = false
            self.comment = ""
            status = .submitted
        } catch { status = .failed }
    }
}

struct MessageFeedbackControls: View {
    @Environment(\.chatStrings) private var strings
    @ObservedObject var state: MessageFeedbackState
    let enabled: Bool
    let maxLength: Int
    let send: (Int, String?) async throws -> Void
    private var locked: Bool { !enabled || state.status == .pending || state.status == .submitted }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ratingButton(1, icon: "hand.thumbsup", label: "Thumbs up") {
                    state.showsComment = false
                    Task { await state.submit(rating: 1, comment: nil, send: send) }
                }
                ratingButton(0, icon: "hand.thumbsdown", label: "Thumbs down") {
                    state.chooseNegative()
                }
                if state.status == .pending { ProgressView().controlSize(.small) }
                if state.status == .submitted { Text(strings("Thanks for your feedback.")).font(.caption) }
            }
            if state.showsComment, state.status != .submitted {
                Text(strings("Optional — what was wrong?")).font(.caption)
                TextEditor(text: $state.comment).frame(height: 64)
                    .accessibilityLabel(strings("Feedback comment"))
                    .disabled(locked)
                    .onChange(of: state.comment) { value in
                        if value.count > maxLength { state.comment = String(value.prefix(maxLength)) }
                    }
                HStack {
                    Text("\(state.comment.count)/\(maxLength)").font(.caption)
                    Spacer()
                    Button(strings("Skip")) {
                        Task { await state.submit(rating: 0, comment: nil, send: send) }
                    }
                    Button(strings("Send feedback")) {
                        Task { await state.submit(rating: 0, comment: state.comment, send: send) }
                    }
                }.disabled(locked)
            }
            if state.status == .failed {
                HStack {
                    Text(strings("Could not send feedback.")).font(.caption)
                    Button(strings("Retry")) {
                        Task { await state.retry(send: send) }
                    }.disabled(locked)
                }.foregroundStyle(.red)
            }
        }
    }
    private func ratingButton(
        _ rating: Int, icon: String, label: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: state.rating == rating ? icon + ".fill" : icon).frame(
                minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(strings(label)).disabled(locked)
            .accessibilityAddTraits(state.rating == rating ? .isSelected : [])
    }
}
