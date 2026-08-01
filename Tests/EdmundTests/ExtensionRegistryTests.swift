import Foundation
import Testing
@testable import EdmundCore

@Suite("ExtensionRegistry")
struct ExtensionRegistryTests {

    @Test("Advanced Math is registered and not installed before its payload is downloaded")
    @MainActor func advancedMathListed() {
        let ext = ExtensionRegistry.all.first { $0.id == "advanced-math" }
        #expect(ext != nil)
        #expect(ext?.name == "Advanced Math")
        // Nothing in this suite calls download() on the shared instance (that's
        // a real network fetch — see RaTeXWasmIntegrationTests, gated on
        // RATEX_ARCHIVE), so it stays not-installed here regardless of whether
        // RaTeXRelease.isConfigured is true.
        #expect(ext?.isInstalled == false)
        #expect(ext?.mathRenderer != nil)
    }

    @Test("Advanced Math's mathRenderer is the RaTeX engine, not SwiftMath")
    @MainActor func advancedMathProvidesRaTeX() {
        let ext = AdvancedMathExtension.shared
        #expect(ext.mathRenderer?.id == ext.renderer.id)
        #expect(ext.mathRenderer?.id.hasPrefix("ratex@") == true)
    }

    @Test("Advanced Math's version is Edmund's own packaging version, not RaTeX's")
    @MainActor func advancedMathVersioning() {
        let ext = AdvancedMathExtension.shared
        #expect(ext.version == "1.0.0")
        #expect(String(ext.summary.characters).split(separator: " ").count <= 30)
    }

    @Test("An extension summary renders its markdown links, and keeps a leading >")
    @MainActor func advancedMathSummaryLinks() {
        let summary = AdvancedMathExtension.shared.summary
        let text = String(summary.characters)

        // Full markdown parsing would read the leading ">" as a blockquote and
        // drop it, turning ">99.5% coverage" into "99.5% coverage" — a quietly
        // wrong claim. Inline-only parsing is what keeps it.
        #expect(text.hasPrefix(">99.5%"))
        // The link markup is consumed, not shown.
        #expect(!text.contains("https://"))
        #expect(text.contains("RaTeX"))

        let links = summary.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://ratex.lites.dev")])
        // …and it is "RaTeX" that carries it, not the whole sentence.
        let linked = summary.runs.filter { $0.link != nil }
            .map { String(summary[$0.range].characters) }
        #expect(linked == ["RaTeX"])
    }

    @Test("Advanced Math's metadata fields are honest about what's actually known")
    @MainActor func advancedMathMetadata() {
        let ext = AdvancedMathExtension.shared
        #expect(ext.developer?.name == "I7T5")
        #expect(ext.developer?.profileURL != nil)
        #expect(ext.installedSizeDescription != nil)
        #expect(ext.lastUpdated != nil)
        // No dedicated extension repo/README/analytics/donate source exists
        // yet — these must stay nil rather than fabricate data.
        #expect(ext.repositoryURL == nil)
        #expect(ext.longDescriptionURL == nil)
        #expect(ext.downloadCount == nil)
        #expect(ext.donateURL == nil)
        // No update-checking source exists yet.
        #expect(ext.hasUpdate == false)
    }

    // MARK: - Mermaid

    @Test("Mermaid is registered and not installed before its payload is downloaded")
    @MainActor func mermaidListed() {
        #expect(ExtensionRegistry.all.count == 2)
        let ext = ExtensionRegistry.all.first { $0.id == "mermaid" }
        #expect(ext != nil)
        #expect(ext?.name == "Mermaid")
        #expect(ext?.isInstalled == false)
        // This one provides diagram rendering, not a math engine.
        #expect(ext?.mathRenderer == nil)
    }

    @Test("Extension IDs are unique — they key the persisted enabled set")
    @MainActor func idsAreUnique() {
        let ids = ExtensionRegistry.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("Mermaid's version is Edmund's own packaging version, not the library's")
    @MainActor func mermaidVersioning() {
        let ext = MermaidExtension.shared
        #expect(ext.version == "1.0.0")
        // beautiful-mermaid's own version is named in MermaidRelease, and the
        // library is credited in `summary` — not conflated with this number.
        #expect(ext.version != MermaidRelease.version)
        #expect(String(ext.summary.characters).split(separator: " ").count <= 30)
    }

    @Test("Mermaid's summary keeps its triple-backtick fence and links the library")
    @MainActor func mermaidSummaryLinks() {
        let summary = MermaidExtension.shared.summary
        let text = String(summary.characters)

        // The fence spelling is the whole point of the sentence — a markdown
        // parser that swallowed it (a code span opened by ``` and never
        // closed) would leave the user guessing at the syntax. Inline-only
        // parsing preserves it verbatim.
        #expect(text.contains("(```mermaid)"))
        // The link markup is consumed, not shown.
        #expect(!text.contains("https://"))
        #expect(!text.contains("]("))

        let links = summary.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://github.com/lukilabs/beautiful-mermaid")])
        // …and it is "beautiful-mermaid" that carries it, not the whole sentence.
        let linked = summary.runs.filter { $0.link != nil }
            .map { String(summary[$0.range].characters) }
        #expect(linked == ["beautiful-mermaid"])

        // Every diagram type the description claims is one the payload can
        // actually render (asserted end-to-end in MermaidJSIntegrationTests).
        for kind in ["flowchart", "state", "sequence", "class", "ER", "XY Chart"] {
            #expect(text.contains(kind), "summary should mention \(kind)")
        }
    }

    @Test("Mermaid's metadata fields are honest about what's actually known")
    @MainActor func mermaidMetadata() {
        let ext = MermaidExtension.shared
        #expect(ext.developer?.name == "I7T5")
        #expect(ext.developer?.profileURL != nil)
        #expect(ext.installedSizeDescription != nil)
        #expect(ext.lastUpdated != nil)
        #expect(ext.repositoryURL == nil)
        #expect(ext.longDescriptionURL == nil)
        #expect(ext.downloadCount == nil)
        #expect(ext.donateURL == nil)
        #expect(ext.hasUpdate == false)
        // Tracks the release pin, so Settings can say "not available in this
        // build yet" instead of offering a download that cannot be verified.
        #expect(ext.payloadIsConfigured == MermaidRelease.isConfigured)
    }
}
