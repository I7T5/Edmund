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
        // QUIRK: `isInspectable` (macOS 13.3+) marks the webview as inspectable
        // but does NOT add the "Inspect Element" context menu on its own. The
        // legacy `developerExtrasEnabled` preference key is what actually shows
        // the menu item. Both must be set for right-click → Inspect Element to
        // work; the developer tools must also be enabled in Safari's settings.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        super.init(frame: .zero, configuration: config)
        coordinator.owner = self
        navigationDelegate = coordinator
        if #available(macOS 13.3, *) { isInspectable = true }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called when the user activates a `[[wikilink]]` — the (decoded) target is
    /// routed through the app's document graph rather than navigating the webview.
    public var onOpenWikiLink: ((String) -> Void)?

    /// Called when the user activates a relative/internal markdown link
    /// destination (e.g. `[text](other.md)`), routed the same way.
    public var onOpenInternalLink: ((String) -> Void)?

    /// The most recent render inputs, so the view can re-render itself when the
    /// system appearance flips (light ↔ dark) without the document re-driving it.
    private var pending: (markdown: String, theme: EditorTheme,
                          callouts: [String: CalloutStyle], baseURL: URL?,
                          options: ReadRenderOptions)?

    /// Renders `markdown` with the given theme; appearance is resolved from the
    /// view itself. `baseURL` is the document's directory (for resolving relative
    /// image paths to inline).
    public func render(markdown: String,
                       theme: EditorTheme,
                       callouts: [String: CalloutStyle],
                       baseURL: URL? = nil,
                       options: ReadRenderOptions = .default) {
        pending = (markdown, theme, callouts, baseURL, options)
        reloadHTML()
    }

    func reloadHTML() {
        guard let p = pending else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let html = DocumentHTML.full(markdown: p.markdown, theme: p.theme,
                                     callouts: p.callouts, dark: dark,
                                     baseURL: p.baseURL, options: p.options)
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

    /// Weak back-reference so the coordinator can re-inject HTML on reload
    /// without needing the webview to be its own delegate.
    weak var owner: ReadModeWebView?

    // QUIRK: use the *async* form of this delegate method, not the
    // completion-handler form. Under Swift 6 the SDK annotates the
    // completion-handler's closure (`@MainActor @Sendable`); a plain
    // `@escaping (WKNavigationActionPolicy) -> Void` does NOT match the
    // requirement, so the compiler exposes it under the naïve selector
    // `webView:decidePolicyFor:decisionHandler:` instead of the real
    // `webView:decidePolicyForNavigationAction:decisionHandler:`. WebKit's
    // `respondsToSelector:` check then fails and the method is never called —
    // every link navigates in-view. The async form matches the requirement
    // (`webView(_:decidePolicyFor:)`) exactly and registers the correct selector.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // QUIRK: the page is loaded via `loadHTMLString(_, baseURL: nil)`, so the
        // document URL is `about:blank`. A user-triggered or WebKit-triggered
        // reload navigates back to `about:blank` and clears the content. Intercept
        // it and re-inject the HTML ourselves instead of allowing the blank reload.
        if navigationAction.navigationType == .reload {
            owner?.reloadHTML()
            return .cancel
        }
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased()

        // `[[wikilink]]`s and relative/internal markdown links carry their target
        // in a private scheme (the renderer classifies them), so routing doesn't
        // depend on how WebKit rewrites relative hrefs under `baseURL: nil`.
        // Decode the target and route it through the app's document graph.
        if scheme == HTMLRenderer.wikiScheme || scheme == HTMLRenderer.linkScheme {
            let target = decodeTarget(url, scheme: scheme!)
            if scheme == HTMLRenderer.wikiScheme {
                owner?.onOpenWikiLink?(target)
            } else {
                owner?.onOpenInternalLink?(target)
            }
            return .cancel
        }
        // Decide by URL scheme, not navigation type: with `baseURL: nil` a click
        // does not reliably report `.linkActivated`. A real web scheme is an
        // external link to hand off to the browser; everything else (the
        // about:blank initial load, in-page `#fragment` scrolls, data:) loads in place.
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            NSWorkspace.shared.open(url)
            return .cancel
        }
        return .allow
    }

    /// Recovers the percent-decoded target from a private-scheme URL
    /// (`scheme:encoded`), which has no `//` authority.
    private func decodeTarget(_ url: URL, scheme: String) -> String {
        let raw = String(url.absoluteString.dropFirst(scheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }
}
