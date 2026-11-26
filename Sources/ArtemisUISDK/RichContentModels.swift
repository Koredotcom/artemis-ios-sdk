#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import Foundation

public struct CarouselButton: Sendable {
    public let value: String?
    public let url: String?
    public let id: String
    public let type: String
    public let label: String
    public let options: [[String: AnySendable]]
}

public struct CarouselItem: Sendable {
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    public let defaultActionURL: String?
    public let buttons: [CarouselButton]
}

public struct CarouselTemplate: Sendable {
    public let cards: [CarouselItem]
}

public struct QuickReply: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let iconURL: String?
}

public enum DeepLinkNavigation: Sendable {
    case internalLink
    case external
}

public struct DeepLinkElement: Sendable {
    public let title: String
    public let url: String
    public let navigation: DeepLinkNavigation
}

public struct DeepLinkTemplate: Sendable {
    public let text: String?
    public let lang: String?
    public let elements: [DeepLinkElement]
}

public struct MediaContent: Sendable {
    public let url: String
    public let alt: String?
    public let thumbnailURL: String?
    public let caption: String?
}

public struct FileContent: Sendable {
    public let url: String
    public let filename: String
    public let sizeBytes: Int?
    public let mimeType: String?
}

public struct ListTemplateItem: Sendable, Identifiable {
    public let id = UUID()
    public let title: String
    public let subtitle: String?
    public let imageURL: String?
    public let defaultActionURL: String?
}

public struct ListTemplate: Sendable {
    public let title: String?
    public let items: [ListTemplateItem]
}

public struct TableColumn: Sendable, Identifiable {
    public let id: String
    public let key: String
    public let header: String
    public let align: String?
}

public struct TableTemplate: Sendable {
    public let columns: [TableColumn]
    public let rows: [[String: AnySendable]]
    public let maxVisibleRows: Int?
}

public struct ChartDataPoint: Sendable, Identifiable {
    public let id = UUID()
    public let label: String
    public let value: Double
    public let color: String?
}

public struct ChartTemplate: Sendable {
    public let type: String
    public let title: String?
    public let data: [ChartDataPoint]
}

public struct KPITemplate: Sendable {
    public let label: String
    public let value: AnySendable?
    public let unit: String?
    public let trend: String?
    public let iconURL: String?

    public var displayValue: String {
        let raw = value.map { RichContentParser.displayString($0.value) } ?? ""
        guard let unit, !unit.trimmed.isEmpty else { return raw }
        return "\(raw) \(unit.trimmed)"
    }
}

public struct FormFieldOption: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
}

public struct FormTemplateField: Sendable, Identifiable {
    public let id: String
    public let type: String
    public let label: String
    public let value: String?
    public let options: [FormFieldOption]
    public let inputType: String?
    public let placeholder: String?
    public let required: Bool
}

public struct FormTemplate: Sendable {
    public let title: String?
    public let fields: [FormTemplateField]
    public let submitLabel: String?
}

public struct FeedbackFollowUp: Sendable {
    public let enabled: Bool
    public let answerType: String
    public let ratingType: String?
    public let questions: [String: String]
}

public struct ProgressTemplate: Sendable {
    public let label: String?
    public let value: Double
    public let max: Double
    public let variant: String
}

public struct FeedbackTemplate: Sendable {
    public let prompt: String
    public let type: String
    public let max: Int
    public let ratingDisplay: String?
    public let submitLabel: String?
    public let pendingMessage: String?
    public let successMessage: String?
    public let errorMessage: String?
    public let commentThreshold: Int?
    public let commentVisibility: String?
    public let commentRatings: [Int]
    public let commentPrompt: String?
    public let commentPlaceholder: String?
    public let followUp: FeedbackFollowUp?
}

public struct ActionOption: Sendable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
}

