import Foundation

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

public struct MessageTimestampSettings: Sendable, Equatable {
    public enum Visibility: String, Sendable { case always, interaction }
    public enum Position: String, Sendable { case above, below }
    public enum TimeFormat: String, Sendable {
        case locale
        case twelveHour = "12h"
        case twentyFourHour = "24h"
    }
    public enum DateFormat: String, Sendable {
        case locale
        case monthDayYear = "mm-dd-yy"
        case dayMonthYear = "dd-mm-yy"
        case namedMonthDayYear = "mmm-dd-yyyy"
    }
    public var enabled: Bool
    public var visibility: Visibility
    public var position: Position
    public var timeFormat: TimeFormat
    public var dateFormat: DateFormat
    public var customFormat: String?
    public init(
        enabled: Bool = true, visibility: Visibility = .always, position: Position = .below,
        timeFormat: TimeFormat = .twentyFourHour, dateFormat: DateFormat = .locale,
        customFormat: String? = nil
    ) {
        self.enabled = enabled
        self.visibility = visibility
        self.position = position
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
        self.customFormat = customFormat
    }
    init(runtime: [String: Any]) {
        self.init(
            enabled: runtime["messageTimestampEnabled"] as? Bool ?? true,
            visibility: Visibility(rawValue: runtime["messageTimestampVisibility"] as? String ?? "")
                ?? .always,
            position: Position(rawValue: runtime["messageTimestampPosition"] as? String ?? "") ?? .below,
            timeFormat: TimeFormat(rawValue: runtime["messageTimestampTimeFormat"] as? String ?? "")
                ?? .twentyFourHour,
            dateFormat: DateFormat(rawValue: runtime["messageTimestampDateFormat"] as? String ?? "")
                ?? .locale,
            customFormat: runtime["messageTimestampFormat"] as? String)
    }
    init(widgetTheme: WidgetTheme?, configurationTheme: ThemeConfig? = nil) {
        let configuredTimeFormat = TimeFormat(
            rawValue: configurationTheme?.messageTimestampTimeFormat ?? "")
        let configuredDateFormat = DateFormat(
            rawValue: configurationTheme?.messageTimestampDateFormat ?? "")
        let customFormat: String?
        if let configuredFormat = Self.nonEmpty(configurationTheme?.messageTimestampFormat) {
            customFormat = configuredFormat
        } else if configuredTimeFormat == nil, configuredDateFormat == nil {
            customFormat = Self.nonEmpty(widgetTheme?.messageTimestampFormat)
        } else {
            customFormat = nil
        }
        self.init(
            enabled: widgetTheme?.messageTimestampEnabled ?? true,
            visibility: Visibility(rawValue: widgetTheme?.messageTimestampVisibility ?? "") ?? .always,
            position: Position(rawValue: widgetTheme?.messageTimestampPosition ?? "") ?? .below,
            timeFormat: configuredTimeFormat
                ?? TimeFormat(rawValue: widgetTheme?.messageTimestampTimeFormat ?? "") ?? .twentyFourHour,
            dateFormat: configuredDateFormat
                ?? DateFormat(rawValue: widgetTheme?.messageTimestampDateFormat ?? "") ?? .locale,
            customFormat: customFormat)
    }
    public func format(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current)
        -> String
    {
        if let customFormat = Self.nonEmpty(customFormat) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateFormat = customFormat
            return Self.normalize(formatter.string(from: date), formatter: formatter, locale: locale)
        }

        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        switch dateFormat {
        // Match the Web SDK's day-first locale output while keeping the
        // abbreviated month localized for the active locale.
        case .locale: day.dateFormat = "d MMM yyyy"
        case .monthDayYear: day.dateFormat = "MM/dd/yy"
        case .dayMonthYear: day.dateFormat = "dd/MM/yy"
        case .namedMonthDayYear: day.dateFormat = "MMM dd, yyyy"
        }
        let time = DateFormatter()
        time.locale = locale
        time.timeZone = timeZone
        switch timeFormat {
        case .locale: time.timeStyle = .short
        case .twelveHour: time.dateFormat = "h:mm a"
        case .twentyFourHour: time.dateFormat = "HH:mm"
        }
        let localizedTime = Self.normalize(time.string(from: date), formatter: time, locale: locale)
        return day.string(from: date) + " • " + localizedTime
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalize(
        _ value: String, formatter: DateFormatter, locale: Locale
    ) -> String {
        var normalized = value
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        if locale.languageCode == "en" {
            for symbol in [formatter.amSymbol, formatter.pmSymbol].compactMap({ $0 })
                where !symbol.isEmpty
            {
                normalized = normalized.replacingOccurrences(
                    of: symbol, with: symbol.lowercased(), options: [.caseInsensitive])
            }
        }
        return normalized
    }
}
