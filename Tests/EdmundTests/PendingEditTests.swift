import Testing
import AppKit
@testable import EdmundCore

/// EditorTextStorage accumulates string mutations into one (oldRange, delta)
/// pending edit — the incremental parser's input. The invariant under test:
/// applying the pending edit's hull to the OLD string explains every
/// difference, i.e. old and new strings agree outside it.
@Suite("Pending edit accumulation")
struct PendingEditTests {

    @MainActor private func storage(_ s: String) -> EditorTextStorage {
        let ts = EditorTextStorage()
        ts.replaceCharacters(in: NSRange(location: 0, length: 0), with: s)
        _ = ts.consumePendingEdit()
        return ts
    }

    /// Checks the hull invariant for a sequence of edits.
    @MainActor private func verify(_ initial: String, _ edits: [(NSRange, String)],
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let ts = storage(initial)
        let old = ts.string as NSString
        for (range, replacement) in edits {
            ts.replaceCharacters(in: range, with: replacement)
        }
        let new = ts.string as NSString
        guard let p = ts.consumePendingEdit() else {
            Issue.record("no pending edit recorded", sourceLocation: sourceLocation)
            return
        }
        #expect(new.length - old.length == p.delta,
                "delta must match total length change", sourceLocation: sourceLocation)
        // Outside the hull, old and new must agree.
        let prefixOld = old.substring(to: min(p.oldRange.location, old.length))
        let prefixNew = new.substring(to: min(p.oldRange.location, new.length))
        #expect(prefixOld == prefixNew, "prefix must be untouched", sourceLocation: sourceLocation)
        let suffixOld = old.substring(from: min(p.oldRange.upperBound, old.length))
        let suffixNew = new.substring(from: min(p.oldRange.upperBound + p.delta, new.length))
        #expect(suffixOld == suffixNew, "suffix must be untouched", sourceLocation: sourceLocation)
    }

    @Test("Single insert")
    @MainActor func singleInsert() {
        verify("hello world", [(NSRange(location: 5, length: 0), "XYZ")])
    }

    @Test("Single delete")
    @MainActor func singleDelete() {
        verify("hello world", [(NSRange(location: 2, length: 4), "")])
    }

    @Test("Consecutive typing (insert after insert)")
    @MainActor func consecutiveTyping() {
        verify("ab", [(NSRange(location: 1, length: 0), "x"),
                      (NSRange(location: 2, length: 0), "y"),
                      (NSRange(location: 3, length: 0), "z")])
    }

    @Test("Insert then delete spanning it")
    @MainActor func insertThenDelete() {
        verify("abcdef", [(NSRange(location: 2, length: 0), "XY"),
                          (NSRange(location: 1, length: 4), "")])
    }

    @Test("Disjoint edits coalesce into the hull")
    @MainActor func disjointEdits() {
        verify("0123456789", [(NSRange(location: 8, length: 1), "Z"),
                              (NSRange(location: 1, length: 1), "AA")])
    }

    @Test("IME-style replace of a marked region")
    @MainActor func imeReplace() {
        // Composition: insert provisional text, replace it twice, commit.
        verify("abc", [(NSRange(location: 1, length: 0), "ni"),
                       (NSRange(location: 1, length: 2), "你"),
                       (NSRange(location: 1, length: 1), "你好")])
    }

    @Test("Backspace run (deletes moving left)")
    @MainActor func backspaceRun() {
        verify("abcdef", [(NSRange(location: 5, length: 1), ""),
                          (NSRange(location: 4, length: 1), ""),
                          (NSRange(location: 3, length: 1), "")])
    }

    @Test("Consume clears; programmatic clear works")
    @MainActor func consumeAndClear() {
        let ts = storage("abc")
        ts.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Z")
        #expect(ts.pendingEdit != nil)
        _ = ts.consumePendingEdit()
        #expect(ts.pendingEdit == nil)
        ts.replaceCharacters(in: NSRange(location: 0, length: 1), with: "Q")
        ts.clearPendingEdit()
        #expect(ts.pendingEdit == nil)
    }
}
