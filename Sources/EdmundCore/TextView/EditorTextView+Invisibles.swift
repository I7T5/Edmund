// Invisible characters: faint marks overdrawn on whitespace so the author can
// see spaces, tabs, and line endings. A pure display overlay — no characters
// are inserted (storage stays == rawSource) and it rides the existing TextKit 2
// fragment-draw path (DecoratedTextLayoutFragment). Editor-only: Read mode
// never shows invisibles (they're an edit affordance, not content). Modeled on
// CotEditor's invisibles.

import AppKit

/// What the app pushes onto `EditorTextView.invisibles`. `nil` there means the
/// feature is off (the default). Built from Settings ▸ Edit.
public struct InvisiblesConfig: Equatable {
    // Marks used to have an Always / Upon Selection mode; it was cut (commit
    // 6652972) and is parked here in case it returns. Restoring it means
    // un-commenting this enum, the `mode` property and init parameter, and the
    // two gates in `drawInvisibles` — plus the app-side pieces commented in
    // AppSettings / EditSettingsView.
    // public enum Mode: Equatable { case always, uponSelection }

    public var lineEnding: Bool
    public var tab: Bool
    public var space: Bool
    public var otherWhitespace: Bool
    public var otherControl: Bool
    // public var mode: Mode
    /// The faint mark color, resolved by the app from the active appearance
    /// (the fragment has no theme access, so it's handed in like the other
    /// vend-time values).
    public var color: NSColor

    public init(lineEnding: Bool = true, tab: Bool = true, space: Bool = true,
                otherWhitespace: Bool = true, otherControl: Bool = true,
                /* mode: Mode = .uponSelection, */
                color: NSColor = .tertiaryLabelColor) {
        self.lineEnding = lineEnding
        self.tab = tab
        self.space = space
        self.otherWhitespace = otherWhitespace
        self.otherControl = otherControl
        // self.mode = mode
        self.color = color
    }

    /// False when every category is off — nothing to draw, so the delegate can
    /// keep vending plain fragments.
    var drawsAnything: Bool {
        lineEnding || tab || space || otherWhitespace || otherControl
    }

    /// Whether this category's mark is enabled.
    func draws(_ category: InvisibleCategory) -> Bool {
        switch category {
        case .lineEnding: return lineEnding
        case .tab: return tab
        case .space: return space
        case .otherWhitespace: return otherWhitespace
        case .otherControl: return otherControl
        }
    }
}

/// The kind of invisible a character is, or nil for a visible glyph.
public enum InvisibleCategory: Equatable {
    case lineEnding, tab, space, otherWhitespace, otherControl

    /// Classifies one UTF-16 unit. BMP-only: astral scalars arrive as surrogate
    /// halves, which are never whitespace/control, so returning nil for a
    /// surrogate is correct.
    // ponytail: UTF-16-unit granularity is enough — every invisible we mark is a
    // single BMP unit. Full grapheme handling is the upgrade path if we ever
    // mark astral format characters.
    public static func of(_ u: unichar) -> InvisibleCategory? {
        switch u {
        case 0x0A, 0x0D, 0x2028, 0x2029: return .lineEnding   // LF, CR, LS, PS
        case 0x09: return .tab
        case 0x20: return .space
        default:
            guard let scalar = Unicode.Scalar(UInt32(u)) else { return nil }
            if scalar.properties.isWhitespace { return .otherWhitespace }
            // C0/C1 controls and DEL. Zero-width/format chars stay unmarked in v1.
            if u < 0x20 || u == 0x7F || (u >= 0x80 && u <= 0x9F) { return .otherControl }
            return nil
        }
    }

    /// The glyph drawn for this category.
    var mark: String {
        switch self {
        case .lineEnding: return "\u{00AC}"      // ¬
        case .tab: return "\u{2192}"             // →
        case .space: return "\u{00B7}"           // ·
        case .otherWhitespace: return "\u{2423}" // ␣
        case .otherControl: return "\u{25AF}"    // ▯
        }
    }
}

