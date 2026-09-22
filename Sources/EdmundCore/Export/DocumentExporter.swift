import AppKit
import UniformTypeIdentifiers

// MARK: - DocumentExporter
//
// File-menu exports other than PDF/Print (which live in `MarkdownPrinter`):
//   - HTML — the same self-contained themed document Read mode renders.
//   - Self-contained Markdown — a share copy with local images inlined as
//     base64 data URIs (see `SelfContainedMarkdown`), for handing someone a
//     single .md file that still shows its pictures. GitHub strips `data:`
//     image URIs, so this is for direct sharing, not for pushing to a repo —
//     the working document's relative paths + assets folder are the right form
//     there.
//
// The HTML/markdown is built only after the save panel is confirmed, so a
// cancelled export never pays the render cost.
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
               suggestedName: suggestedName + " (Self-contained)", window: window) { url in
            let inlined = SelfContainedMarkdown.inlineLocalImages(markdown: markdown,
                                                                  baseURL: baseURL,
                                                                  features: features)
            try inlined.write(to: url, atomically: true, encoding: .utf8)
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