public struct ActionElement: Sendable, Identifiable {
    public let url: String?
    public let id: String
    public let type: String
    public let label: String
    public let value: String?
    public let description: String?
    public let options: [ActionOption]
    public let inputType: String?
    public let placeholder: String?
    public let required: Bool
}

public struct ActionSet: Sendable {
    public let elements: [ActionElement]
    public let submitLabel: String?
    public let submitId: String?
    public let renderId: String?
    public let submittedActionId: String?
    public let submittedActionIds: [String]

    public var hasElements: Bool { !elements.isEmpty }
}

public struct ChannelFallbackItem: Sendable, Identifiable {
    public let id = UUID()
    public let type: String
    public let payload: String
}

public struct RichContent: Sendable {
    /// Recognized component keys in the order they appeared in the incoming payload.
    public let componentOrder: [String]
    public let markdown: String?
    public let adaptiveCard: String?
    public let html: String?
    public let slack: String?
    public let agUI: String?
    public let whatsapp: String?
    public let carousel: CarouselTemplate?
    public let quickReplies: [QuickReply]?
    public let deepLink: DeepLinkTemplate?
    public let image: MediaContent?
    public let video: MediaContent?
    public let audio: MediaContent?
    public let file: FileContent?
    public let list: ListTemplate?
    public let kpi: KPITemplate?
    public let table: TableTemplate?
    public let chart: ChartTemplate?
    public let form: FormTemplate?
    public let progress: ProgressTemplate?
    public let feedback: FeedbackTemplate?
    public let extensions: [String: AnySendable]

    public var channelFallbackItems: [ChannelFallbackItem] {
        [
            ("adaptive_card", adaptiveCard),
            ("slack", slack),
            ("ag_ui", agUI),
            ("whatsapp", whatsapp),
        ].compactMap { type, value in
            guard let trimmed = value?.trimmed, !trimmed.isEmpty else { return nil }
            return ChannelFallbackItem(type: type, payload: trimmed)
        }
    }

    public func extensionValue(for type: String) -> Any? {
        guard let value = extensions[type]?.value, RichContentParser.hasRenderableValue(value) else { return nil }
        return value
    }
}

extension Message {
    public var rawRichContent: [String: Any]? {
        guard let metadata else { return nil }
        if let direct = RichContentParser.dictionary(metadata["richContent"]?.value) { return direct }
        if let direct = RichContentParser.dictionary(metadata["rich_content"]?.value) { return direct }
        return nil
    }

    public var richContent: RichContent? {
        rawRichContent.flatMap {
            RichContentParser.parseRichContent(
                $0, componentOrder: metadata?["_sdkRichContentOrder"]?.value as? [String])
        }
    }

    public var rawActions: [String: Any]? {
        guard let metadata else { return nil }
        return RichContentParser.dictionary(metadata["actions"]?.value)
    }

    public var actions: ActionSet? {
        rawActions.flatMap(RichContentParser.parseActions)
    }
}

enum RichContentParser {
    static let knownKeys: Set<String> = [
        "markdown", "adaptive_card", "html", "slack", "ag_ui", "whatsapp",
        "carousel", "quick_replies", "deep_link", "image", "video", "audio", "file",
        "list", "kpi", "table", "chart", "form", "progress", "feedback",
    ]

    static let webRendererOrder = [
        "markdown", "html", "channel_fallback", "adaptive_card", "carousel", "image", "video", "audio", "file",
        "list", "kpi", "table", "chart", "form", "progress", "feedback", "quick_replies", "deep_link",
    ]

