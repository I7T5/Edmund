import Testing
import Foundation
@testable import EdmundCore

@Suite("Mermaid — payload scaffold")
struct MermaidPayloadTests {

    // MARK: Fence recognition

    @Test("A mermaid info string selects the renderer, other languages don't")
    func fenceRecognition() {
        #expect(MermaidSyntax.matches(language: "mermaid"))
        // Mermaid permits whitespace after the language name, so only the
        // first info-string word decides.
        #expect(MermaidSyntax.matches(language: "mermaid  "))
        #expect(MermaidSyntax.matches(language: "mermaid theme=dark"))
        #expect(MermaidSyntax.matches(language: "MERMAID"))
        #expect(MermaidSyntax.matches(language: "Mermaid"))

        #expect(!MermaidSyntax.matches(language: "swift"))
        #expect(!MermaidSyntax.matches(language: "mermaidjs"))
        #expect(!MermaidSyntax.matches(language: ""))
        #expect(!MermaidSyntax.matches(language: nil))
    }

    // MARK: Release pin

    @Test("The payload is pinned to a version-stamped directory and a sentinel file")
    func payloadShape() {
        let payload = MermaidRelease.payload
        #expect(payload.directoryName == "Diagrams/beautiful-mermaid-\(MermaidRelease.version)")
        #expect(payload.sentinelFile == "beautiful-mermaid.js")
        #expect(payload.archiveURL.absoluteString.contains(MermaidRelease.version))
        // A version-stamped install directory means a new pin installs fresh
        // rather than merging into the previous version's files.
        #expect(payload.installDirectory.path.hasSuffix("Edmund/Diagrams/beautiful-mermaid-\(MermaidRelease.version)"))
    }

    @Test("The pinned hash is either absent or a real lowercase SHA-256")
    func hashPinIsHonest() {
        // Empty is legitimate: it means the asset isn't published yet, and
        // `isConfigured` stays false so nothing tries to download something it
        // cannot verify. What must never happen is a malformed pin.
        let hash = MermaidRelease.archiveSHA256
        #expect(MermaidRelease.isConfigured == !hash.isEmpty)
        if !hash.isEmpty {
            #expect(hash.count == 64)
            #expect(hash == hash.lowercased())
            #expect(hash.allSatisfy { $0.isHexDigit })
        }
    }

    // MARK: Renderer, before anything is installed

    @Test("A renderer with no payload returns nil instead of crashing")
    @MainActor func rendererNotReady() {
        let renderer = MermaidRenderer()
        #expect(!renderer.isReady)

        // Disabled and not installed.
        #expect(renderer.svg(source: "graph TD\n A --> B", style: .init(backgroundHex: "#FFFFFF", foregroundHex: "#000000")) == nil)

        // Enabled but still not installed — the caller falls back to showing
        // the fence as a plain code block.
        renderer.isEnabled = true
        #expect(renderer.svg(source: "graph TD\n A --> B", style: .init(backgroundHex: "#FFFFFF", foregroundHex: "#000000")) == nil)
    }

    @Test("Uninstalling before ever installing is safe")
    @MainActor func uninstallWithoutInstall() async {
        let renderer = MermaidRenderer()
        await renderer.uninstall()   // must not crash
        #expect(!renderer.isReady)
    }

    @Test("Style JSON carries the page palette and sets no font")
    func styleJSON() {
        let json = MermaidStyle(backgroundHex: "#FFFFFF", foregroundHex: "#27272A").optionsJSON
        #expect(json == ##"{"bg":"#FFFFFF","fg":"#27272A"}"##)
        // Passing the editor's serif body font would risk labels overflowing
        // boxes sized by the library's Inter-calibrated width heuristic.
        #expect(!json.contains("font"))
    }

    // MARK: SVG safety filter

    @Test("The safety filter allows arrowhead refs but rejects script and network reach")
    func svgSafetyFilter() {
        // url(#…) is how every arrowhead is drawn — rejecting `url(` outright
        // would silently strip the arrowheads off every diagram.
        #expect(MermaidRenderer.isSafeSVG(#"<svg><path marker-end="url(#arrowhead)"/></svg>"#))
        #expect(MermaidRenderer.isSafeSVG(#"<svg><style>svg { --_line: color-mix(in srgb, var(--fg) 50%, var(--bg)); }</style></svg>"#))

        #expect(!MermaidRenderer.isSafeSVG("<svg><script>alert(1)</script></svg>"))
        #expect(!MermaidRenderer.isSafeSVG(#"<svg><image href="javascript:alert(1)"/></svg>"#))
        #expect(!MermaidRenderer.isSafeSVG("<svg><style>@import url('https://fonts.googleapis.com/x');</style></svg>"))
        #expect(!MermaidRenderer.isSafeSVG(#"<svg><rect fill="url(https://evil.example/x)"/></svg>"#))
        #expect(!MermaidRenderer.isSafeSVG(#"<svg onload="alert(1)"></svg>"#))
        #expect(!MermaidRenderer.isSafeSVG(#"<svg><foreignObject><body/></foreignObject></svg>"#))
        #expect(!MermaidRenderer.isSafeSVG(#"<svg><use href="http://evil.example/x"/></svg>"#))
    }
}
