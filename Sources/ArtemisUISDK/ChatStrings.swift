import Foundation
import SwiftUI

/// SDK-owned copy only. Server-authored prompts and message content are never translated here.
/// Supply overrides using the English source text as keys, or an ArtemisChat.strings table in the host bundle.
public struct ChatStrings: Sendable, Equatable {
    public var localeIdentifier: String
    public var fallbackLocaleIdentifier: String
    public var overrides: [String: String]
    public var bundleURL: URL
    public init(
        localeIdentifier: String = Locale.current.identifier, fallbackLocaleIdentifier: String = "en",
        overrides: [String: String] = [:], bundle: Bundle = .main
    ) {
        self.localeIdentifier = localeIdentifier
        self.fallbackLocaleIdentifier = fallbackLocaleIdentifier
        self.overrides = overrides
        self.bundleURL = bundle.bundleURL
    }
    public func callAsFunction(_ key: String) -> String {
        if let value = overrides[key] { return value }
        let fallback = Self.defaults[key] ?? key
        guard let root = Bundle(url: bundleURL) else { return fallback }
        let candidates = [
            localeIdentifier, localeIdentifier.replacingOccurrences(of: "_", with: "-"),
            String(localeIdentifier.prefix(while: { $0 != "_" && $0 != "-" })), fallbackLocaleIdentifier,
        ]
        for locale in candidates {
            if let path = root.path(forResource: locale, ofType: "lproj"), let bundle = Bundle(path: path) {
                let value = bundle.localizedString(
                    forKey: key, value: "__artemis_missing__", table: "ArtemisChat")
                if value != "__artemis_missing__" { return value }
            }
        }
        return fallback
    }
    public func format(_ key: String, _ values: [String: String]) -> String {
        // Replace placeholders in the template, never recursively inside user data.
        let template = self(key)
        guard let regex = try? NSRegularExpression(pattern: #"\{([A-Za-z][A-Za-z0-9_]*)\}"#) else {
            return template
        }
        var result = template
        for match in regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
            .reversed()
        {
            guard let keyRange = Range(match.range(at: 1), in: template),
                let range = Range(match.range, in: result),
                let value = values[String(template[keyRange])]
            else { continue }
            result.replaceSubrange(range, with: value)
        }
        return result
    }
    private static let defaults = [
        "validation.required": "This field is required.",
        "validation.option": "Choose one of the available options.",
        "validation.number": "Enter a valid number.",
        "validation.email": "Enter a valid email address.",
        "validation.date": "Choose a valid date.",
        "validation.time": "Choose a valid time.",
    ]
}

private struct ChatStringsKey: EnvironmentKey { static let defaultValue = ChatStrings() }
extension EnvironmentValues {
    var chatStrings: ChatStrings {
        get { self[ChatStringsKey.self] }
        set { self[ChatStringsKey.self] = newValue }
    }
}
