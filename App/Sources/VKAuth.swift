import SwiftUI
import WebKit

// In-app VK OAuth (implicit flow via Kate Mobile app_id) — user logs in on vk.com, we grab the token.
struct VKAuthWeb: UIViewRepresentable {
    let onToken: (String) -> Void

    // Kate Mobile app_id — the classic client that still grants the messages scope.
    private var authURL: URL {
        URL(string: "https://oauth.vk.com/authorize?client_id=2685278" +
            "&scope=friends,messages,photos,docs,status,groups,offline" +
            "&redirect_uri=https://oauth.vk.com/blank.html" +
            "&display=mobile&response_type=token&revoke=1&v=5.199")!
    }

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.load(URLRequest(url: authURL))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        private var done = false
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let t = token(from: url) {
                fire(t); decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url, let t = token(from: url) { fire(t) }
        }

        private func fire(_ token: String) {
            guard !done else { return }
            done = true
            onToken(token)
        }

        private func token(from url: URL) -> String? {
            let s = url.absoluteString
            guard s.contains("access_token=") else { return nil }
            let frag = url.fragment ?? url.query ?? ""
            for part in frag.split(separator: "&") {
                let kv = part.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "access_token" { return String(kv[1]) }
            }
            return nil
        }
    }
}
