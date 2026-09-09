import Testing
import AppKit
import Foundation
@testable import EdmundCore

/// Covers the verbose editor-tracing facility and the model invariants it guards.
/// Serialized because it drives the global `Log` singleton (file output).
@Suite("Editor diagnostics", .serialized) @MainActor
struct EditorDiagnosticsTests {

    /// Configures `Log` to a fresh temp dir, runs `body`, flushes, and returns the
    /// log file's contents. Always restores logging to off.
    private func captureLog(verbose: Bool, _ body: () -> Void) -> String {
        LogTestIsolation.withLock {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("edmund-diag-\(UUID().uuidString)", isDirectory: true)
            Log.configure(enabled: true, directory: dir, retention: nil)
            Log.setVerbose(verbose)
            defer {
                Log.configure(enabled: false, directory: dir, retention: nil)
                Log.setVerbose(false)
                try? FileManager.default.removeItem(at: dir)
            }
            body()
            Log.flush()
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                includingPropertiesForKeys: nil)) ?? []
            return files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        }
    }

    @Test func verboseTracingEmitsEditLines() {
        let log = captureLog(verbose: true) {
            let editor = makeEditor()
            editor.loadContent("hello\nworld")
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            type("!", into: editor)
        }
        #expect(log.contains("[edit]"))
        #expect(log.contains("shouldChangeText OK"))
        #expect(log.contains("sel="))   // the live-state prefix is present
    }

    @Test func tracingSilentWhenVerboseOff() {
        let log = captureLog(verbose: false) {
            let editor = makeEditor()
            editor.loadContent("hello\nworld")
            editor.setSelectedRange(NSRange(location: 5, length: 0))
            type("!", into: editor)
        }
        #expect(!log.contains("[edit]"))   // no trace spam in normal use
    }

    /// The model-level merge that the live bug only *appears* to break: backspace
    /// at the start of a list item under a heading merges cleanly, the caret moves
    /// back by exactly one, and both invariants hold each step. (The reported
    /// "delete drift" is a live NSTextView/TextKit 2 caret issue, not this.)
    @Test func backspaceMergeKeepsModelConsistent() {
        let editor = makeEditor()
        editor.loadContent("# What to test for\n- Undo/redo\n- Open\n- Save\n")
        let startOfList = ("# What to test for\n" as NSString).length

        editor.setSelectedRange(NSRange(location: startOfList, length: 0))
        for _ in 0..<3 {
            let before = editor.selectedRange().location
            pressBackspace(in: editor)
            #expect(editor.selectedRange().location == before - 1)   // no caret drift
            #expect(editor.textStorage!.string == editor.rawSource)  // invariant intact
            let recon = editor.blocks.map(\.content).joined(separator: "\n")
            #expect(recon == editor.rawSource)                       // block model consistent
        }
    }

    // MARK: - List indent diagnostics
    //
    // `listIndentUnit` is document-global and every list item's rendered depth
    // is `columns / unit`, so one Tab that writes a narrower indent than the
    // document already uses re-indents every *other* list on screen. These two
    // tests pin the evidence that makes that diagnosable from a user's log.

    /// A document that nests at 4 spaces, Tab on a top-level item writing 2 —
    /// the unit drops to 2 and every 4-space item silently gains a level.
    private func indentUnitContaminationEditor() -> EditorTextView {
        let editor = makeEditor()
        editor.loadContent("- alpha\n    - alpha child\n- beta\n\nprose\n\n- gamma\n    - gamma child")
        #expect(editor.listIndentUnit == 4)
        let beta = (editor.rawSource as NSString).range(of: "- beta").location
        editor.setSelectedRange(NSRange(location: beta, length: 6))
        return editor
    }

    @Test func indentUnitChangeIsLoggedWithoutVerbose() {
        var depths: (Int, Int) = (0, 0)
        let log = captureLog(verbose: false) {
            let editor = indentUnitContaminationEditor()
            let before = editor.listDepth(leadingWhitespace: "    ")
            editor.insertTab(nil)
            depths = (before, editor.listDepth(leadingWhitespace: "    "))
        }
        // The unrelated list really did move: this is the bug being logged.
        #expect(depths == (1, 2))
        #expect(log.contains("list indent unit 4 → 2"))
        #expect(log.contains("every list re-depths"))
        #expect(!log.contains("indent blocks"))   // still no verbose spam
    }

    @Test func verboseIndentTraceNamesTheAffectedBlocks() {
        let log = captureLog(verbose: true) {
            let editor = indentUnitContaminationEditor()
            editor.insertTab(nil)
        }
        #expect(log.contains("indent blocks 2…2"))   // only "- beta" was touched
        #expect(log.contains("target=2"))            // padded to "- alpha"'s content column
    }
}
