import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

private struct FeedbackChoice: Identifiable {
    let value: Int
    var id: Int { value }
}

private struct FeedbackEmojiChoice: Identifiable {
    let value: Int
    let glyph: String
    let label: String
    var id: Int { value }
}

struct FeedbackRichTemplate: View {
    @Environment(\.chatTheme) private var chatTheme
    @Environment(\.chatStrings) private var strings
    private var palette: TemplatePalette { TemplatePalette(theme: chatTheme) }

    let feedback: FeedbackTemplate
    let messageId: String
    let context: RichTemplateContext
    @State private var selected: Int?
    @State private var commentText = ""
    @State private var followUpText = ""
    @State private var followUpRating: Int?
    @State private var pending = false
    @State private var submitted = false
    @State private var error: String?

    private var presentationKey: String { messageId + ":feedback" }
    private var supported: Bool { ["thumbs", "star", "stars", "scale", "text"].contains(feedback.type) }
    private var maxRating: Int { min(20, max(1, feedback.max)) }
    private var isCommentOnly: Bool { feedback.type == "text" }
    private var isThumbs: Bool { feedback.type == "thumbs" }
    private var isStar: Bool { feedback.type == "star" || feedback.type == "stars" }
    private var isEmoji: Bool { isStar && feedback.ratingDisplay == "emoji" }
    private var locked: Bool { pending || submitted }
    private var followUpQuestion: String? {
        guard let selected, let followUp = feedback.followUp, followUp.enabled else { return nil }
        if followUp.answerType == "rating", followUpRatingValues.isEmpty { return nil }
        let key = String(selected)
        guard let question = followUp.questions[key], !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return question
    }
    private var followUpRatingValues: [Int] {
        guard let followUp = feedback.followUp, followUp.answerType == "rating" else { return [] }
        guard let ratingType = followUp.ratingType else { return [] }
        switch ratingType {
        case "thumbs": return [0, 1]
        case "scale": return Array(0...10)
        case "star": return Array(1...5)
        default: return []
        }
    }
    private var showsComment: Bool {
        if isCommentOnly { return true }
        if let visibility = feedback.commentVisibility {
            switch visibility {
            case "always": return true
            case "never": return false
            case "conditional": return selected.map { feedback.commentRatings.contains($0) } ?? false
            default: break
            }
        }
        if isThumbs { return selected == 0 }
        if isStar, let selected, let threshold = feedback.commentThreshold {
            return selected <= min(maxRating, threshold) && selected >= 1
        }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !supported {
                Text(strings("This feedback type is not available yet"))
                    .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                    .foregroundStyle(.red)
            } else {
                Text(feedback.prompt)
                    .font(chatTheme?.font(size: 15, weight: .semibold) ?? .system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.text)

                ratingOptions

                if showsComment, !isCommentOnly {
                    commentField(
                        prompt: nonEmpty(feedback.commentPrompt, fallback: strings("What could we improve?")),
                        placeholder: nonEmpty(
                            feedback.commentPlaceholder, fallback: strings("Tell us what went wrong (optional)")),
                        text: $commentText)
                } else if isCommentOnly {
                    commentField(
                        prompt: nil,
                        placeholder: nonEmpty(
                            feedback.commentPlaceholder, fallback: strings("Tell us what went wrong (optional)")),
                        text: $commentText)
                }

                if let followUpQuestion {
                    followUpField(question: followUpQuestion)
                }

                if isThumbs && (showsComment || followUpQuestion != nil) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        Button(strings("Skip")) { submit(includeComment: false) }
                            .buttonStyle(RichTemplateButtonStyle(accentColor: context.accentColor, variant: .outline))
                            .disabled(locked)
                        Button(strings("Send")) { submit(includeComment: true) }
                            .buttonStyle(RichTemplateButtonStyle(accentColor: context.accentColor, variant: .outline))
                            .disabled(locked)
                    }
                } else if !isThumbs {
                    Button(
                        pending ? nonEmpty(feedback.pendingMessage, fallback: strings("Submitting..."))
                            : nonEmpty(feedback.submitLabel, fallback: strings("Submit"))) {
                        submit(includeComment: showsComment)
                    }
                    .buttonStyle(RichTemplateButtonStyle(
                        accentColor: context.accentColor, variant: .outline, minimumHeight: 40,
                        fontWeight: .semibold))
                    .disabled(selected == nil && !isCommentOnly || locked)
                }

