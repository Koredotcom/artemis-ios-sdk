#if canImport(UIKit)
    import SwiftUI
    import UIKit
    import WebKit
    import XCTest
    @testable import ArtemisUISDK

    final class NativeWebFeatureTests: XCTestCase {
        @MainActor func testFormattedHTMLCannotExecuteAuthoredScriptAndRoutesSafeLinksToHost() async throws {
            var opened: URL?
            let view = SafeHTMLView(
                content: """
                    <h2>Formatted title</h2><p><strong>Readable</strong></p>
                    <script>window.authoredScriptRan = true</script>
                    <a href="javascript:window.authoredScriptRan=true">Unsafe</a>
                    <a href="https://example.com/source">Source</a>
                    """
            )
            .environment(
                \.openURL,
                OpenURLAction { url in
                    opened = url
                    return .handled
                }
            )
            .frame(width: 320)
            let controller = UIHostingController(rootView: view)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
                window.rootViewController = nil
            }
            var web: WKWebView?
            for _ in 0..<50 {
                web = findWebView(controller.view)
                if let web, !web.isLoading, web.url != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let browser = try XCTUnwrap(web)
            let text = try await browser.evaluateJavaScript("document.body.innerText") as? String
            XCTAssertTrue(text?.contains("Formatted title") == true)
            XCTAssertTrue(text?.contains("Readable") == true)
            let scriptCount = try await browser.evaluateJavaScript("document.querySelectorAll('script').length") as? Int
            let scriptState = try await browser.evaluateJavaScript("typeof window.authoredScriptRan") as? String
            let safeLinkCount =
                try await browser.evaluateJavaScript("document.querySelectorAll('a[href]').length") as? Int
            XCTAssertEqual(scriptCount, 0)
            XCTAssertEqual(scriptState, "undefined")
            XCTAssertEqual(safeLinkCount, 1)
            _ = try await browser.evaluateJavaScript("document.querySelector('a[href]').click()")
            for _ in 0..<20 where opened == nil { try await Task.sleep(nanoseconds: 50_000_000) }
            XCTAssertEqual(opened?.absoluteString, "https://example.com/source")
        }

        @MainActor func testNestedMarkdownAndTablesFitNarrowNativeContainer() throws {
            let view = ChatMarkdownView(
                content: """
                    # Heading
                    - Parent
                      - Nested child with a long line that wraps inside the available width.
                    > A quoted answer

                    | First column | Second column |
                    | --- | --- |
                    | One | Two |

                    ```swift
                    let value = "A long code line stays inside a horizontal scroll view"
                    ```
                    """
            )
            .frame(width: 288)
            let controller = UIHostingController(rootView: view)
            if #available(iOS 16.0, *) {
                let size = controller.sizeThatFits(in: CGSize(width: 288, height: 2000))
                XCTAssertTrue(size.height.isFinite)
                XCTAssertGreaterThan(size.height, 150)
                XCTAssertLessThanOrEqual(size.width, 288)
            }
        }

        @MainActor private func findWebView(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.lazy.compactMap { self.findWebView($0) }.first
        }
    }
#endif
