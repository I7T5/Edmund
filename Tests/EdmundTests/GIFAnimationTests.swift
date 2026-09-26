import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import EdmundCore

@Suite("Animated GIF")
struct GIFAnimationTests {

    /// A GIF of `frames` 2×2 frames, each shown for `delay` seconds.
    private func gif(frames: Int, delay: Double = 0.25) -> NSImage {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil)!
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for i in 0 ..< frames {
            context.setFillColor(gray: CGFloat(i) / CGFloat(max(frames, 1)), alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            CGImageDestinationAddImage(dest, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        return NSImage(data: data as Data)!
    }

    @Test("A multi-frame GIF is animated; a single frame is not")
    func detectsAnimation() {
        #expect(gif(frames: 3).animatedGIFRep != nil)
        #expect(gif(frames: 1).animatedGIFRep == nil)
    }

    @Test("The frame follows the clock and loops forever")
    func frameLoops() {
        let d = [0.25, 0.5, 0.25]   // loop length 1.0
        #expect(EditorTextView.gifFrame(at: 0, durations: d) == 0)
        #expect(EditorTextView.gifFrame(at: 0.3, durations: d) == 1)
        #expect(EditorTextView.gifFrame(at: 0.8, durations: d) == 2)
        #expect(EditorTextView.gifFrame(at: 1000.3, durations: d) == 1)
        #expect(EditorTextView.gifFrame(at: 5, durations: []) == 0)
    }
}