                if let statusText {
                    Text(statusText)
                        .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                        .foregroundStyle(error == nil ? palette.mutedText : Color(hexString: "#DC2626"))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .richTemplateCard()
        .padding(.top, 0)
        .onAppear {
            let values = context.presentation?.values(for: presentationKey) ?? [:]
            submitted = values["submitted"] == "true"
            if let rawRating = values["selectedRating"], let rating = Int(rawRating), isValidRating(rating) {
                selected = rating
            }
            if isCommentOnly, selected == nil { selected = 0 }
        }
        .onChange(of: commentText) { if $0.count > 5000 { commentText = String($0.prefix(5000)) } }
        .onChange(of: followUpText) { if $0.count > 5000 { followUpText = String($0.prefix(5000)) } }
    }

    @ViewBuilder private var ratingOptions: some View {
        if isCommentOnly {
            EmptyView()
        } else if isThumbs {
            HStack(spacing: 8) {
                ratingButton(1, label: "👍", accessibilityLabel: strings("Thumbs up"))
                ratingButton(0, label: "👎", accessibilityLabel: strings("Thumbs down"))
            }
        } else if isEmoji {
            HStack(spacing: 4) {
                ForEach(emojiChoices) { choice in
                    Button { choose(choice.value) } label: {
                        VStack(spacing: 2) {
                            Text(choice.glyph).font(.system(size: 20)).lineLimit(1)
                            Text(choice.label).font(.system(size: 10)).lineLimit(1)
                                .foregroundStyle(palette.mutedText.opacity(0.75))
                        }
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(optionStyle(selected: selected == choice.value))
                    .disabled(locked)
                    .accessibilityLabel("\(choice.value), \(choice.label)")
                }
            }
        } else if isStar {
            let choices = (1...maxRating).map(FeedbackChoice.init(value:))
            TemplateFlowRow(choices, spacing: 8, verticalSpacing: 8) { choice in
                let filled = (selected ?? 0) >= choice.value
                Button { choose(choice.value) } label: {
                    Text(filled ? "★" : "☆")
                        .font(.system(size: 18))
                        .frame(minWidth: 38, minHeight: 38)
                }
                .buttonStyle(optionStyle(selected: filled, foreground: filled ? Color(hexString: "#F59E0B") : palette.text))
                .disabled(locked)
                .accessibilityLabel(strings.format("{count} stars", ["count": String(choice.value)]))
                .accessibilityAddTraits(selected == choice.value ? .isSelected : [])
            }
        } else if feedback.type == "scale" {
            let choices = (0...10).map(FeedbackChoice.init(value:))
            TemplateFlowRow(choices, spacing: 4, verticalSpacing: 4) { choice in
                let bucket = npsColors(choice.value)
                Button { choose(choice.value) } label: {
                    Text(String(choice.value))
                        .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                        .frame(minWidth: 34, minHeight: 38)
                }
                .buttonStyle(optionStyle(
                    selected: selected == choice.value,
                    foreground: selected == choice.value ? .white : bucket.foreground,
                    background: selected == choice.value ? bucket.selected : bucket.background,
                    border: selected == choice.value ? bucket.selected : bucket.border))
                .disabled(locked)
                .accessibilityLabel(String(choice.value))
                .accessibilityAddTraits(selected == choice.value ? .isSelected : [])
            }
        }
    }

    private func ratingButton(_ value: Int, label: String, accessibilityLabel: String) -> some View {
        Button { choose(value) } label: {
            Text(label).font(.system(size: 18)).frame(minWidth: 38, minHeight: 38)
        }
        .buttonStyle(optionStyle(selected: selected == value))
        .disabled(locked)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected == value ? .isSelected : [])
    }

