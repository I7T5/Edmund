import Testing
import AppKit
@testable import MarkdownEditorCore

/// Large-file latency measurements, gated behind `MD_PERF=1` so the regular
/// suite stays fast. Numbers are printed for recording in commit messages;
/// assertions are deliberately generous (sanity bounds, not budgets).
///
/// The editor runs windowed (scroll view + window), the same configuration as
/// the app: loads are viewport-first and the idle drain styles the rest —
/// headless editors style everything synchronously by design, which is a
/// tests-only path and not representative.
@Suite("Perf harness (MD_PERF)",
       .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
struct PerfHarnessTests {

    /// Document size; override with MD_PERF_BYTES to bisect or scale.
    static let documentBytes = ProcessInfo.processInfo.environment["MD_PERF_BYTES"]
        .flatMap(Int.init) ?? 1_500_000

    @MainActor private func measureMS(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let duration = clock.measure(body)
        return Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
    }

    /// Unbuffered progress marker so a hard crash still shows how far we got.
    private func mark(_ s: String) {
        FileHandle.standardError.write(Data("[MD_PERF] …\(s)\n".utf8))
    }

    @Test("Pipeline latency on a large document (windowed, lazy)")
    @MainActor func largeFileLatency() {
        let source = makeLargeMarkdown(approximateBytes: Self.documentBytes, seed: 42)

        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]

        mark("loading")
        let loadMS = measureMS { editor.loadContent(source) }
        let blockCount = editor.blocks.count
        let styledAtLoad = editor.blocks.filter(\.isStyled).count
        let length = (editor.rawSource as NSString).length

        // Keystroke at the end of the document.
        mark("keystroke end: setSelectedRange")
        editor.setSelectedRange(NSRange(location: length, length: 0))
        mark("keystroke end: recomposeIncremental")
        editor.recomposeIncremental(cursorInRaw: length)
        mark("keystroke end: type")
        let endKeystrokeMS = measureMS { type("x", into: editor) }

        // Keystroke mid-document (inside whatever block is there).
        mark("keystroke mid")
        let midBlock = editor.blockIndexForRawOffset(length / 2) ?? 0
        let midLoc = editor.blocks[midBlock].range.location
        editor.setSelectedRange(NSRange(location: midLoc, length: 0))
        editor.recomposeIncremental(cursorInRaw: midLoc)
        let midKeystrokeMS = measureMS { type("x", into: editor) }

        // Enter mid-document (block split).
        mark("enter mid")
        let enterMS = measureMS { pressEnter(in: editor) }

        // 10 KB paste mid-document.
        mark("paste")
        let pasteText = makeLargeMarkdown(approximateBytes: 10_000, seed: 99)
        let pasteMS = measureMS { paste(pasteText, into: editor) }

        // Undo of the paste.
        mark("undo")
        let undoMS = measureMS { editor.performUndo() }

        // Drain the remaining lazy styling to completion.
        mark("drain")
        let drainMS = measureMS { drainAllStyling(editor, maxSlices: 100_000) }

        print("""
        [MD_PERF] document: \(length) chars, \(blockCount) blocks (\(styledAtLoad) styled at load)
        [MD_PERF] loadContent:        \(String(format: "%9.2f", loadMS)) ms
        [MD_PERF] keystroke (end):    \(String(format: "%9.2f", endKeystrokeMS)) ms
        [MD_PERF] keystroke (mid):    \(String(format: "%9.2f", midKeystrokeMS)) ms
        [MD_PERF] enter (mid):        \(String(format: "%9.2f", enterMS)) ms
        [MD_PERF] paste 10KB (mid):   \(String(format: "%9.2f", pasteMS)) ms
        [MD_PERF] undo:               \(String(format: "%9.2f", undoMS)) ms
        [MD_PERF] full drain:         \(String(format: "%9.2f", drainMS)) ms
        """)

        // Sanity bounds only — wildly generous so this never flakes.
        #expect(loadMS < 120_000)
        #expect(enterMS < 120_000)
    }
}
