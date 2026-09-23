import Foundation

/// Shared recognition for Mermaid fenced-code info strings. Mermaid permits
/// whitespace after the language name, so only the first info-string word
/// selects the renderer; the complete code body is passed through unchanged.
enum MermaidSyntax {
    static func matches(language: String?) -> Bool {
        language?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() == "mermaid"
    }
}
