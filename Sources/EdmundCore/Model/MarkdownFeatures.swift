import Foundation

/// Which Markdown extensions the editor recognizes. A single flag set threaded
/// into both render back-ends (the live editor's `SyntaxHighlighter.parse` /
/// styling, and Read mode's `ReadRenderOptions` / `HTMLRenderer`) so a feature
/// can be turned off in Settings and stop being parsed/styled everywhere at
/// once. A cleared flag makes the syntax render as plain text.
///
/// Lives in EdmundCore (no UserDefaults/AppKit dependency); the app layer maps
/// `AppSettings` toggles onto this set. `.all` is the default everywhere, so
/// behavior is unchanged until a user clears a toggle.
public struct MarkdownFeatures: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    // Extensions that already shipped (always-on before this became toggleable).
    public static let highlight          = MarkdownFeatures(rawValue: 1 << 0)  // ==text==
    public static let inlineComment      = MarkdownFeatures(rawValue: 1 << 1)  // %%comment%%
    /// Callouts render at all. The base 5 GitHub alert types (NOTE/TIP/
    /// IMPORTANT/WARNING/CAUTION) are GFM, so this flag is governed only by the
    /// Callouts toggle — the non-GFM master switch doesn't clear it.
    public static let callout            = MarkdownFeatures(rawValue: 1 << 2)  // > [!note]
    public static let wikilink           = MarkdownFeatures(rawValue: 1 << 3)  // [[target]]
    public static let footnote           = MarkdownFeatures(rawValue: 1 << 4)  // [^id]
    public static let math               = MarkdownFeatures(rawValue: 1 << 5)  // $…$ / $$…$$

    // New Obsidian-flavored syntax.
    public static let frontMatter        = MarkdownFeatures(rawValue: 1 << 6)  // --- YAML --- (Phase 2)
    public static let tag                = MarkdownFeatures(rawValue: 1 << 7)  // #tag (Phase 2)
    public static let blockRef           = MarkdownFeatures(rawValue: 1 << 8)  // ^blockid (Phase 2)
    public static let imageDimensions    = MarkdownFeatures(rawValue: 1 << 9)  // ![alt|200](url)
    public static let wikilinkEmbed      = MarkdownFeatures(rawValue: 1 << 10) // ![[file]]
    public static let collapsibleCallout = MarkdownFeatures(rawValue: 1 << 11) // [!note]- / [!note]+
    public static let multiBlockComment  = MarkdownFeatures(rawValue: 1 << 12) // %%…%% spanning blocks (Phase 2)
    /// Obsidian-only callout types (info, bug, quote, …) beyond the 5 GFM
    /// alerts. Non-GFM: cleared by the master switch, so with it off only the
    /// GFM alert types render as callouts and the rest fall back to plain quotes.
    public static let calloutExtendedTypes = MarkdownFeatures(rawValue: 1 << 13)
    /// Native rendering for fenced code blocks whose info string starts with
    /// `mermaid`. The source remains the literal fenced block in text storage.
    public static let mermaid            = MarkdownFeatures(rawValue: 1 << 14)

    /// Every feature enabled — the default.
    public static let all: MarkdownFeatures = [
        .highlight, .inlineComment, .callout, .wikilink, .footnote, .math,
        .frontMatter, .tag, .blockRef, .imageDimensions, .wikilinkEmbed,
        .collapsibleCallout, .multiBlockComment, .calloutExtendedTypes, .mermaid,
    ]
}
