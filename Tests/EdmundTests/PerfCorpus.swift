import AppKit

/// Feature-dominated documents for the perf harness: each profile stresses one
/// rendering path, so a regression shows up under the feature that caused it
/// rather than averaged into a mixed document. Deterministic per seed.
enum PerfCorpus {

    static let profiles = ["mixed", "prose", "longlines", "hardwrap", "tables", "callouts",
                           "code", "math", "images", "mermaid", "lists"]

    static func document(_ profile: String, bytes: Int, seed: UInt64 = 42) -> String {
        var g = Gen(seed: seed)
        switch profile {
        case "mixed":     return makeLargeMarkdown(approximateBytes: bytes, seed: seed)
        case "prose":     return Gen.fill(&g, bytes) { g in let n = g.int(30...80); return g.paragraph(words: n, styled: 4) }
                              + g.footnoteDefinitions()
        case "longlines": return Gen.fill(&g, bytes) { g in let n = g.int(600...1200); return g.paragraph(words: n, styled: 12) }
        case "hardwrap":  return Gen.fill(&g, bytes) { g in let n = g.int(600...1200); return g.wrapped(g.paragraph(words: n, styled: 12)) }
        case "tables":    return Gen.fill(&g, bytes) { $0.table() }
        case "callouts":  return Gen.fill(&g, bytes) { $0.callout() }
        case "code":      return Gen.fill(&g, bytes) { $0.codeBlock() }
        case "math":      return Gen.fill(&g, bytes) { $0.mathChunk() }
        case "images":    return Gen.fill(&g, bytes) { $0.imageChunk() }
        case "mermaid":   return Gen.fill(&g, bytes) { $0.mermaidChunk() }
        case "lists":     return Gen.fill(&g, bytes) { $0.list() }
        default:          fatalError("unknown perf profile \(profile)")
        }
    }