    static func parseRichContent(_ json: [String: Any], componentOrder: [String]? = nil) -> RichContent? {
        var extensions: [String: AnySendable] = [:]
        for (key, value) in json where !knownKeys.contains(key) {
            extensions[key] = AnySendable(value)
        }
        var orderedTypes: [String] = []
        let preferredOrder = componentOrder ?? []
        for key in preferredOrder + webRendererOrder {
            let type = ["adaptive_card", "slack", "ag_ui", "whatsapp"].contains(key) ? "channel_fallback" : key
            if (knownKeys.contains(type) || type == "channel_fallback"), !orderedTypes.contains(type) {
                orderedTypes.append(type)
            }
        }
        let content = RichContent(
            componentOrder: orderedTypes,
            markdown: string(json["markdown"]),
            adaptiveCard: string(json["adaptive_card"]),
            html: string(json["html"]),
            slack: string(json["slack"]),
            agUI: string(json["ag_ui"]),
            whatsapp: string(json["whatsapp"]),
            carousel: dictionary(json["carousel"]).flatMap(parseCarousel),
            quickReplies: array(json["quick_replies"])?.compactMap { dictionary($0).flatMap(parseQuickReply) }
                .nilIfEmpty,
            deepLink: dictionary(json["deep_link"]).flatMap(parseDeepLink),
            image: dictionary(json["image"]).flatMap(parseMedia),
            video: dictionary(json["video"]).flatMap(parseMedia),
            audio: dictionary(json["audio"]).flatMap(parseMedia),
            file: dictionary(json["file"]).flatMap(parseFile),
            list: dictionary(json["list"]).flatMap(parseList),
            kpi: dictionary(json["kpi"]).flatMap(parseKPI),
            table: dictionary(json["table"]).flatMap(parseTable),
            chart: dictionary(json["chart"]).flatMap(parseChart),
            form: dictionary(json["form"]).flatMap(parseForm),
            progress: dictionary(json["progress"]).map(parseProgress),
            feedback: dictionary(json["feedback"]).flatMap(parseFeedback),
            extensions: extensions
        )
        return hasRenderableContent(content) ? content : nil
    }

    static func parseActions(_ json: [String: Any]) -> ActionSet? {
        let elements =
            array(json["elements"])?.compactMap { raw -> ActionElement? in
                guard let item = dictionary(raw),
                    let id = string(item["id"]), !id.isEmpty,
                    let label = string(item["label"]), !label.isEmpty
                else { return nil }
                return ActionElement(
                    url: string(item["url"]),
                    id: id,
                    type: normalizeActionType(string(item["type"])),
                    label: label,
                    value: string(item["value"] ?? item["payload"] ?? item["url"]),
                    description: string(item["description"]),
                    options: parseOptions(item["options"]),
                    inputType: string(item["input_type"]) ?? string(item["inputType"]),
                    placeholder: string(item["placeholder"]),
                    required: bool(item["required"]) ?? false
                )
            } ?? []
        let rawRenderId = string(json["renderId"] ?? json["render_id"])
        let renderId = rawRenderId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? rawRenderId : nil
        let submittedActionId = dictionary(json["submitted"]).flatMap { string($0["actionId"]) }
        var submittedActionIds = (array(json["submittedActionIds"]) ?? []).compactMap(string)
        if let submittedActionId, !submittedActionIds.contains(submittedActionId) {
            submittedActionIds.append(submittedActionId)
        }
        guard !elements.isEmpty || renderId != nil || submittedActionId != nil || !submittedActionIds.isEmpty else {
            return nil
        }
        return ActionSet(
            elements: elements,
            submitLabel: string(json["submit_label"]),
            submitId: string(json["submit_id"]),
            renderId: renderId,
            submittedActionId: submittedActionId,
            submittedActionIds: submittedActionIds
        )
    }

