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

    /// Inline HTML element names that *render* their formatting rather than show
    /// as colored source. Single source of truth shared by the editor's
    /// `parseHTMLTags` (Edit mode) and `HTMLRenderer.sanitizeInlineHTML` (Read
    /// mode), so the two back-ends can't drift on which tags are allowed.
    public static let htmlFormatTags: Set<String> = ["u", "kbd", "mark", "sub", "sup", "small"]

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
            /// A markdown `![alt](src)` image, or an HTML `<img src="…">` tag
            /// (which may carry declared pixel dimensions).
            case image(destination: String, width: Int?, height: Int?)
            /// A `![[file]]` wikilink embed of a non-image file (audio, video,
            /// pdf, note, or an unrecognized type). Edmund can't render these, so
            /// both back-ends draw a per-type "unsupported" placeholder instead.
            /// Image embeds (`![[pic.png]]`) stay `.image` and render the picture.
            case embed(destination: String)
            /// `depth` is the nesting level (0 = outermost, not itself inside
            /// another plain quote). A `> > text` emits two spans, depth 0 and
            /// depth 1, so each level's own marker hides and draws its own bar.
            case blockquote(depth: Int)
            case listItem(ordered: Bool, checkbox: CheckboxState? = nil)
            case table
            case thematicBreak
            case lineBreak
            case math(display: Bool)
            /// An inline `[^id]` footnote reference.
            case footnoteReference(id: String)
            /// A `[^id]:` footnote definition marker at the start of a block.
            case footnoteDefinition(id: String)
            /// An Obsidian-style `%%comment%%` (hidden in reading view).
            case comment
            /// An Obsidian-style `[[target]]` internal link. `target` is the raw
            /// `path#heading` portion (before any `|alias`); the visible display
            /// text is the span's contentRange.
            case wikilink(target: String)
            /// A CommonMark backslash escape `\X`. The backslash is the delimiter
            /// (hidden when inactive, dimmed when active); the escaped character
            /// `X` renders literally as its content.
            case escape
            /// A single inline HTML tag (`<tag …>` or `</tag>`) shown only as
            /// colored source: the `<`/`>`/`/` dim and the tag name colors red
            /// (like math). Used for unknown / unpaired tags. `contentRange` is
            /// the tag name.
            case htmlTag
            /// A whitelisted HTML formatting tag pair (`<u>…</u>`, etc.). When the
            /// caret is outside, the open/close tags hide and the corresponding
            /// attribute is applied to the inner `contentRange`; inside, the raw
            /// tags show colored. `tag` is the lowercased element name; the two
            /// delimiterRanges are the open and close tags.
            case htmlFormat(tag: String)
            /// An Obsidian `#tag`. `name` is the text after the leading `#`.
            /// Styled as a pill in Edit and `<span class="tag">` in Read; no
            /// navigation (style only).
            case tag(name: String)
            /// An Obsidian `^blockid` block reference at the end of a block.
            /// `id` is the text after the `^`. Hidden in reading like a comment,
            /// dimmed in Edit; no link resolution (style only).
            case blockRef(id: String)

            public enum CheckboxState: Equatable, Sendable {
                case checked, unchecked
            }
        }
    }

    // MARK: - Parsing

    /// Returns all inline syntax spans found in `text`, ordered by position.
    ///
    /// `linkDefinitions` (`[label]: url` lines — the editor passes the ones the
    /// block references, `LinkDefinitionState.definitions(for:)`; export
    /// passes the whole `defsText`) is appended after the block so
    /// swift-markdown can resolve GFM reference links whose definition lives in
    /// another block; spans landing in the appended region are dropped. Empty
    /// (the common case) means no append and no cost.
    public static func parse(_ text: String, linkDefinitions: String = "",
                             features: MarkdownFeatures = .all) -> [Span] {
        guard !text.isEmpty else { return [] }

        // Walk the AST over the block plus any appended reference definitions,
        // then keep only spans within the original block. Custom parsers below
        // still run on `text`, so their offsets need no adjustment.
        let textLen = (text as NSString).length
        let parseText = linkDefinitions.isEmpty ? text : text + "\n\n" + linkDefinitions
        let doc = Document(parsing: parseText, options: [.disableSmartOpts])
        var walker = SpanCollector(source: parseText, features: features)
        walker.visit(doc)
        if !linkDefinitions.isEmpty {
            // A block-level node can legitimately run past the block into the
            // appended region: an indented code block swallows the blank
            // separator line, so its span ends at textLen+2. Dropping those
            // left the block unstyled (serif, no mono). Clamp spans that START
            // inside the block; drop only what begins in the appended region.
            walker.spans = walker.spans.compactMap { span in
                guard span.fullRange.location < textLen else { return nil }
                guard span.fullRange.upperBound > textLen else { return span }
                func clamp(_ r: NSRange) -> NSRange {
                    NSRange(location: min(r.location, textLen),
                            length: max(0, min(r.upperBound, textLen) - min(r.location, textLen)))
                }
                return Span(kind: span.kind,
                            fullRange: clamp(span.fullRange),
                            contentRange: clamp(span.contentRange),
                            delimiterRanges: span.delimiterRanges.map(clamp).filter { $0.length > 0 })
            }
        }

        // Each custom pass below is gated by its feature flag: a cleared flag
        // emits no span, so the syntax falls back to plain text everywhere.

        // ==highlight== is not supported by swift-markdown; parse with regex.
        if features.contains(.highlight) { parseHighlight(text, into: &walker.spans) }

        // $$…$$ display math (the block is pre-merged by BlockParser), then
        // $…$ inline math.
        if features.contains(.math) {
            parseDisplayMath(text, into: &walker.spans)
            parseMath(text, into: &walker.spans)
        }

        // Trailing backslash line break (single-line blocks only).
        parseLineBreak(text, into: &walker.spans)

        // Deeply indented list items (4+ spaces) that swift-markdown treats as code.
        parseIndentedListItem(text, into: &walker.spans, features: features)

        // [^id] footnote references and [^id]: definition markers.
        if features.contains(.footnote) { parseFootnotes(text, into: &walker.spans) }

        // Obsidian #tag pills and a trailing ^blockid reference. Both skip spans
        // inside code / math (checked in the parsers).
        if features.contains(.tag) { parseTag(text, into: &walker.spans) }
        if features.contains(.blockRef) { parseBlockRef(text, into: &walker.spans) }

        // %%comments%% and [[wikilinks]]. Both are opaque: their inner text is
        // a raw note / link target, not markdown — drop any span fully inside
        // one so the content isn't re-styled.
        if features.contains(.inlineComment) { parseComments(text, into: &walker.spans) }
        if features.contains(.wikilink) || features.contains(.wikilinkEmbed) {
            parseWikiLinks(text, into: &walker.spans, features: features)
        }

        // CommonMark backslash escapes (`\*`, `\$`, …). Runs after math/line-break
        // so it can defer to them; before HTML tags so `\<` defers to the escape.
        parseEscapes(text, into: &walker.spans)

        // HTML `<!-- comments -->` share the `.comment` kind (and its opaque
        // treatment below). Before parseHTMLTags so a tag inside a comment
        // belongs to the comment, not the tag pass.
        parseHTMLComments(text, into: &walker.spans)

        // Inline HTML tags: whitelist pairs render (`<u>…</u>`); any other tag is
        // colored source. Runs after escapes so an escaped `\<` isn't seen as a tag.
        parseHTMLTags(text, into: &walker.spans)

        // Bare www./http(s)/email autolinks (GFM extension). Last, so every
        // guard (code, math, real links, HTML tags, …) is already in place.
        parseAutolinks(text, into: &walker.spans)

        let opaqueRanges: [NSRange] = walker.spans.compactMap { span in
            switch span.kind {
            case .comment, .wikilink: return span.fullRange
            default: return nil
            }
        }
        if !opaqueRanges.isEmpty {
            walker.spans.removeAll { span in
                switch span.kind {
                case .comment, .wikilink: return false
                default: break
                }
                return opaqueRanges.contains {
                    $0.location <= span.fullRange.location && $0.upperBound >= span.fullRange.upperBound
                }
            }
        }

        // A callout's body is rendered recursively by the styling layer (it
        // strips the `>` prefixes and re-parses the inner markdown), so drop any
        // other span the custom parsers placed inside a callout — keeping it
        // would double-style the body. Plain block quotes are unaffected: their
        // inline spans are intentionally kept.
        let calloutRanges: [NSRange] = walker.spans.compactMap { span in
            guard case .blockquote(_) = span.kind,
                  isCalloutFirstLine(of: span.fullRange, in: text) else { return nil }
            return span.fullRange
        }
        if !calloutRanges.isEmpty {
            walker.spans.removeAll { span in
                if case .blockquote(_) = span.kind { return false }
                return calloutRanges.contains {
                    $0.location <= span.fullRange.location && $0.upperBound >= span.fullRange.upperBound
                }
            }
        }

        return walker.spans.sorted { $0.fullRange.location < $1.fullRange.location }
    }

    /// Whether the first line of `range` in `text` opens a callout (`> [!type]`).
    private static func isCalloutFirstLine(of range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        let nl = ns.range(of: "\n", options: [], range: range)
        let lineEnd = nl.location == NSNotFound ? range.upperBound : nl.location
        let line = ns.substring(with: NSRange(location: range.location,
                                              length: lineEnd - range.location))
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.first == ">" else { return false }
        return Callout.parseMarker(String(trimmed.dropFirst())) != nil
    }

}