    /// A few real PNGs of different sizes, written once per process.
    @MainActor static let imagePaths: [String] = [(640, 480), (1600, 900), (200, 200)].map { w, h in
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGradient(starting: .systemTeal, ending: .systemOrange)!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 30)
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-perf-\(w)x\(h).png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
        return url.path
    }

    struct Gen {
        var rng: SeededGenerator
        var footnotes = 0
        init(seed: UInt64) { rng = SeededGenerator(seed: seed) }

        static let words = ["alpha", "beta", "gamma", "delta", "lorem", "ipsum", "dolor",
                            "editor", "markdown", "render", "block", "cursor", "style",
                            "viewport", "layout", "anchor", "fragment", "glyph", "parse"]

        mutating func int(_ r: ClosedRange<Int>) -> Int { Int.random(in: r, using: &rng) }
        mutating func word() -> String { Self.words.randomElement(using: &rng)! }
        mutating func words(_ n: Int) -> String { (0..<n).map { _ in word() }.joined(separator: " ") }

        static func fill(_ g: inout Gen, _ bytes: Int, _ chunk: (inout Gen) -> String) -> String {
            var out: [String] = []
            var size = 0
            while size < bytes {
                let c = chunk(&g)
                out.append(c)
                size += c.utf8.count + 2
            }
            return out.joined(separator: "\n\n")
        }

        /// Prose with roughly one styled token per `styled` words, drawn from
        /// every inline construct the editor renders.
        mutating func paragraph(words n: Int, styled: Int) -> String {
            (0..<n).map { _ -> String in
                let w = word()
                guard int(1...styled) == 1 else { return w }
                switch int(0...9) {
                case 0: return "**\(w)**"
                case 1: return "*\(w)*"
                case 2: return "`\(w)`"
                case 3: return "[\(w)](https://example.com/\(w))"
                case 4: return "==\(w)=="
                case 5: return "~~\(w)~~"
                case 6: return "[[\(w.capitalized) note|\(w)]]"
                case 7: return "#\(w)"
                case 8: footnotes += 1; return "\(w)[^\(footnotes)]"
                default: return "***\(w)***"
                }
            }.joined(separator: " ") + "."
        }

        func footnoteDefinitions() -> String {
            footnotes == 0 ? "" : "\n\n" + (1...footnotes).map { "[^\($0)]: Footnote \($0)." }
                .joined(separator: "\n")
        }

        /// Hard-wraps at 72 columns: the same text as `longlines`, as many short lines.
        func wrapped(_ text: String) -> String {
            var lines: [String] = [], line = ""
            for w in text.split(separator: " ") {
                if line.count + w.count + 1 > 72 { lines.append(line); line = "" }
                line += line.isEmpty ? String(w) : " " + w
            }
            return (lines + [line]).joined(separator: "\n")
        }

        mutating func table() -> String {
            let cols = int(3...8)
            let row = { (g: inout Gen) -> String in
                "| " + (0..<cols).map { _ in g.int(1...5) == 1 ? g.words(g.int(20...40)) : g.words(g.int(1...3)) }
                    .joined(separator: " | ") + " |"
            }
            let aligns = [":---", "---:", ":---:", "---"]
            var rows = [row(&self),
                        "| " + (0..<cols).map { _ in aligns.randomElement(using: &rng)! }.joined(separator: " | ") + " |"]
            for _ in 0..<int(4...20) { rows.append(row(&self)) }
            return rows.joined(separator: "\n")
        }

        mutating func callout() -> String {
            let types = ["note", "tip", "warning", "important", "abstract", "bug", "quote", "example"]
            var lines = ["> [!\(types.randomElement(using: &rng)!)] \(words(3))"]
            for _ in 0..<int(2...6) { lines.append("> \(paragraph(words: int(8...25), styled: 6))") }
            if int(1...3) == 1 {
                lines.append(">")
                lines.append("> > [!tip] \(words(2))")
                for _ in 0..<int(1...3) { lines.append("> > \(words(int(8...20)))") }
            }
            return lines.joined(separator: "\n")
        }

        mutating func codeBlock() -> String {
            let langs: [(String, (inout Gen) -> String)] = [
                ("swift", { g in "    let \(g.word()) = \(g.word())(\(g.int(0...99)), \"\(g.word())\") // \(g.word())" }),
                ("python", { g in "    def \(g.word())(self, \(g.word())): return [\(g.int(0...9)) for _ in \"\(g.word())\"]" }),
                ("javascript", { g in "  const \(g.word()) = await \(g.word())({ \(g.word()): \(g.int(0...99)) });" }),
                ("json", { g in "  \"\(g.word())\": [\(g.int(0...99)), true, null, \"\(g.word())\"]," }),
                ("bash", { g in "\(g.word()) --\(g.word())=\(g.int(0...9)) | grep \"\(g.word())\" > /tmp/\(g.word())" }),
            ]
            let (lang, line) = langs.randomElement(using: &rng)!
            return (["```\(lang)"] + (0..<int(10...60)).map { _ in line(&self) } + ["```"])
                .joined(separator: "\n")
        }

        mutating func mathChunk() -> String {
            let n = int(0...99)
            let inline = ["$x_{\(n)}^2 + y^2 = r^2$", "$\\frac{a_{\(n)}}{b}$", "$\\sqrt{\(n) + \\alpha}$",
                          "$\\sum_{i=1}^{\(n)} i$", "$e^{i\\pi \(n)}$"]
            if int(1...3) == 1 {
                return "$$\n\\begin{aligned}\nf(x) &= \\int_0^{\(n)} e^{-t^2}\\,dt \\\\\n"
                    + "g(x) &= \\sum_{k=0}^{\\infty} \\frac{x^k}{k!} + \(n)\n\\end{aligned}\n$$"
            }
            return (0..<int(2...4)).map { _ in words(int(5...12)) + " " + inline.randomElement(using: &rng)! }
                .joined(separator: " ") + "."
        }

        mutating func imageChunk() -> String {
            let path = MainActor.assumeIsolated { PerfCorpus.imagePaths }.randomElement(using: &rng)!
            let img = int(1...2) == 1 ? "![\(word())](\(path))" : "![\(word())|\(int(120...480))](\(path))"
            return paragraph(words: int(10...30), styled: 8) + "\n\n" + img
        }

        mutating func mermaidChunk() -> String {
            if int(1...2) == 1 {
                let nodes = (0..<int(5...15)).map { "N\($0)[\(words(2))]" }
                var lines = ["```mermaid", "flowchart TD"]
                for i in 1..<nodes.count { lines.append("  \(nodes[int(0...(i - 1))]) --> \(nodes[i])") }
                return (lines + ["```"]).joined(separator: "\n")
            }
            var lines = ["```mermaid", "sequenceDiagram"]
            for _ in 0..<int(4...10) { lines.append("  Alice->>Bob: \(words(3))") }
            return (lines + ["```"]).joined(separator: "\n")
        }

        mutating func list() -> String {
            (0..<int(5...20)).map { i -> String in
                let depth = int(0...3)
                let marker = ["- ", "- [ ] ", "- [x] ", "\(i + 1). "].randomElement(using: &rng)!
                return String(repeating: "    ", count: depth) + marker + paragraph(words: int(4...15), styled: 6)
            }.joined(separator: "\n")
        }
    }
}