    private func commentField(prompt: String?, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let prompt {
                Text(prompt)
                    .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.mutedText)
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .font(chatTheme?.font(size: 13) ?? .system(size: 13))
                        .foregroundStyle(palette.mutedText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
                ThemedFeedbackTextEditor(
                    text: text, theme: chatTheme, disabled: locked,
                    accessibilityLabel: prompt ?? feedback.prompt)
            }
            .background(Color(hexString: chatTheme?.backgroundColor ?? "#FFFFFF"))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                Color(hexString: chatTheme?.borderColor ?? "#E2E8F0"), lineWidth: 1))
        }
    }

    @ViewBuilder private func followUpField(question: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(chatTheme?.font(size: 12, weight: .semibold) ?? .system(size: 12, weight: .semibold))
                .foregroundStyle(palette.mutedText)
            if feedback.followUp?.answerType == "rating" {
                TemplateFlowRow(followUpChoices, spacing: 6, verticalSpacing: 6) { choice in
                    let isEmojiChoice = isEmoji && feedback.followUp?.ratingType == "star"
                    Button { followUpRating = choice.value } label: {
                        if isEmojiChoice {
                            let emoji = emojiChoices.first { $0.value == choice.value }
                            VStack(spacing: 2) {
                                Text(emoji?.glyph ?? "").font(.system(size: 20))
                                Text(emoji?.label ?? "").font(.system(size: 10)).lineLimit(1)
                            }
                            .frame(minWidth: 38, minHeight: 56)
                        } else {
                            Text(followUpLabel(choice.value))
                                .font(chatTheme?.font(size: 13) ?? .system(size: 13))
                                .frame(minWidth: 38, minHeight: 38)
                                .padding(.horizontal, 10)
                        }
                    }
                    .buttonStyle(optionStyle(
                        selected: followUpRating == choice.value,
                        foreground: followUpRating == choice.value ? .white : palette.text,
                        background: followUpRating == choice.value ? context.accentColor : nil,
                        border: followUpRating == choice.value ? context.accentColor : nil))
                    .disabled(locked)
                    .accessibilityLabel(followUpAccessibilityLabel(choice.value))
                    .accessibilityAddTraits(followUpRating == choice.value ? .isSelected : [])
                }
            } else {
                ZStack(alignment: .topLeading) {
                    if followUpText.isEmpty {
                        Text(strings("Type your answer"))
                            .font(chatTheme?.font(size: 13) ?? .system(size: 13))
                            .foregroundStyle(palette.mutedText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                    ThemedFeedbackTextEditor(
                        text: $followUpText, theme: chatTheme, disabled: locked,
                        accessibilityLabel: question)
                }
                .background(Color(hexString: chatTheme?.backgroundColor ?? "#FFFFFF"))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(
                    Color(hexString: chatTheme?.borderColor ?? "#E2E8F0"), lineWidth: 1))
            }
        }
    }

    private var followUpChoices: [FeedbackChoice] { followUpRatingValues.map(FeedbackChoice.init(value:)) }

    private var emojiChoices: [FeedbackEmojiChoice] {
        [
            FeedbackEmojiChoice(value: 1, glyph: "😠", label: "Terrible"),
            FeedbackEmojiChoice(value: 2, glyph: "🙁", label: "Poor"),
            FeedbackEmojiChoice(value: 3, glyph: "😐", label: "Okay"),
            FeedbackEmojiChoice(value: 4, glyph: "🙂", label: "Good"),
            FeedbackEmojiChoice(value: 5, glyph: "😀", label: "Great"),
        ]
    }

    private func followUpLabel(_ value: Int) -> String {
        feedback.followUp?.ratingType == "thumbs" ? (value == 1 ? "👍" : "👎") : String(value)
    }

    private func followUpAccessibilityLabel(_ value: Int) -> String {
        if feedback.followUp?.ratingType == "thumbs" {
            return strings(value == 1 ? "Thumbs up" : "Thumbs down")
        }
        if isEmoji, feedback.followUp?.ratingType == "star",
            let choice = emojiChoices.first(where: { $0.value == value })
        {
            return "\(choice.value), \(choice.label)"
        }
        return String(value)
    }

    private func choose(_ value: Int) {
        guard !locked else { return }
        selected = value
        savePresentationState()
        if !commentShouldShow(for: value) { commentText = "" }
        followUpRating = nil
        followUpText = ""
        error = nil
        if isThumbs && !commentShouldShow(for: value) && question(for: value) == nil {
            submit(value: value, includeComment: false)
        }
    }

    private func commentShouldShow(for value: Int) -> Bool {
        if isCommentOnly { return true }
        if let visibility = feedback.commentVisibility {
            switch visibility {
            case "always": return true
            case "never": return false
            case "conditional": return feedback.commentRatings.contains(value)
            default: break
            }
        }
        if isThumbs { return value == 0 }
        if isStar, let threshold = feedback.commentThreshold {
            return value >= 1 && value <= min(maxRating, threshold)
        }
        return false
    }

    private func question(for value: Int) -> String? {
        guard let followUp = feedback.followUp, followUp.enabled else { return nil }
        if followUp.answerType == "rating" {
            guard let ratingType = followUp.ratingType else { return nil }
            switch ratingType {
            case "thumbs", "scale", "star": break
            default: return nil
            }
        }
        guard let question = followUp.questions[String(value)],
            !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return question
    }

    private func submit(includeComment: Bool) {
        guard let selected else {
            if isCommentOnly { submit(value: 0, includeComment: true) }
            return
        }
        submit(value: selected, includeComment: includeComment)
    }

    private func submit(value: Int, includeComment: Bool) {
        guard !pending, !submitted else { return }
        pending = true
        error = nil
        let ratingType = isThumbs ? "thumbs" : isCommentOnly ? "text" : feedback.type == "scale" ? "scale" : "star"
        let comment = includeComment ? commentText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let question = question(for: value)
        let extraText = question == nil ? nil : followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { pending = false }
            do {
                if let send = context.sendRichFeedback {
                    try await send(
                        messageId, ratingType, value, comment.isEmpty ? nil : comment,
                        question == nil ? nil : followUpRating, extraText?.isEmpty == true ? nil : extraText)
                } else if let send = context.sendFeedback {
                    try await send(messageId, ratingType, value, messageId)
                } else {
                    context.submitFeedback(messageId, ratingType, value, messageId)
                }
                submitted = true
                savePresentationState(submitted: true)
            } catch {
                self.error = strings("Could not save feedback. Try again.")
            }
        }
    }

    private func isValidRating(_ value: Int) -> Bool {
        if isStar { return (1...maxRating).contains(value) }
        if isThumbs { return (0...1).contains(value) }
        if feedback.type == "scale" { return (0...10).contains(value) }
        return isCommentOnly && value == 0
    }

    private func savePresentationState(submitted: Bool? = nil) {
        guard let presentation = context.presentation else { return }
        var values = presentation.values(for: presentationKey)
        if let selected {
            values["selectedRating"] = String(selected)
        } else {
            values.removeValue(forKey: "selectedRating")
        }
        if let submitted { values["submitted"] = submitted ? "true" : "false" }
        presentation.save(values, for: presentationKey)
    }

    private var statusText: String? {
        if pending { return nonEmpty(feedback.pendingMessage, fallback: strings("Submitting...")) }
        if submitted { return nonEmpty(feedback.successMessage, fallback: strings("Thanks for your feedback.")) }
        if error != nil { return nonEmpty(feedback.errorMessage, fallback: strings("Could not save feedback. Try again.")) }
        return nil
    }

    private func nonEmpty(_ value: String?, fallback: String) -> String {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
        return value
    }

    private func optionStyle(
        selected: Bool, foreground: Color? = nil, background: Color? = nil, border: Color? = nil
    ) -> FeedbackOptionButtonStyle {
        FeedbackOptionButtonStyle(
            theme: chatTheme, accentColor: context.accentColor, selected: selected,
            foreground: foreground, background: background, border: border)
    }

    private func npsColors(_ value: Int) -> (foreground: Color, background: Color, border: Color, selected: Color) {
        if value <= 6 {
            return (Color(hexString: "#B91C1C"), Color(hexString: "#FEF2F2"), Color(hexString: "#FCA5A5"), Color(hexString: "#EF4444"))
        }
        if value <= 8 {
            return (Color(hexString: "#B45309"), Color(hexString: "#FFFBEB"), Color(hexString: "#FCD34D"), Color(hexString: "#F59E0B"))
        }
        return (Color(hexString: "#15803D"), Color(hexString: "#F0FDF4"), Color(hexString: "#86EFAC"), Color(hexString: "#22C55E"))
    }
}

