import AppKit

// MARK: - RichTextExport
//
// File ▸ Export To ▸ Rich Text…: Read mode's page through AppKit's own HTML
// importer — the conversion TextEdit uses — so headings, emphasis, lists,
// tables, quotes and colored code arrive as real word-processor formatting.
// `DocumentHTML.full(forAttributedString:)` shapes the page first (stand-ins
// for what the importer drops); `punctuatingOrderedLists` fixes the one thing
// it gets wrong afterwards.
//
// RTF or RTFD follows TextEdit's rule: a document with pictures (images,
// math, diagrams) is RTFD — "rich text with attachments", a package that
// TextEdit and Pages open — because plain RTF silently drops every picture.
// Without pictures it stays RTF, which every word processor opens.
//
// The attributed string never goes near the editor: the NSTextTable and
// NSTextAttachment attributes the importer produces are fine here. The
// TextKit 2 rules (ARCHITECTURE §2) are about the editor's storage.
@MainActor
enum RichTextExport {

    /// Read mode's page, prepared for the importer. Light, like PDF export.
    static func html(markdown: String, theme: EditorTheme, callouts: [String: CalloutStyle],
                     baseURL: URL?, options: ReadRenderOptions) -> String {
        DocumentHTML.full(markdown: markdown, theme: theme, callouts: callouts, dark: false,
                          baseURL: baseURL, options: options, forAttributedString: true)
    }

    /// Whether the export must be RTFD. Decided from the page, before the save
    /// panel, so the panel can offer the right extension: every attachment
    /// the importer makes comes from an `<img>` (inline SVG becomes nothing).
    static func needsAttachments(_ html: String) -> Bool { html.contains("<img ") }

    static func attributedString(fromHTML html: String) throws -> NSAttributedString {
        let imported = try NSAttributedString(
            data: Data(html.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil)
        return punctuatingOrderedLists(imported)
    }

    /// The file to write: an RTFD package, or a single RTF file.
    static func fileWrapper(for text: NSAttributedString, rtfd: Bool) throws -> FileWrapper {
        let range = NSRange(location: 0, length: text.length)
        if rtfd {
            guard let wrapper = text.rtfdFileWrapper(from: range, documentAttributes: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return wrapper
        }
        return FileWrapper(regularFileWithContents: try text.data(
            from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]))
    }

    /// The importer numbers `<ol>` items "1", "2" — list format `{decimal}`
    /// with no period — where TextEdit, Pages and Word all write "1.". The
    /// marker exists twice: as the list's format, which a word processor
    /// re-numbers from, and as literal text at the start of each paragraph
    /// (`"\t1\tfirst"`), which is what a reader sees. Both get the period.
    static func punctuatingOrderedLists(_ input: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: input)
        // One replacement per list, so a list's items keep sharing one object
        // and still number as one list.
        var punctuated: [ObjectIdentifier: NSTextList] = [:]
        func fixed(_ list: NSTextList) -> NSTextList {
            guard list.isOrdered, !list.markerFormat.rawValue.hasSuffix(".") else { return list }
            if let hit = punctuated[ObjectIdentifier(list)] { return hit }
            let new = NSTextList(markerFormat: NSTextList.MarkerFormat(rawValue: list.markerFormat.rawValue + "."),
                                 options: Int(list.listOptions.rawValue))
            new.startingItemNumber = list.startingItemNumber
            punctuated[ObjectIdentifier(list)] = new
            return new
        }

        var paragraphs: [NSRange] = []
        (text.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
                paragraphs.append(enclosing)
            }
        // Back to front: inserting a period shifts everything after it.
        for range in paragraphs.reversed() where range.length > 0 {
            guard let style = text.attribute(.paragraphStyle, at: range.location,
                                             effectiveRange: nil) as? NSParagraphStyle,
                  let shown = style.textLists.last else { continue }
            let lists = style.textLists.map(fixed)
            guard zip(lists, style.textLists).contains(where: { $0 !== $1 }) else { continue }
            let updated = style.mutableCopy() as! NSMutableParagraphStyle
            updated.textLists = lists
            text.addAttribute(.paragraphStyle, value: updated, range: range)

            // Only the innermost list's marker is printed in the paragraph.
            guard lists.last !== shown else { continue }
            let paragraph = (text.string as NSString).substring(with: range)
            guard paragraph.hasPrefix("\t"),
                  let tab = paragraph.dropFirst().firstIndex(of: "\t") else { continue }
            let offset = paragraph.utf16.distance(from: paragraph.startIndex, to: tab)
            text.replaceCharacters(in: NSRange(location: range.location + offset, length: 0), with: ".")
        }
        return text
    }
}
