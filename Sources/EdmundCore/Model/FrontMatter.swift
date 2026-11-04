import Foundation

/// The top-level `key: value` pairs of a YAML front-matter block, for the
/// inspector's Info pane.
///
/// ponytail: not a YAML parser. Reads flat `key: value` lines at column 0,
/// strips one pair of matching quotes, and joins a block list (`- item` lines
/// under an empty value) with ", ". Nested maps, multi-line scalars (`|`, `>`)
/// and flow collections show their first line as written. Swap in a real YAML
/// parser if front matter ever drives behaviour rather than display.
public enum FrontMatter {
    public static func pairs(in block: String) -> [(key: String, value: String)] {
        var pairs: [(key: String, value: String)] = []
        var items: [String] = []
        func flushItems() {
            guard !items.isEmpty, let last = pairs.indices.last else { return }
            pairs[last].value = items.joined(separator: ", ")
            items = []
        }
        for line in block.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.first?.isWhitespace == true || line.hasPrefix("-") {
                // A list item under the previous key; any other indented line
                // (a nested map) is left out.
                if trimmed.hasPrefix("- "), pairs.last?.value.isEmpty == true || !items.isEmpty {
                    items.append(unquoted(String(trimmed.dropFirst(2))))
                }
                continue
            }
            flushItems()
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            pairs.append((key, unquoted(value)))
        }
        flushItems()
        return pairs
    }

    private static func unquoted(_ s: String) -> String {
        guard s.count >= 2, let first = s.first, first == "\"" || first == "'", s.last == first else { return s }
        return String(s.dropFirst().dropLast())
    }
}
