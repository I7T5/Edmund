import AppKit
import UniformTypeIdentifiers

// MARK: - DocumentExporter
//
// File ▸ Export To ▸ … (PDF, the first item, lives in `MarkdownPrinter`):
//   - HTML — the same self-contained themed document Read mode renders.
//   - Plain Text — the words without the Markdown syntax (`PlainTextExport`).
//   - Rich Text Format — RTF, or RTFD when it has pictures (`RichTextExport`).
//   - Markdown with Embedded Images — a share copy with local images inlined
//     as base64 data URIs (see `SelfContainedMarkdown`), for handing someone a
//     single .md file that still shows its pictures. GitHub strips `data:`
//     image URIs, so this is for direct sharing, not for pushing to a repo —
//     the working document's relative paths + assets folder are the right form
//     there.
//
// The output is built only after the save panel is confirmed, so a cancelled
// export never pays the render cost — except Rich Text's page, which decides
// the extension the panel offers.
@MainActor
public enum DocumentExporter {

    /// Prompts for a destination and writes the document as a self-contained,
    /// themed HTML file (images and math inlined; light theme, like PDF export).
    public static func exportHTML(markdown: String,
                                  theme: EditorTheme,
                                  callouts: [String: CalloutStyle],
                                  baseURL: URL? = nil,
                                  options: ReadRenderOptions = .default,
                                  suggestedName: String,
                                  window: NSWindow?) {
        prompt(extension: "html", contentType: .html,
               suggestedName: suggestedName, window: window) { url in
            let html = DocumentHTML.full(markdown: markdown, theme: theme,
                                         callouts: callouts, dark: false,
                                         baseURL: baseURL, options: options)
            try html.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Prompts for a destination and writes a share copy of the markdown with
    /// every local image inlined as a data URI (see `SelfContainedMarkdown`).
    public static func exportSelfContainedMarkdown(markdown: String,
                                                   baseURL: URL? = nil,
                                                   features: MarkdownFeatures = .all,
                                                   suggestedName: String,
                                                   window: NSWindow?) {
        prompt(extension: "md", contentType: .plainText,
               suggestedName: suggestedName + " (Embedded Images)", window: window) { url in
            let inlined = SelfContainedMarkdown.inlineLocalImages(markdown: markdown,
                                                                  baseURL: baseURL,
                                                                  features: features)
            try inlined.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Prompts for a destination and writes the document as rich text (see
    /// `RichTextExport`): RTFD when it has pictures, RTF otherwise. The page
    /// is built before the panel — it decides which of the two the panel
    /// offers — but the slow part, AppKit's HTML import, runs only after Save.
    public static func exportRichText(markdown: String,
                                      theme: EditorTheme,
                                      callouts: [String: CalloutStyle],
                                      baseURL: URL? = nil,
                                      options: ReadRenderOptions = .default,
                                      suggestedName: String,
                                      window: NSWindow?) {
        let html = RichTextExport.html(markdown: markdown, theme: theme, callouts: callouts,
                                       baseURL: baseURL, options: options)
        let rtfd = RichTextExport.needsAttachments(html)
        prompt(extension: rtfd ? "rtfd" : "rtf", contentType: rtfd ? .rtfd : .rtf,
               suggestedName: suggestedName, window: window) { url in
            let text = try RichTextExport.attributedString(fromHTML: html)
            try RichTextExport.fileWrapper(for: text, rtfd: rtfd)
                .write(to: url, options: .atomic, originalContentsURL: nil)
        }
    }

    /// Prompts for a destination and writes the document's text without its
    /// Markdown syntax (see `PlainTextExport`).
    public static func exportPlainText(markdown: String,
                                       features: MarkdownFeatures = .all,
                                       suggestedName: String,
                                       window: NSWindow?) {
        prompt(extension: "txt", contentType: .plainText,
               suggestedName: suggestedName, window: window) { url in
            try PlainTextExport.text(markdown: markdown, features: features)
                .write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Runs the save panel (as a sheet when `window` is given, matching the
    /// PDF export) and hands the chosen URL to `write`. A write failure is
    /// reported with a standard error alert.
    private static func prompt(extension ext: String, contentType: UTType,
                               suggestedName: String, window: NSWindow?,
                               write: @escaping (URL) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = suggestedName + "." + ext

        let begin: (URL) -> Void = { url in
            do {
                try write(url)
                Log.info("Exported \(url.lastPathComponent)", category: .io)
            } catch {
                Log.error("Export failed: \(error.localizedDescription)", category: .io)
                NSAlert(error: error).runModal()
            }
        }

        if let window {
            panel.beginSheetModal(for: window) { if $0 == .OK, let url = panel.url { begin(url) } }
        } else if panel.runModal() == .OK, let url = panel.url {
            begin(url)
        }
    }
}
