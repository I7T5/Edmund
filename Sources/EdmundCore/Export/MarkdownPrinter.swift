import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - MarkdownPrinter
//
// Print and Export-to-PDF over the same themed HTML the Read mode renders. Both
// go through `WKWebView.printOperation`, which lays the document out as **real
// vector text** with native pagination — Print shows the system dialog; Export
// writes the PDF headlessly via `jobDisposition = .save`. This replaces the
// older rasterized (bitmap-page) approach.
@MainActor
public enum MarkdownPrinter {

    /// Shows the native Print dialog for `markdown`.
    public static func print(markdown: String,
                             theme: EditorTheme,
                             callouts: [String: CalloutStyle]) {
        // Print on white paper regardless of the screen appearance.
        let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                     callouts: callouts, dark: false)
        PrintJob.start(html: html, printInfo: makePrintInfo(), showsPanel: true)
    }

    /// Prompts for a destination and writes a vector PDF of `markdown`.
    public static func exportPDF(markdown: String,
                                 theme: EditorTheme,
                                 callouts: [String: CalloutStyle],
                                 suggestedName: String,
                                 window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"

        let begin: (URL) -> Void = { url in
            let info = makePrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                         callouts: callouts, dark: false)
            PrintJob.start(html: html, printInfo: info, showsPanel: false)
        }

        if let window {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { begin(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            begin(url)
        }
    }

    /// US-Letter with 0.75" margins; WKWebView reflows content to the imageable
    /// width and paginates.
    private static func makePrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let margin: CGFloat = 54
        info.topMargin = margin
        info.bottomMargin = margin
        info.leftMargin = margin
        info.rightMargin = margin
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

// MARK: - PrintJob
//
// Loads the HTML into an offscreen WKWebView and runs the print operation once
// the page finishes laying out. Retains itself until the op completes so the
// async load isn't torn down early.
@MainActor
private final class PrintJob: NSObject, WKNavigationDelegate {

    private static var live: Set<PrintJob> = []

    private let webView: WKWebView
    private let printInfo: NSPrintInfo
    private let showsPanel: Bool

    static func start(html: String, printInfo: NSPrintInfo, showsPanel: Bool) {
        let job = PrintJob(html: html, printInfo: printInfo, showsPanel: showsPanel)
        live.insert(job)
    }

    private init(html: String, printInfo: NSPrintInfo, showsPanel: Bool) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // A comfortable layout width; printOperation scales/paginates to paper.
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000),
                                 configuration: config)
        self.printInfo = printInfo
        self.showsPanel = showsPanel
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Let layout settle a runloop turn before printing.
        DispatchQueue.main.async { [self] in
            let op = webView.printOperation(with: printInfo)
            op.showsPrintPanel = showsPanel
            op.showsProgressPanel = showsPanel
            op.run()
            PrintJob.live.remove(self)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        PrintJob.live.remove(self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        PrintJob.live.remove(self)
    }
}
