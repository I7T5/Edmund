import AppKit

// MARK: - Animated GIFs
//
// An `NSImage` loaded from a GIF already holds every frame in its
// `NSBitmapImageRep` (`.frameCount`/`.currentFrame`); drawing it draws the
// current frame, so the image overlay needs no new mechanism — only something
// that advances the frame and redraws. That is a display link on the editor
// (paused by AppKit while the window is offscreen), started by the layout
// fragment whenever it draws an animated overlay and stopped by the first tick
// that finds none in the viewport — so scrolling a GIF back into view restarts
// it. The frame is picked from wall-clock time modulo the loop's length, so
// it loops forever and two views of one (shared, cached) GIF agree.

/// Per-frame delays by rep, read once (reading one means selecting its frame).
nonisolated(unsafe) private var gifFrameDurations: [ObjectIdentifier: [TimeInterval]] = [:]

extension NSImage {
    /// The bitmap rep to animate, if this image has more than one frame.
    var animatedGIFRep: NSBitmapImageRep? {
        representations.lazy.compactMap { $0 as? NSBitmapImageRep }
            .first { (($0.value(forProperty: .frameCount) as? Int) ?? 0) > 1 }
    }
}

extension EditorTextView {

    /// Called from `DecoratedTextLayoutFragment.draw` for an animated overlay.
    func startGIFPlayback() {
        guard gifLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(stepGIFs))
        link.add(to: .main, forMode: .common)
        gifLink = link
    }

    @objc private func stepGIFs(_ link: CADisplayLink) {
        guard let tlm = textLayoutManager,
              let viewport = tlm.textViewportLayoutController.viewportRange else { return }
        let now = CACurrentMediaTime()
        var animating = false
        tlm.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
            guard fragment.rangeInElement.location.compare(viewport.endLocation) == .orderedAscending else { return false }
            guard let decorated = fragment as? DecoratedTextLayoutFragment else { return true }
            for (_, overlay) in decorated.overlays {
                guard let rep = overlay.image?.animatedGIFRep else { continue }
                animating = true
                let frame = Self.gifFrame(at: now, durations: Self.frameDurations(rep))
                if (rep.value(forProperty: .currentFrame) as? Int) != frame {
                    rep.setProperty(.currentFrame, withValue: frame)
                    redisplay(decorated)
                }
            }
            return true
        }
        if !animating {
            link.invalidate()
            gifLink = nil
        }
    }

    /// TextKit 2 paints each fragment in its own private view, two levels down
    /// (`_NSTextContentView` › `_NSTextViewportElementView`), and marking the
    /// text view dirty doesn't reach it — so mark every view under the rect.
    private func redisplay(_ fragment: NSTextLayoutFragment) {
        let rect = fragment.renderingSurfaceBounds
            .offsetBy(dx: fragment.layoutFragmentFrame.minX + textContainerOrigin.x,
                      dy: fragment.layoutFragmentFrame.minY + textContainerOrigin.y)
        func mark(_ view: NSView, _ rect: NSRect) {
            view.setNeedsDisplay(rect)
            for sub in view.subviews where !sub.isHidden {
                let local = view.convert(rect, to: sub)
                if sub.bounds.intersects(local) { mark(sub, local) }
            }
        }
        mark(self, rect)
    }

    private static func frameDurations(_ rep: NSBitmapImageRep) -> [TimeInterval] {
        let key = ObjectIdentifier(rep)
        if let cached = gifFrameDurations[key] { return cached }
        let count = (rep.value(forProperty: .frameCount) as? Int) ?? 1
        let current = rep.value(forProperty: .currentFrame)
        let durations = (0 ..< count).map { i -> TimeInterval in
            rep.setProperty(.currentFrame, withValue: i)
            let d = (rep.value(forProperty: .currentFrameDuration) as? Double) ?? 0
            // Browsers play a 0/10 ms delay as 100 ms; so should we.
            return d <= 0.011 ? 0.1 : d
        }
        rep.setProperty(.currentFrame, withValue: current)
        gifFrameDurations[key] = durations
        return durations
    }

    /// The frame showing at `time` in a loop of `durations`, looping forever.
    nonisolated static func gifFrame(at time: TimeInterval, durations: [TimeInterval]) -> Int {
        let total = durations.reduce(0, +)
        guard total > 0 else { return 0 }
        var t = time.truncatingRemainder(dividingBy: total)
        for (i, d) in durations.enumerated() {
            if t < d { return i }
            t -= d
        }
        return durations.count - 1
    }
}
