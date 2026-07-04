import AppKit

// MARK: - Editor diagnostics
//
// The edit pipeline lives in the live NSTextView / TextKit 2 / input-context
// layer, which can't be reproduced or inspected headlessly — so bugs there
// (caret drift, sync desyncs) are hard to pin down from a recording alone. These
// helpers capture the decisive live state:
//
//   - `traceEdit` — a one-line snapshot of caret + flags + lengths, emitted only
//     when verbose editor tracing is on (Settings ▸ Advanced). Sprinkled at the
//     key pipeline points so a reproduction yields a readable keystroke-level
//     trail in `~/.edmund/logs`.
//   - `verifyEditorInvariants` — checks the two model invariants after a sync. A
//     cheap length check is effectively always on (logs an error if the
//     storage==rawSource invariant ever breaks); the full structural check runs
//     under verbose tracing (and asserts in DEBUG).

extension EditorTextView {

    /// Compact live-state prefix: caret, active block, marked-text, the sync
    /// flags, and storage-vs-rawSource lengths — everything that explains a caret
    /// drift or a stranded sync.
    var diagnosticState: String {
        let sel = selectedRange()
        let marked = markedRange()
        let markedDesc = marked.location == NSNotFound
            ? "-" : "{\(marked.location),\(marked.length)}"
        let storLen = textStorage?.length ?? -1
        let rawLen = (rawSource as NSString).length
        return "sel={\(sel.location),\(sel.length)} active=\(activeBlockIndex.map(String.init) ?? "nil") "
            + "marked=\(markedDesc) up=\(isUpdating ? "Y" : "N") undo=\(isUndoRedoing ? "Y" : "N") "
            + "blocks=\(blocks.count) storLen=\(storLen) rawLen=\(rawLen)"
            + (storLen == rawLen ? "" : " ⚠︎LEN-MISMATCH")
    }

    /// One verbose trace line: `<event> | <live state>`. No-op (and the message
    /// closure isn't built) unless verbose editor tracing is on.
    func traceEdit(_ event: @autoclosure () -> String) {
        Log.trace("\(event()) | \(diagnosticState)", category: .edit)
    }

    /// Under verbose tracing, logs a condensed call stack for a suspicious
    /// selection change — one arriving mid-recompose (up=Y) or while a
    /// pendingEdit is unconsumed. Those are exactly the changes behind the
    /// issue-#156 caret drifts, and the stack names the AppKit path that
    /// moved the caret.
    func traceSelectionOrigin() {
        guard Log.shouldTrace else { return }
        let frames = Thread.callStackSymbols.dropFirst(2).prefix(14).map { frame in
            // "3  AppKit  0x00: -[NSTextView foo] + 12" → drop index/module/addr.
            let parts = frame.split(separator: " ", omittingEmptySubsequences: true)
            return parts.count > 3 ? parts[3...].joined(separator: " ") : frame
        }
        Log.trace("selection origin:\n    " + frames.joined(separator: "\n    "),
                  category: .edit)
    }

    /// A short, newline-escaped, length-capped rendering of edit text for traces.
    func logSnippet(_ s: String?) -> String {
        guard let s else { return "nil" }
        let flat = s.replacingOccurrences(of: "\n", with: "⏎")
        return flat.count <= 24 ? "\"\(flat)\"" : "\"\(flat.prefix(24))…\"(\(s.count))"
    }

    /// Validates the editor's two model invariants and reports violations. The
    /// length check is O(1) and the error is written whenever logging is on (the
    /// always-on tripwire for a desync); the structural checks are O(n) and run
    /// only under verbose tracing. In DEBUG any violation also trips an assertion.
    func verifyEditorInvariants(_ context: String) {
        guard let ts = textStorage else { return }
        let storLen = ts.length
        let rawLen = (rawSource as NSString).length
        if storLen != rawLen {
            Log.error("invariant: storage.length \(storLen) != rawSource.length \(rawLen) [\(context)]",
                      category: .edit)
            assertionFailure("storage != rawSource length after \(context)")
            return
        }
        guard Log.shouldTrace else { return }
        if ts.string != rawSource {
            Log.error("invariant: storage string != rawSource (same length) [\(context)]", category: .edit)
            assertionFailure("storage string != rawSource after \(context)")
        }
        let reconstructed = blocks.map(\.content).joined(separator: blockSeparator)
        if reconstructed != rawSource {
            Log.error("invariant: blocks do not reconstruct rawSource [\(context)]", category: .edit)
            assertionFailure("blocks != rawSource after \(context)")
        }
        if let bad = blocks.first(where: { $0.range.upperBound > rawLen }) {
            Log.error("invariant: block range \(bad.range) exceeds rawSource \(rawLen) [\(context)]",
                      category: .edit)
            assertionFailure("block range out of bounds after \(context)")
        }
    }
}
