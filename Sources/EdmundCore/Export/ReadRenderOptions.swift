import Foundation

/// User-configurable options for the Read-mode / export HTML rendering. Kept in
/// EdmundCore (no AppKit/UserDefaults dependency) so the renderer stays pure;
/// the app layer reads the values from `AppSettings` and passes them in.
public struct ReadRenderOptions: Sendable, Equatable {

    /// When true, runs of blank lines in the source add proportional vertical
    /// space in the output (one extra blank line → one extra line of space),
    /// preserving the author's intentional spacing instead of collapsing it the
    /// way Markdown normally does.
    public var preserveBlankLines: Bool

    /// When true, remote (`http`/`https`) image URLs are loaded in the rendered
    /// document. Off by default so Read mode makes no surprise network requests;
    /// local images are always inlined regardless of this flag.
    public var allowRemoteImages: Bool

    /// The centered reading column's max width in points, matching the editor's
    /// `EditorTextView.maxContentWidthPoints` (§EditorTextView+ContentWidth). CSS
    /// px and AppKit points are both device-independent, so the same number caps
    /// the column to the same physical width in Read mode as in Edit mode.
    /// `.greatestFiniteMagnitude` → uncapped (fills the page).
    public var maxContentWidthPoints: Double

    public init(preserveBlankLines: Bool = true, allowRemoteImages: Bool = false,
                maxContentWidthPoints: Double = .greatestFiniteMagnitude) {
        self.preserveBlankLines = preserveBlankLines
        self.allowRemoteImages = allowRemoteImages
        self.maxContentWidthPoints = maxContentWidthPoints
    }

    public static let `default` = ReadRenderOptions()
}
