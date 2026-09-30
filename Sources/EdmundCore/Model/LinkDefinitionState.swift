import Foundation

/// Incremental backing for the document's link reference definitions.
///
/// GFM reference links (`[text][label]`, `[label][]`, `[label]`) resolve
/// against `[label]: destination` definitions that may live in *other* blocks.
/// Edmund styles one block at a time, so the editor collects every definition
/// line here — built whole-document on load and maintained per changed block on
/// the edit path (mirroring `ListIndentState`) — and appends `defsText` to each
/// block's parse so swift-markdown's CommonMark parser resolves the references
/// (see `SyntaxHighlighter.parse(_:linkDefinitions:)`).
///
/// A multiset of the raw definition *lines* is enough: swift-markdown applies
/// CommonMark's "first definition wins" itself, and `defsText` is sorted so the
/// incremental state and a from-scratch rebuild always produce the identical
/// string (the full-recompose oracle depends on that determinism).
struct LinkDefinitionState: Equatable {
    /// Unique `[label]: url` source lines → occurrence count, so per-block
    /// add/remove stays exact when the same line appears more than once.
    private var lines: [String: Int] = [:]

    /// The collected definition lines, sorted and newline-joined. Empty when the
    /// document defines no references (then parsing skips the append entirely).
    /// Stored, not computed: every block parse reads it, and it changes only
    /// when a definition line appears or disappears.
    private(set) var defsText = ""

    mutating func add(_ content: String) { scan(content, sign: 1) }
    mutating func remove(_ content: String) { scan(content, sign: -1) }

    static func build(from source: String) -> LinkDefinitionState {
        var state = LinkDefinitionState()
        state.add(source)
        return state
    }

    private mutating func scan(_ content: String, sign: Int) {
        var keysChanged = false
        for line in content.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let key = Self.canonicalDefinition(from: String(line)) else { continue }
            let old = lines[key] ?? 0
            let count = old + sign
            lines[key] = count <= 0 ? nil : count
            if (old > 0) != (count > 0) { keysChanged = true }
        }
        if keysChanged { defsText = lines.keys.sorted().joined(separator: "\n") }
    }

    /// A CommonMark link reference definition line: up to 3 leading spaces, a
    /// non-empty `[label]`, `:`, then a destination. (Rare multi-line / titled
    /// forms aren't recognized; ponytail: single-line covers the common case.)
    private static let defRegex = try! NSRegularExpression(
        pattern: #"^ {0,3}\[[^\]\n]+\]:\s*\S.*$"#)
    /// One leading list marker (`-`/`*`/`+` or `1.`/`1)`) plus its trailing run.
    private static let listMarkerRegex = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+"#)

    static func isDefinitionLine(_ line: String) -> Bool {
        canonicalDefinition(from: line) != nil
    }

    /// The canonical `[label]: destination` line if `line` is a definition,
    /// else nil. Definitions may sit inside a block quote or list item and still
    /// define references for the whole document (GFM ex. 187), so leading `>`
    /// quote markers and one list marker are stripped first; the stripped form is
    /// what gets appended and re-parsed, so it must be container-free. The strip
    /// only consumes whitespace that belongs to a marker — a bare `    [x]: u`
    /// (4-space indent) is still rejected as code by `defRegex`.
    static func canonicalDefinition(from line: String) -> String? {
        var s = Substring(line)
        var stripped = false

        // Block-quote markers: `>` optionally preceded by ≤3 spaces and followed
        // by one space, repeated for nesting.
        while true {
            let t = s.drop { $0 == " " || $0 == "\t" }
            guard t.first == ">" else { break }
            var rest = t.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
            s = rest
            stripped = true
        }

        // One list marker on the same line as the definition.
        let ns = String(s) as NSString
        if let m = listMarkerRegex.firstMatch(in: String(s), range: NSRange(location: 0, length: ns.length)) {
            s = Substring(ns.substring(from: m.range.length))
            stripped = true
        }

        if stripped {
            // Drop residual container indentation before the label.
            s = s.drop { $0 == " " || $0 == "\t" }
        }
        let candidate = stripped ? String(s) : line
        let cn = candidate as NSString
        guard defRegex.firstMatch(in: candidate, range: NSRange(location: 0, length: cn.length)) != nil
        else { return nil }
        return candidate
    }
}
