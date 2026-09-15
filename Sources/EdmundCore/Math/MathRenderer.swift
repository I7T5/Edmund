import AppKit
import SwiftMath

// MARK: - MathRenderer
//
// A pluggable math-typesetting engine. `SwiftMathRenderer` wraps the bundled,
// always-available SwiftMath renderer; other engines (e.g. a future RaTeX
// extension) implement the same interface so `EditorTextView` (edit mode) and
// `DocumentHTML` (read mode) don't care which one draws math — both render
// through the `MathRendering` coordinator below instead of calling a specific
// engine directly.

/// One rendered equation, tinted to the requested color: the image plus the
/// typographic ascent/descent needed to sit it on the surrounding text's
/// baseline (inline math) or split its reserved space correctly (display
/// math). `ascent + descent == image.size.height`.
public struct RenderedMath {
    public let image: NSImage
    /// Height above the baseline.
    public let ascent: CGFloat
    /// Height below the baseline (>= 0).
    public let descent: CGFloat
    public var size: CGSize { image.size }
}

/// A math-typesetting engine. Renders LaTeX to an image plus the metrics
/// needed to place it against surrounding text. `@MainActor` because
/// rendering touches AppKit drawing (SwiftMath's `MTMathUILabel`, `NSImage`).
@MainActor
public protocol MathRenderer: AnyObject {
    /// Stable identity, distinguishing engines (e.g. "swiftmath").
    var id: String { get }
    /// Whether this renderer can render right now (loaded, no pending
    /// download/install).
    var isReady: Bool { get }
    /// Renders `latex`; `displayMode` selects block vs inline typesetting.
    /// Returns `nil` when the engine can't render it (unknown command, parse
    /// error, not ready) so the caller can fall back to another engine or
    /// show the raw source.
    func render(latex: String, displayMode: Bool,
               pointSize: CGFloat, color: NSColor) -> RenderedMath?
}

/// Wraps SwiftMath — bundled, native, always ready. The default (and, today,
/// only) renderer. Folds together the render+metrics logic that used to be
/// duplicated between `EditorTextView.mathOverlay` (edit mode) and
/// `DocumentHTML.fillMath`'s private `mathImage` (read mode), so both
/// back-ends share one implementation.
@MainActor
public final class SwiftMathRenderer: MathRenderer {
    public let id = "swiftmath"
    public var isReady: Bool { true }

    private final class Cached {
        let image: NSImage
        let ascent: CGFloat
        let descent: CGFloat
        init(image: NSImage, ascent: CGFloat, descent: CGFloat) {
            self.image = image
            self.ascent = ascent
            self.descent = descent
        }
    }

    /// Rendered math is cached so repeated renders of the same equation (a
    /// keystroke restyle, or the same equation appearing more than once in a
    /// read-mode export) don't re-typeset. The key encodes everything that
    /// affects the pixels/metrics: latex, display vs inline, font size, and
    /// the resolved color.
    // NSCache is internally thread-safe; `nonisolated(unsafe)` opts it out of
    // the Swift 6 Sendable check (in practice it's only touched on the main actor).
    nonisolated(unsafe) private let cache = NSCache<NSString, Cached>()

    public init() {}

    public func render(latex: String, displayMode: Bool,
                       pointSize: CGFloat, color: NSColor) -> RenderedMath? {
        let key = "\(displayMode ? "D" : "I")|\(String(format: "%.1f", pointSize))|" +
                  "\(String(format: "%.3f,%.3f,%.3f,%.3f", color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent))|" +
                  latex as NSString

        if let cached = cache.object(forKey: key) {
            return RenderedMath(image: cached.image, ascent: cached.ascent, descent: cached.descent)
        }

        let mode: MTMathUILabelMode = displayMode ? .display : .text
        let math = MTMathImage(latex: latex, fontSize: pointSize, textColor: color, labelMode: mode)
        // SwiftMath sizes the image to the exact typographic ascent+descent,
        // which crops a glyph's ink overshoot below the baseline — the bottom
        // of a lone `x`/`c` sits flush on the image edge and renders clipped.
        // A small content inset gives the rasterizer room so the full glyph is
        // drawn; it's folded into ascent/descent below so alignment is unchanged.
        let insetPad: CGFloat = 2
        math.contentInsets = MTEdgeInsets(top: insetPad, left: 0, bottom: insetPad, right: 0)
        let (error, image) = math.asImage()
        guard error == nil, let image else { return nil }

        // Typeset once more via a label to read ascent/descent, then compute
        // the baseline's distance from the image bottom the way SwiftMath's
        // asImage does — including its `height < fontSize/2` clamp, which
        // re-centers small glyphs (a lone x/c/n). Ignoring the clamp left
        // those a pixel below the surrounding text baseline.
        let label = MTMathUILabel()
        label.latex = latex
        label.fontSize = pointSize
        label.labelMode = mode
        label.layout()
        let asc = label.displayList?.ascent ?? 0
        let desc = label.displayList?.descent ?? 0
        let clamped = max(asc + desc, pointSize / 2)
        let descent = (asc + desc - clamped) / 2 + desc + insetPad
        let ascent = image.size.height - descent

        cache.setObject(Cached(image: image, ascent: ascent, descent: descent), forKey: key)
        return RenderedMath(image: image, ascent: ascent, descent: descent)
    }
}

/// Coordinates which math engine is active and falls back to SwiftMath
/// per-equation when a non-default engine can't render a given equation
/// (e.g. one it doesn't yet support), so a single hard construct doesn't
/// blank the whole document. `EditorTextView` and `DocumentHTML` both render
/// math through this rather than calling a renderer directly.
@MainActor
public final class MathRendering {
    public static let shared = MathRendering()

    public let swiftMath = SwiftMathRenderer()
    /// A non-default engine, once one is enabled and installed (e.g. RaTeX).
    /// `nil` until an extension provides one.
    public var alternate: MathRenderer?

    private init() {}

    /// The engine that should render right now: `alternate` if set and ready,
    /// else the always-available SwiftMath default.
    public var active: MathRenderer {
        (alternate?.isReady == true) ? alternate! : swiftMath
    }

    public func render(latex: String, displayMode: Bool,
                       pointSize: CGFloat, color: NSColor) -> RenderedMath? {
        let primary = active
        if let r = primary.render(latex: latex, displayMode: displayMode,
                                  pointSize: pointSize, color: color) {
            return r
        }
        guard primary !== swiftMath else { return nil }
        return swiftMath.render(latex: latex, displayMode: displayMode,
                                pointSize: pointSize, color: color)
    }

    /// Call after switching the active engine (or finishing an install) so
    /// on-screen equations re-render with the new engine.
    public func engineDidChange() {
        NotificationCenter.default.post(name: .mathEngineChanged, object: nil)
    }
}

public extension Notification.Name {
    /// Posted by `MathRendering.engineDidChange()`. Editors observe this and
    /// recompose their math blocks (narrowest recompose that covers them).
    static let mathEngineChanged = Notification.Name("EdmundCore.mathEngineChanged")
}