private struct FeedbackOptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let theme: ChatTheme?
    let accentColor: Color
    let selected: Bool
    let foreground: Color?
    let background: Color?
    let border: Color?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        let baseBorder = Color(hexString: theme?.borderColor ?? "#E2E8F0")
        let isPressed = configuration.isPressed && isEnabled
        return configuration.label
            .foregroundStyle(foreground ?? (isPressed ? Color.white : selected ? accentColor : Color(hexString: theme?.textColor ?? "#1E293B")))
            .background(background ?? (isPressed ? accentColor : selected
                ? accentColor.opacity(0.14)
                : Color(hexString: theme?.backgroundColor ?? "#FFFFFF")))
            .clipShape(shape)
            .overlay(shape.stroke(border ?? (selected ? accentColor.opacity(0.6) : baseBorder), lineWidth: 1))
            .shadow(color: selected && background == nil ? Color(hexString: "#6366F1").opacity(0.1) : .clear, radius: 3)
            .opacity(isEnabled ? 1 : 0.65)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
    }
}

private struct ThemedFeedbackTextEditor: View {
    @Binding var text: String
    let theme: ChatTheme?
    let disabled: Bool
    let accessibilityLabel: String

    var body: some View {
        Group {
            if #available(iOS 16.0, macOS 13.0, *) {
                editor.scrollContentBackground(.hidden)
            } else {
                editor
            }
        }
        .font(theme?.font(size: 13) ?? .system(size: 13))
        .foregroundStyle(Color(hexString: theme?.textColor ?? "#1E293B"))
        .frame(minHeight: 72)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var editor: TextEditor { TextEditor(text: $text) }
}
