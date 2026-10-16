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
    static func document(_ content: String, theme: ChatTheme?) -> String {
        func color(_ value: String?, _ fallback: String) -> String {
            guard let value,
                value.range(of: #"^#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?$"#, options: .regularExpression)
                    != nil
            else { return fallback }
            return value
        }
        let candidate = theme?.fontFamily ?? ""
        let font =
            candidate != "System"
                && candidate.range(of: #"^[A-Za-z0-9 -]{1,80}$"#, options: .regularExpression) != nil
            ? "'" + candidate + "'" : "-apple-system"
        return """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; img-src https: http:; base-uri 'none'; form-action 'none'">
            <style>body{display:flow-root;margin:0;font-family:\(font),sans-serif;font-size:\(theme?.baseFontSize ?? 16)px;color:\(color(theme?.textColor,"#1E293B"));overflow-wrap:anywhere}a{color:\(color(theme?.primaryColor,"#2563EB"))}img{max-width:100%;height:auto}pre{white-space:pre-wrap}table{border-collapse:collapse;width:100%}td,th{padding:6px;border:1px solid \(color(theme?.borderColor,"#64748B"))}blockquote{margin:8px 0;padding-left:12px;border-left:3px solid #64748B}</style>
            </head><body>\(sanitize(content))</body></html>
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
    @Environment(\.chatTheme) private var theme
    @Environment(\.openURL) private var openURL
    @State private var height: CGFloat = 100
    var body: some View {
        HTMLWebView(
            document: ChatHTMLSanitizer.document(content, theme: theme), height: $height,
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
