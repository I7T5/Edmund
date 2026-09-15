import Testing
import AppKit
@testable import EdmundCore

// The invisibles drawing itself is visual (screencapture-verified); these cover
// the pure decision logic: which characters classify as which invisible, and
// the per-category gating.
struct InvisiblesTests {

    @Test func classifiesCommonWhitespace() {
        #expect(InvisibleCategory.of(0x20) == .space)
        #expect(InvisibleCategory.of(0x09) == .tab)
        #expect(InvisibleCategory.of(0x0A) == .lineEnding)   // LF
        #expect(InvisibleCategory.of(0x0D) == .lineEnding)   // CR
        #expect(InvisibleCategory.of(0x2028) == .lineEnding) // line separator
    }

    @Test func classifiesOtherBuckets() {
        #expect(InvisibleCategory.of(0xA0) == .otherWhitespace)   // NBSP
        #expect(InvisibleCategory.of(0x3000) == .otherWhitespace) // ideographic space
        #expect(InvisibleCategory.of(0x00) == .otherControl)      // NUL
        #expect(InvisibleCategory.of(0x7F) == .otherControl)      // DEL
    }

    @Test func visibleGlyphsAreNil() {
        #expect(InvisibleCategory.of(0x41) == nil)   // 'A'
        #expect(InvisibleCategory.of(0x2192) == nil) // '→' is a real glyph, not a mark
    }

    @Test func perCategoryGating() {
        let onlySpace = InvisiblesConfig(lineEnding: false, tab: false, space: true,
                                         otherWhitespace: false, otherControl: false)
        #expect(onlySpace.draws(.space))
        #expect(!onlySpace.draws(.tab))
        #expect(!onlySpace.draws(.lineEnding))

        let noSpace = InvisiblesConfig(lineEnding: true, tab: true, space: false,
                                       otherWhitespace: true, otherControl: true)
        #expect(!noSpace.draws(.space))
        #expect(noSpace.draws(.tab))
        #expect(noSpace.draws(.otherWhitespace))
    }

    @Test func drawsAnythingReflectsToggles() {
        #expect(InvisiblesConfig().drawsAnything)
        let allOff = InvisiblesConfig(lineEnding: false, tab: false, space: false,
                                      otherWhitespace: false, otherControl: false)
        #expect(!allOff.drawsAnything)
    }
}
