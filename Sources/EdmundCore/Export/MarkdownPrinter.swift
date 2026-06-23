import AppKit
import WebKit
import UniformTypeIdentifiers

// MARK: - MarkdownPrinter
//
// Export-to-PDF and Print over the same themed HTML the Read mode renders.
//
// Export:  WKWebView.createPDF — async, non-blocking, returns PDF Data without
//          involving NSPrintOperation. Produces vector text (selectable in
//          Preview), self-contained (all assets inlined by DocumentHTML).
//
// Print:   WKWebView.printOperation — vector text, native pagination, native
//          print dialog. The webview is placed in a real (but off-screen, non-
//          activating) window so AppKit can draw it for the operation; the print
//          panel is presented as a sheet on the document window via
//          runModal(for:), which uses a nested event loop and avoids the deadlock
//          that op.run() causes (op.run() blocks the main thread; WKWebView
//          rendering needs the main thread; the two deadlock).
@MainActor
public enum MarkdownPrinter {

    /// Prompts for a PDF destination and writes the document as a vector PDF.
    public static func exportPDF(markdown: String,
                                 theme: EditorTheme,
                                 callouts: [String: CalloutStyle],
                                 suggestedName: String,
                                 window: NSWindow?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName + ".pdf"

        let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                     callouts: callouts, dark: false)
        let begin: (URL) -> Void = { url in
            PDFExportJob.start(html: html, outputURL: url)
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
                             window: NSWindow?) {
        let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                     callouts: callouts, dark: false)
        PrintJob.start(html: html, parentWindow: window, printInfo: makePrintInfo())
    }

    static func makePrintInfo() -> NSPrintInfo {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        let margin: CGFloat = 54   // 0.75"
        info.topMargin = margin; info.bottomMargin = margin
        info.leftMargin = margin;  info.rightMargin = margin
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }
}

// MARK: - PDFExportJob
//
// Loads HTML into an offscreen WKWebView, waits for the page to finish, then
// calls WKWebView.createPDF — the blessed async API for programmatic PDF
// generation. Unlike NSPrintOperation, createPDF doesn't block the main thread.
@MainActor
private final class PDFExportJob: NSObject, WKNavigationDelegate {

    private static var live: Set<PDFExportJob> = []

    private let webView: WKWebView
    private let outputURL: URL

    static func start(html: String, outputURL: URL) {
        let job = PDFExportJob(html: html, outputURL: outputURL)
        live.insert(job)
    }

    private init(html: String, outputURL: URL) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792),
                            configuration: config)
        self.outputURL = outputURL
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.createPDF(configuration: WKPDFConfiguration()) { [self] result in
            if case .success(let data) = result {
                try? data.write(to: outputURL)
            }
            PDFExportJob.live.remove(self)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        PDFExportJob.live.remove(self)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        PDFExportJob.live.remove(self)
    }
}

// MARK: - PrintJob
//
// Loads HTML into a WKWebView that's placed in a real (off-screen, non-
// activating) window so AppKit can draw it, then calls printOperation.runModal
// — a sheet-based API that runs a nested event loop, allowing WebKit IPC to
// proceed without deadlocking the main thread.
@MainActor
private final class PrintJob: NSObject, WKNavigationDelegate {

    private static var live: Set<PrintJob> = []

    private let webView: WKWebView
    private let offscreenWindow: NSWindow
    private let parentWindow: NSWindow?
    private let printInfo: NSPrintInfo

    static func start(html: String, parentWindow: NSWindow?, printInfo: NSPrintInfo) {
        let job = PrintJob(html: html, parentWindow: parentWindow, printInfo: printInfo)
        live.insert(job)
    }

    private init(html: String, parentWindow: NSWindow?, printInfo: NSPrintInfo) {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000),
                            configuration: config)

        // Place the webview in a real window far off-screen so AppKit's print
        // rendering path can draw into it (a windowless WKWebView renders blank).
        offscreenWindow = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 1000),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.contentView = webView
        offscreenWindow.orderBack(nil)

        self.parentWindow = parentWindow
        self.printInfo = printInfo
        super.init()
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let op = webView.printOperation(with: printInfo)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        if let parentWindow {
            op.runModal(for: parentWindow, delegate: self,
                        didRun: #selector(printDidRun(_:success:contextInfo:)),
                        contextInfo: nil)
        } else {
            // No parent window: run without a sheet. This uses a nested event
            // loop, so it doesn't deadlock (unlike op.run() called on the main
            // thread from a navigation delegate).
            op.run()
            cleanup()
        }
    }

    @objc func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        cleanup()
    }

    private func cleanup() {
        offscreenWindow.close()
        PrintJob.live.remove(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { cleanup() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { cleanup() }
}