    private static func parseCarousel(_ json: [String: Any]) -> CarouselTemplate? {
        let cards =
            array(json["cards"])?.compactMap { raw -> CarouselItem? in
                guard let item = dictionary(raw), let title = string(item["title"]), !title.isEmpty else { return nil }
                let buttons =
                    array(item["buttons"])?.compactMap { buttonRaw -> CarouselButton? in
                        guard let button = dictionary(buttonRaw), let label = string(button["label"]), !label.isEmpty
                        else { return nil }
                        return CarouselButton(
                            value: string(button["value"] ?? button["payload"]), url: string(button["url"]),
                            id: string(button["id"]) ?? UUID().uuidString,
                            type: string(button["type"]) ?? "button",
                            label: label,
                            options: (array(button["options"]) ?? []).compactMap { dictionary($0)?.sendableDictionary }
                        )
                    } ?? []
                return CarouselItem(
                    title: title,
                    subtitle: string(item["subtitle"] ?? item["description"]),
                    imageURL: string(item["image_url"] ?? item["imageUrl"]),
                    defaultActionURL: string(item["default_action_url"] ?? item["defaultActionUrl"]),
                    buttons: buttons
                )
            } ?? []
        return cards.isEmpty ? nil : CarouselTemplate(cards: cards)
    }

    private static func parseQuickReply(_ json: [String: Any]) -> QuickReply? {
        guard let label = string(json["label"]), !label.isEmpty else { return nil }
        return QuickReply(
            id: string(json["id"]) ?? label, label: label, iconURL: string(json["icon_url"] ?? json["iconUrl"]))
    }

    private static func parseDeepLink(_ json: [String: Any]) -> DeepLinkTemplate? {
        let text = nonEmptyString(json["text"])
        let elements = array(json["elements"])?.prefix(50).compactMap { raw -> DeepLinkElement? in
            guard let item = dictionary(raw),
                let title = nonEmptyString(item["title"]),
                let url = nonEmptyString(item["url"])
            else { return nil }
            let navigation = string(item["navigation_type"])?.lowercased() == "internal"
                ? DeepLinkNavigation.internalLink : .external
            return DeepLinkElement(title: title, url: url, navigation: navigation)
        } ?? []
        guard text != nil || !elements.isEmpty else { return nil }
        return DeepLinkTemplate(text: text, lang: string(json["lang"]), elements: elements)
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = string(raw)?.templateTrimmed, !value.isEmpty else { return nil }
        return value
    }

    private static func parseMedia(_ json: [String: Any]) -> MediaContent? {
        guard let url = string(json["url"]), !url.trimmed.isEmpty else { return nil }
        return MediaContent(
            url: url, alt: string(json["alt"]), thumbnailURL: string(json["thumbnail_url"] ?? json["thumbnailUrl"]),
            caption: string(json["caption"]))
    }

    private static func parseFile(_ json: [String: Any]) -> FileContent? {
        guard let url = string(json["url"]), !url.trimmed.isEmpty else { return nil }
        return FileContent(
            url: url, filename: string(json["filename"]) ?? URL(string: url)?.lastPathComponent ?? "Attachment",
            sizeBytes: int(json["size_bytes"] ?? json["sizeBytes"]),
            mimeType: string(json["mime_type"] ?? json["mimeType"]))
    }

    private static func parseList(_ json: [String: Any]) -> ListTemplate? {
        let items =
            array(json["items"])?.compactMap { raw -> ListTemplateItem? in
                guard let item = dictionary(raw), let title = string(item["title"]), !title.isEmpty else { return nil }
                return ListTemplateItem(
                    title: title, subtitle: string(item["subtitle"] ?? item["description"]),
                    imageURL: string(item["image_url"] ?? item["imageUrl"]),
                    defaultActionURL: string(item["default_action_url"] ?? item["defaultActionUrl"]))
            } ?? []
        return items.isEmpty ? nil : ListTemplate(title: string(json["title"]), items: items)
    }

    private static func parseKPI(_ json: [String: Any]) -> KPITemplate? {
        guard let label = string(json["label"]), !label.trimmed.isEmpty else { return nil }
        return KPITemplate(
            label: label, value: json["value"].map(AnySendable.init), unit: string(json["unit"]),
            trend: string(json["trend"]), iconURL: string(json["icon_url"] ?? json["iconUrl"]))
    }

