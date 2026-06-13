import Foundation

/// Incremental backing for the document-global list indent unit.
///
/// Replicates `EditorTextView.detectListIndentUnit` exactly — any
/// tab-indented list line forces 4; otherwise the smallest space indent of
/// any list line; 4 when none — but as a histogram that can be updated per
/// block on the edit path instead of rescanning the whole document per
/// keystroke. Block contents tile the document's lines exactly (merged
/// constructs keep their inner newlines), so adding/removing block contents
/// is equivalent to rescanning those lines.
struct ListIndentState {
    private(set) var tabLines = 0
    private(set) var histogram: [Int: Int] = [:]

    var unit: Int {
        if tabLines > 0 { return 4 }
        return histogram.keys.min() ?? 4
    }

    mutating func add(_ content: String) { scan(content, sign: 1) }
    mutating func remove(_ content: String) { scan(content, sign: -1) }

    static func build(from source: String) -> ListIndentState {
        var state = ListIndentState()
        state.add(source)
        return state
    }

    private mutating func scan(_ content: String, sign: Int) {
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            var spaces = 0
            var sawTab = false
            for ch in line {
                if ch == " " { spaces += 1 }
                else if ch == "\t" { sawTab = true; break }
                else { break }
            }
            let rest = line.drop(while: { $0 == " " || $0 == "\t" })
            guard EditorTextView.startsWithListMarker(rest) else { continue }
            if sawTab {
                tabLines += sign
            } else if spaces > 0 {
                let count = (histogram[spaces] ?? 0) + sign
                histogram[spaces] = count <= 0 ? nil : count
            }
        }
    }
}
