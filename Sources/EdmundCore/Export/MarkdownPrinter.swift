import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - MarkdownPrinter
//
// Export-to-PDF and Print over the same themed HTML the Read mode renders, using
// the same PDF *creator* — `WKWebView.printOperation` — so both are real vector
// text with native pagination. Export sets `jobDisposition = .save` to write the
// file headlessly; Print shows the system dialog. They remain separate entry
// points so Export can grow its own settings (margins, page size, …) later.
//
// `printOperation` is run via `runModal(for:)` (a nested event loop) rather than
// `op.run()` — the latter blocks the main thread inside the WKWebView load
// callback and deadlocks, since WebKit rendering also needs the main thread.
@MainActor
public enum MarkdownPrinter {

    /// Prompts for a PDF destination and writes the document as a paginated
    /// vector PDF.
    public static func exportPDF(markdown: String,
                                 theme: EditorTheme,
                                 callouts: [String: CalloutStyle],
                                 options: ReadRenderOptions = .default,
                                 suggestedName: String,
                                 window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"

        let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                     callouts: callouts, dark: false, options: options)
        let begin: (URL) -> Void = { url in
            let info = makePrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            PrintJob.start(html: html, parentWindow: window, printInfo: info, showsPanel: false)
        }

        if let window {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { begin(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            begin(url)
        }
    }

    /// Shows the native Print dialog for `markdown`.
    public static func print(markdown: String,
                             theme: EditorTheme,
                             callouts: [String: CalloutStyle],
                             options: ReadRenderOptions = .default,
                             window: NSWindow?) {
        let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                     callouts: callouts, dark: false, options: options)
        PrintJob.start(html: html, parentWindow: window, printInfo: makePrintInfo(), showsPanel: true)
    }

    /// US-Letter with 0.75" margins; WKWebView reflows content to the imageable
    /// width and paginates.
    static func makePrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let margin: CGFloat = 54
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin;  info.rightMargin = margin
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

// MARK: - PrintJob
//
// Loads HTML into a WKWebView placed in a real (off-screen, non-activating)
// window so AppKit can draw it, then runs printOperation via runModal(for:).
// Retains itself until the operation completes.
@MainActor
private final class PrintJob: NSObject, WKNavigationDelegate {

    private static var live: Set<PrintJob> = []

    private let webView: WKWebView
    private let offscreenWindow: NSWindow
    private let parentWindow: NSWindow?
    private let printInfo: NSPrintInfo
    private let showsPanel: Bool

    static func start(html: String, parentWindow: NSWindow?,
                      printInfo: NSPrintInfo, showsPanel: Bool) {
        let job = PrintJob(html: html, parentWindow: parentWindow,
                           printInfo: printInfo, showsPanel: showsPanel)
        live.insert(job)
    }

    private init(html: String, parentWindow: NSWindow?,
                 printInfo: NSPrintInfo, showsPanel: Bool) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000),
                            configuration: config)

        offscreenWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.contentView = webView
        offscreenWindow.orderBack(nil)

        self.parentWindow = parentWindow
        self.printInfo = printInfo
        self.showsPanel = showsPanel
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = showsPanel
        op.showsProgressPanel = showsPanel
        if let parentWindow {
            op.runModal(for: parentWindow, delegate: self,
                        didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
        } else {
            op.run()
            cleanup()
        }
    }

    // QUIRK: for a `.save` (headless export) job, NSPrintOperation runs
    // `_continueModalOperationToTheEnd` on a *spawned* thread and invokes this
    // didRun callback off the main thread. `cleanup()` closes an NSWindow, which
    // must happen on main — so this callback is `nonisolated` (otherwise the
    // Swift-6 main-actor check traps when AppKit calls it off-main) and hops back
    // to the main actor before touching any AppKit state.
    @objc nonisolated func printDidRun(_ op: NSPrintOperation, success: Bool,
                                       contextInfo: UnsafeMutableRawPointer?) {
        Task { @MainActor in self.cleanup() }
    }

    private func cleanup() {
        offscreenWindow.close()
        PrintJob.live.remove(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { cleanup() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { cleanup() }
}
