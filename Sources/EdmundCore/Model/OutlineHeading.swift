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
    public static func title(of content: String) -> String {
        var lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 { lines.removeLast() }   // setext underline
        var s = lines.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        if s.hasPrefix("#") {
            s = String(s.drop(while: { $0 == "#" }))
            // A closing sequence counts only when separated from the text by a
            // space (`# C#` keeps its `#`), or when it is all there is.
            let body = s.trimmingCharacters(in: .whitespaces)
            let stripped = body.reversed().drop(while: { $0 == "#" })
            if stripped.first?.isWhitespace ?? true {
                s = String(stripped.reversed())
            }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// A heading with the headings nested under it. A class because `NSOutlineView`
/// tells its items apart by identity.
public final class OutlineNode {
    public let heading: OutlineHeading
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
