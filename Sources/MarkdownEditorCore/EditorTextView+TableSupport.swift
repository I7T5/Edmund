import AppKit

// MARK: - Table Rendering Support
//
// Helpers used by the `.table` branch of `styleBlock` (in
// EditorTextView+Rendering.swift) to lay out GFM tables:
// `splitTableRow` / `cellRanges` parse a pipe-delimited row into its cells.
//
// A rendered table is a run of consecutive single-line paragraphs (one per
// table row) that the BlockParser merges into a single block. Each row
// carries a `.tableRow` BlockDecoration; because every row uses the same
// column X offsets, the per-row vertical strokes line up into continuous
// column borders.

// MARK: - Table Row Parsing

/// Splits a markdown table row into cell strings (text between pipes).
/// Handles both `| A | B |` (outer pipes) and `A | B` (no outer pipes).
func splitTableRow(_ line: String) -> [String] {
    var parts = line.components(separatedBy: "|")
    // Remove empty/whitespace-only first/last from outer pipes.
    if let first = parts.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeFirst()
    }
    if let last = parts.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
        parts.removeLast()
    }
    return parts
}

/// Returns `(start, end)` character ranges for each cell in a table line.
/// Works with or without outer pipes. `start` is the first content char,
/// `end` is one past the last content char (i.e., the next pipe or line end).
func cellRanges(in line: NSString) -> [(start: Int, end: Int)] {
    var pipePos: [Int] = []
    for ci in 0..<line.length {
        if line.character(at: ci) == 0x7C { pipePos.append(ci) }
    }
    guard !pipePos.isEmpty else { return [] }

    // Build edge list: either the pipe position or a virtual -1/length sentinel.
    var edges: [Int] = []
    if pipePos[0] == 0 {
        edges.append(contentsOf: pipePos)
    } else {
        edges.append(-1)
        edges.append(contentsOf: pipePos)
    }
    if pipePos.last != line.length - 1 {
        edges.append(line.length)
    }

    var result: [(start: Int, end: Int)] = []
    for ei in 0..<(edges.count - 1) {
        let s = edges[ei] + 1
        let e = edges[ei + 1]
        if e > s { result.append((s, e)) }
    }
    return result
}
