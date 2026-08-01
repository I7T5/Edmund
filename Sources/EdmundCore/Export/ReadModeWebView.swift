import AppKit
import WebKit

// MARK: - ReadModeWebView
//
// The WKWebView that backs Read mode. It is a pure renderer of the user's own
// document: JavaScript is disabled (plus a `script-src 'none'` CSP meta in the
// page itself), all assets are inlined (so no file/network reach), raw HTML
// passes through per GFM but filtered by `HTMLRenderer.filterRawHTML`
// (tagfilter + hardening), and navigation is intercepted — internal scrolling
// stays, external links open in the default browser, and the view never
// navigates away from the rendered document (§G, ARCHITECTURE §10).
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

        // A rendering engine was enabled, installed, or removed (e.g. the
        // Mermaid extension toggled in Settings). Re-render so diagrams appear
        // or fall back to code blocks without the user leaving and re-entering
        // Read mode. Same treatment as an appearance flip; the scroll position
        // is preserved by `reloadHTML()`.
        NotificationCenter.default.addObserver(
            forName: .renderEngineChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadHTML() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Called when the user activates a `[[wikilink]]` — the (decoded) target is
    /// routed through the app's document graph rather than navigating the webview.
    public var onOpenWikiLink: ((String) -> Void)?

    /// Called when the user activates a relative/internal markdown link
    /// destination (e.g. `[text](other.md)`), routed the same way.
    public var onOpenInternalLink: ((String) -> Void)?

    /// Called after a `loadHTMLString` finishes (including any pending scroll
    /// restore, applied first — see `pendingScrollRestore`).
    public var onLoadFinished: (() -> Void)?

    /// A code block's copy button was clicked. Handled entirely here (unlike
    /// `onOpenWikiLink`/`onOpenInternalLink`, which need the app's document
    /// graph to resolve a target) — writing to the pasteboard needs no
    /// document context, so there's nothing for an owner to do.
    fileprivate func handleCopyCode(_ base64: String) {
        guard let data = Data(base64Encoded: base64), let code = String(data: data, encoding: .utf8)
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        flashCopyButtonCopied(base64: base64)
    }

    /// Swaps the clicked button's content to "Copied" for ~1s, then restores
    /// it. Uses `evaluateJavaScript` from the host side, which — per the
    /// QUIRK note on the scroll bridge below — still runs with
    /// `allowsContentJavaScript = false`; that setting only gates script *in
    /// the page*. `base64` (the already-decoded target from
    /// `ReadModeNavigationPolicy`) is re-encoded the same way `HTMLRenderer`
    /// encoded it, to reconstruct the exact href suffix the DOM carries; the
    /// encoding is deterministic and its output alphabet is
    /// alphanumeric-plus-`%`, so it's safe to interpolate as-is.
    private func flashCopyButtonCopied(base64: String) {
        let hrefSuffix = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? base64
        let js = """
        (function() {
          var el = document.querySelector('a[href$="\(hrefSuffix)"]');
          if (!el) return;
          if (el._copyTimer) clearTimeout(el._copyTimer);
          if (el._copyOriginal === undefined) el._copyOriginal = el.innerHTML;
          el.textContent = 'Copied';
          el.classList.add('copied');
          el._copyTimer = setTimeout(function() {
            el.innerHTML = el._copyOriginal;
            el.classList.remove('copied');
          }, 1000);
        })()
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    /// The most recent render inputs, so the view can re-render itself when the
    /// system appearance flips (light ↔ dark) without the document re-driving it.
    private var pending: (markdown: String, theme: EditorTheme,
                          callouts: [String: CalloutStyle], baseURL: URL?,
                          options: ReadRenderOptions)?

    /// A scroll position (source line + fraction into that block) to apply once
    /// the *next* load finishes. Set either by `reloadHTML()` itself (to carry
    /// the current scroll position across an appearance-driven re-render) or
    /// externally via `setPendingScrollRestore` (e.g. an Edit→Read entry point).
    private var pendingScrollRestore: (line: Int, fraction: Double)?

    /// Guards a `readScrollPosition` capture in flight against a second
    /// `reloadHTML()` racing ahead of it — the completion only acts if this
    /// hasn't moved on since it was captured.
    private var loadGeneration = 0

    /// True once the first `loadHTMLString` has been issued. The very first
    /// load has nothing on-screen to capture a scroll position from, so
    /// `reloadHTML()` skips straight to loading instead of awaiting
    /// `readScrollPosition`.
    private var hasLoadedOnce = false

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

    /// Sets the scroll position to restore on the *next* load, for callers that
    /// need to drive where a fresh Read-mode render lands (e.g. entering Read
    /// mode at the Edit-mode caret's position) rather than at the top.
    public func setPendingScrollRestore(line: Int, fraction: Double) {
        pendingScrollRestore = (line: line, fraction: fraction)
    }

    /// The HTML from the most recent `loadHTMLString` call, so a re-render that
    /// produces byte-identical HTML (e.g. a mode-switch re-entry with no
    /// document change) can skip the reload entirely — instant, no white flash.
    private var lastLoadedHTML: String?

    func reloadHTML() {
        guard let p = pending else { return }
        guard hasLoadedOnce else {
            hasLoadedOnce = true
            performLoad(p)
            return
        }
        // Externally-set restores (e.g. Edit→Read entry via
        // `setPendingScrollRestore`) win over self-capture: skip straight to
        // load rather than clobbering the caller's position with the current
        // (pre-switch) scroll offset.
        guard pendingScrollRestore == nil else {
            performLoad(p)
            return
        }
        // Capture the current scroll position before we blow it away with a
        // fresh `loadHTMLString`, so the re-render (appearance flip, settings
        // change) can restore it once the new document finishes loading.
        let generation = loadGeneration
        readScrollPosition { [weak self] restored in
            guard let self, self.loadGeneration == generation else { return }
            self.pendingScrollRestore = restored
            self.loadGeneration += 1
            self.performLoad(p)
        }
    }

    private func performLoad(_ p: (markdown: String, theme: EditorTheme,
                                   callouts: [String: CalloutStyle], baseURL: URL?,
                                   options: ReadRenderOptions)) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        // Kills the white flash between `loadHTMLString` and first paint (most
        // visible in dark mode): the page background shows immediately instead
        // of the system default white.
        underPageBackgroundColor = HTMLTheme.backgroundColor(dark: dark)
        let html = DocumentHTML.full(markdown: p.markdown, theme: p.theme,
                                     callouts: p.callouts, dark: dark,
                                     baseURL: p.baseURL, options: p.options)
        guard html != lastLoadedHTML else {
            // Nothing changed — the document on screen is already correct.
            applyPendingScrollRestoreAndNotify()
            return
        }
        lastLoadedHTML = html
        loadHTMLString(html, baseURL: ReadModeNavigationPolicy.trustedBaseURL)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        reloadHTML()
    }

    // MARK: - Web Inspector (⌥⌘I)

    /// The private `_WKInspector` backing this web view. A standalone WKWebView,
    /// unlike Safari, doesn't bind ⌥⌘I on its own; `isInspectable` /
    /// `developerExtrasEnabled` enable the inspector but never open it.
    private var webInspector: NSObject? { value(forKey: "_inspector") as? NSObject }

    /// Whether the Web Inspector is currently showing for this read view.
    public var isWebInspectorVisible: Bool {
        (webInspector?.value(forKey: "isVisible") as? Bool) ?? false
    }

    /// Opens the Web Inspector on this read view. Wired to the View-menu item
    /// ("Inspect Reader", ⌥⌘I) via `Document.toggleReaderInspector`.
    @objc public func showWebInspector(_ sender: Any?) {
        webInspector?.perform(Selector(("show")))
    }

    /// Closes the Web Inspector, leaving the read view in place.
    @objc public func hideWebInspector(_ sender: Any?) {
        webInspector?.perform(Selector(("hide")))
    }

    /// Append "Inspect Element" (⌥⌘I) to the web view's right-click menu.
    /// Already in Read mode here, so the item is a plain open/close toggle of
    /// the inspector. WebKit's own "Inspect Element" item is dropped first —
    /// it does the same job without the toggle and without the shortcut, so
    /// keeping both would just be a duplicate entry.
    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        menu.items.filter { $0.identifier?.rawValue.contains("InspectElement") == true }
            .forEach(menu.removeItem)
        let item = NSMenuItem(title: "Inspect Element",
                              action: isWebInspectorVisible
                                  ? #selector(hideWebInspector(_:))
                                  : #selector(showWebInspector(_:)),
                              keyEquivalent: "i")
        item.keyEquivalentModifierMask = [.command, .option]
        item.target = self
        menu.addItem(.separator())
        menu.addItem(item)
    }

    /// Forwarded from the navigation coordinator's `didFinish`.
    fileprivate func handleDidFinishLoad() {
        applyPendingScrollRestoreAndNotify()
    }

    /// Applies any pending scroll restore, then notifies the owner the
    /// document is ready. Shared by a real load's `didFinish` and the
    /// cache-hit path in `performLoad` (which has nothing to load, so there's
    /// no `didFinish` to forward from).
    private func applyPendingScrollRestoreAndNotify() {
        if let restore = pendingScrollRestore {
            pendingScrollRestore = nil
            setScrollPosition(line: restore.line, fraction: restore.fraction)
        }
        onLoadFinished?()
    }

    // MARK: - Scroll bridge
    //
    // QUIRK: `evaluateJavaScript` still runs even with
    // `allowsContentJavaScript = false` and the page's `script-src 'none'` CSP
    // (verified empirically) — those two only govern JS *in the page*;
    // API-injected JS is a separate, trusted channel. That's load-bearing here:
    // it's why this bridge can exist while content JS stays fully disabled. All
    // JS below is a static template with only Swift-computed numeric values
    // (Int/Double) interpolated — never document content — so nothing user- or
    // document-controlled ever reaches `evaluateJavaScript`.

    /// Scrolls so the block anchored at source `line` sits at the viewport top,
    /// offset `fraction` (0–1) into the block's rendered height.
    public func setScrollPosition(line: Int, fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        // QUIRK: wrapped in an IIFE — each `evaluateJavaScript` runs as a new
        // program in the page's one global realm, so a top-level `const` here
        // would throw a redeclaration SyntaxError on the second call without an
        // intervening reload (and the scroll would silently no-op).
        let js = """
        (function() { \
        var el = document.getElementById('edmund-l\(line)'); \
        if (el) { var se = document.scrollingElement; \
        se.scrollTop = el.getBoundingClientRect().top + se.scrollTop + \(String(describing: clamped)) * el.offsetHeight; } \
        })()
        """
        evaluateJavaScript(js, completionHandler: nil)
    }

    /// Reads the current scroll position as (anchor source line, fraction into
    /// that block). nil when the document has no anchors or JS fails.
    public func readScrollPosition(completion: @escaping ((line: Int, fraction: Double)?) -> Void) {
        let js = """
        (function() {
          var nodes = document.querySelectorAll('[id^="edmund-l"]');
          if (nodes.length === 0) return '';
          var top = document.scrollingElement.scrollTop;
          var chosen = null;
          for (var i = 0; i < nodes.length; i++) {
            var elTop = nodes[i].getBoundingClientRect().top + top;
            /* 1px tolerance: setScrollPosition puts the anchor's top exactly at
               the viewport top; sub-pixel rounding must not flip the pick to
               the previous block (which would drift the round trip). */
            if (elTop <= top + 1) { chosen = nodes[i]; } else { break; }
          }
          var fraction;
          if (!chosen) {
            chosen = nodes[0];
            fraction = 0;
          } else {
            var chosenTop = chosen.getBoundingClientRect().top + top;
            fraction = (top - chosenTop) / Math.max(1, chosen.offsetHeight);
            if (fraction < 0) fraction = 0;
            if (fraction > 1) fraction = 1;
          }
          return chosen.id.slice(8) + ',' + fraction;
        })()
        """
        evaluateJavaScript(js) { result, error in
            Task { @MainActor in
                guard error == nil, let str = result as? String else {
                    completion(nil)
                    return
                }
                completion(Self.parseScrollPosition(str))
            }
        }
    }

    /// Parses the `"<line>,<fraction>"` string produced by `readScrollPosition`'s
    /// JS. Extracted as a pure helper so it's unit-testable without a webview.
    internal static func parseScrollPosition(_ s: String) -> (line: Int, fraction: Double)? {
        guard !s.isEmpty else { return nil }
        let parts = s.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, let line = Int(parts[0]), let fraction = Double(parts[1]) else {
            return nil
        }
        return (line: line, fraction: fraction)
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
        // QUIRK: the page is loaded with an explicit `about:blank` base URL.
        // A user-triggered or WebKit-triggered
        // reload navigates back to `about:blank` and clears the content. Intercept
        // it and re-inject the HTML ourselves instead of allowing the blank reload.
        switch ReadModeNavigationPolicy.decision(for: navigationAction.request.url,
                                                 navigationType: navigationAction.navigationType) {
        case .reload:
            owner?.reloadHTML()
            return .cancel
        case .openWiki(let target):
            owner?.onOpenWikiLink?(target)
            return .cancel
        case .openInternal(let target):
            owner?.onOpenInternalLink?(target)
            return .cancel
        case .copyCode(let base64):
            owner?.handleCopyCode(base64)
            return .cancel
        case .openExternal(let url):
            NSWorkspace.shared.open(url)
            return .cancel
        case .allow:
            return .allow
        case .cancel:
            return .cancel
        }
    }

    // No completion handler on this one, so — unlike `decidePolicyFor` above —
    // there's no Swift-6 async/completion-handler selector mismatch to worry
    // about; the plain delegate method matches the requirement as written.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.handleDidFinishLoad()
    }
}

// MARK: - Navigation classifier

enum ReadModeNavigationPolicy {

    static let trustedBaseURL = URL(string: "about:blank")!

    enum Decision: Equatable {
        case allow
        case reload
        case openWiki(String)
        case openInternal(String)
        case copyCode(String)
        case openExternal(URL)
        case cancel
    }

    /// Classifies read-mode navigation without touching WebKit/AppKit state. The
    /// generated document is self-contained and loaded against `about:blank`, so
    /// only in-document anchors, Edmund's private schemes, and browser handoffs are
    /// expected. `file:` and other explicit schemes stay out of the webview.
    static func decision(for url: URL?, navigationType: WKNavigationType) -> Decision {
        if navigationType == .reload { return .reload }
        guard let url else { return .allow }
        let scheme = url.scheme?.lowercased()

        // `[[wikilink]]`s and relative/internal markdown links carry their target
        // in a private scheme (the renderer classifies them). Decode the target
        // and route it through the app's document graph.
        if scheme == HTMLRenderer.wikiScheme {
            return .openWiki(decodeTarget(url, scheme: HTMLRenderer.wikiScheme))
        }
        if scheme == HTMLRenderer.linkScheme {
            return .openInternal(decodeTarget(url, scheme: HTMLRenderer.linkScheme))
        }
        if scheme == HTMLRenderer.copyScheme {
            return .copyCode(decodeTarget(url, scheme: HTMLRenderer.copyScheme))
        }
        // Decide by URL scheme, not navigation type: WebKit does not reliably
        // report `.linkActivated` for every click. Real web schemes are handed to
        // the user's browser; `about:` covers the initial document and in-page
        // `#fragment` scrolls; anything else is not fetched in the webview.
        if scheme == "http" || scheme == "https" || scheme == "mailto" {
            return .openExternal(url)
        }
        if scheme == nil || scheme == "about" {
            return .allow
        }
        return .cancel
    }

    /// Recovers the percent-decoded target from a private-scheme URL
    /// (`scheme:encoded`), which has no `//` authority.
    private static func decodeTarget(_ url: URL, scheme: String) -> String {
        let raw = String(url.absoluteString.dropFirst(scheme.count + 1))
        return raw.removingPercentEncoding ?? raw
    }
}
