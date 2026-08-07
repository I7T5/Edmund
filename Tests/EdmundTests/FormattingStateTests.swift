import Testing
import AppKit
@testable import EdmundCore

/// What the format bar lights up from: which formatting is in effect where the
/// caret or selection currently sits.
@MainActor @Suite("Formatting state")
struct FormattingStateTests {

    private func mk(_ content: String, _ sel: NSRange) -> EditorTextView {
        let e = makeEditor()
        e.loadContent(content)
        e.setSelectedRange(sel)
        return e
    }

    private func active(_ content: String, _ sel: NSRange) -> Set<Selector> {
        mk(content, sel).activeFormattingActions()
    }

    private let bold = #selector(EditorTextView.formatBold(_:))
    private let italic = #selector(EditorTextView.formatItalic(_:))
    private let strike = #selector(EditorTextView.formatStrikethrough(_:))
    private let highlight = #selector(EditorTextView.formatHighlight(_:))
    private let sub = #selector(EditorTextView.formatSubscript(_:))
    private let bullet = #selector(EditorTextView.formatBulletedList(_:))
    private let checklist = #selector(EditorTextView.formatChecklist(_:))
    private let numbered = #selector(EditorTextView.formatNumberedList(_:))
    private let quote = #selector(EditorTextView.formatBlockQuote(_:))

    // MARK: - Caret inside

    @Test func caretInsideBoldIsBold() {
        let a = active("a **word** b", NSRange(location: 5, length: 0))
        #expect(a.contains(bold))
        #expect(!a.contains(italic))
    }

    @Test func caretInsideItalicIsItalic() {
        let a = active("a *word* b", NSRange(location: 4, length: 0))
        #expect(a.contains(italic))
        #expect(!a.contains(bold))
    }

    /// `***x***` is both, and the run length is the only thing that says so —
    /// a plain search for `*` would find the inner star of the `**`.
    @Test func tripleStarIsBoldAndItalic() {
        let a = active("a ***word*** b", NSRange(location: 6, length: 0))
        #expect(a.contains(bold))
        #expect(a.contains(italic))
    }

    @Test func caretOutsideSpanIsNotActive() {
        let a = active("a **word** b", NSRange(location: 0, length: 0))
        #expect(!a.contains(bold))
    }

    /// The star pairing must not read `a **b** c **d** e` as one long span, or
    /// the gap between the two bold words would report as bold.
    @Test func caretBetweenTwoSpansIsNotActive() {
        let a = active("**b** X **d**", NSRange(location: 6, length: 0))
        #expect(!a.contains(bold))
    }

    // MARK: - Selection

    @Test func selectionInsideSpanIsActive() {
        let a = active("a **word** b", NSRange(location: 4, length: 4))
        #expect(a.contains(bold))
    }

    /// Selecting the delimiters too still counts — pressing the button in that
    /// state is what unwraps it.
    @Test func selectionSwallowingTheWholeSpanIsActive() {
        let a = active("a **word** b", NSRange(location: 2, length: 8))
        #expect(a.contains(bold))
    }

    @Test func selectionSpillingPastTheSpanIsNotActive() {
        let a = active("a **word** b", NSRange(location: 5, length: 6))
        #expect(!a.contains(bold))
    }

    // MARK: - Other inline delimiters

    @Test func strikeHighlightAndSubscriptEachReportThemselves() {
        #expect(active("a ~~x~~ b", NSRange(location: 5, length: 0)).contains(strike))
        #expect(active("a ==x== b", NSRange(location: 5, length: 0)).contains(highlight))
        #expect(active("a <sub>x</sub> b", NSRange(location: 8, length: 0)).contains(sub))
    }

    @Test func highlightDoesNotLeakIntoStrikethrough() {
        let a = active("a ==x== b", NSRange(location: 5, length: 0))
        #expect(!a.contains(strike))
        #expect(!a.contains(bold))
    }

    // MARK: - Line prefixes

    @Test func listAndQuoteLinesReportTheirType() {
        #expect(active("- item", NSRange(location: 3, length: 0)).contains(bullet))
        #expect(active("1. item", NSRange(location: 4, length: 0)).contains(numbered))
        #expect(active("- [ ] task", NSRange(location: 8, length: 0)).contains(checklist))
        #expect(active("> quoted", NSRange(location: 4, length: 0)).contains(quote))
    }

    /// A checklist is not a plain bullet — the two buttons must not both light.
    @Test func checklistIsNotABullet() {
        let a = active("- [ ] task", NSRange(location: 8, length: 0))
        #expect(a.contains(checklist))
        #expect(!a.contains(bullet))
    }

    /// The toggles only clear a prefix when every selected line carries it, so
    /// the on-state has to agree.
    @Test func mixedSelectionIsNotActive() {
        let a = active("- one\nplain\n", NSRange(location: 0, length: 11))
        #expect(!a.contains(bullet))
    }

    // MARK: - Thematic break

    @Test func thematicBreakLineReportsItself() {
        let thematic = #selector(EditorTextView.formatThematicBreak(_:))
        #expect(active("---", NSRange(location: 1, length: 0)).contains(thematic))
        #expect(!active("- item", NSRange(location: 3, length: 0)).contains(thematic))
        #expect(!active("--- trailing", NSRange(location: 1, length: 0)).contains(thematic))
    }

    // MARK: - Pulldown state

    @Test func headingLevelReportsTheCaretsLine() {
        #expect(mk("## Title", NSRange(location: 4, length: 0)).activeHeadingLevel() == 2)
        #expect(mk("Body", NSRange(location: 2, length: 0)).activeHeadingLevel() == 0)
        #expect(mk("###### Six", NSRange(location: 8, length: 0)).activeHeadingLevel() == 6)
    }

    /// Mixed levels have no single answer, so nothing is ticked — the same rule
    /// `applyHeadingLevel` uses to decide a level is already applied.
    @Test func mixedHeadingLevelsReportNothing() {
        #expect(mk("# One\n## Two\n", NSRange(location: 0, length: 12)).activeHeadingLevel() == nil)
    }

    @Test func calloutTypeReportsTheHeaderLine() {
        #expect(mk("> [!NOTE]", NSRange(location: 3, length: 0)).activeCalloutType() == "note")
        #expect(mk("> [!tip]", NSRange(location: 3, length: 0)).activeCalloutType() == "tip")
        #expect(mk("> plain quote", NSRange(location: 3, length: 0)).activeCalloutType() == nil)
        #expect(mk("Body", NSRange(location: 2, length: 0)).activeCalloutType() == nil)
    }

    /// Obsidian's fold markers and a custom title still name the same type,
    /// because parsing goes through the renderer's own matcher.
    @Test func foldedAndTitledCalloutsStillReportTheirType() {
        #expect(mk("> [!warning]-", NSRange(location: 3, length: 0)).activeCalloutType() == "warning")
        #expect(mk("> [!info] Custom", NSRange(location: 3, length: 0)).activeCalloutType() == "info")
    }

    // MARK: - Robustness

    @Test func emptyDocumentAndDocumentEndAreSafe() {
        #expect(active("", NSRange(location: 0, length: 0)).isEmpty)
        #expect(!active("abc", NSRange(location: 3, length: 0)).contains(bold))
    }

    /// Emphasis does not carry across a blank line, and the scan is bounded by
    /// the paragraph so a stray delimiter elsewhere cannot light the button.
    @Test func unclosedDelimiterOnAnotherLineDoesNotLeak() {
        let a = active("**open\n\nplain line", NSRange(location: 12, length: 0))
        #expect(!a.contains(bold))
    }
}
