import Testing
import AppKit
@testable import EdmundCore

/// Latency and memory benchmarks, gated behind `MD_PERF=1` so the regular suite
/// stays fast. Assertions are sanity bounds, not budgets; the numbers are the
/// output. `scripts/bench.sh` runs this in a release build and compares refs.
///
/// Each *case* is a document profile (`PerfCorpus`: one rendering feature per
/// document — tables, math, images, …) under an editor *variant* (theme,
/// appearance, zoom, width, overlays), named `profile/variant@bytes`. Every
/// case runs the same scenarios on a fresh windowed editor — the app's
/// configuration: loads are viewport-first and the idle drain styles the rest.
///
/// Environment:
/// - `MD_PERF_BYTES`  comma-separated sizes (default 50000,300000). The matrix
///   runs at the first; `mixed/default` also runs at every size. The default
///   pair brackets `EditorTextView.fullLayoutMaxLength`, so both layout regimes
///   are measured — a number from one says nothing about the other.
/// - `MD_PERF_CASES`  regex selecting cases, e.g. `tables|math` or `/dark`.
/// - `MD_PERF_REPS`   repetitions per case; each metric reports the median
///   (default 3). Rep 1 runs with cold process caches (math images, overlays,
///   decoded images), later reps warm — the median is the warm figure.
/// - `MD_PERF_DRAIN`  also time draining all lazy styling (slow on big docs).
/// - `MD_PERF_MERMAID_DIR`  an unpacked beautiful-mermaid directory; else the
///   installed engine if present; else `mermaid` times unrendered code blocks.
/// - `MD_PERF_OUT`    append `case<TAB>metric<TAB>median<TAB>min` rows here.
@Suite("Perf harness (MD_PERF)",
       .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
@MainActor
struct PerfHarnessTests {

    static let env = ProcessInfo.processInfo.environment
    static let sizes = env["MD_PERF_BYTES"]?.split(separator: ",").compactMap { Int($0) }
        ?? [50_000, 300_000]
    static let reps = env["MD_PERF_REPS"].flatMap(Int.init) ?? 3
    static let measureDrain = env["MD_PERF_DRAIN"] != nil

    /// Editor configurations applied before loading. Theme and appearance only
    /// change colors today; they're here so a future theme-dependent cost shows.
    static let variants: [(name: String, apply: (EditorTextView, NSWindow) -> Void)] = [
        ("default", { _, _ in }),
        ("dark", { e, w in w.appearance = NSAppearance(named: .darkAqua); e.appearance = w.appearance }),
        ("solarized", { e, _ in
            ThemeStore.shared.activeGeneralLight = "solarized-light"
            ThemeStore.shared.activeSyntaxLight = "solarized-code-light"
            e.applyTheme(e.theme, persist: false)
        }),
        ("zoom150", { e, _ in e.setZoom(1.5) }),
        ("narrow", { e, _ in e.maxContentWidthPoints = 360 }),
        ("linenumbers", { e, _ in e.showLineNumbers = true }),
        ("invisibles", { e, _ in e.invisibles = InvisiblesConfig(); e.refreshOverdraw() }),
        ("focus", { e, _ in e.focusMode = true; e.refreshOverdraw() }),
    ]

    struct Case {
        let profile: String, variant: String, bytes: Int
        var name: String { "\(profile)/\(variant)@\(bytes)" }
    }

    static var cases: [Case] {
        let first = sizes[0]
        var all = PerfCorpus.profiles.map { Case(profile: $0, variant: "default", bytes: first) }
        all += variants.dropFirst().map { Case(profile: "mixed", variant: $0.name, bytes: first) }
        all += sizes.dropFirst().map { Case(profile: "mixed", variant: "default", bytes: $0) }
        guard let pattern = env["MD_PERF_CASES"], let re = try? Regex(pattern) else { return all }
        return all.filter { $0.name.contains(re) }
    }

    /// The app drains an autorelease pool once per event; a test never turns the
    /// run loop, so without this every step's temporaries accumulate. The drain
    /// is timed too, as it is in the app.
    private func measureMS(_ body: () -> Void) -> Double {
        let d = ContinuousClock().measure { autoreleasepool(invoking: body) }
        return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    /// Current physical footprint (what Activity Monitor and jetsam count).
    static func footprintMB() -> Double {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? Double(info.ri_phys_footprint) / 1_048_576 : -1
    }

    /// Unbuffered progress marker: a jetsam kill leaves no crash report and
    /// loses buffered stdout, so stderr shows how far a run got and at what size.
    private func mark(_ s: String) {
        FileHandle.standardError.write(Data(
            "[MD_PERF] …\(s) [\(Int(Self.footprintMB())) MB]\n".utf8))
    }

    private func loadMermaidIfAvailable() -> Bool {
        let dir = Self.env["MD_PERF_MERMAID_DIR"].map { URL(fileURLWithPath: $0) }
            ?? MermaidRelease.payload.installDirectory
        guard FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(MermaidRelease.payload.sentinelFile).path) else { return false }
        MermaidRenderer.shared.load(dir: dir)
        MermaidRenderer.shared.isEnabled = true
        return MermaidRenderer.shared.isReady
    }

    /// One fresh windowed editor through every scenario, in a fixed order
    /// (each scenario sees the state the previous one left, as a user would).
    private func runScenarios(_ c: Case, source: String) -> [(String, Double)] {
        let editor = makeEditor()
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: win.contentLayoutRect)
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        Self.variants.first { $0.name == c.variant }!.apply(editor, win)

        let before = Self.footprintMB()
        var r: [(String, Double)] = []

        mark("load")
        r.append(("load", measureMS { editor.loadContent(source) }))
        let length = (editor.rawSource as NSString).length
        // A profile that silently renders nothing would time the wrong path:
        // images, math and (engine loaded) diagrams all draw as overlays.
        if ["images", "math"].contains(c.profile) || (c.profile == "mermaid" && MermaidRenderer.shared.isReady),
           let ts = editor.textStorage {
            var overlays = 0
            ts.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: min(ts.length, 5_000))) { v, _, _ in
                if v != nil { overlays += 1 }
            }
            #expect(overlays > 0, "\(c.name) rendered no overlays after load")
        }

        mark("keystroke end")
        editor.setSelectedRange(NSRange(location: length, length: 0))
        r.append(("keystroke end", measureMS { type("x", into: editor) }))

        mark("keystroke mid")
        let midLoc = editor.blocks[editor.blockIndexForRawOffset(length / 2) ?? 0].range.location
        editor.setSelectedRange(NSRange(location: midLoc, length: 0))
        r.append(("keystroke mid", measureMS { type("x", into: editor) }))

        mark("enter mid")
        r.append(("enter mid", measureMS { pressEnter(in: editor) }))

        mark("paste")
        let pasteText = PerfCorpus.document(c.profile, bytes: 10_000, seed: 99)
        r.append(("paste 10KB", measureMS { paste(pasteText, into: editor) }))

        mark("undo")
        r.append(("undo paste", measureMS { editor.performUndo() }))

        // Caret jumps across the document through the real selection path
        // (typewriter centering, active-block restyle). Mean per jump.
        mark("caret move")
        let jumps = 20
        let now = (editor.rawSource as NSString).length
        let caret = measureMS {
            for i in 0..<jumps {
                editor.setSelectedRange(NSRange(location: now * (i * 7 % jumps) / jumps, length: 0))
            }
        }
        r.append(("caret move", caret / Double(jumps)))

        // Scroll through the document with a real draw at each stop: layout of
        // newly visible fragments plus all fragment and margin-chrome drawing.
        mark("scroll")
        let stops = 10
        if let rep = scroll.bitmapImageRepForCachingDisplay(in: scroll.bounds) {
            let total = measureMS {
                for i in 0..<stops {
                    editor.scrollRangeToVisible(NSRange(location: now * i / stops, length: 0))
                    scroll.cacheDisplay(in: scroll.bounds, to: rep)
                }
            }
            r.append(("scroll frame", total / Double(stops)))
        }

        if Self.measureDrain {
            mark("drain")
            r.append(("full drain", measureMS { drainAllStyling(editor, maxSlices: 100_000) }))
        }
        r.append(("footprint +MB", Self.footprintMB() - before))
        return r
    }

    @Test("Latency and memory across document features and editor variants")
    func matrix() throws {
        let savedGeneral = ThemeStore.shared.activeGeneralLight
        let savedSyntax = ThemeStore.shared.activeSyntaxLight
        defer {
            ThemeStore.shared.activeGeneralLight = savedGeneral
            ThemeStore.shared.activeSyntaxLight = savedSyntax
            MermaidRenderer.shared.isEnabled = false
        }
        let mermaid = loadMermaidIfAvailable()
        var rows: [String] = []
        for c in Self.cases {
            let source = PerfCorpus.document(c.profile, bytes: c.bytes)
            var samples: [String: [Double]] = [:]
            var order: [String] = []
            for rep in 0..<Self.reps {
                mark("\(c.name) rep \(rep + 1)/\(Self.reps)")
                for (metric, v) in runScenarios(c, source: source) {
                    if samples[metric] == nil { order.append(metric) }
                    samples[metric, default: []].append(v)
                }
                ThemeStore.shared.activeGeneralLight = savedGeneral
                ThemeStore.shared.activeSyntaxLight = savedSyntax
            }
            let chars = (source as NSString).length
            let regime = chars <= EditorTextView.fullLayoutMaxLength ? "full layout" : "estimate"
            let note = c.profile == "mermaid" && !mermaid ? ", engine not installed: unrendered" : ""
            print("[MD_PERF] \(c.name): \(chars) chars, \(regime) regime\(note)")
            for metric in order {
                let sorted = samples[metric]!.sorted()
                let median = sorted[sorted.count / 2]
                let unit = metric.hasSuffix("MB") ? "MB" : "ms"
                print("[MD_PERF]   \(metric.padding(toLength: 14, withPad: " ", startingAt: 0))"
                      + String(format: "%10.2f %@   (min %.2f)", median, unit, sorted[0]))
                rows.append(String(format: "%@\t%@\t%.3f\t%.3f", c.name, metric, median, sorted[0]))
                if unit == "ms" { #expect(median < 120_000, "\(metric) in \(c.name)") }
            }
        }
        if let out = Self.env["MD_PERF_OUT"] {
            let text = rows.joined(separator: "\n") + "\n"
            if let h = FileHandle(forWritingAtPath: out) {
                h.seekToEndOfFile(); h.write(Data(text.utf8)); try h.close()
            } else {
                try text.write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
    }
}
