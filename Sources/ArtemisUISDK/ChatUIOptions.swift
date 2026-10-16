import SwiftUI

/// Presentation options shared by the stock chat and its built-in templates.
public struct ChatUIOptions: Sendable, Equatable {
    public var enableMessageFeedback: Bool
    public var feedbackCommentMaxLength: Int
    public var strings: ChatStrings?
    public var timestamps: MessageTimestampSettings?

    public init(
        enableMessageFeedback: Bool = false, feedbackCommentMaxLength: Int = 500,
        timestamps: MessageTimestampSettings? = nil, strings: ChatStrings? = nil
    ) {
        self.enableMessageFeedback = enableMessageFeedback
        self.timestamps = timestamps
        self.strings = strings
        self.feedbackCommentMaxLength = min(4000, max(1, feedbackCommentMaxLength))
    }
}

private struct ChatUIOptionsKey: EnvironmentKey {
    static let defaultValue = ChatUIOptions()
}

extension EnvironmentValues {
    var artemisChatOptions: ChatUIOptions {
        get { self[ChatUIOptionsKey.self] }
        set { self[ChatUIOptionsKey.self] = newValue }
    }
}

extension View {
    /// Customize SDK presentation without changing the connection configuration.
    public func artemisChatOptions(_ options: ChatUIOptions) -> some View {
        environment(\.artemisChatOptions, options)
    }
}

private struct ChatThemeKey: EnvironmentKey { static let defaultValue: ChatTheme? = nil }
extension EnvironmentValues {
    var chatTheme: ChatTheme? {
        get { self[ChatThemeKey.self] }
        set { self[ChatThemeKey.self] = newValue }
    }
}