    private static func parseTable(_ json: [String: Any]) -> TableTemplate? {
        let columns =
            array(json["columns"])?.compactMap { raw -> TableColumn? in
                guard let item = dictionary(raw) else { return nil }
                let key = string(item["key"]) ?? ""
                let header = string(item["header"]) ?? key
                guard !key.isEmpty || !header.isEmpty else { return nil }
                return TableColumn(
                    id: key.isEmpty ? header : key, key: key, header: header, align: string(item["align"]))
            } ?? []
        let rows = array(json["rows"])?.compactMap { dictionary($0)?.sendableDictionary } ?? []
        guard !columns.isEmpty, !rows.isEmpty else { return nil }
        return TableTemplate(
            columns: columns, rows: rows, maxVisibleRows: int(json["max_visible_rows"] ?? json["maxVisibleRows"]))
    }

    private static func parseChart(_ json: [String: Any]) -> ChartTemplate? {
        let points =
            array(json["data"])?.compactMap { raw -> ChartDataPoint? in
                guard let item = dictionary(raw) else { return nil }
                return ChartDataPoint(
                    label: string(item["label"]) ?? "", value: double(item["value"]) ?? 0, color: string(item["color"]))
            } ?? []
        return points.isEmpty
            ? nil
            : ChartTemplate(
                type: string(json["type"]) ?? "bar", title: string(json["title"]), data: Array(points.prefix(100)))
    }

    private static func parseForm(_ json: [String: Any]) -> FormTemplate? {
        let fields =
            array(json["fields"])?.compactMap { raw -> FormTemplateField? in
                guard let item = dictionary(raw), let id = string(item["id"]), !id.isEmpty else { return nil }
                return FormTemplateField(
                    id: id,
                    type: string(item["type"]) ?? "input",
                    label: string(item["label"]) ?? id,
                    value: string(item["value"]),
                    options: parseOptions(item["options"]).map {
                        FormFieldOption(id: $0.id, label: $0.label, description: $0.description)
                    },
                    inputType: string(item["input_type"]) ?? string(item["inputType"]),
                    placeholder: string(item["placeholder"]),
                    required: bool(item["required"]) ?? false
                )
            } ?? []
        return fields.isEmpty
            ? nil
            : FormTemplate(
                title: string(json["title"]), fields: fields,
                submitLabel: string(json["submit_label"]) ?? string(json["submitLabel"]))
    }

    private static func parseProgress(_ json: [String: Any]) -> ProgressTemplate {
        ProgressTemplate(
            label: string(json["label"]), value: double(json["value"]) ?? 0, max: double(json["max"]) ?? 100,
            variant: string(json["variant"]) ?? "bar")
    }

    private static func parseFeedback(_ json: [String: Any]) -> FeedbackTemplate? {
        guard let prompt = string(json["prompt"]), !prompt.trimmed.isEmpty else { return nil }
        let rawFollowUp = dictionary(json["follow_up"]) ?? dictionary(json["followUp"])
        let followUp = rawFollowUp.map { value in
            let questions = dictionary(value["questions"])?.reduce(into: [String: String]()) { result, pair in
                result[pair.key] = displayString(pair.value)
            } ?? [:]
            return FeedbackFollowUp(
                enabled: bool(value["enabled"]) ?? false,
                answerType: string(value["answer_type"]) ?? string(value["answerType"]) ?? "text",
                ratingType: string(value["rating_type"]) ?? string(value["ratingType"]),
                questions: questions)
        }
        let commentRatings = (array(json["comment_ratings"]) ?? array(json["commentRatings"]) ?? [])
            .compactMap(int)
        return FeedbackTemplate(
            prompt: prompt, type: string(json["type"]) ?? "stars", max: int(json["max"]) ?? 5,
            ratingDisplay: string(json["rating_display"]) ?? string(json["ratingDisplay"]),
            submitLabel: string(json["submit_label"]) ?? string(json["submitLabel"]),
            pendingMessage: string(json["pending_message"]) ?? string(json["pendingMessage"]),
            successMessage: string(json["success_message"]) ?? string(json["successMessage"]),
            errorMessage: string(json["error_message"]) ?? string(json["errorMessage"]),
            commentThreshold: int(json["comment_threshold"]) ?? int(json["commentThreshold"]),
            commentVisibility: string(json["comment_visibility"]) ?? string(json["commentVisibility"]),
            commentRatings: commentRatings,
            commentPrompt: string(json["comment_prompt"]) ?? string(json["commentPrompt"]),
            commentPlaceholder: string(json["comment_placeholder"]) ?? string(json["commentPlaceholder"]),
            followUp: followUp)
    }

