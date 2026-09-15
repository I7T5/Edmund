import Foundation

// MARK: - EdmundExtension
//
// A minimal, internal extension-point registry: what an extension IS
// (metadata) and the one capability the app exposes today (an alternate
// math-typesetting engine). New capabilities belong on this protocol only
// once a second real extension needs one — see the "no speculative
// abstraction" guidance in docs/ARCHITECTURE.md. This is not a third-party
// code-loading mechanism (that would mean running arbitrary code against
// storage/undo/the TextKit 2 stack, which is a separate, much larger
// security/sandboxing project); it's a seam shaped so the app's *own*
// optional features plug in without EditorTextView/DocumentHTML needing to
// know about them.

public extension AttributedString {
    /// Parses inline markdown — an extension `summary`, a Settings note — so links
    /// can be written in place (`[RaTeX](https://ratex.lites.dev)`).
    ///
    /// Inline-only parsing is required, not a preference: full markdown reads a
    /// leading `>` as a blockquote and would silently eat the `>` in a summary
    /// that opens with something like ">99.5% coverage". It also keeps the
    /// result a single paragraph, which is what the one-line pane expects.
    ///
    /// Falls back to the markdown as literal text — a summary that shows its
    /// source is worse than one that renders, but better than an empty pane.
    init(inlineMarkdown markdown: String) {
        self = (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }
}

/// An extension's author credit: a display name, and an optional link to
/// their profile/site (rendered as plain text when there's no link).
public struct ExtensionDeveloper: Sendable {
    public let name: String
    public let profileURL: URL?

    public init(name: String, profileURL: URL? = nil) {
        self.name = name
        self.profileURL = profileURL
    }
}

/// One optional feature the app can enable, described for Settings and for
/// whatever capability (today: `mathRenderer`) it provides.
@MainActor
public protocol EdmundExtension: AnyObject {
    /// Stable identity (e.g. "advanced-math"), used to persist which
    /// extensions are enabled.
    var id: String { get }
    var name: String { get }
    /// One-line description shown in the Extensions settings pane. Keep it
    /// to ≤30 words — this is a summary, not the README (see
    /// `longDescriptionURL` for the full thing).
    ///
    /// Attributed so a summary can name the upstream project it wraps and link
    /// straight to it; `SwiftUI.Text` renders link runs and opens them. Build
    /// one with `AttributedString(inlineMarkdown:)`.
    var summary: AttributedString { get }
    /// This extension's own packaging version (e.g. "1.0.0") — distinct from
    /// any upstream library version it wraps, which belongs in `summary`.
    var version: String { get }
    /// Whether the extension's payload is downloaded, verified, and loaded.
    /// Settings shows a "Download" button while false, "Enable"/"Disable"
    /// once true.
    var isInstalled: Bool { get }
    /// Downloads, verifies, and loads the extension's payload. Never throws
    /// to the caller — a failure just leaves `isInstalled` false so the
    /// Download button stays put (retryable), per the degrade-to-default
    /// failure mode described in the RaTeX handoff spec.
    func download() async
    /// Removes the downloaded payload, reverting to not-installed. Safe to
    /// call even if never installed.
    func uninstall() async
    /// The math renderer this extension provides, if any. `nil` for an
    /// extension that doesn't touch math rendering.
    var mathRenderer: MathRenderer? { get }

    // MARK: Metadata (Settings display only — none of this affects behavior)

