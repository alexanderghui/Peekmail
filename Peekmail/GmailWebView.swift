import SwiftUI
import WebKit
import os

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
        private let logger = Logger(subsystem: "com.peekmail.app", category: "navigation")

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

        private func isWebLink(_ url: URL) -> Bool {
            let scheme = url.scheme?.lowercased() ?? ""
            return scheme == "http" || scheme == "https" || scheme == "mailto"
        }

        // Sign-in popups must stay in the app so the session lands in the account's data store
        private func isAuthPopup(_ url: URL) -> Bool {
            let host = url.host?.lowercased() ?? ""
            return host == "accounts.google.com" || host == "mail.google.com"
        }

        // Gmail wraps email-body links in its safe-redirect URL (google.com/url?q=<destination>),
        // which passes the Google domain check even when the destination is external
        private func unwrapGoogleRedirect(_ url: URL) -> URL {
            guard let host = url.host?.lowercased(),
                  host == "google.com" || host.hasSuffix(".google.com"),
                  url.path == "/url",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let target = components.queryItems?.first(where: { $0.name == "q" || $0.name == "url" })?.value,
                  let targetURL = URL(string: target) else {
                return url
            }
            return targetURL
        }

        // Handle new window requests (e.g., target="_blank" links) — open non-Google in browser
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            logger.info("createWebView url=\(navigationAction.request.url?.absoluteString ?? "nil", privacy: .public)")
            if let url = navigationAction.request.url {
                let destination = unwrapGoogleRedirect(url)
                logger.info("createWebView destination=\(destination.absoluteString, privacy: .public)")
                if isWebLink(destination) && !isAuthPopup(destination) {
                    NSWorkspace.shared.open(destination)
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

            let frameDesc = navigationAction.targetFrame == nil ? "newWindow" : (navigationAction.targetFrame!.isMainFrame ? "mainFrame" : "subFrame")
            logger.info("decidePolicy url=\(url.absoluteString, privacy: .public) frame=\(frameDesc, privacy: .public) type=\(navigationAction.navigationType.rawValue)")

            let destination = unwrapGoogleRedirect(url)

            // New-window requests are clicked links (email CTAs, target="_blank") —
            // those always go to the default browser, even for Google destinations
            // like Docs or YouTube. Only sign-in popups stay in the app.
            if navigationAction.targetFrame == nil {
                if isWebLink(destination) && !isAuthPopup(destination) {
                    NSWorkspace.shared.open(destination)
                    decisionHandler(.cancel)
                    return
                }
                decisionHandler(.allow)
                return
            }

            if shouldOpenExternally(destination) {
                NSWorkspace.shared.open(destination)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
