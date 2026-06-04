import Foundation

/// A file's line-ending style. The editor always keeps its buffer in LF
/// internally (so `BlockParser`'s `\n` split is clean and no stray `\r`
/// characters leak into block content); the original style is remembered so
/// it can be written back on save without silently changing the user's file.
public enum LineEnding: String, Sendable {
    case lf    // "\n"
    case crlf  // "\r\n"
    case cr    // "\r"

    /// The literal character sequence for this line ending.
    public var string: String {
        switch self {
        case .lf:   return "\n"
        case .crlf: return "\r\n"
        case .cr:   return "\r"
        }
    }

    /// Short label for display in the status bar.
    public var displayName: String {
        switch self {
        case .lf:   return "LF"
        case .crlf: return "CRLF"
        case .cr:   return "CR"
        }
    }

    /// Detects the line ending used in `text`. CRLF is checked before CR/LF
    /// because it contains both. Defaults to `.lf` when there are no breaks.
    public static func detect(in text: String) -> LineEnding {
        if text.contains("\r\n") { return .crlf }
        if text.contains("\r")   { return .cr }
        return .lf
    }

    /// Converts every line ending in `text` to LF (`\n`).
    public static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