    private static func parseOptions(_ raw: Any?) -> [ActionOption] {
        array(raw)?.compactMap { optionRaw -> ActionOption? in
            guard let option = dictionary(optionRaw) else { return nil }
            let id = string(option["id"]) ?? string(option["value"]) ?? string(option["label"]) ?? UUID().uuidString
            let label = string(option["label"]) ?? id
            return ActionOption(id: id, label: label, description: string(option["description"]))
        } ?? []
    }

    private static func hasRenderableContent(_ content: RichContent) -> Bool {
        [
            content.markdown, content.adaptiveCard, content.html, content.slack,
            content.agUI, content.whatsapp,
        ].contains { !($0?.trimmed.isEmpty ?? true) }
            || content.carousel != nil
            || !(content.quickReplies?.isEmpty ?? true)
            || content.deepLink != nil
            || content.image != nil
            || content.video != nil
            || content.audio != nil
            || content.file != nil
            || content.list != nil
            || content.kpi != nil
            || content.table != nil
            || content.chart != nil
            || content.form != nil
            || content.progress != nil
            || content.feedback != nil
            || content.extensions.values.contains { hasRenderableValue($0.value) }
    }

    static func hasRenderableValue(_ value: Any) -> Bool {
        if let string = value as? String { return !string.trimmed.isEmpty }
        if let map = dictionary(value) { return !map.isEmpty }
        if let list = array(value) { return !list.isEmpty }
        return !(value is NSNull)
    }

    static func dictionary(_ raw: Any?) -> [String: Any]? {
        if let wrapped = raw as? AnySendable { return dictionary(wrapped.value) }
        if let value = raw as? [String: Any] { return value }
        if let value = raw as? [String: AnySendable] { return value.mapValues(\.value) }
        return nil
    }

    static func array(_ raw: Any?) -> [Any]? {
        if let wrapped = raw as? AnySendable { return array(wrapped.value) }
        if let value = raw as? [Any] { return value }
        if let value = raw as? [AnySendable] { return value.map(\.value) }
        return nil
    }

    static func string(_ raw: Any?) -> String? {
        if let wrapped = raw as? AnySendable { return string(wrapped.value) }
        if let value = raw as? String { return value }
        if let value = raw as? CustomStringConvertible, !(value is NSNull) { return value.description }
        return nil
    }

    static func bool(_ raw: Any?) -> Bool? {
        if let wrapped = raw as? AnySendable { return bool(wrapped.value) }
        if let value = raw as? Bool { return value }
        if let value = raw as? String { return Bool(value) }
        return nil
    }

    static func int(_ raw: Any?) -> Int? {
        if let wrapped = raw as? AnySendable { return int(wrapped.value) }
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    static func double(_ raw: Any?) -> Double? {
        if let wrapped = raw as? AnySendable { return double(wrapped.value) }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    static func displayString(_ raw: Any?) -> String {
        guard let raw, !(raw is NSNull) else { return "" }
        if let value = raw as? String { return value }
        if let value = raw as? CustomStringConvertible { return value.description }
        return "\(raw)"
    }

    private static func normalizeActionType(_ raw: String?) -> String {
        switch raw {
        case "button", "select", "input": return raw!
        default: return "button"
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    fileprivate var sendableDictionary: [String: AnySendable] { mapValues(AnySendable.init) }
}

extension Array {
    fileprivate var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