extension EditorTextView {
    /// Re-vends the visible fragments after a draw-only setting changed
    /// (`invisibles`, `showListIndentGuides`). These alter no styled
    /// attributes, so a restyle wouldn't re-consult the layout delegate;
    /// invalidating layout forces the plain ↔ decorated swap and a redraw.
    /// Call after every such assignment.
    /// Anchored, and it re-lays the viewport itself: invalidating the whole
    /// document drops every fragment back to a height estimate, so without the
    /// anchor the visible band slides (measured on a 2000-line file), and
    /// nothing forces a viewport layout afterward — the editor sat blank until
    /// a click supplied the missing event. Same repair as `swapToEditor`.
    @MainActor public func refreshOverdraw() {
        preservingViewportAnchor {
            if let tlm = textLayoutManager {
                tlm.invalidateLayout(for: tlm.documentRange)
            }
            // Invalidating layout is not enough on its own: the layout manager
            // keeps its fragments and hands the cached ones back, so a paragraph
            // that was vended plain stays plain and the new overdraw never appears
            // (measured — a live toggle drew nothing until the next edit). Only the
            // content storage re-offering its elements re-vends them, and an
            // attributes-only edit is the cheapest way to ask for that: no text
            // changes, no restyle, no undo entry — the same call every `setAttributes`
            // already makes (EditorTextStorage).
            if let storage = textStorage, storage.length > 0 {
                storage.edited(.editedAttributes,
                               range: NSRange(location: 0, length: storage.length),
                               changeInLength: 0)
            }
        }
        textLayoutManager?.textViewportLayoutController.layoutViewport()
        needsDisplay = true
    }
}

extension DecoratedTextLayoutFragment {
    /// Overdraws whitespace marks for `invisibles`, called from `draw` after the
    /// real glyphs. Reads laid-out positions from the line fragments and inserts
    /// nothing.
    func drawInvisibles(at point: CGPoint, in context: CGContext) {
        guard let config = invisibles, config.drawsAnything else { return }

        // Mark only characters inside the live selection. Nothing selected →
        // nothing to draw. Selection is read from the fragment's own layout
        // manager — no extra plumbing.
        //
        // With the parked Always mode this was gated instead:
        //     let onlyInSelection = config.mode == .uponSelection
        //     let selectionRanges: [NSTextRange] = onlyInSelection
        //         ? (textLayoutManager?.textSelections.flatMap { $0.textRanges } ?? [])
        //         : []
        //     if onlyInSelection && selectionRanges.isEmpty { return }
        let selectionRanges = textLayoutManager?.textSelections.flatMap { $0.textRanges } ?? []
        if selectionRanges.isEmpty { return }
        let elementStart = textElement?.elementRange?.location

        let nsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        for line in textLineFragments {
            let range = line.characterRange
            guard range.length > 0 else { continue }
            // `attributedString` is the whole element's string; `characterRange`
            // and `locationForCharacter(at:)` index into it element-relative.
            let full = line.attributedString.string as NSString
            let elementLength = full.length
            let bounds = line.typographicBounds
            var i = range.location
            let end = min(NSMaxRange(range), elementLength)
            while i < end {
                defer { i += 1 }
                guard let category = InvisibleCategory.of(full.character(at: i)),
                      config.draws(category) else { continue }
                // With the parked Always mode this whole guard sat inside
                // `if onlyInSelection { … }`.
                guard let tlm = textLayoutManager, let base = elementStart,
                      let loc = tlm.location(base, offsetBy: i),
                      selectionRanges.contains(where: { $0.contains(loc) })
                else { continue }
                // locationForCharacter is line-local; add the line origin.
                let startX = line.locationForCharacter(at: i).x
                let nextX = line.locationForCharacter(at: min(i + 1, elementLength)).x
                let advance = max(nextX - startX, 0)
                var size: CGFloat = 12
                if let font = line.attributedString.attribute(
                    .font, at: i, effectiveRange: nil) as? NSFont {
                    size = max(font.pointSize, 6)   // hidden-font runs are ~0pt
                }
                drawMark(category.mark, color: config.color, fontSize: size,
                         cellX: point.x + bounds.minX + startX, cellWidth: advance,
                         lineTop: point.y + bounds.minY, lineHeight: bounds.height)
            }
        }
    }

    private func drawMark(_ mark: String, color: NSColor, fontSize: CGFloat,
                          cellX: CGFloat, cellWidth: CGFloat,
                          lineTop: CGFloat, lineHeight: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color,
        ]
        let glyph = mark as NSString
        let glyphSize = glyph.size(withAttributes: attrs)
        // Center in the character cell (a tab's cell spans to its stop; a line
        // ending has ~0 advance and draws just past the last glyph).
        let width = cellWidth > 0 ? cellWidth : glyphSize.width
        let x = cellX + (width - glyphSize.width) / 2
        let y = lineTop + (lineHeight - glyphSize.height) / 2
        glyph.draw(at: CGPoint(x: x, y: y), withAttributes: attrs)
    }
}
