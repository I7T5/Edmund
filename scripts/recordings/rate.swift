// Scores recordings on what can be measured, the video twin of
// scripts/screenshots/rate.swift. Judging taste is the recording-rater agent's
// job; this is the part a script can do, and it draws the contact sheet the
// agent judges from (an agent can't play a video).
//
//   format      size, frame rate, codec, length, audio (the App Store wants a
//               track); a miss fails the clip outright
//   visibility  OCR'd text height on the last frame, and where the motion is
//   clarity     the `# expect:` words on the last frame, no "Edited", no
//               one-frame flashes
//   flow        a still lead-in to orient on, a held end to read, no dead gaps,
//               the eye not sent across the canvas between actions
//   pace        no jarring cuts (most of the frame replaced at once)
//
// Usage: rate.swift <recordings dir> <clip.mp4>...   (clips from recordings.sh)
//        rate.swift --review <video> [marker,...]     (App Review recording)
//        rate.swift --selftest
// The .rec behind <name>-<mode>[-appstore].mp4 is <recordings dir>/<name>.rec.
// Writes <clip>-sheet.png next to each clip: 12 frames with times, and a strip
// of how much changed per frame.
import AppKit
import AVFoundation
import Vision

// Median OCR line height, in pixels of a 2880-wide canvas, that counts as
// legible: the screenshots' floor, so a clip reads like a shot.
let defaultLegible = 40.0
// A frame counts as moving when this many sample pixels changed by more than
// `pixelDelta`: one typed character changes ~10 at 320 wide; H.264 noise stays under.
let movingPixels = 3, pixelDelta: UInt8 = 24
let thumbWidth = 320
// Flow: seconds of stillness to orient before the first change, and to read
// the result after the last; a still longer than `deadGap` mid-clip drags.
let leadIn = 0.4, endHold = 1.5, deadGap = 2.0
// The eye has to hunt when consecutive actions are this far apart (fraction
// of the canvas diagonal).
let huntJump = 0.4
// A cut: this fraction of the frame replaced in one frame.
let cutFraction = 0.3
// Output targets: site clips (README, edmund.md) and the App Store app preview.
let siteSize = "1440x900", siteLength = 3.0 ... 15.0
let storeSize = "1920x1080", storeLength = 15.0 ... 30.0
// App Review: launch to quit, the typical flow.
let reviewLength = 60.0 ... 300.0, reviewDeadGap = 8.0, reviewLegible = 12.0
let defaultMarkers = ["Save", "Open", "Settings", "Read", "Print"]

struct Thumb { let pixels: [UInt8]; let width: Int; let height: Int }

func thumb(_ image: CGImage) -> Thumb {
    let w = thumbWidth, h = max(1, image.height * thumbWidth / image.width)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return Thumb(pixels: Array(UnsafeBufferPointer(start: data, count: w * h)), width: w, height: h)
}

