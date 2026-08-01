import Foundation

/// "Mermaid" — renders ```` ```mermaid ```` fenced code blocks as diagrams in
/// Read mode and in HTML/PDF export, using `beautiful-mermaid` (MIT) run as
/// plain JavaScript in JavaScriptCore rather than shipped in the binary.
/// See `MermaidRelease`/`MermaidRenderer` for the download, verify, and load
/// machinery this wraps.
///
/// Edit mode deliberately still shows the raw fence as a code block; see
/// `docs/architecture/reader-and-export.md`.
@MainActor
public final class MermaidExtension: EdmundExtension {
    public static let shared = MermaidExtension()

    public let id = "mermaid"
    public let name = "Mermaid"
    /// This is Edmund's packaging version, not beautiful-mermaid's — the
    /// upstream project is named and linked in `summary` instead (mirrors how
    /// Obsidian plugins version themselves separately from any library they
    /// wrap).
    public let summary = AttributedString(
        inlineMarkdown:
            "Render Mermaid diagrams with code block syntax (```mermaid) using "
            + "[beautiful-mermaid](https://github.com/lukilabs/beautiful-mermaid). "
            + "Currently supports flowcharts, state, sequence, class, ER, and XY Charts (bar, line, combined).")
    public let version = "1.0.0"
    public var isInstalled: Bool { renderer.isReady }
    /// This extension provides diagram rendering, not math.
    public var mathRenderer: MathRenderer? { nil }

    // I7T5 (i7t5.com) is this extension's author. beautiful-mermaid itself
    // (the library it wraps) is Craft Docs' separate project; that credit
    // belongs in this extension's own README once it has one, not asserted
    // here as authorship of this repo. No dedicated extension repo exists yet;
    // stub until it does.
    public let developer: ExtensionDeveloper? =
        ExtensionDeveloper(name: "I7T5", profileURL: URL(string: "https://i7t5.com"))
    public let repositoryURL: URL? = nil
    // Measured from the unpacked payload: a 1.49 MB bundled JS file plus three
    // license texts.
    public let installedSizeDescription: String? = "1.5 MB"
    // beautiful-mermaid 1.1.3's actual npm publish date (read from the registry,
    // not a guess) — not Edmund's own commit date.
    public let lastUpdated: Date? = {
        var c = DateComponents()
        c.year = 2026; c.month = 1; c.day = 28
        return Calendar(identifier: .gregorian).date(from: c)
    }()
    // No real download-analytics source exists for this extension.
    public let downloadCount: Int? = nil
    // No README exists at a stable URL yet (extension has no repo of its own).
    public let longDescriptionURL: URL? = nil
    public let donateURL: URL? = nil
    // No update-checking source exists yet — same "scaffold now, wire later"
    // shape as the install flow itself.
    public let hasUpdate = false
    public var payloadIsConfigured: Bool { MermaidRelease.isConfigured }

    public let renderer: MermaidRenderer

    init(renderer: MermaidRenderer = MermaidRenderer.shared) {
        self.renderer = renderer
    }

    /// The installer's current state, for Settings to surface a specific
    /// reason on failure (e.g. the payload not published for this build yet).
    public var installState: ExtensionInstallState {
        get async { await renderer.installState }
    }

    /// Downloads/verifies/installs (if needed) and loads the library. Safe to
    /// call repeatedly; a no-op once already loaded. Callers still need to set
    /// `MermaidRenderer.shared.isEnabled` for rendering to actually happen
    /// (Settings does this on enable).
    public func download() async {
        await renderer.install()
    }

    public func uninstall() async {
        await renderer.uninstall()
    }
}
