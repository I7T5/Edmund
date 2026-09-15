import Testing
import AppKit
@testable import EdmundCore

/// Emphasis nested only *partway* inside its opposite — `**a *b* c**` or
/// `*a **b** c*` — used to drop the inner run: the walker emitted the outer
/// trait, saw it was already inside the opposite construct, and just descended
/// without emitting the inner one. Only the whole-range `***…***` form worked.
/// This is the general inline parser, so it fixes tables too (cells style
/// through the same `styleBlock`).

@Suite("Nested emphasis")
@MainActor
struct NestedEmphasisTests {

    private func traits(_ s: NSAttributedString, of needle: String) -> NSFontDescriptor.SymbolicTraits {
        let r = (s.string as NSString).range(of: needle)
        guard r.location != NSNotFound,
              let f = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        else { return [] }
        return f.fontDescriptor.symbolicTraits
    }

    @Test("Italic nested inside bold is bold and italic")
    func italicInsideBold() {
        let editor = makeEditor()
        let styled = editor.styleBlock("**bold *inner* tail**")
        // The inner run carries both traits; the plain bold run only bold.
        #expect(traits(styled, of: "inner").contains(.bold))
        #expect(traits(styled, of: "inner").contains(.italic))
        #expect(traits(styled, of: "bold").contains(.bold))
        #expect(!traits(styled, of: "bold").contains(.italic))
    }

    @Test("Bold nested inside italic is bold and italic")
    func boldInsideItalic() {
        let editor = makeEditor()
        let styled = editor.styleBlock("*italic **inner** tail*")
        #expect(traits(styled, of: "inner").contains(.bold))
        #expect(traits(styled, of: "inner").contains(.italic))
        #expect(traits(styled, of: "italic").contains(.italic))
        #expect(!traits(styled, of: "italic").contains(.bold))
    }

    /// The whole-range form still resolves to bold+italic throughout.
    @Test("*** throughout is bold and italic")
    func wholeRangeBoldItalic() {
        let editor = makeEditor()
        let styled = editor.styleBlock("***both***")
        #expect(traits(styled, of: "both").contains(.bold))
        #expect(traits(styled, of: "both").contains(.italic))
    }

    /// The same, rendered inside a table cell (styles through `styleBlock`).
    @Test("Nested emphasis renders inside a table cell")
    func nestedEmphasisInACell() {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent("| a | b |\n| --- | --- |\n| **bold *inner* x** | y |\n")
        ensureFullLayout(editor); layOutViewport(editor)
        guard let storage = editor.textStorage else {
            Issue.record("no storage")
            return
        }
        let full = NSAttributedString(attributedString: storage)
        #expect(traits(full, of: "inner").contains(.bold))
        #expect(traits(full, of: "inner").contains(.italic))
    }
}
