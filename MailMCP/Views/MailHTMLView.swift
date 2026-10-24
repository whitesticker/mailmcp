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
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.render(html: html, allowRemoteContent: allowRemoteContent, in: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var renderedKey: Int?
        private var renderToken = 0

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
