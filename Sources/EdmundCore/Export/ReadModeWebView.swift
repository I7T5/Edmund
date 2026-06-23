import AppKit
import WebKit

// MARK: - ReadModeWebView
//
// The WKWebView that backs Read mode. It is a pure renderer of the user's own
// document: JavaScript is disabled, all assets are inlined (so no file/network
// reach), and navigation is intercepted — internal scrolling stays, external
// links open in the default browser, and the view never navigates away from the
// rendered document (§G).
//
// The navigation delegate is a *separate* object (not the webview itself). A
// WKWebView that is its own `navigationDelegate` does not reliably receive the
// policy callbacks, so link clicks would navigate in-view instead of opening
// externally; a dedicated, retained coordinator fixes that.
@MainActor
public final class ReadModeWebView: WKWebView {

    private let coordinator = ReadModeNavigationCoordinator()

    public init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        super.init(frame: .zero, configuration: config)
        navigationDelegate = coordinator
        // Allow the Web Inspector (⌥⌘I). Inspecting HTML/CSS is safe: page
        // JavaScript stays disabled, so this opens no execution vector.
        if #available(macOS 13.3, *) { isInspectable = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The most recent render inputs, so the view can re-render itself when the
    /// system appearance flips (light ↔ dark) without the document re-driving it.
    private var pending: (markdown: String, theme: EditorTheme,
                          callouts: [String: CalloutStyle], options: ReadRenderOptions)?

    /// Renders `markdown` with the given theme; appearance is resolved from the
    /// view itself.
    public func render(markdown: String,
                       theme: EditorTheme,
                       callouts: [String: CalloutStyle],
                       options: ReadRenderOptions = .default) {
        pending = (markdown, theme, callouts, options)
        reloadHTML()
    }

    private func reloadHTML() {
        guard let p = pending else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let html = DocumentHTML.full(markdown: p.markdown, theme: p.theme,
                                     callouts: p.callouts, dark: dark, options: p.options)
        loadHTMLString(html, baseURL: nil)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reloadHTML()
    }
}

// MARK: - Navigation policy

/// Intercepts navigation for Read mode: the initial load and in-page anchor
/// scrolls proceed; any link the user activates opens in the default browser and
/// the read view stays put.
@MainActor
private final class ReadModeNavigationCoordinator: NSObject, WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else {
            // Initial loadHTMLString, reloads, in-page fragment scrolls, etc.
            decisionHandler(.allow)
            return
        }
        // A clicked link: open external schemes in the default browser; never
        // navigate the read view away from the document.
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" || scheme == "mailto" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
