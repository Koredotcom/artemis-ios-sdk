import Foundation
import ImageIO
import SwiftUI

@MainActor enum ChatMarkdownCache {
    private final class Entry: NSObject {
        let text: AttributedString
        init(_ text: AttributedString) { self.text = text }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 100
        cache.totalCostLimit = 512 * 1024
        return cache
    }()
    static func text(
        _ source: String, linkColor: Color? = nil, disabledNumbersHyperlink: Bool = false
    ) -> AttributedString {
        let cacheKey = "\(disabledNumbersHyperlink ? "disabled" : "enabled"):" + source
        if let entry = cache.object(forKey: cacheKey as NSString) {
            return applyingLinkColor(linkColor, to: entry.text)
        }
        var result =
            (try? AttributedString(
                markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
        let unsafeLinks = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return ["http", "https", "mailto", "tel"].contains(url.scheme?.lowercased() ?? "")
                && url.user == nil && url.password == nil ? nil : run.range
        }
        for range in unsafeLinks { result[range].link = nil }
        if !disabledNumbersHyperlink { ChatPhoneNumberLinkifier.apply(to: &result) }
        cache.setObject(Entry(result), forKey: cacheKey as NSString, cost: source.utf8.count * 2)
        return applyingLinkColor(linkColor, to: result)
    }

    private static func applyingLinkColor(_ color: Color?, to source: AttributedString) -> AttributedString {
        var result = source
        let linkedRanges = result.runs.compactMap { run in run.link == nil ? nil : run.range }
        for range in linkedRanges {
            if let color { result[range].foregroundColor = color }
            result[range].underlineStyle = .single
        }
        return result
    }
}

/// Adds the same underlined, tappable treatment to phone numbers that are found in rendered chat text.
@MainActor private enum ChatPhoneNumberLinkifier {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.phoneNumber.rawValue)

    static func apply(to text: inout AttributedString) {
        guard let detector else { return }
        let renderedText = String(text.characters)
        let matches = detector.matches(in: renderedText, range: NSRange(renderedText.startIndex..., in: renderedText))

        for match in matches {
            guard match.resultType == .phoneNumber,
                let stringRange = Range(match.range, in: renderedText),
                let start = AttributedString.Index(stringRange.lowerBound, within: text),
                let end = AttributedString.Index(stringRange.upperBound, within: text),
                let phoneNumber = match.phoneNumber,
                let url = telephoneURL(for: phoneNumber)
            else { continue }

            let attributedRange = start..<end
            let alreadyLinked = text.runs.contains { run in
                run.link != nil && run.range.overlaps(attributedRange)
            }
            guard !alreadyLinked else { continue }

            text[attributedRange].link = url
            text[attributedRange].underlineStyle = .single
        }
    }

    private static func telephoneURL(for phoneNumber: String) -> URL? {
        // A tel URL must not contain formatting whitespace. Keep the international prefix
        // and dialable characters while dropping display-only punctuation.
        var dialableNumber = ""
        for character in phoneNumber {
            if character.isNumber || "*#,;".contains(character) {
                dialableNumber.append(character)
            } else if character == "+", dialableNumber.isEmpty {
                dialableNumber.append(character)
            }
        }
        guard dialableNumber.contains(where: \.isNumber) else { return nil }
        return URL(string: "tel:\(dialableNumber)")
    }
}

/// Shared, bounded decoded-image cache. Download and downsampling stay off the UI thread.
private actor ChatImageCache {
    static let shared = ChatImageCache()
    private final class Entry: NSObject, @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache: NSCache<NSURL, Entry> = {
        let cache = NSCache<NSURL, Entry>()
        cache.totalCostLimit = 8 * 1024 * 1024
        cache.countLimit = 40
        return cache
    }()
    private var requests: [URL: Task<CGImage?, Never>] = [:]
    func image(_ url: URL) async -> CGImage? {
        guard url.isHTTP else { return nil }
        if let cached = cache.object(forKey: url as NSURL) { return cached.image }
        if let request = requests[url] { return await request.value }
        guard requests.count < 32 else { return nil }
        let task = Task.detached { () -> CGImage? in
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                (response as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) == true,
                data.count <= 10 * 1024 * 1024,
                let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        }
        requests[url] = task
        let image = await task.value
        requests[url] = nil
        if let image {
            cache.setObject(Entry(image), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        }
        return image
    }
}
struct TemplateRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: Image?
    var body: some View {
        Group { if let image { content(image) } else { placeholder() } }
            .task(id: url) {
                image = nil
                guard let url, let result = await ChatImageCache.shared.image(url), !Task.isCancelled else {
                    return
                }
                image = Image(decorative: result, scale: 1)
            }
    }
}
