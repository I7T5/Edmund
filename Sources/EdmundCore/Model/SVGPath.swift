import CoreGraphics
import Foundation

// MARK: - SVGPath
//
// Minimal SVG → CGPath converter for the vendored Lucide icon geometry
// (`LucideIcons.geometry`). Exists so the editor can draw a callout icon as a
// *stroked vector path* instead of an NSImage: drawing an image on a wrapping,
// multi-line TextKit 2 layout fragment wedges that fragment's layout to a
// single line, while shape drawing does not (see
// docs/investigations/archives/callout-title-wrap-investigation.md). Supports exactly what the
// vendored geometry uses: `<path>`, `<circle>`, and `<rect>` elements, and the
// full SVG path-data command set. Coordinates stay in the icons' 24×24,
// y-down viewBox space; callers scale to the target size.
enum SVGPath {

    /// Parses a fragment of SVG markup (one or more `<path>`/`<circle>`/
    /// `<rect>` elements) into a single CGPath in viewBox coordinates.
    /// Returns `nil` if nothing parseable is found.
    static func path(fromGeometry svg: String) -> CGPath? {
        let result = CGMutablePath()
        let elementRegex = try! NSRegularExpression(pattern: #"<(path|circle|rect)\b([^>]*?)/?>"#)
        let attrRegex = try! NSRegularExpression(pattern: #"([\w-]+)="([^"]*)""#)
        let ns = svg as NSString

        for m in elementRegex.matches(in: svg, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range(at: 1))
            let attrString = ns.substring(with: m.range(at: 2))
            var attrs: [String: String] = [:]
            let ans = attrString as NSString
            for am in attrRegex.matches(in: attrString,
                                        range: NSRange(location: 0, length: ans.length)) {
                attrs[ans.substring(with: am.range(at: 1))] = ans.substring(with: am.range(at: 2))
            }
            func num(_ key: String) -> CGFloat? { attrs[key].flatMap { Double($0) }.map { CGFloat($0) } }

            switch tag {
            case "path":
                if let d = attrs["d"], let p = path(fromData: d) { result.addPath(p) }
            case "circle":
                if let cx = num("cx"), let cy = num("cy"), let r = num("r") {
                    result.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
                }
            case "rect":
                if let w = num("width"), let h = num("height") {
                    let rect = CGRect(x: num("x") ?? 0, y: num("y") ?? 0, width: w, height: h)
                    let rx = num("rx") ?? num("ry") ?? 0
                    let ry = num("ry") ?? rx
                    if rx > 0 || ry > 0 {
                        result.addRoundedRect(in: rect, cornerWidth: rx, cornerHeight: ry)
                    } else {
                        result.addRect(rect)
                    }
                }
            default:
                break
            }
        }
        return result.isEmpty ? nil : result
    }

    /// Parses an SVG path-data string (the `d` attribute) into a CGPath.
    static func path(fromData d: String) -> CGPath? {
        var scanner = NumberScanner(d)
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        // Reflection anchors for S/T smooth curves.
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var lastCommand: Character = " "

        while let command = scanner.nextCommand() {
            let relative = command.isLowercase
            let cmd = Character(command.uppercased())
            // Each iteration of the repeat loop consumes one parameter set;
            // SVG allows implicit command repetition until a new letter.
            repeat {
                func point() -> CGPoint? {
                    guard let x = scanner.nextNumber(), let y = scanner.nextNumber() else { return nil }
                    return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                }
                switch cmd {
                case "M":
                    guard let p = point() else { return nil }
                    path.move(to: p); current = p; subpathStart = p
                    // Subsequent implicit pairs are LineTos.
                    while scanner.peekNumber() {
                        guard let q = point() else { return nil }
                        path.addLine(to: q); current = q
                    }
                case "L":
                    guard let p = point() else { return nil }
                    path.addLine(to: p); current = p
                case "H":
                    guard let x = scanner.nextNumber() else { return nil }
                    current.x = relative ? current.x + x : x
                    path.addLine(to: current)
                case "V":
                    guard let y = scanner.nextNumber() else { return nil }
                    current.y = relative ? current.y + y : y
                    path.addLine(to: current)
                case "C":
                    guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                    path.addCurve(to: p, control1: c1, control2: c2)
                    current = p; lastCubicControl = c2
                case "S":
                    // First control point reflects the previous cubic's second
                    // control about the current point (or is the current point).
                    let c1: CGPoint
                    if "CS".contains(lastCommand), let prev = lastCubicControl {
                        c1 = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                    } else {
                        c1 = current
                    }
                    guard let c2 = point(), let p = point() else { return nil }
                    path.addCurve(to: p, control1: c1, control2: c2)
                    current = p; lastCubicControl = c2
                case "Q":
                    guard let c = point(), let p = point() else { return nil }
                    path.addQuadCurve(to: p, control: c)
                    current = p; lastQuadControl = c
                case "T":
                    let c: CGPoint
                    if "QT".contains(lastCommand), let prev = lastQuadControl {
                        c = CGPoint(x: 2 * current.x - prev.x, y: 2 * current.y - prev.y)
                    } else {
                        c = current
                    }
                    guard let p = point() else { return nil }
                    path.addQuadCurve(to: p, control: c)
                    current = p; lastQuadControl = c
                case "A":
                    guard let rx = scanner.nextNumber(), let ry = scanner.nextNumber(),
                          let rot = scanner.nextNumber(),
                          let largeArc = scanner.nextNumber(), let sweep = scanner.nextNumber(),
                          let end = point() else { return nil }
                    addArc(to: path, from: current, rx: rx, ry: ry,
                           xAxisRotationDegrees: rot,
                           largeArc: largeArc != 0, sweep: sweep != 0, end: end)
                    current = end
                case "Z":
                    path.closeSubpath()
                    current = subpathStart
                default:
                    return nil
                }
                if !"CS".contains(cmd) { lastCubicControl = nil }
                if !"QT".contains(cmd) { lastQuadControl = nil }
                lastCommand = cmd
            } while cmd != "Z" && scanner.peekNumber()
        }
        return path.isEmpty ? nil : path
    }

    /// SVG elliptical arc → cubic Béziers, via the endpoint-to-center
    /// conversion in SVG spec appendix B.2.4, splitting into ≤90° segments.
    private static func addArc(to path: CGMutablePath, from start: CGPoint,
                               rx: CGFloat, ry: CGFloat, xAxisRotationDegrees: CGFloat,
                               largeArc: Bool, sweep: Bool, end: CGPoint) {
        if start == end { return }
        var rx = abs(rx), ry = abs(ry)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }

        let phi = xAxisRotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)

