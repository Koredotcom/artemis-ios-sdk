import Foundation
import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct RichContentTemplatesView: View {
    @Environment(\.chatTheme) private var chatTheme
    private var templateStyle: TemplatePalette { TemplatePalette(theme: chatTheme) }
    let message: Message
    let context: RichTemplateContext
    var suppressedTypes: Set<String> = []
    var fillsAvailableWidth = true

    private var richContent: RichContent? { message.richContent }
    private var actions: ActionSet? { message.actions }
    private var componentOrder: [String] {
        var types = richContent?.componentOrder ?? RichContentParser.webRendererOrder
        if actions?.hasElements == true, !types.contains(RichTemplateTypes.actions) {
            let index = types.firstIndex(of: RichTemplateTypes.quickReplies) ?? types.endIndex
            types.insert(RichTemplateTypes.actions, at: index)
        }
        return types
    }
    private var messageTextColor: Color {
        message.role == .user
            ? Color(hexString: chatTheme?.userBubbleTextColor)
            : Color(hexString: chatTheme?.assistantBubbleTextColor)
    }

    var body: some View {
        if richContent != nil || (actions?.hasElements == true && !isSuppressed(RichTemplateTypes.actions)) {
            VStack(alignment: .leading, spacing: templateStyle.sectionSpacing) {
                ForEach(componentOrder, id: \.self) { type in
                    componentView(for: type)
                }
            }
            .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
        }
    }

    private func componentView(for type: String) -> AnyView {
        switch type {
        case "markdown":
            guard !isSuppressed(type), let markdown = richContent?.markdown, !markdown.templateTrimmed.isEmpty
            else { return AnyView(EmptyView()) }
            return AnyView(
                ChatMarkdownView(
                    content: markdown, linkColor: messageTextColor,
                    disabledNumbersHyperlink: chatTheme?.disabledNumbersHyperlink ?? false,
                    fillsAvailableWidth: fillsAvailableWidth))
        case RichTemplateTypes.html:
            guard !isSuppressed(type), richContent?.markdown?.templateTrimmed.isEmpty != false,
                let html = richContent?.html, !html.templateTrimmed.isEmpty
            else { return AnyView(EmptyView()) }
            return AnyView(HTMLRichTemplate(content: html, isUserMessage: message.role == .user))
        case RichTemplateTypes.image:
            guard !isSuppressed(type), let image = richContent?.image else { return AnyView(EmptyView()) }
            return AnyView(MediaImageTemplate(image: image, accentColor: context.accentColor))
        case RichTemplateTypes.video:
            guard !isSuppressed(type), let video = richContent?.video else { return AnyView(EmptyView()) }
            return AnyView(
                VideoRichTemplate(media: video, accentColor: context.accentColor, presentation: context.presentation))
        case RichTemplateTypes.audio:
            guard !isSuppressed(type), let audio = richContent?.audio else { return AnyView(EmptyView()) }
            return AnyView(AudioRichTemplate(media: audio, accentColor: context.accentColor))
        case RichTemplateTypes.file:
            guard !isSuppressed(type), let file = richContent?.file else { return AnyView(EmptyView()) }
            return AnyView(FileTemplate(file: file, accentColor: context.accentColor))
        case RichTemplateTypes.list:
            guard !isSuppressed(type), let list = richContent?.list else { return AnyView(EmptyView()) }
            return AnyView(ListRichTemplate(list: list, accentColor: context.accentColor))
        case RichTemplateTypes.kpi:
            guard !isSuppressed(type), let kpi = richContent?.kpi else { return AnyView(EmptyView()) }
            return AnyView(KPIRichTemplate(kpi: kpi))
        case RichTemplateTypes.table:
            guard !isSuppressed(type), let table = richContent?.table else { return AnyView(EmptyView()) }
            return AnyView(TableRichTemplate(table: table, accentColor: context.accentColor))
        case RichTemplateTypes.chart:
            guard !isSuppressed(type), let chart = richContent?.chart else { return AnyView(EmptyView()) }
            return AnyView(ChartRichTemplate(chart: chart, accentColor: context.accentColor))
        case RichTemplateTypes.form:
            guard !isSuppressed(type), let form = richContent?.form else { return AnyView(EmptyView()) }
            return AnyView(FormRichTemplate(form: form, messageId: message.id, context: context))
        case RichTemplateTypes.progress:
            guard !isSuppressed(type), let progress = richContent?.progress else { return AnyView(EmptyView()) }
            return AnyView(ProgressRichTemplate(progress: progress, accentColor: context.accentColor))
        case RichTemplateTypes.feedback:
            guard !isSuppressed(type), let feedback = richContent?.feedback else { return AnyView(EmptyView()) }
            return AnyView(FeedbackRichTemplate(feedback: feedback, messageId: message.id, context: context))
        case RichTemplateTypes.actions:
            guard !isSuppressed(type), let actions, actions.hasElements else { return AnyView(EmptyView()) }
            return AnyView(ActionsRichTemplate(actions: actions, context: context))
        case RichTemplateTypes.quickReplies:
            guard !isSuppressed(type), let replies = richContent?.quickReplies else { return AnyView(EmptyView()) }
            return AnyView(QuickRepliesTemplate(replies: replies, context: context))
        case RichTemplateTypes.channelFallback:
            guard !isSuppressed(type), let items = richContent?.channelFallbackItems, !items.isEmpty
            else { return AnyView(EmptyView()) }
            return AnyView(
                VStack(alignment: .leading, spacing: 8 * (chatTheme?.spacingScale ?? 1)) {
                    ForEach(items) { item in ChannelFallbackTemplate(item: item) }
                })
        case "carousel":
            guard !isSuppressed(type), let carousel = richContent?.carousel else { return AnyView(EmptyView()) }
            return AnyView(
                CarouselRichTemplate(
                    carousel: carousel, accentColor: context.accentColor,
                    submitAction: context.submitAction,
                    renderId: actions?.renderId, context: context))
        default:
            return AnyView(EmptyView())
        }
    }

    private func isSuppressed(_ type: String) -> Bool { suppressedTypes.contains(type) }
}
