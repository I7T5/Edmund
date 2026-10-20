import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import EdmundCore
import os.log

private let qlLog = Logger(subsystem: "com.i7t5.edmund.quicklook", category: "preview")

// MARK: - Quick Look preview for Markdown
//
// A data-based preview (`QLIsDataBasedPreview` in the appex Info.plist): we
// return the page's HTML and Quick Look renders it in its own view, inside its
// native rounded panel. A view-based extension gets no clipping or corner
// radius from Quick Look, and there is no API for the panel's radius, so a page
// in our own WKWebView showed square corners.
//
// Trade-off: the page is built for the appearance at preview time, so an open
// preview does not re-render on a light/dark flip (the view-based one did).
//
// The `@objc` name is what `NSExtensionPrincipalClass` in the appex Info.plist
// references; Swift's mangled name would not resolve.
@objc(EdmundPreviewProvider)
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        qlLog.log("providePreview: \(url.lastPathComponent, privacy: .public)")
        let markdown = try String(contentsOf: url, encoding: .utf8)
        let html = await MainActor.run {
            let appearanceDark = NSApplication.shared.effectiveAppearance
                .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            // The extension's appearance may not track the system's; the global
            // AppleInterfaceStyle default does ("Dark" only in dark mode).
            let styleDark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            qlLog.log("appearance dark: \(appearanceDark, privacy: .public), AppleInterfaceStyle dark: \(styleDark, privacy: .public)")
            return QuickLookPage.html(markdown: markdown,
                                      baseURL: url.deletingLastPathComponent(),
                                      dark: appearanceDark || styleDark)
        }
        qlLog.log("built \(html.utf8.count) bytes of HTML")
        let data = Data(html.utf8)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 800)) { _ in data }
    }
}