        // (x1', y1'): midpoint vector rotated into the ellipse frame.
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        // Scale radii up if the endpoints can't be spanned (spec F.6.6).
        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let s = sqrt(lambda)
            rx *= s; ry *= s
        }

        // Center in the ellipse frame (spec F.6.5.2).
        let rx2 = rx * rx, ry2 = ry * ry, x1p2 = x1p * x1p, y1p2 = y1p * y1p
        var radicand = (rx2 * ry2 - rx2 * y1p2 - ry2 * x1p2) / (rx2 * y1p2 + ry2 * x1p2)
        radicand = max(0, radicand)
        let coef = (largeArc != sweep ? 1 : -1) * sqrt(radicand)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * -(ry * x1p / rx)

        // Center in user space.
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(1, max(-1, dot / len)))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }
        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle((x1p - cxp) / rx, (y1p - cyp) / ry,
                          (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        // Approximate each ≤90° slice with one cubic.
        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let segmentDelta = delta / CGFloat(segments)
        // Control-point distance for a cubic approximating a unit arc.
        let t = 4 / 3 * tan(segmentDelta / 4)

        var theta = theta1
        for _ in 0..<segments {
            let thetaNext = theta + segmentDelta
            func onEllipse(_ a: CGFloat) -> CGPoint {
                CGPoint(x: cx + rx * cos(a) * cosPhi - ry * sin(a) * sinPhi,
                        y: cy + rx * cos(a) * sinPhi + ry * sin(a) * cosPhi)
            }
            // Derivative (tangent) at the segment endpoints.
            func tangent(_ a: CGFloat) -> CGPoint {
                CGPoint(x: -rx * sin(a) * cosPhi - ry * cos(a) * sinPhi,
                        y: -rx * sin(a) * sinPhi + ry * cos(a) * cosPhi)
            }
            let p0 = onEllipse(theta), p1 = onEllipse(thetaNext)
            let t0 = tangent(theta), t1 = tangent(thetaNext)
            path.addCurve(to: p1,
                          control1: CGPoint(x: p0.x + t * t0.x, y: p0.y + t * t0.y),
                          control2: CGPoint(x: p1.x - t * t1.x, y: p1.y - t * t1.y))
            theta = thetaNext
        }
    }

    /// Lexer for SVG path data: commands are single letters; numbers may be
    /// packed together (`-.5.83` is −0.5 then 0.83 — a second `.` starts a new
    /// number), separated by whitespace or commas.
    private struct NumberScanner {
        private let chars: [Character]
        private var index = 0

        init(_ s: String) { chars = Array(s) }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index] == " " || chars[index] == "," ||
                chars[index] == "\n" || chars[index] == "\t" || chars[index] == "\r" {
                index += 1
            }
        }

        mutating func nextCommand() -> Character? {
            skipSeparators()
            guard index < chars.count, chars[index].isLetter else { return nil }
            defer { index += 1 }
            return chars[index]
        }

        /// True if a number (not a command letter) comes next.
        mutating func peekNumber() -> Bool {
            skipSeparators()
            guard index < chars.count else { return false }
            let c = chars[index]
            return c.isNumber || c == "-" || c == "+" || c == "."
        }

        mutating func nextNumber() -> CGFloat? {
            skipSeparators()
            var s = ""
            guard index < chars.count else { return nil }
            if chars[index] == "-" || chars[index] == "+" { s.append(chars[index]); index += 1 }
            var seenDot = false
            while index < chars.count {
                let c = chars[index]
                if c.isNumber { s.append(c); index += 1 }
                else if c == ".", !seenDot { seenDot = true; s.append(c); index += 1 }
                else { break }
            }
            return Double(s).map { CGFloat($0) }
        }
    }
}
