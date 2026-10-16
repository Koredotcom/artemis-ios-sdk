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
    static func text(_ source: String) -> AttributedString {
        if let entry = cache.object(forKey: source as NSString) { return entry.text }
        let result = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        cache.setObject(Entry(result), forKey: source as NSString, cost: source.utf8.count * 2)
        return result
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
                    kCGImageSourceThumbnailMaxPixelSize: 1024, kCGImageSourceCreateThumbnailWithTransform: true,
                ] as CFDictionary)
        }
        requests[url] = task
        let image = await task.value
        requests[url] = nil
        if let image { cache.setObject(Entry(image), forKey: url as NSURL, cost: image.bytesPerRow * image.height) }
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
                guard let url, let result = await ChatImageCache.shared.image(url), !Task.isCancelled else { return }
                image = Image(decorative: result, scale: 1)
            }
    }
}
