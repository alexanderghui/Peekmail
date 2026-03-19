import SwiftUI
import WebKit

class EditableWKWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                evaluateJavaScript("document.execCommand('copy')") { _, _ in }
                return true
            case "v":
                if let text = NSPasteboard.general.string(forType: .string) {
                    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "'", with: "\\'")
                        .replacingOccurrences(of: "\n", with: "\\n")
                        .replacingOccurrences(of: "\r", with: "\\r")
                    evaluateJavaScript("document.execCommand('insertText', false, '\(escaped)')") { _, _ in }
                }
                return true
            case "x":
                evaluateJavaScript("document.execCommand('cut')") { _, _ in }
                return true
            case "a":
                evaluateJavaScript("document.execCommand('selectAll')") { _, _ in }
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct GmailWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private func isGoogleDomain(_ host: String) -> Bool {
            let googleDomains = [
                "google.com", "googleapis.com", "gstatic.com", "googleusercontent.com",
                "google.co", "youtube.com", "google-analytics.com", "googletagmanager.com",
                "googlesyndication.com", "googleadservices.com", "doubleclick.net",
                "gmail.com", "google.com.au", "google.co.uk", "google.ca",
                "recaptcha.net", "goog"
            ]
            return googleDomains.contains { host.hasSuffix($0) } || host.contains("google")
        }

        private func shouldOpenExternally(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            let host = url.host?.lowercased() ?? ""

            // Never open about:blank, data:, or javascript: URLs externally
            if scheme == "about" || scheme == "data" || scheme == "javascript" || scheme == "blob" {
                return false
            }

            // Keep Google domains in the WebView
            if isGoogleDomain(host) {
                return false
            }

            // Everything else opens in default browser
            return scheme == "http" || scheme == "https" || scheme == "mailto"
        }

        // Handle new window requests (e.g., target="_blank" links) — open non-Google in browser
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if shouldOpenExternally(url) {
                    NSWorkspace.shared.open(url)
                } else {
                    webView.load(navigationAction.request)
                }
            }
            return nil
        }

        // Handle navigation decisions — allow Google domains, open others externally
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if shouldOpenExternally(url) {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
