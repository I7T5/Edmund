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

    public init(preserveBlankLines: Bool = true, allowRemoteImages: Bool = false) {
        self.preserveBlankLines = preserveBlankLines
        self.allowRemoteImages = allowRemoteImages
    }

    public static let `default` = ReadRenderOptions()
}
