import Foundation
import Markdown

/// Parses raw markdown using Apple's swift-markdown (cmark-gfm) and returns
/// spans identifying inline formatting with their delimiter and content ranges.
///
/// This ensures the active block's syntax highlighting is consistent with the
/// rendered (non-active) blocks, including mismatched-delimiter edge cases
/// like `**hi*` (treated as literal `*` + italic `hi`).
///
/// This file holds the public model (`Span`/`Kind`) and the `parse` entry
/// point. The heavy lifting lives in two siblings:
///   - SyntaxHighlighter+Walker.swift        — the swift-markdown AST walker
///   - SyntaxHighlighter+CustomParsers.swift  — regex passes for constructs the
///     AST doesn't model (==highlight==, $math$, indented list items)
public enum SyntaxHighlighter {

    // MARK: - Model

    public struct Span: Sendable {
        public let kind: Kind
        public let fullRange: NSRange
        public let contentRange: NSRange
        public let delimiterRanges: [NSRange]

        public enum Kind: Equatable, Sendable {
            case bold
            case italic
            case boldItalic
            case code
            case codeBlock(language: String?)
            case strikethrough
            case highlight
            case heading(Int)
            case link(destination: String)
            case image(destination: String)
            case blockquote
            case listItem(ordered: Bool, checkbox: CheckboxState? = nil)
            case table
            case thematicBreak
            case lineBreak
            case math(display: Bool)
            /// An inline `[^id]` footnote reference.
            case footnoteReference(id: String)
            /// A `[^id]:` footnote definition marker at the start of a block.
            case footnoteDefinition(id: String)

            public enum CheckboxState: Equatable, Sendable {
                case checked, unchecked
            }
        }
    }

    // MARK: - Parsing

    /// Returns all inline syntax spans found in `text`, ordered by position.
    public static func parse(_ text: String) -> [Span] {
        guard !text.isEmpty else { return [] }

        let doc = Document(parsing: text, options: [.disableSmartOpts])
        var walker = SpanCollector(source: text)
        walker.visit(doc)

        // ==highlight== is not supported by swift-markdown; parse with regex.
        parseHighlight(text, into: &walker.spans)

        // $$…$$ display math (the block is pre-merged by BlockParser), then
        // $…$ inline math.
        parseDisplayMath(text, into: &walker.spans)
        parseMath(text, into: &walker.spans)

        // Trailing backslash line break (single-line blocks only).
        parseLineBreak(text, into: &walker.spans)

        // Deeply indented list items (4+ spaces) that swift-markdown treats as code.
        parseIndentedListItem(text, into: &walker.spans)

        // [^id] footnote references and [^id]: definition markers.
        parseFootnotes(text, into: &walker.spans)

        return walker.spans.sorted { $0.fullRange.location < $1.fullRange.location }
    }

}
