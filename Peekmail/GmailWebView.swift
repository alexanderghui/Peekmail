import SwiftUI
import WebKit

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
        // Handle new window requests (e.g., target="_blank" links) by loading in the same view
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil || !navigationAction.targetFrame!.isMainFrame {
                webView.load(navigationAction.request)
            }
            return nil
        }

        // Handle navigation decisions — allow Google domains, open others externally
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let host = url.host?.lowercased() ?? ""

            // Allow Google domains
            if host.hasSuffix("google.com") || host.hasSuffix("googleapis.com") ||
               host.hasSuffix("gstatic.com") || host.hasSuffix("googleusercontent.com") ||
               host.hasSuffix("accounts.google.com") || host.hasSuffix("google.co") {
                decisionHandler(.allow)
                return
            }

            // Open non-Google links in default browser
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }
    }
}
