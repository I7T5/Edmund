import AppKit

// MARK: - What formatting applies at the caret
//
// The format popup shows which commands are already in effect, the way Apple
// Notes lights up "I" inside italic text. Both answers are derived from the
// same sources the renderer uses — `blocks` for the block kind and
// `SyntaxHighlighter.parse` for the inline spans — so the popup can never
// disagree with what is drawn.

/// The inline styles in effect at the caret. An OptionSet because they nest:
/// `***word***` inside `<u>` is bold + italic + underline at once.
public struct ActiveInlineStyles: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold          = ActiveInlineStyles(rawValue: 1 << 0)
    public static let italic        = ActiveInlineStyles(rawValue: 1 << 1)
    public static let underline     = ActiveInlineStyles(rawValue: 1 << 2)
    public static let strikethrough = ActiveInlineStyles(rawValue: 1 << 3)
    public static let highlight     = ActiveInlineStyles(rawValue: 1 << 4)
    public static let code          = ActiveInlineStyles(rawValue: 1 << 5)
    public static let math          = ActiveInlineStyles(rawValue: 1 << 6)
    public static let `subscript`   = ActiveInlineStyles(rawValue: 1 << 7)
    public static let superscript   = ActiveInlineStyles(rawValue: 1 << 8)
}

/// The block the caret sits in, reduced to the cases the format popup offers.
/// Deliberately coarser than `BlockKind`: the popup has one row per entry here.
public enum ActiveBlockStyle: Equatable, Sendable {
    case heading(level: Int)
    case bulletedList
    case numberedList
    case checklist
    case blockQuote
    case callout
    case codeBlock
    case mathBlock
    case body
}

extension EditorTextView {

    /// The inline styles covering the caret (or the start of the selection).
    ///
    /// A style counts as active when the caret is anywhere within its *content*,
    /// including hard against either edge — typing at the end of `**word**`
    /// continues the bold run, so the button has to agree.
    public func activeInlineStyles() -> ActiveInlineStyles {
        let probe = selectedRange().location
        guard let index = blockIndexForRawOffset(probe), index < blocks.count else { return [] }
        let block = blocks[index]
        let local = probe - block.range.location
        guard local >= 0 else { return [] }

        var styles: ActiveInlineStyles = []
        for span in SyntaxHighlighter.parse(block.content,
                                            linkDefinitions: linkDefState.defsText,
                                            features: markdownFeatures) {
            let r = span.contentRange
            guard local >= r.location, local <= r.location + r.length else { continue }
            switch span.kind {
            case .bold:                  styles.insert(.bold)
            case .italic:                styles.insert(.italic)
            case .boldItalic:            styles.formUnion([.bold, .italic])
            case .strikethrough:         styles.insert(.strikethrough)
            case .highlight:             styles.insert(.highlight)
            case .code:                  styles.insert(.code)
            case .math(let display):     if !display { styles.insert(.math) }
            case .htmlFormat(let tag):
                switch tag {
                case "u":   styles.insert(.underline)
                case "sub": styles.insert(.subscript)
                case "sup": styles.insert(.superscript)
                default:    break
                }
            default: break
            }
        }
        return styles
    }

    /// The block style at the caret. `body` when nothing more specific applies.
    public func activeBlockStyle() -> ActiveBlockStyle {
        let probe = selectedRange().location
        guard let index = blockIndexForRawOffset(probe), index < blocks.count else { return .body }
        let block = blocks[index]

        switch block.kind {
        case .heading(let level):        return .heading(level: level)
        case .fence, .indentedCode:      return .codeBlock
        case .mathDisplay:               return .mathBlock
        case .quoteRun(let isCallout):   return isCallout ? .callout : .blockQuote
        case .listItem:
            // The marker distinguishes the three list flavours, and only the
            // caret's own line counts — a multi-line block may mix them.
            let line = lineAtCaret(in: block, probe: probe)
            if isChecklistLine(line) { return .checklist }
            if isBulletLine(line) { return .bulletedList }
            return leadingListNumber(line) != nil ? .numberedList : .bulletedList
        default:
            return .body
        }
    }

    /// The text of the caret's own line within `block`.
    private func lineAtCaret(in block: Block, probe: Int) -> String {
        let ns = rawSource as NSString
        guard probe <= ns.length else { return block.content }
        return ns.substring(with: ns.lineRange(for: NSRange(location: probe, length: 0)))
    }
}
