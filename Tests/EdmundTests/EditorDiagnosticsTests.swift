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
}
