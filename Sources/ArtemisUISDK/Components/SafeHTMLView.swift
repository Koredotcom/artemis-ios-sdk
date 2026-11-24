import Foundation
import SwiftUI
import WebKit

/// Reconstructs formatting from an allowlist. No authored CSS, handlers, scripts, frames or forms survive.
enum ChatHTMLSanitizer {
    private static let allowed: Set<String> = [
        "p", "div", "span", "br", "hr", "strong", "b", "em", "i", "u", "s", "del",
        "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "code", "ul", "ol", "li", "table",
        "thead", "tbody",
        "tfoot", "tr", "th", "td", "a", "img", "sub", "sup",
    ]
    private static let suppressed: Set<String> = [
        "script", "style", "iframe", "object", "embed", "svg", "math", "template", "noscript",
    ]
    static func sanitize(_ source: String) -> String {
        let source = String(source.prefix(100_000))
        var index = source.startIndex
        var output = ""
        var hidden: [String] = []
        while index < source.endIndex {
            if source[index] != "<" {
                if hidden.isEmpty { output.append(source[index]) }
                index = source.index(after: index)
                continue
            }
            if source[index...].hasPrefix("<!--") {
                guard let end = source.range(of: "-->", range: index..<source.endIndex) else { break }
                index = end.upperBound
                continue
            }
            var end = source.index(after: index)
            var quote: Character?
            while end < source.endIndex {
                let character = source[end]
                if let q = quote {
                    if character == q { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                end = source.index(after: end)
            }
            guard end < source.endIndex else {
                if hidden.isEmpty { output += "&lt;" }
                index = source.index(after: index)
                continue
            }
            var tag = String(source[source.index(after: index)..<end]).templateTrimmed
            index = source.index(after: end)
            let closing = tag.hasPrefix("/")
            if closing {
                tag.removeFirst()
                tag = tag.templateTrimmed
            }
            let name = String(tag.prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber) }))
                .lowercased()
            if suppressed.contains(name) {
                if closing {
                    if let position = hidden.lastIndex(of: name) { hidden.removeSubrange(position...) }
                } else if !tag.hasSuffix("/") {
                    hidden.append(name)
                }
                continue
            }
            guard hidden.isEmpty, allowed.contains(name) else { continue }
            if closing {
                if !["br", "hr", "img"].contains(name) { output += "</\(name)>" }
                continue
            }
            let attrs = attributes(String(tag.dropFirst(name.count)))
            var safe: [String: String] = [:]
            if let title = attrs["title"] { safe["title"] = title }
            if name == "a", let value = attrs["href"], let url = safeURL(value, image: false) {
                safe["href"] = url.absoluteString
            }
            if name == "img" {
                guard let value = attrs["src"], let url = safeURL(value, image: true) else { continue }
                safe["src"] = url.absoluteString
                safe["alt"] = attrs["alt"] ?? ""
            }
            if ["th", "td"].contains(name) {
                for attr in ["colspan", "rowspan"] {
                    if let value = attrs[attr].flatMap(Int.init), (1...100).contains(value) {
                        safe[attr] = String(value)
                    }
                }
            }
            output +=
                "<" + name + safe.keys.sorted().map { " \($0)=\"\(escape(safe[$0]!))\"" }.joined() + ">"
        }
        return output
    }
    private static func attributes(_ value: String) -> [String: String] {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#)
        else { return [:] }
        var result: [String: String] = [:]
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)) {
            guard let name = Range(match.range(at: 1), in: value) else { continue }
            let content = (2...4).compactMap { Range(match.range(at: $0), in: value) }.first
            if let content {
                result[String(value[name]).lowercased()] = decodeEntities(String(value[content]))
            }
        }
        return result
    }
    private static func decodeEntities(_ value: String) -> String {
        let named = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " "]
        guard
            let regex = try? NSRegularExpression(
                pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);"#)
        else { return value }
        var result = value
        for match in regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).reversed() {
            guard let keyRange = Range(match.range(at: 1), in: value),
                let range = Range(match.range, in: result)
            else { continue }
            let key = String(value[keyRange])
            let decoded: String?
            if key.hasPrefix("#") {
                let number =
                    key.hasPrefix("#x") ? UInt32(key.dropFirst(2), radix: 16) : UInt32(key.dropFirst())
                decoded = number.flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                decoded = named[key]
            }
            if let decoded { result.replaceSubrange(range, with: decoded) }
        }
        return result
    }
    static func safeURL(_ value: String, image: Bool) -> URL? {
        // Entity-encoded schemes cannot pass this explicit scheme check.
        guard let url = URL(string: value), url.user == nil, url.password == nil else { return nil }
        if url.isHTTP { return url }
        if !image, ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") { return url }
        return nil
    }
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(
            of: "\"", with: "&quot;"
        )
        .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    static func document(
        _ content: String, theme: ChatTheme?, isUserMessage: Bool = false
    ) -> String {
        func color(_ value: String?, _ fallback: String) -> String {
            guard let value,
                value.range(of: #"^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$"#, options: .regularExpression)
                    != nil
            else { return fallback }
            return value
        }
        let bubbleTextColor = isUserMessage ? theme?.userBubbleTextColor : theme?.assistantBubbleTextColor
        let textColor = color(bubbleTextColor ?? theme?.textColor, isUserMessage ? "#FFFFFF" : "#1F2937")
        let secondaryTextColor = color(theme?.mutedTextColor, "#6B7280")
        let primaryColor = color(theme?.primaryColor, "#6366F1")
        let borderColor = color(theme?.borderColor, "#E5E7EB")
        let baseFontSize = min(24, max(10, theme?.baseFontSize ?? 14))
        let candidate = theme?.fontFamily ?? ""
        let font =
            candidate != "System"
                && candidate.range(of: #"^[A-Za-z0-9 -]{1,80}$"#, options: .regularExpression) != nil
            ? "'" + candidate + "'" : "-apple-system"
        return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: http:; base-uri 'none'; form-action 'none'">
            <style>
            * {
              box-sizing: border-box;
              margin: 0;
              padding: 0;
            }
            body {
              display: flow-root;
              font-family: \(font), sans-serif;
              font-size: \(baseFontSize)px;
              line-height: 1.4;
              color: \(textColor);
              overflow-wrap: break-word;
              word-break: break-word;
              white-space: pre-wrap;
            }
            .rich-text {
              box-sizing: border-box;
              min-width: 0;
              max-width: 100%;
              word-wrap: break-word;
              overflow-wrap: anywhere;
              overflow: visible;
            }
            .rich-text h1, .rich-text h2, .rich-text h3,
            .rich-text h4, .rich-text h5, .rich-text h6 {
              margin: 8px 0 4px;
              line-height: 1.3;
            }
            .rich-text h1 { font-size: 1.4em; }
            .rich-text h2 { font-size: 1.25em; }
            .rich-text h3 { font-size: 1.1em; }
            .rich-text p { margin: 4px 0; }
            .rich-text a {
              color: \(primaryColor);
              text-decoration: underline;
            }
            .rich-text code {
              background: rgba(0,0,0,0.06);
              padding: 1px 5px;
              border-radius: 4px;
              font-size: 0.9em;
              font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace;
            }
            .rich-text pre {
              box-sizing: border-box;
              max-width: 100%;
              min-width: 0;
              background: rgba(0,0,0,0.06);
              padding: 10px 12px;
              border-radius: 8px;
              overflow: visible;
              white-space: pre-wrap;
              overflow-wrap: anywhere;
              word-break: break-word;
              margin: 8px 0;
            }
            .rich-text pre code {
              background: none;
              padding: 0;
              white-space: inherit;
              overflow-wrap: inherit;
              word-break: inherit;
            }
            .rich-text ul, .rich-text ol {
              box-sizing: border-box;
              max-width: 100%;
              margin: 6px 0;
              margin-inline-start: 0.75em;
              list-style-position: outside;
            }
            .rich-text li {
              margin: 2px 0;
              padding-inline-start: 0.15em;
            }
            .rich-text ul { padding-inline-start: 1.75em; }
            .rich-text ol { padding-inline-start: 2em; }
            .rich-text li > ul, .rich-text li > ol {
              margin-top: 0.25em;
              margin-bottom: 0;
            }
            .rich-text img {
              max-width: 100%;
              border-radius: 8px;
              margin: 6px 0;
            }
            .rich-text hr {
              border: none;
              border-top: 1px solid \(borderColor);
              margin: 8px 0;
            }
            .rich-text blockquote {
              border-left: 3px solid \(primaryColor);
              padding-left: 12px;
              margin: 6px 0;
              color: \(secondaryTextColor);
            }
            .rich-text table {
              width: 100%;
              min-width: 0;
              table-layout: fixed;
              border-collapse: collapse;
              margin: 8px 0;
              font-size: 0.95em;
            }
            .rich-text th, .rich-text td {
              border: 1px solid \(borderColor);
              padding: 8px 10px;
              text-align: left;
              vertical-align: top;
              overflow-wrap: anywhere;
              word-break: break-word;
            }
            .rich-text thead { background: rgba(0,0,0,0.04); }
            .rich-text tbody tr:nth-child(even) { background: rgba(0,0,0,0.02); }
            </style>
            </head><body><div class="rich-text">\(sanitize(content))</div></body></html>
            """
    }
}

#if os(iOS)
    private typealias ChatHTMLRepresentable = UIViewRepresentable
#else
    private typealias ChatHTMLRepresentable = NSViewRepresentable
#endif

struct SafeHTMLView: View {
    let content: String
    let isUserMessage: Bool
    @Environment(\.chatTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var height: CGFloat = 100

    init(content: String, isUserMessage: Bool = false) {
        self.content = content
        self.isUserMessage = isUserMessage
    }

    var body: some View {
        HTMLWebView(
            document: ChatHTMLSanitizer.document(
                content, theme: theme, isUserMessage: isUserMessage), height: $height,
            open: { openURL($0) }
        ).frame(height: height)
    }
}
private struct HTMLWebView: ChatHTMLRepresentable {
    let document: String
    @Binding var height: CGFloat
    let open: (URL) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    #if os(iOS)
        func makeUIView(context: Context) -> WKWebView { make(context.coordinator) }
        func updateUIView(_ view: WKWebView, context: Context) {
            update(view, coordinator: context.coordinator)
        }
    #else
        func makeNSView(context: Context) -> WKWebView { make(context.coordinator) }
        func updateNSView(_ view: WKWebView, context: Context) {
            update(view, coordinator: context.coordinator)
        }
    #endif
    private func make(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        #if os(iOS)
            view.isOpaque = false
            view.backgroundColor = .clear
            view.scrollView.contentInsetAdjustmentBehavior = .never
            coordinator.sizeObserver = view.scrollView.observe(\.contentSize, options: [.new]) {
                [weak coordinator, weak view] _, _ in
                Task { @MainActor in
                    guard let view else { return }
                    coordinator?.measureContent(in: view)
                }
            }
        #else
            view.setValue(false, forKey: "drawsBackground")
        #endif
        return view
    }
    private func update(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.parent = self
        guard coordinator.document != document else { return }
        coordinator.document = document
        coordinator.isDocumentReady = false
        view.loadHTMLString(document, baseURL: nil)
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: HTMLWebView
        var document = ""
        var isDocumentReady = false
        var sizeObserver: NSKeyValueObservation?
        init(_ parent: HTMLWebView) { self.parent = parent }
        func resize(_ value: CGFloat) {
            guard value.isFinite else { return }
            let height = min(2000, max(44, ceil(value)))
            if abs(parent.height - height) > 1 { parent.height = height }
        }
        func measureContent(in webView: WKWebView) {
            guard isDocumentReady, webView.bounds.width > 0 else { return }
            let measuredDocument = document
            // Only this fixed, app-owned measurement script runs; content JavaScript stays disabled.
            // contentSize includes the current viewport height, so it cannot reliably shrink a card.
            webView.evaluateJavaScript("document.body.getBoundingClientRect().height") {
                [weak self] value, _ in
                guard let number = value as? NSNumber else { return }
                Task { @MainActor in
                    guard let self, self.isDocumentReady, self.document == measuredDocument else { return }
                    self.resize(CGFloat(truncating: number))
                }
            }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isDocumentReady = true
            measureContent(in: webView)
        }
        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated, let url = action.request.url,
                ChatHTMLSanitizer.safeURL(url.absoluteString, image: false) != nil
            {
                parent.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
