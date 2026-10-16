import Foundation

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
    public init(
        enabled: Bool = true, visibility: Visibility = .always, position: Position = .below,
        timeFormat: TimeFormat = .locale, dateFormat: DateFormat = .locale
    ) {
        self.enabled = enabled
        self.visibility = visibility
        self.position = position
        self.timeFormat = timeFormat
        self.dateFormat = dateFormat
    }
    init(runtime: [String: Any]) {
        self.init(
            enabled: runtime["messageTimestampEnabled"] as? Bool ?? true,
            visibility: Visibility(rawValue: runtime["messageTimestampVisibility"] as? String ?? "")
                ?? .always,
            position: Position(rawValue: runtime["messageTimestampPosition"] as? String ?? "") ?? .below,
            timeFormat: TimeFormat(rawValue: runtime["messageTimestampTimeFormat"] as? String ?? "")
                ?? .locale,
            dateFormat: DateFormat(rawValue: runtime["messageTimestampDateFormat"] as? String ?? "")
                ?? .locale)
    }
    public func format(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current)
        -> String
    {
        let day = DateFormatter()
        day.locale = locale
        day.timeZone = timeZone
        switch dateFormat {
        case .locale: day.dateStyle = .medium
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
        return day.string(from: date) + " • " + time.string(from: date)
    }
}
