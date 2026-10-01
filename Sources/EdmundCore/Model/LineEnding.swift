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
        let found = styles(in: text)
        return found.crlf ? .crlf : found.cr ? .cr : .lf
    }

    /// Whether `text` mixes more than one line-ending style (e.g. some CRLF and
    /// some LF) — the case the "inconsistent line endings" warning flags.
    public static func isInconsistent(in text: String) -> Bool {
        let found = styles(in: text)
        return [found.crlf, found.cr, found.lf].filter { $0 }.count > 1
    }

    /// Converts every line ending in `text` to LF (`\n`).
    public static func normalize(_ text: String) -> String {
        guard text.utf8.contains(0x0D) else { return text }   // already LF
        return text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Which styles occur, in one pass over the UTF-8 bytes: a CR followed by
    /// LF is CRLF, any other CR is CR, an LF without a CR before it is LF.
    /// Byte-wise because `"\r\n"` is a single Character, which sent the old
    /// `String.contains` checks through Unicode-aware search — four passes,
    /// ~0.1 s, over a 1 MB document on every open.
    private static func styles(in text: String) -> (crlf: Bool, cr: Bool, lf: Bool) {
        var crlf = false, cr = false, lf = false
        var afterCR = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if afterCR { crlf = true } else { lf = true }
            } else if afterCR {
                cr = true
            }
            afterCR = byte == 0x0D
        }
        if afterCR { cr = true }
        return (crlf, cr, lf)
    }
}
