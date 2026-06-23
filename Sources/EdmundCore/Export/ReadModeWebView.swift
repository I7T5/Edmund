import AppKit
import WebKit

// MARK: - ReadModeWebView
//
// The WKWebView that backs Read mode. It is a pure renderer of the user's own
// document: JavaScript is disabled, all assets are inlined (so no file/network
// reach), and navigation is intercepted — internal scrolling stays, external
// links open in the default browser, and the view never navigates away from the
// rendered document (§G).
@MainActor
public final class ReadModeWebView: WKWebView, WKNavigationDelegate {

    public init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        super.init(frame: .zero, configuration: config)
        navigationDelegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The most recent render inputs, so the view can re-render itself when the
    /// system appearance flips (light ↔ dark) without the document re-driving it.
    private var pending: (markdown: String, theme: EditorTheme, callouts: [String: CalloutStyle])?

    /// Renders `markdown` with the given theme; appearance is resolved from the
    /// view itself.
    public func render(markdown: String,
                       theme: EditorTheme,
                       callouts: [String: CalloutStyle]) {
        pending = (markdown, theme, callouts)
        reloadHTML()
    }

    private func reloadHTML() {
        guard let p = pending else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let html = DocumentHTML.full(markdown: p.markdown, theme: p.theme,
                                     callouts: p.callouts, dark: dark)
        loadHTMLString(html, baseURL: nil)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reloadHTML()
    }

    // MARK: Navigation policy

    public func webView(_ webView: WKWebView,
                        decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme ?? ""

        // Allow the initial loadHTMLString load and in-page anchor scrolls.
        // When baseURL is nil, both come through as about:blank (or about:blank#anchor),
        // not as .linkActivated — so checking navigationType alone is not reliable;
        // check the URL scheme instead.
        if scheme == "about" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }

        // External links → default browser. The read view never navigates away.
        if scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
