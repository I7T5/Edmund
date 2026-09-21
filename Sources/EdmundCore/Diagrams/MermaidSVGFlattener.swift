import Foundation

/// Rewrites a beautiful-mermaid SVG into the dialect CoreSVG (`NSImage(data:)`)
/// can draw, for Edit mode. Read mode hands WebKit the original — it resolves
/// all of this natively — so this runs on the Edit-mode path only.
///
/// CoreSVG ignores exactly three things the library leans on, and leaves
/// black boxes with no labels, no edges and no arrowheads when it meets them
/// (measured, not assumed — see the spike notes in the edit-mode plan):
///
/// 1. CSS custom properties — every colour is `fill="var(--_line)"`.
/// 2. `color-mix()` — every derived shade is `color-mix(in srgb, var(--fg) 50%, var(--bg))`.
/// 3. `<marker>` — every arrowhead is `marker-end="url(#arrowhead)"`.
///
/// Everything else CoreSVG needs it already handles: `<style>` class rules,
/// `<text>`/`text-anchor`/`dy`/`font-weight`, `opacity`, `rx`, `stroke-dasharray`,
/// `transform`. So this is deliberately no more than those three rewrites, and
/// it takes its inputs from the SVG itself — the `--bg`/`--fg` on the `<svg>`
/// tag and the `--_x: …` declarations in its `<style>` — rather than a table
/// of the library's mix percentages, so a library bump can't silently change
/// a shade here without changing it in Read mode too. The pinned SHA-256 in
/// `MermaidRelease` is what bounds the markup this has to understand.
enum MermaidSVGFlattener {

    static func flatten(_ svg: String) -> String {
        let declarations = collectDeclarations(svg)
        let resolved = substituteColorFunctions(in: svg, declarations: declarations)
        return inlineMarkers(in: resolved)
    }

    // MARK: - Custom properties and color-mix()

