#if DEBUG
import AppKit

extension EditorTextView {
    /// The model invariants `verifyEditorInvariants` checks, returned instead of
    /// asserted, for the ReproScript `assertinvariants` command (the `edmd`
    /// module can't see `blocks`). Empty = healthy. Runs every check regardless
    /// of trace settings, and adds the marked-text state a script should never
    /// end a step in unknowingly.
    public func debugInvariantViolations() -> [String] {
        guard let ts = textStorage else { return ["no text storage"] }
        var out: [String] = []
        let rawLen = (rawSource as NSString).length
        if ts.length != rawLen { out.append("storage.length \(ts.length) != rawSource.length \(rawLen)") }
        else if ts.string != rawSource { out.append("storage string != rawSource (same length)") }
        if blocks.map(\.content).joined(separator: blockSeparator) != rawSource {
            out.append("blocks do not reconstruct rawSource")
        }
        if let bad = blocks.first(where: { $0.range.upperBound > rawLen }) {
            out.append("block range \(bad.range) exceeds rawSource \(rawLen)")
        }
        if hasMarkedText() { out.append("marked text still open \(markedRange())") }
        return out
    }
}
#endif
