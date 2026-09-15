import Foundation

/// Nesting depth of every list line in the document, from a column stack over
/// the lines that precede it.
///
/// This replaces dividing a line's indent by a document-global unit. That older
/// rule made depth a function of the *whole document*: the unit was the smallest
/// list indent anywhere, so one Tab writing a narrower indent than the document
/// otherwise used re-depthed every other list on screen — "I indented this list
/// and a different one moved". Stacking the indents makes a line's depth depend
/// only on the lines above it, so indenting one list cannot disturb another.
///
/// The nesting rule itself is unchanged and stays the editor's own, not
/// CommonMark's: *any* deeper indent opens a level. CommonMark would require a
/// child to reach its parent's content column (3 for `1. `), and applying that
/// here would silently re-draw documents whose lists nest by two spaces under an
/// ordered marker — see docs on the editor-vs-read-mode split. What changed is
/// only how many levels a given indent is worth, and that is now read off the
/// lines above rather than off the document's narrowest indent.
///
/// `build` returns one entry per block — the block's depth, or `notAList` — so
/// the renderer can look depth up by block index. BlockParser emits one block
/// per list line (only a `$$…$$` item merges forward, and its first line is
/// still the list line), so one depth per block is exact.
enum ListDepthMap {

    /// Depth stored for a block that has no list line of its own.
    static let notAList = -1

    /// Tab stop width for turning leading whitespace into columns, per
    /// CommonMark. Only matters for tab-indented documents.
    private static let tabWidth = 4

    static func build(from blocks: [Block]) -> [Int] {
        var depths = [Int](repeating: notAList, count: blocks.count)
        // Indent column of each open ancestor, outermost first and strictly
        // increasing.
        var stack: [Int] = []

        for (i, block) in blocks.enumerated() {
            // A blank line leaves a list open (a loose list is still one list),
            // so it neither closes ancestors nor takes a depth.
            if case .blank = block.kind { continue }

            let indent = columns(of: block.content.prefix(while: { $0 != "\n" }))

            // Close every ancestor this line is not indented past: it is that
            // ancestor's sibling, or shallower still.
            while let top = stack.last, indent <= top { stack.removeLast() }

            guard case .listItem = block.kind else {
                // A non-list block that survived the popping above is indented
                // inside the innermost open item — a continuation paragraph,
                // say — so it leaves the stack alone. One that popped
                // everything has ended the list, which the popping already did.
                continue
            }
            depths[i] = stack.count
            stack.append(indent)
        }
        return depths
    }

    /// Leading whitespace of `line` in columns, tabs advancing to the next stop.
    private static func columns(of line: Substring) -> Int {
        var cols = 0
        for ch in line {
            if ch == " " { cols += 1 }
            else if ch == "\t" { cols += tabWidth - (cols % tabWidth) }
            else { break }
        }
        return cols
    }
}