// Changed pixels between two thumbs, and their bounding box (fractions, y down).
struct Change { var count = 0; var box = CGRect.null }
func change(_ a: Thumb, _ b: Thumb) -> Change {
    var c = Change()
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0 ..< a.height {
        for x in 0 ..< a.width {
            let i = y * a.width + x
            let d = a.pixels[i] > b.pixels[i] ? a.pixels[i] - b.pixels[i] : b.pixels[i] - a.pixels[i]
            if d > pixelDelta {
                c.count += 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    if c.count > 0 {
        // CGContext rows run bottom-up; flip to y down.
        c.box = CGRect(x: Double(minX) / Double(a.width), y: 1 - Double(maxY + 1) / Double(a.height),
                       width: Double(maxX - minX + 1) / Double(a.width),
                       height: Double(maxY - minY + 1) / Double(a.height))
    }
    return c
}

struct Line { let text: String; let height: Double; let box: CGRect }   // box y down, fractions
func ocr(_ image: CGImage, fast: Bool = false) -> [Line] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = fast ? .fast : .accurate
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { o in
        guard let text = o.topCandidates(1).first?.string else { return nil }
        let b = o.boundingBox
        return Line(text: text, height: Double(b.height) * Double(image.height),
                    box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
    }
}
func median(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.sorted()[xs.count / 2] }

struct Sampled {
    var times: [Double] = []
    var thumbs: [Thumb] = []
    var sheet: [(Double, CGImage)] = []   // 12 frames for the contact sheet
    var ocrFrames: [(Double, CGImage)] = []
    var last: CGImage?
    var size = CGSize.zero
    var duration = 0.0, fps = 0.0, codec = "", hasAudio = false
}

// Every frame at `rate` per second, a thumb of each; full frames kept for the
// sheet, the end, and OCR every `ocrEvery` seconds.
func sample(_ url: URL, rate: Double, ocrEvery: Double? = nil) async throws -> Sampled {
    let asset = AVURLAsset(url: url)
    var s = Sampled()
    s.duration = try await asset.load(.duration).seconds
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return s }
    s.hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
    let natural = try await track.load(.naturalSize)
    s.size = natural
    s.fps = Double(try await track.load(.nominalFrameRate))
    if let desc = try await track.load(.formatDescriptions).first {
        let sub = CMFormatDescriptionGetMediaSubType(desc).bigEndian
        s.codec = withUnsafeBytes(of: sub) { String(decoding: $0, as: UTF8.self) }
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    generator.appliesPreferredTrackTransform = true
    let n = max(1, Int((s.duration * rate).rounded(.down)))
    let times = (0 ..< n).map { CMTime(seconds: Double($0) / rate, preferredTimescale: 600) }
    let sheetAt = Set((0 ..< 12).map { $0 * (n - 1) / 11 })
    var nextOCR = 0.0
    var index = 0
    for await result in generator.images(for: times) {
        defer { index += 1 }
        guard let image = try? result.image else { continue }
        let t = result.requestedTime.seconds
        s.times.append(t); s.thumbs.append(thumb(image))
        if sheetAt.contains(index) { s.sheet.append((t, image)) }
        if let every = ocrEvery, t >= nextOCR { s.ocrFrames.append((t, image)); nextOCR = t + every }
        s.last = image
    }
    return s
}

// Contact sheet: 4×3 frames with their times, and under them a strip of how
// much changed per frame, scaled to the busiest frame.
func writeSheet(_ s: Sampled, changes: [Change], to path: String) {
    let cellW = 480.0, cellH = s.size.width > 0 ? cellW * s.size.height / s.size.width : 300
    let strip = 60.0, pad = 8.0
    let W = 4 * cellW + 5 * pad, H = 3 * cellH + 4 * pad + strip + pad
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 22, weight: .semibold),
        .foregroundColor: NSColor.white, .backgroundColor: NSColor(white: 0, alpha: 0.6)]
    for (i, (t, image)) in s.sheet.enumerated() {
        let col = Double(i % 4), row = Double(i / 4)
        let rect = NSRect(x: pad + col * (cellW + pad), y: H - (row + 1) * (cellH + pad),
                          width: cellW, height: cellH)
        NSGraphicsContext.current?.cgContext.draw(image, in: rect)
        NSString(format: " %.1fs ", t).draw(at: NSPoint(x: rect.minX + 6, y: rect.minY + 6), withAttributes: attrs)
    }
    let peak = Double(max(1, changes.map(\.count).max() ?? 1))
    let barW = (W - 2 * pad) / Double(max(1, changes.count))
    NSColor.systemOrange.setFill()
    for (i, c) in changes.enumerated() where c.count >= movingPixels {
        NSRect(x: pad + Double(i) * barW, y: pad, width: max(1, barW),
               height: max(2, strip * sqrt(Double(c.count) / peak))).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

struct Report { var score = 0; var fails: [String] = []; var warns: [String] = []; var facts: [String] = [] }

// Motion analysis shared by clips and review recordings.
struct Motion {
    var changes: [Change] = []
    var moving: [Bool] = []
    var firstMove: Double?, lastMove: Double?
    var longestStill = 0.0, longestStillAt = 0.0
    var flashes: [Double] = [], cuts: [Double] = [], hunts: [Double] = []
    var box = CGRect.null
}
func analyse(_ s: Sampled) -> Motion {
    var m = Motion()
    let total = Double(s.thumbs.first.map { $0.width * $0.height } ?? 1)
    m.changes = [Change()] + zip(s.thumbs, s.thumbs.dropFirst()).map { change($0, $1) }
    m.moving = m.changes.map { $0.count >= movingPixels }
    var stillSince: Double?
    var lastBurstCentre: CGPoint?, burstBox = CGRect.null
    for (i, t) in s.times.enumerated() {
        let c = m.changes[i]
        if m.moving[i] {
            if m.firstMove == nil { m.firstMove = t }
            m.lastMove = t
            m.box = m.box.union(c.box); burstBox = burstBox.union(c.box)
            if let since = stillSince, m.firstMove != t, t - since > m.longestStill {
                m.longestStill = t - since; m.longestStillAt = since
            }
            stillSince = nil
            if Double(c.count) / total > cutFraction { m.cuts.append(t) }
            // A flash: this frame differs from both neighbours, which match
            // each other — something drew for one frame and went away.
            if i >= 1, i + 1 < s.thumbs.count, m.moving[i + 1],
               change(s.thumbs[i - 1], s.thumbs[i + 1]).count * 5 < c.count {
                m.flashes.append(t)
            }
        } else if stillSince == nil {
            stillSince = t
            // A burst ended: compare where it happened with the burst before.
            if !burstBox.isNull {
                let centre = CGPoint(x: burstBox.midX, y: burstBox.midY)
                if let prev = lastBurstCentre, hypot(centre.x - prev.x, centre.y - prev.y) / sqrt(2) > huntJump {
                    m.hunts.append(t)
                }
                lastBurstCentre = centre; burstBox = .null
            }
        }
    }
    return m
}

// The value of `# <key>:` in the .rec behind a clip.
func header(_ key: String, recDir: String, clip: String) -> String? {
    var name = ((clip as NSString).lastPathComponent as NSString).deletingPathExtension
    if name.hasSuffix("-appstore") { name = String(name.dropLast("-appstore".count)) }
    for suffix in ["-light", "-dark"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
    guard let rec = try? String(contentsOfFile: "\(recDir)/\(name).rec", encoding: .utf8) else { return nil }
    return rec.split(separator: "\n").first { $0.hasPrefix("# \(key):") }
        .map { $0.dropFirst("# \(key):".count).trimmingCharacters(in: .whitespaces) }
}

func rateClip(_ path: String, recDir: String?) async -> Report {
    var r = Report()
    let store = path.hasSuffix("-appstore.mp4")
    guard let s = try? await sample(URL(fileURLWithPath: path), rate: 30), let last = s.last else {
        r.fails.append("unreadable"); return r
    }
    // Format.
    let size = "\(Int(s.size.width))x\(Int(s.size.height))"
    let (wantSize, length) = store ? (storeSize, storeLength) : (siteSize, siteLength)
    if size != wantSize { r.fails.append("size \(size), want \(wantSize)") }
    if abs(s.fps - 30) > 0.5 { r.fails.append(String(format: "%.1f fps, want 30", s.fps)) }
    if s.codec != "avc1" { r.fails.append("codec \(s.codec), want H.264") }
    // A clip's App Store render is a part; the 15–30 s rule is for the
    // `# combine:` preview made of them.
    let part = store && recDir.flatMap { header("combine", recDir: $0, clip: path) } == nil
    if !part && !length.contains(s.duration) {
        r.fails.append(String(format: "%.1f s, want %.0f–%.0f", s.duration, length.lowerBound, length.upperBound))
    }
    if store && !s.hasAudio { r.fails.append("no audio track") }

    let m = analyse(s)
    writeSheet(s, changes: m.changes, to: (path as NSString).deletingPathExtension + "-sheet.png")

    // Visibility: text height at 2880 wide, overall and where the action is.
    let lines = ocr(last)
    let toCanvas = 2880 / Double(last.width)
    let legible = recDir.flatMap { header("legible", recDir: $0, clip: path) }.flatMap(Double.init) ?? defaultLegible
    let textHeight = median(lines.map { $0.height * toCanvas })
    let action = lines.filter { !m.box.isNull && $0.box.intersects(m.box) }
    let actionHeight = action.isEmpty ? textHeight : median(action.map { $0.height * toCanvas })
    r.facts.append(String(format: "text %.0fpx action %.0fpx (want ≥%.0f)", textHeight, actionHeight, legible))
    if textHeight < legible { r.warns.append("text small: zoom in or a smaller window") }
    if actionHeight < legible { r.warns.append("the changing text is small: zoom in") }
    if !m.box.isNull {
        r.facts.append(String(format: "action area %.0f%%", m.box.width * m.box.height * 100))
    }

    // Clarity.
    let all = lines.map(\.text).joined(separator: "\n")
    let wants = (recDir.flatMap { header("expect", recDir: $0, clip: path) } ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let missing = wants.filter { !all.localizedCaseInsensitiveContains($0) }
    if !missing.isEmpty { r.warns.append("missing at the end: \(missing.joined(separator: ", "))") }
    if lines.contains(where: { $0.text.range(of: #"\bEdited\b"#, options: .regularExpression) != nil }) {
        r.fails.append("\"Edited\" on screen")
    }
    if !m.flashes.isEmpty { r.warns.append("one-frame flash at " + m.flashes.map { String(format: "%.2fs", $0) }.joined(separator: ", ")) }

    // Flow.
    var flow = 25.0
    if let first = m.firstMove, let lastMove = m.lastMove {
        if first < leadIn { r.warns.append(String(format: "lead-in %.1fs, want ≥%.1f", first, leadIn)); flow -= 5 }
        let hold = s.duration - lastMove
        if hold < endHold { r.warns.append(String(format: "end hold %.1fs, want ≥%.1f", hold, endHold)); flow -= 8 }
        if m.longestStill > deadGap {
            r.warns.append(String(format: "dead gap %.1fs at %.1fs", m.longestStill, m.longestStillAt)); flow -= 7
        }
        if !m.hunts.isEmpty { r.warns.append("eye jumps across the canvas at " + m.hunts.map { String(format: "%.1fs", $0) }.joined(separator: ", ")); flow -= 5 }
    } else {
        r.warns.append("nothing moves"); flow = 0
    }
    // Pace.
    let pace = max(0, 15 - 5 * Double(m.cuts.count))
    if !m.cuts.isEmpty { r.warns.append("cut at " + m.cuts.map { String(format: "%.1fs", $0) }.joined(separator: ", ")) }

    let legibility = min(1, min(textHeight, actionHeight) / legible) * 35
    let coverage = wants.isEmpty ? 15 : Double(wants.count - missing.count) / Double(wants.count) * 15
    let clarity = coverage + max(0, 10 - 5 * Double(m.flashes.count))
    r.score = r.fails.isEmpty ? Int((legibility + clarity + max(0, flow) + pace).rounded()) : 0
    return r
}

func rateReview(_ path: String, markers: [String]) async -> Report {
    var r = Report()
    guard let s = try? await sample(URL(fileURLWithPath: path), rate: 5, ocrEvery: 1), s.last != nil else {
        r.fails.append("unreadable"); return r
    }
    r.facts.append(String(format: "%.0fs %dx%d", s.duration, Int(s.size.width), Int(s.size.height)))
    if !reviewLength.contains(s.duration) {
        r.warns.append(String(format: "%.0f s; App Review flows usually run %.0f–%.0f s", s.duration,
                              reviewLength.lowerBound, reviewLength.upperBound))
    }
    let m = analyse(s)
    writeSheet(s, changes: m.changes, to: (path as NSString).deletingPathExtension + "-sheet.png")
    if m.longestStill > reviewDeadGap {
        r.warns.append(String(format: "nothing happens for %.0fs at %.0fs", m.longestStill, m.longestStillAt))
    }

    // It has to start at launch: the menu bar names another app first, Edmund later.
    var menuApp: [(Double, Bool)] = []
    var seen = Set<String>(), heights: [Double] = [], privacy: [String] = []
    let email = try! NSRegularExpression(pattern: #"[\w.+-]+@[\w-]+\.[\w.]+"#)
    let phone = try! NSRegularExpression(pattern: #"\+?\d[\d ()-]{8,}\d"#)
    for (t, image) in s.ocrFrames {
        let lines = ocr(image, fast: true)
        let bar = lines.filter { $0.box.minY < 0.04 }.sorted { $0.box.minX < $1.box.minX }
        menuApp.append((t, bar.first.map { $0.text.contains("Edmund") } ?? false))
        heights += lines.map { $0.height * 1920 / Double(image.width) }
        for line in lines {
            for marker in markers where line.text.localizedCaseInsensitiveContains(marker) { seen.insert(marker) }
            let range = NSRange(line.text.startIndex..., in: line.text)
            if email.firstMatch(in: line.text, range: range) != nil || phone.firstMatch(in: line.text, range: range) != nil {
                privacy.append(String(format: "%.0fs \"%@\"", t, line.text))
            }
        }
    }
    let startsElsewhere = menuApp.first.map { !$0.1 } ?? false
    let launchAt = menuApp.first { $0.1 }?.0
    if !startsElsewhere { r.fails.append("doesn't start before launch: Edmund is frontmost in the first frame") }
    if let launchAt { r.facts.append(String(format: "Edmund frontmost from %.0fs", launchAt)) } else {
        r.fails.append("Edmund never frontmost (menu bar)")
    }
    let missing = markers.filter { !seen.contains($0) }
    if !missing.isEmpty { r.warns.append("flow never shows: \(missing.joined(separator: ", "))") }
    if !privacy.isEmpty { r.warns.append("personal info? " + privacy.prefix(5).joined(separator: "; ")) }
    let text = median(heights)
    r.facts.append(String(format: "text %.0fpx at 1080p (want ≥%.0f)", text, reviewLegible))
    if text < reviewLegible { r.warns.append("text small at 1080p") }
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    r.facts.append("recorded on \(os)")
    r.warns.append("App Review wants the latest macOS: check \(os) is current")
    let covered = Double(markers.count - missing.count) / Double(max(1, markers.count))
    r.score = r.fails.isEmpty ? Int((covered * 60 + (privacy.isEmpty ? 20 : 0)
                                     + (m.longestStill > reviewDeadGap ? 0 : 20)).rounded()) : 0
    return r
}

func print(_ name: String, _ r: Report) {
    print(String(format: "%3d  %@  %@", r.score, name, r.facts.joined(separator: "  ")))
    for f in r.fails { print("       FAIL: \(f)") }
    for w in r.warns { print("       warn: \(w)") }
}

// MARK: self-test: synthetic clips with known answers.

func writeClip(_ path: String, frames: Int, draw: (Int, CGContext) -> Void) async throws {
    try? FileManager.default.removeItem(atPath: path)
    let w = 1440, h = 900
    let writer = try AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h])
    writer.add(input)
    writer.startWriting(); writer.startSession(atSourceTime: .zero)
    for i in 0 ..< frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer!), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        draw(i, ctx)
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

func text(_ s: String, _ ctx: CGContext, size: Double = 60, at point: NSPoint = NSPoint(x: 200, y: 450)) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    (s as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size)])
    NSGraphicsContext.restoreGraphicsState()
}

func selftest() async throws {
    let dir = NSTemporaryDirectory() + "rate-selftest-\(getpid())/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let typed = "Hello world from Edmund"
    // Good: 0.6 s still, typing at 80 ms a key, 2 s hold.
    try await writeClip(dir + "good.mp4", frames: 18 + typed.count * 3 + 60) { i, ctx in
        text(String(typed.prefix(max(0, (i - 18) / 3 + 1)).prefix(i < 18 ? 0 : typed.count)), ctx)
    }
    // Still: nothing moves.
    try await writeClip(dir + "still.mp4", frames: 120) { _, ctx in text(typed, ctx) }
    // Flash: one black frame at 2 s in a still clip.
    try await writeClip(dir + "flash.mp4", frames: 120) { i, ctx in
        if i == 60 { ctx.setFillColor(.black); ctx.fill(CGRect(x: 100, y: 100, width: 600, height: 300)) }
        text(typed, ctx)
    }
    // Rushed: typing starts on frame 0 and the clip ends on the last key.
    try await writeClip(dir + "rushed.mp4", frames: typed.count * 3 + 30) { i, ctx in
        text(String(typed.prefix(i / 3 + 1)), ctx)
    }
    // Review: Finder's menu bar for 2 s, then Edmund's, then its flow.
    try await writeClip(dir + "review.mp4", frames: 180) { i, ctx in
        text(i < 60 ? "Finder   File   Edit   View" : "Edmund   File   Edit   Format", ctx, size: 24,
             at: NSPoint(x: 20, y: 868))
        if i >= 60 { text(i < 120 ? "Save As:  notes.md" : "Settings   Open   Read   Print", ctx) }
    }
    try await writeClip(dir + "nolaunch.mp4", frames: 90) { _, ctx in
        text("Edmund   File   Edit   Format", ctx, size: 24, at: NSPoint(x: 20, y: 868))
    }
    let review = await rateReview(dir + "review.mp4", markers: defaultMarkers)
    let nolaunch = await rateReview(dir + "nolaunch.mp4", markers: defaultMarkers)
    let good = await rateClip(dir + "good.mp4", recDir: nil)
    let still = await rateClip(dir + "still.mp4", recDir: nil)
    let flash = await rateClip(dir + "flash.mp4", recDir: nil)
    let rushed = await rateClip(dir + "rushed.mp4", recDir: nil)
    for (n, r) in [("good", good), ("still", still), ("flash", flash), ("rushed", rushed),
                   ("review", review), ("nolaunch", nolaunch)] { print(n, r) }
    func has(_ r: Report, _ s: String) -> Bool { r.warns.contains { $0.contains(s) } }
    var ok = true
    func check(_ c: Bool, _ what: String) { if !c { print("SELFTEST FAIL: \(what)"); ok = false } }
    check(good.fails.isEmpty && good.warns.isEmpty, "good clip has no fails or warnings")
    check(good.score >= 90, "good clip scores ≥ 90")
    check(has(still, "nothing moves"), "still clip: nothing moves")
    check(has(flash, "one-frame flash at 2.00s"), "flash clip: flash at 2.00s")
    check(has(rushed, "lead-in") && has(rushed, "end hold"), "rushed clip: lead-in and end hold")
    check(FileManager.default.fileExists(atPath: dir + "good-sheet.png"), "sheet written")
    check(review.fails.isEmpty && review.facts.contains("Edmund frontmost from 2s"), "review: starts before launch")
    check(!has(review, "flow never shows"), "review: every marker seen")
    check(nolaunch.fails.contains { $0.contains("doesn't start before launch") }, "nolaunch: fails")
    print(ok ? "selftest ok" : "selftest FAILED")
    exit(ok ? 0 : 1)
}

// MARK: main

var args = Array(CommandLine.arguments.dropFirst())
if args.first == "--selftest" { try await selftest() }
if args.first == "--review", args.count >= 2 {
    let markers = args.count > 2 ? args[2].split(separator: ",").map(String.init) : defaultMarkers
    let r = await rateReview(args[1], markers: markers)
    print((args[1] as NSString).lastPathComponent, r)
    exit(r.fails.isEmpty ? 0 : 1)
}
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: rate.swift <recordings dir> <clip.mp4>... | --review <video> [markers] | --selftest\n".data(using: .utf8)!)
    exit(2)
}
let recDir = args.removeFirst()
var below: [String] = []
// Below the bar: any failure or warning; each names a fix. The score ranks.
for path in args {
    let r = await rateClip(path, recDir: recDir)
    print((path as NSString).lastPathComponent, r)
    if !r.fails.isEmpty || !r.warns.isEmpty {
        var name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        for suffix in ["-appstore", "-light", "-dark"] where name.hasSuffix(suffix) { name = String(name.dropLast(suffix.count)) }
        if !below.contains(name) { below.append(name) }
    }
}
// For `scripts/recordings.sh --failed`.
if !below.isEmpty { print("below: \(below.joined(separator: " "))") }
exit(below.isEmpty ? 0 : 1)
