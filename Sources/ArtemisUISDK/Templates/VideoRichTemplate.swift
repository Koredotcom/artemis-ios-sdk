import SwiftUI

struct VideoRichTemplate: View {
    let media: MediaContent
    let accentColor: Color
    let presentation: ChatPresentationState?

    private var displayCaption: String? {
        guard let caption = media.caption ?? media.alt else { return nil }
        let withoutRepeatedTopic = caption.replacingOccurrences(
            of: #"(?i)(\bfor\s+)destination\s+(guide\b)"#,
            with: "$1$2",
            options: .regularExpression)
        return withoutRepeatedTopic.replacingOccurrences(
            of: #"(?i)(\bfor\s+)guide\b"#,
            with: "$1guide",
            options: .regularExpression)
    }

    var body: some View {
        InlineVideoPlayer(
            media: media, displayCaption: displayCaption,
            presentation: presentation)
    }
}
