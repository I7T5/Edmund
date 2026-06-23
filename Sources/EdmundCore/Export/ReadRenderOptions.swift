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

    public init(preserveBlankLines: Bool = true) {
        self.preserveBlankLines = preserveBlankLines
    }

    public static let `default` = ReadRenderOptions()
}
