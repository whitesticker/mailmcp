import AppKit
import SwiftUI
import WebKit

enum MailBodyDocument {
    private static let remoteContentPattern = try? NSRegularExpression(
        pattern: #"(<img[^>]+src\s*=\s*["']?\s*(https?:)?//)|(url\(\s*["']?\s*(https?:)?//)|(background\s*=\s*["']?\s*(https?:)?//)|(<link[^>]+href\s*=\s*["']?\s*(https?:)?//)"#,
        options: [.caseInsensitive]
    )

    static func hasRemoteContent(_ html: String) -> Bool {
        guard let remoteContentPattern else { return true }
        let range = NSRange(html.startIndex..., in: html)
        return remoteContentPattern.firstMatch(in: html, range: range) != nil
    }

    static func html(for message: MailMessage, allowRemoteContent: Bool) -> String {
        if let html = message.bodyHTML, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return wrapHTML(html, allowRemoteContent: allowRemoteContent)
        }
        return wrapPlainText(message.body)
    }

    private static func contentSecurityPolicy(allowRemoteContent: Bool) -> String {
        if allowRemoteContent {
            return "default-src 'none'; img-src * data:; style-src * 'unsafe-inline'; font-src * data:; media-src *"
        }
        return "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"
    }

    private static func wrapHTML(_ html: String, allowRemoteContent: Bool) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemoteContent: allowRemoteContent))">
        <meta name="color-scheme" content="light">
        <style>
        html { background: #ffffff; }
        body { margin: 16px 20px; color: #1d1d1f; font: 14px -apple-system, "Helvetica Neue", sans-serif; word-wrap: break-word; overflow-wrap: anywhere; }
        img { max-width: 100%; height: auto; }
        img[src^="cid:"] { display: none; }
        pre { white-space: pre-wrap; }
        </style>
        </head><body>
        \(html)
        </body></html>
        """
    }

    private static func wrapPlainText(_ text: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy(allowRemoteContent: false))">
        <meta name="color-scheme" content="light dark">
        <style>
        body { margin: 16px 20px; font: 13px -apple-system, "Helvetica Neue", sans-serif; line-height: 1.45; }
        .text { white-space: pre-wrap; word-wrap: break-word; overflow-wrap: anywhere; }
        a { color: -apple-system-control-accent; }
        </style>
        </head><body><div class="text">\(linkified(text))</div></body></html>
        """
    }

    private static func linkified(_ text: String) -> String {
        let source = text.isEmpty ? "(This message has no text.)" : text
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escape(source)
        }
        let ns = source as NSString
        var output = ""
        var cursor = 0
        for match in detector.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { continue }
            output += escape(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let label = escape(ns.substring(with: match.range))
            output += "<a href=\"\(escape(url.absoluteString))\">\(label)</a>"
            cursor = match.range.location + match.range.length
        }
        output += escape(ns.substring(from: cursor))
        return output
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Renders untrusted mail HTML: no JavaScript, no persistent website data, remote loads blocked unless allowed, and links open in the default browser.
struct MailHTMLView: NSViewRepresentable {
    let html: String
    let allowRemoteContent: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        let webView = FittingWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.onWidthChange = { [weak coordinator = context.coordinator, weak webView] in
            guard let coordinator, let webView else { return }
            coordinator.scheduleFit(webView, delayNs: 120_000_000)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(html: html, allowRemoteContent: allowRemoteContent, in: webView)
    }

    final class FittingWebView: WKWebView {
        var onWidthChange: (() -> Void)?
        private var lastWidth: CGFloat = 0

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard abs(newSize.width - lastWidth) > 0.5 else { return }
            lastWidth = newSize.width
            onWidthChange?()
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var renderedKey: Int?
        private var renderToken = 0
        private var fitTask: Task<Void, Never>?

        /// Fixed-width newsletters (often 600–700 px tables) are zoomed out to the reader's width instead of running off the edge.
        @MainActor
        func scheduleFit(_ webView: WKWebView, delayNs: UInt64) {
            fitTask?.cancel()
            fitTask = Task { @MainActor [weak webView] in
                if delayNs > 0 {
                    try? await Task.sleep(nanoseconds: delayNs)
                }
                guard !Task.isCancelled, let webView else { return }
                await Self.fit(webView)
            }
        }

        @MainActor
        private static func fit(_ webView: WKWebView) async {
            let available = webView.bounds.width
            guard available > 0 else { return }
            // Shrinking the root to 1px makes scrollWidth report the narrowest width the content can lay out in, independent of the current zoom.
            let script = """
            const root = document.documentElement;
            const previous = root.style.width;
            root.style.width = '1px';
            const needed = root.scrollWidth;
            root.style.width = previous;
            return needed;
            """
            guard let needed = (try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)) as? Double,
                  needed > 0 else { return }
            let zoom = min(1, max(0.5, Double(available) / needed))
            if abs(webView.pageZoom - zoom) > 0.01 {
                webView.pageZoom = zoom
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.scheduleFit(webView, delayNs: 0) }
        }

        @MainActor
        func render(html: String, allowRemoteContent: Bool, in webView: WKWebView) {
            var hasher = Hasher()
            hasher.combine(html)
            hasher.combine(allowRemoteContent)
            let key = hasher.finalize()
            guard key != renderedKey else { return }
            renderedKey = key
            renderToken += 1
            let token = renderToken
            Task { @MainActor in
                let controller = webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if !allowRemoteContent, let rules = await RemoteContentBlocker.ruleList() {
                    controller.add(rules)
                }
                guard token == self.renderToken else { return }
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let url = navigationAction.request.url
            if navigationAction.navigationType == .other, url?.scheme == "about" || url == nil {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated,
                  let url,
                  ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

@MainActor
private enum RemoteContentBlocker {
    private static var cached: WKContentRuleList?

    static func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        let rules = #"[{"trigger":{"url-filter":"^(https?|ftp|wss?)://"},"action":{"type":"block"}}]"#
        let list = await withCheckedContinuation { (continuation: CheckedContinuation<WKContentRuleList?, Never>) in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "MailMCPBlockRemoteContent",
                encodedContentRuleList: rules
            ) { list, _ in
                continuation.resume(returning: list)
            }
        }
        cached = list
        return list
    }
}
