import Foundation

/// One heading in the document outline (the inspector's Outline section).
public struct OutlineHeading: Equatable, Sendable {
    public var level: Int
    public var title: String
    /// The heading block's range in the source.
    public var range: NSRange

    public init(level: Int, title: String, range: NSRange) {
        self.level = level
        self.title = title
        self.range = range
    }

    /// The display title of a heading block's source: an ATX heading loses its
    /// opening and closing `#` runs, a setext heading its underline, and a
    /// multi-line setext heading is joined onto one line.
    ///
    /// Runs for every heading on every outline refresh, so the one-line case —
    /// nearly all of them — slices one `Substring` instead of splitting,
    /// trimming and joining; on a 1,509-heading document that cut the heading
    /// walk from ~6.5 to ~5.4ms (debug).
    public static func title(of content: String) -> String {
        // A byte search: `contains(Character)` walks graphemes.
        guard !content.utf8.contains(UInt8(ascii: "\n")) else {
            var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeLast()   // setext underline
            return lines.map { String(trimmed($0)) }.joined(separator: " ")
        }
        var s = trimmed(Substring(content))
        guard s.first == "#" else { return String(s) }
        s = trimmed(s.drop(while: { $0 == "#" }))
        // A closing sequence counts only when separated from the text by a
        // space (`# C#` keeps its `#`), or when it is all there is.
        if let last = s.lastIndex(where: { $0 != "#" }) {
            if s[last].isWhitespace { s = trimmed(s[...last]) }
        } else {
            s = ""
        }
        return String(s)
    }

    private static func trimmed(_ s: Substring) -> Substring {
        let start = s.firstIndex(where: { !$0.isWhitespace }) ?? s.endIndex
        let end = s.lastIndex(where: { !$0.isWhitespace }).map(s.index(after:)) ?? start
        return s[start..<max(start, end)]
    }
}

/// A heading with the headings nested under it. A class because `NSOutlineView`
/// tells its items apart by identity.
public final class OutlineNode {
    /// Settable so an edit that only retitles headings can update the nodes
    /// already on screen rather than rebuild the tree.
    public var heading: OutlineHeading
    /// Position in the flat heading list the tree was built from.
    public let index: Int
    public private(set) var children: [OutlineNode] = []

    init(heading: OutlineHeading, index: Int) {
        self.heading = heading
        self.index = index
    }

    /// Nests a flat heading list: each heading goes under the nearest earlier
    /// heading of a shallower level, so a skipped level (H1 → H3) still nests
    /// and a document opening on an H2 starts at the top.
    public static func tree(_ headings: [OutlineHeading]) -> [OutlineNode] {
        var roots: [OutlineNode] = []
        var stack: [OutlineNode] = []
        for (i, heading) in headings.enumerated() {
            let node = OutlineNode(heading: heading, index: i)
            while let last = stack.last, last.heading.level >= heading.level { stack.removeLast() }
            if let parent = stack.last { parent.children.append(node) } else { roots.append(node) }
            stack.append(node)
        }
        return roots
    }
}
