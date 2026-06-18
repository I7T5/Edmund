import Foundation

// MARK: - Code Highlighter
//
// A small, language-agnostic tokenizer for fenced code blocks. It is not a full
// parser — it recognizes the lexical tokens that carry most of the visual
// signal (comments, strings, numbers, keywords, types, function calls) across
// the common C-family / script languages. The block's info string picks the
// comment style (`#` vs `//`), everything else is shared.

enum CodeHighlighter {

    enum TokenType: Equatable {
        case keyword, type, string, number, comment, function
    }

    struct Token: Equatable {
        let range: NSRange
        let type: TokenType
    }

    /// Languages whose line comments start with `#` rather than `//`.
    private static let hashCommentLanguages: Set<String> = [
        "python", "py", "ruby", "rb", "sh", "bash", "shell", "zsh", "fish",
        "yaml", "yml", "toml", "ini", "perl", "pl", "r", "makefile", "make",
        "dockerfile", "docker", "elixir", "ex", "nim", "julia", "jl", "tcl",
    ]

    /// A union of frequent keywords across popular languages. Over-inclusive is
    /// fine: a keyword that doesn't apply to the current language simply won't
    /// appear in its code.
    private static let keywords: Set<String> = [
        // declarations / control flow (shared across many languages)
        "func", "function", "fn", "def", "let", "var", "val", "const", "static",
        "final", "class", "struct", "enum", "interface", "protocol", "trait",
        "impl", "extends", "implements", "namespace", "package", "module", "mod",
        "import", "export", "from", "use", "using", "include", "require",
        "public", "private", "protected", "internal", "fileprivate", "open",
        "if", "else", "elif", "for", "while", "do", "switch", "case", "default",
        "break", "continue", "return", "yield", "goto", "match", "when", "where",
        "try", "catch", "except", "finally", "throw", "throws", "raise", "rescue",
        "guard", "defer", "async", "await", "go", "chan", "select", "with", "as",
        "is", "in", "of", "new", "delete", "typeof", "instanceof", "sizeof",
        "void", "int", "long", "short", "char", "float", "double", "bool",
        "boolean", "string", "unsigned", "signed", "auto", "typedef", "template",
        "virtual", "override", "abstract", "extension", "init", "self", "this",
        "super", "nil", "null", "none", "undefined", "true", "false", "and",
        "or", "not", "lambda", "pass", "global", "nonlocal", "mut", "pub", "dyn",
        "type", "object", "end", "begin", "then", "elsif", "unless", "until",
    ]

    static func tokenize(_ code: String, language: String?) -> [Token] {
        let ns = code as NSString
        let n = ns.length
        guard n > 0 else { return [] }

        let lang = language?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let hashComments = hashCommentLanguages.contains(lang)

        func isIdentStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95
        }
        func isIdentChar(_ c: unichar) -> Bool { isIdentStart(c) || (c >= 48 && c <= 57) }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }

        var tokens: [Token] = []
        var i = 0
        while i < n {
            let c = ns.character(at: i)

            // Line comment: `//` always, `#` for hash-comment languages.
            if (c == 0x2F && i + 1 < n && ns.character(at: i + 1) == 0x2F)
                || (c == 0x23 && hashComments) {
                let start = i
                while i < n && ns.character(at: i) != 0x0A { i += 1 }
                tokens.append(Token(range: NSRange(location: start, length: i - start), type: .comment))
                continue
            }
            // Block comment `/* … */`.
            if c == 0x2F && i + 1 < n && ns.character(at: i + 1) == 0x2A {
                let start = i; i += 2
                while i + 1 < n && !(ns.character(at: i) == 0x2A && ns.character(at: i + 1) == 0x2F) { i += 1 }
                i = min(n, i + 2)
                tokens.append(Token(range: NSRange(location: start, length: i - start), type: .comment))
                continue
            }
            // String: "…", '…', `…` with backslash escapes; stops at end of line.
            if c == 0x22 || c == 0x27 || c == 0x60 {
                let quote = c, start = i; i += 1
                while i < n {
                    let d = ns.character(at: i)
                    if d == 0x5C { i += 2; continue }      // escape
                    if d == quote { i += 1; break }
                    if d == 0x0A { break }
                    i += 1
                }
                tokens.append(Token(range: NSRange(location: start, length: min(i, n) - start), type: .string))
                continue
            }
            // Number (incl. trailing hex/exponent/dot chars).
            if isDigit(c) {
                let start = i; i += 1
                while i < n {
                    let d = ns.character(at: i)
                    if isIdentChar(d) || d == 0x2E { i += 1 } else { break }
                }
                tokens.append(Token(range: NSRange(location: start, length: i - start), type: .number))
                continue
            }
            // Identifier → keyword / type / function call / plain.
            if isIdentStart(c) {
                let start = i; i += 1
                while i < n && isIdentChar(ns.character(at: i)) { i += 1 }
                let word = ns.substring(with: NSRange(location: start, length: i - start))
                let range = NSRange(location: start, length: i - start)
                if keywords.contains(word) {
                    tokens.append(Token(range: range, type: .keyword))
                } else if let first = word.unicodeScalars.first, first.properties.isUppercase {
                    tokens.append(Token(range: range, type: .type))
                } else {
                    // Function call: identifier immediately followed by `(`.
                    var j = i
                    while j < n && ns.character(at: j) == 0x20 { j += 1 }
                    if j < n && ns.character(at: j) == 0x28 {
                        tokens.append(Token(range: range, type: .function))
                    }
                }
                continue
            }
            i += 1
        }
        return tokens
    }
}