    /// `--name` → its (unresolved) value. The `<svg style="…">` attribute wins
    /// over the `<style>` block — that is where the render options land — and
    /// within the block the first definition wins, matching the cascade order
    /// WebKit applies to the same document.
    private static func collectDeclarations(_ svg: String) -> [String: String] {
        var decls: [String: String] = [:]
        if let attr = firstGroup(#"<svg[^>]*\sstyle="([^"]*)""#, in: svg) {
            for decl in attr.split(separator: ";") {
                guard let colon = decl.firstIndex(of: ":") else { continue }
                let name = decl[..<colon].trimmingCharacters(in: .whitespaces)
                guard name.hasPrefix("--") else { continue }
                decls[name] = decl[decl.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        for block in allGroups(#"<style>(.*?)</style>"#, in: svg) {
            for (name, value) in allPairs(#"(--[\w-]+)\s*:\s*([^;]+);"#, in: block)
            where decls[name] == nil {
                decls[name] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return decls
    }

    /// Resolves one `var(…)`/`color-mix(…)` expression to a literal. Anything
    /// it can't resolve is returned verbatim, so a construct this doesn't know
    /// degrades to whatever CoreSVG does with it rather than to a crash.
    private static func resolve(_ raw: String, declarations: [String: String], depth: Int = 0) -> String {
        let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard depth < 16 else { return expr }

        if expr.hasPrefix("var("), expr.hasSuffix(")") {
            let inner = String(expr.dropFirst(4).dropLast())
            let parts = splitTopLevel(inner, on: ",", limit: 2)
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            if let value = declarations[name] {
                return resolve(value, declarations: declarations, depth: depth + 1)
            }
            if parts.count == 2 {
                return resolve(parts[1], declarations: declarations, depth: depth + 1)
            }
            return expr
        }

        if expr.hasPrefix("color-mix("), expr.hasSuffix(")") {
            let inner = String(expr.dropFirst("color-mix(".count).dropLast())
            let parts = splitTopLevel(inner, on: ",")
            // First argument is the colour space ("in srgb"); we only ever mix in sRGB.
            guard parts.count == 3 else { return expr }
            var colors: [(r: Double, g: Double, b: Double)] = []
            var pcts: [Double?] = []
            for part in parts.dropFirst() {
                var value = part.trimmingCharacters(in: .whitespaces)
                var pct: Double? = nil
                if let m = firstGroup(#"(\d+(?:\.\d+)?)%\s*$"#, in: value), let p = Double(m) {
                    pct = p / 100
                    value = String(value.dropLast(m.count + 1)).trimmingCharacters(in: .whitespaces)
                }
                guard let rgb = hexRGB(resolve(value, declarations: declarations, depth: depth + 1))
                else { return expr }
                colors.append(rgb)
                pcts.append(pct)
            }
            // CSS Color 5 §2.1: one missing percentage is the complement of the
            // other; both missing means 50/50; the pair is then normalised.
            var p1 = pcts[0], p2 = pcts[1]
            if p1 == nil && p2 == nil { p1 = 0.5; p2 = 0.5 }
            else if p1 == nil { p1 = 1 - p2! }
            else if p2 == nil { p2 = 1 - p1! }
            let total = p1! + p2!
            guard total > 0 else { return expr }
            let a = p1! / total, b = p2! / total
            func ch(_ x: Double, _ y: Double) -> Int { Int((x * a + y * b).rounded()) }
            return String(format: "#%02X%02X%02X",
                          ch(colors[0].r, colors[1].r), ch(colors[0].g, colors[1].g), ch(colors[0].b, colors[1].b))
        }

        return expr
    }

    /// Replaces every `var(` / `color-mix(` call in the document — attributes
    /// and `<style>` rules alike — with its resolved literal. A hand-rolled
    /// paren-balanced scan, because the calls nest (`var(--x, color-mix(…))`)
    /// and a regex can't match balanced parentheses.
    private static func substituteColorFunctions(in svg: String, declarations: [String: String]) -> String {
        let chars = Array(svg)
        var out = ""
        out.reserveCapacity(svg.count)
        var i = 0
        while i < chars.count {
            if let head = callHead(at: i, in: chars) {
                var j = i + head, depth = 1
                while j < chars.count, depth > 0 {
                    if chars[j] == "(" { depth += 1 } else if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                out += resolve(String(chars[i..<j]), declarations: declarations)
                i = j
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    /// Length of a `var(` or `color-mix(` head starting at `i`, if one does.
    private static func callHead(at i: Int, in chars: [Character]) -> Int? {
        for head in ["var(", "color-mix("] {
            let n = head.count
            if i + n <= chars.count, String(chars[i..<i + n]) == head { return n }
        }
        return nil
    }

    // MARK: - Markers

    private struct Marker {
        let refX: Double, refY: Double
        let reverseAtStart: Bool
        let body: String
    }

    /// Replaces `marker-start`/`marker-end` on every `<polyline>`/`<line>` with
    /// the marker's own shapes, transformed to the line's end point and tangent
    /// — what a marker *is*, spelled out. `scale(strokeWidth)` because SVG's
    /// default `markerUnits="strokeWidth"` sizes the arrowhead with the edge
    /// (the thick `==>` edge visibly has a bigger one in WebKit).
    private static func inlineMarkers(in svg: String) -> String {
        var markers: [String: Marker] = [:]
        for groups in allMatches(#"<marker ([^>]*)>(.*?)</marker>"#, in: svg) {
            let attrs = attributes(groups[1])
            guard let id = attrs["id"] else { continue }
            markers[id] = Marker(refX: Double(attrs["refX"] ?? "") ?? 0,
                                 refY: Double(attrs["refY"] ?? "") ?? 0,
                                 reverseAtStart: attrs["orient"] == "auto-start-reverse",
                                 body: groups[2].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !markers.isEmpty else { return svg }

        var out = replaceMatches(#"<(?:polyline|line) [^>]*marker-(?:start|end)[^>]*/>"#, in: svg) { tag in
            let attrs = attributes(tag)
            guard let points = linePoints(attrs), points.count >= 2 else { return tag }
            var appended = ""
            for (which, isStart) in [("marker-start", true), ("marker-end", false)] {
                guard let ref = attrs[which],
                      let id = firstGroup(#"url\(#([^)]+)\)"#, in: ref),
                      let marker = markers[id] else { continue }
                let at = isStart ? points[0] : points[points.count - 1]
                let neighbour = isStart ? points[1] : points[points.count - 2]
                // `orient="auto"` faces the direction of travel: at→neighbour
                // at the start, neighbour→at at the end.
                var angle = isStart
                    ? atan2(neighbour.y - at.y, neighbour.x - at.x)
                    : atan2(at.y - neighbour.y, at.x - neighbour.x)
                angle *= 180 / .pi
                if isStart, marker.reverseAtStart { angle += 180 }
                let strokeWidth = Double(attrs["stroke-width"] ?? "") ?? 1
                appended += String(
                    format: "<g transform=\"translate(%.3f,%.3f) rotate(%.3f) scale(%g) translate(%g,%g)\">%@</g>",
                    at.x, at.y, angle, strokeWidth, -marker.refX, -marker.refY, marker.body)
            }
            let stripped = tag.replacingOccurrences(of: #"\smarker-(?:start|end)="[^"]*""#,
                                                    with: "", options: .regularExpression)
            return stripped + appended
        }
        // The <defs> block existed only to hold the markers; CoreSVG would
        // ignore it, but there is no reason to hand it something we know it
        // can't use.
        out = replaceMatches(#"<defs>\s*(?:<marker .*?</marker>\s*)+</defs>"#, in: out) { _ in "" }
        return out
    }

    /// The vertices of a `<polyline points="…">` or `<line x1 y1 x2 y2>`.
    private static func linePoints(_ attrs: [String: String]) -> [(x: Double, y: Double)]? {
        if let points = attrs["points"] {
            let nums = points.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" })
                .compactMap { Double($0) }
            guard nums.count >= 4, nums.count % 2 == 0 else { return nil }
            return stride(from: 0, to: nums.count, by: 2).map { (nums[$0], nums[$0 + 1]) }
        }
        guard let x1 = Double(attrs["x1"] ?? ""), let y1 = Double(attrs["y1"] ?? ""),
              let x2 = Double(attrs["x2"] ?? ""), let y2 = Double(attrs["y2"] ?? "") else { return nil }
        return [(x1, y1), (x2, y2)]
    }

    // MARK: - Small helpers

    private static func hexRGB(_ s: String) -> (r: Double, g: Double, b: Double)? {
        let hex = s.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return nil }
        var digits = String(hex.dropFirst())
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let v = UInt32(digits, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
    }

    /// Splits on `separator` outside parentheses; `limit` caps the piece count
    /// (the remainder stays joined), for `var(--x, <fallback that has commas>)`.
    private static func splitTopLevel(_ s: String, on separator: Character, limit: Int = .max) -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for ch in s {
            if ch == "(" { depth += 1 } else if ch == ")" { depth -= 1 }
            if ch == separator, depth == 0, parts.count < limit - 1 {
                parts.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private static func attributes(_ tag: String) -> [String: String] {
        var attrs: [String: String] = [:]
        for (name, value) in allPairs(#"([\w:-]+)="([^"]*)""#, in: tag) { attrs[name] = value }
        return attrs
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns here are literals; a typo is a programmer error, not a runtime case.
        try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    }

    private static func firstGroup(_ pattern: String, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex(pattern).firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func allGroups(_ pattern: String, in s: String) -> [String] {
        allMatches(pattern, in: s).map { $0[1] }
    }

    private static func allPairs(_ pattern: String, in s: String) -> [(String, String)] {
        allMatches(pattern, in: s).map { ($0[1], $0[2]) }
    }

    /// Every match as `[whole, group1, group2, …]` ("" for an unmatched group).
    private static func allMatches(_ pattern: String, in s: String) -> [[String]] {
        let ns = s as NSString
        return regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
        }
    }

    private static func replaceMatches(_ pattern: String, in s: String,
                                       _ transform: (String) -> String) -> String {
        let ns = s as NSString
        let result = NSMutableString(string: s)
        for m in regex(pattern).matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            result.replaceCharacters(in: m.range, with: transform(ns.substring(with: m.range)))
        }
        return result as String
    }
}