    /// Author credit, if known.
    var developer: ExtensionDeveloper? { get }
    /// Source repository link (GitHub, GitLab, SourceForge, wherever).
    var repositoryURL: URL? { get }
    /// Human-readable installed footprint, e.g. "3.2 MB". `nil` if unknown.
    var installedSizeDescription: String? { get }
    /// When this extension's payload was last published, for a relative
    /// "X days/months/years ago" display. `nil` hides the row.
    var lastUpdated: Date? { get }
    /// Download count, if there's a real source for it. `nil` hides the row
    /// — no extension here has a live analytics backend yet, so this should
    /// stay `nil` rather than showing a fabricated number.
    var downloadCount: Int? { get }
    /// Link to a longer description (README or similar), rendered in a
    /// popup webview via "Learn more…". `nil` hides that link.
    var longDescriptionURL: URL? { get }
    /// Optional donation link.
    var donateURL: URL? { get }
    /// Whether a newer version than `version` is known to be available.
    /// `false` when there's no update-checking source — the "Update" button
    /// stays hidden rather than lying about freshness.
    var hasUpdate: Bool { get }
}

/// Catalog of the app's built-in extensions. SwiftMath itself is not an
/// extension — it's the always-on default — so today's only entry is the
/// RaTeX-powered "Advanced Math" option layered over it.
///
/// This is a static array, not a fetched registry — there's no backend here.
/// A real registry, if one gets built later, should follow the shape
/// `github.com/obsidianmd/obsidian-releases` uses (a community index file
/// mapping extension IDs to repos, each repo carrying its own manifest) —
/// noted for later, not built now.
@MainActor
public enum ExtensionRegistry {
    public static let all: [EdmundExtension] = [AdvancedMathExtension.shared]
}

/// "Advanced Math" — an opt-in, KaTeX-compatible math engine (RaTeX), run as
/// sandboxed WebAssembly in JavaScriptCore rather than shipped in the binary.
/// See `RaTeXRelease`/`RaTeXInstaller`/`WasmMathHost` for the download,
/// verify, and load machinery this wraps.
@MainActor
public final class AdvancedMathExtension: EdmundExtension {
    public static let shared = AdvancedMathExtension()

    public let id = "advanced-math"
    public let name = "Advanced Math"
    /// This is Edmund's packaging version, not RaTeX's — RaTeX's own version
    /// is called out in `summary` instead (mirrors how Obsidian plugins
    /// version themselves separately from any library they wrap).
    public let summary = AttributedString(
        inlineMarkdown:
            ">99.5% KaTeX syntax coverage via [RaTeX](https://ratex.lites.dev) (Rust).")
    public let version = "1.0.0"
    public var isInstalled: Bool { renderer.isReady }
    public var mathRenderer: MathRenderer? { renderer }

    // I7T5 (i7t5.com) is this extension's author. RaTeX itself (the engine it
    // wraps) is erweixin's separate project — that credit belongs in this
    // extension's own README once it has one, not asserted here as authorship
    // of this repo. No dedicated extension repo exists yet; stub until it does.
    public let developer: ExtensionDeveloper? =
        ExtensionDeveloper(name: "I7T5", profileURL: URL(string: "https://i7t5.com"))
    public let repositoryURL: URL? = nil
    // Measured from the built payload: 2.6 MB wasm + 540 KB fonts + 8 KB glue.
    public let installedSizeDescription: String? = "3.2 MB"
    // ratex-wasm@0.1.12's actual npm publish date (verified against the
    // registry, not a guess) — not Edmund's own commit date.
    public let lastUpdated: Date? = {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 25
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

    public let renderer: RaTeXRenderer

    init(renderer: RaTeXRenderer = RaTeXRenderer()) {
        self.renderer = renderer
    }

    /// The installer's current state, for Settings to surface a specific
    /// reason on failure (e.g. RaTeX not configured in this build yet).
    public var installState: MathExtensionState {
        get async { await renderer.installState }
    }

    /// Downloads/verifies/installs (if needed) and loads RaTeX. Safe to call
    /// repeatedly; a no-op once already ready. Callers still need to set
    /// `MathRendering.shared.alternate` and call `engineDidChange()` to
    /// actually switch the active engine (Settings does this on enable).
    public func download() async {
        await renderer.install()
    }

    public func uninstall() async {
        await renderer.uninstall()
    }
}
