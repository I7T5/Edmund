import AppKit
import Testing
@testable import EdmundCore

@Suite("Reader background HTML preparation")
@MainActor
struct ReadHTMLPreparationTests {
    @Test("Reader preparation phase timings on a 1 MB document",
          .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
    func phaseTimings() async throws {
        let markdown = PerfCorpus.document("mixed", bytes: 1_000_000)
        let options = ReadRenderOptions.default
        let start = ContinuousClock.now
        let body = try await ReadHTMLRenderer.shared.render(markdown: markdown, options: options)
        let prepared = ContinuousClock.now
        let css = HTMLTheme.css(.default, callouts: Callout.defaultStyles, dark: false)
        let html = DocumentHTML.finish(body: body, css: css, theme: .default,
                                       dark: false, options: options)
        let finished = ContinuousClock.now
        let expected = DocumentHTML.full(markdown: markdown, theme: .default,
                                         callouts: Callout.defaultStyles, dark: false, options: options)
        let synchronousEnd = ContinuousClock.now
        #expect(html == expected)
        func ms(_ duration: Duration) -> Double {
            Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        }
        print("[MD_PERF] reader 1MB: prepare+handoff=\(ms(prepared - start)) ms, main finish=\(ms(finished - prepared)) ms, synchronous total=\(ms(synchronousEnd - finished)) ms")
    }

    @Test("Background preparation preserves the complete synchronous document", arguments: [
        "# Title\n\nA **bold** paragraph with café and 中文.\n\n- [x] done\n- [ ] todo",
        "```swift\nlet x = 1 < 2\n```\n\n```unknown\n</code> & quoted\n```",
        "> [!note]\n> ```swift\n> let café = 42\n> ```\n\n> [!tip]\n> nested **text**",
        "value $x^2$\n\n$$\nx^2\n$$\n\n```mermaid\ngraph TD; A-->B\n```",
        "---\ntitle: hidden\n---\n\n%% hidden %%\n\n![missing](absent.png)\n\n| A | B |\n|---|---|\n| 1 | 2 |"
    ])
    func outputEquivalence(markdown: String) async throws {
        let options = ReadRenderOptions.default
        let body = try await ReadHTMLRenderer.shared.render(markdown: markdown, options: options)
        let css = HTMLTheme.css(.default, callouts: Callout.defaultStyles, dark: false)
        let html = DocumentHTML.finish(body: body, css: css, theme: .default,
                                       dark: false, options: options)
        let expected = DocumentHTML.full(markdown: markdown, theme: .default,
                                         callouts: Callout.defaultStyles, dark: false, options: options)
        #expect(html == expected)
        #expect(!html.contains("data-edmund-code="))
        #expect(!html.contains("data-tex="))
        #expect(html.contains("script-src 'none'"))
    }

    @Test("Only the newest request publishes after rapid replacements")
    func newestRequestWins() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Void>.makeStream()
        let preparation = ReadHTMLPreparation { markdown, options in
            if markdown == "obsolete" {
                started.continuation.yield()
                // Deliberately ignore cancellation until the test releases us.
                for await _ in release.stream { break }
            }
            return try await ReadHTMLRenderer.shared.render(markdown: markdown, options: options)
        }
        var published: [String] = []
        preparation.prepare(markdown: "obsolete",
                            options: .default) { published.append($0) }
        var starts = started.stream.makeAsyncIterator()
        await starts.next()
        preparation.prepare(markdown: "# Latest", options: .default) {
            published.append($0)
            completed.continuation.yield()
        }
        release.continuation.yield()
        var completions = completed.stream.makeAsyncIterator()
        await completions.next()
        _ = try await ReadHTMLRenderer.shared.render(markdown: "barrier", options: .default)
        await Task.yield()
        #expect(!preparation.isPreparing)
        #expect(published.count == 1)
        #expect(published.first?.contains("Latest") == true)
        #expect(published.first?.contains("obsolete") == false)
    }

    @Test("Cancelling on mode exit suppresses an obsolete completion")
    func modeExitCancels() async throws {
        let preparation = ReadHTMLPreparation()
        var published = false
        preparation.prepare(markdown: "# Cancel me", options: .default) { _ in published = true }
        preparation.cancel()
        _ = try await ReadHTMLRenderer.shared.render(markdown: "barrier", options: .default)
        await Task.yield()
        #expect(!preparation.isPreparing)
        #expect(!published)
        // A cancelled preparation remains usable on re-entry.
        preparation.prepare(markdown: "# Returned", options: .default) { _ in published = true }
        let deadline = ContinuousClock.now + .seconds(3)
        while preparation.isPreparing, ContinuousClock.now < deadline { await Task.yield() }
        #expect(published)
    }
}
