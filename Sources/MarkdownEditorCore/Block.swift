import Foundation

/// What a block *is* at the line/merge level. Advisory metadata captured
/// during parsing — used by the recompose engine (e.g. restyling every list
/// block when the document's indent unit changes) and available to future
/// outline/folding features. Styling itself still derives from the block's
/// content, not from this tag.
public enum BlockKind: Equatable, Sendable {
    case paragraph
    case heading(level: Int)
    case quoteRun(isCallout: Bool)
    case fence
    case mathDisplay
    case table
    case listItem
    case thematicBreak
    case blank
}

/// A Block is one paragraph of markdown — the unit of rendering.
///
/// Blocks are separated by newlines (`\n`).  Each block carries:
///   - `id`:       stable UUID so we can track which block the cursor is in
///   - `content`:  the raw markdown text of this paragraph
///   - `range`:    the character range within the full document string
///   - `kind`:     advisory classification (see `BlockKind`)
///
/// The editor renders every block as rich text *except* the one containing
/// the cursor, which stays as raw markdown so the user can edit it.
public struct Block: Identifiable, Sendable {
    public var id: UUID
    public var content: String
    public var range: NSRange
    public var kind: BlockKind
    /// Whether the text storage currently holds this block's full styling.
    /// False = the block is pending lazy styling (base attributes, or stale
    /// styling scheduled for the drain). Maintained by the recompose engine.
    public var isStyled: Bool

    public init(id: UUID = UUID(), content: String, range: NSRange,
                kind: BlockKind = .paragraph, isStyled: Bool = false) {
        self.id = id
        self.content = content
        self.range = range
        self.kind = kind
        self.isStyled = isStyled
    }
}
