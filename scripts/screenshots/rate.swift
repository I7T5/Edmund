// Scores composed screenshots on what can be measured: format ($SHOTS_SIZE,
// default 2880×1800; no alpha), legibility (OCR'd text height), feature coverage (the shot's
// `# expect:` words are on screen), a stray "Edited" title, and clutter (how
// many separate text blocks compete for attention). Judging taste is the
// screenshot-rater agent's job; this is the part a script can do.
//
// Usage: swift scripts/screenshots/rate.swift <shots dir> <composed.png>...
// The shot for <name>-<mode>.png is <shots dir>/<name>.shot.
import AppKit
import Vision

// Median OCR line height, in pixels of a 2880-wide canvas, that counts as
// legible; a shot's `# legible:` overrides it. MarkEdit's App Store shots
// measure 30–46 (rescaled to 2880); Edmund's first 0.8.3 set, with
// 1200-point windows, measured 29–38.
let defaultLegible = 40.0
// The canvas compose.swift was asked for (screenshots.sh exports it).
let expectedSize = ProcessInfo.processInfo.environment["SHOTS_SIZE"] ?? "2880x1800"
// More text blocks than this and the eye has nowhere to land.
let busyBlocks = 70

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: rate.swift <shots dir> <composed.png>...\n".data(using: .utf8)!)
    exit(2)
}
let shotsDir = args.removeFirst()

// The value of `# <key>:` in the .shot behind <name>-<mode>.png.
func header(_ key: String, for png: String) -> String? {
    var name = ((png as NSString).lastPathComponent as NSString).deletingPathExtension
    for suffix in ["-light", "-dark"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
    guard let shot = try? String(contentsOfFile: "\(shotsDir)/\(name).shot", encoding: .utf8) else { return nil }
    return shot.split(separator: "\n").first { $0.hasPrefix("# \(key):") }
        .map { $0.dropFirst("# \(key):".count).trimmingCharacters(in: .whitespaces) }
}

var failed = false
var below: [String] = []   // shot names, without the mode
for path in args {
    guard let rep = NSImage(contentsOfFile: path)?.representations.first as? NSBitmapImageRep,
          let cg = rep.cgImage else { print("FAIL \(path): unreadable"); failed = true; continue }
    var problems: [String] = []
    if "\(rep.pixelsWide)x\(rep.pixelsHigh)" != expectedSize { problems.append("size \(rep.pixelsWide)×\(rep.pixelsHigh)") }
    if rep.hasAlpha { problems.append("has alpha") }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg).perform([request])
    let lines = (request.results ?? []).compactMap { o -> (String, Double)? in
        guard let text = o.topCandidates(1).first?.string else { return nil }
        // Normalised height → pixels of a 2880-wide canvas, whatever the input size.
        return (text, Double(o.boundingBox.height) * Double(rep.pixelsHigh) * 2880 / Double(rep.pixelsWide))
    }
    let heights = lines.map(\.1).sorted()
    let median = heights.isEmpty ? 0 : heights[heights.count / 2]
    let all = lines.map(\.0).joined(separator: "\n")

    let wants = (header("expect", for: path) ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let legibleHeight = header("legible", for: path).flatMap(Double.init) ?? defaultLegible
    let missing = wants.filter { !all.localizedCaseInsensitiveContains($0) }
    if lines.contains(where: { $0.0.range(of: #"\bEdited\b"#, options: .regularExpression) != nil }) {
        problems.append("\"Edited\" on screen")
    }

    // 0–100: legibility 50, coverage 30, calm 20. A format problem or "Edited" fails outright.
    let legibility = min(1, median / legibleHeight) * 50
    let coverage = wants.isEmpty ? 30 : Double(wants.count - missing.count) / Double(wants.count) * 30
    let calm = lines.count <= busyBlocks ? 20 : max(0, 20 - Double(lines.count - busyBlocks) / 2)
    let score = problems.isEmpty ? Int((legibility + coverage + calm).rounded()) : 0
    if !problems.isEmpty || !missing.isEmpty || median < legibleHeight {
        failed = true
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for suffix in ["-light", "-dark"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if !below.contains(name) { below.append(name) }
    }

    print(String(format: "%3d  %@  text %.0fpx (want ≥%.0f)  blocks %d%@%@", score,
                 (path as NSString).lastPathComponent, median, legibleHeight, lines.count,
                 missing.isEmpty ? "" : "  missing: \(missing.joined(separator: ", "))",
                 problems.isEmpty ? "" : "  FAIL: \(problems.joined(separator: "; "))"))
}
// For `scripts/screenshots.sh --failed`.
if !below.isEmpty { print("below: \(below.joined(separator: " "))") }
exit(failed ? 1 : 0)
