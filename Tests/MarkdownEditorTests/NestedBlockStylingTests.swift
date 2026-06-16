import Testing
import AppKit
@testable import MarkdownEditorCore

// Nested block styling: containers decide whether their nested *blocks* render.
//   - Code block  → literal (covered elsewhere; CodeBlock never descends).
//   - Plain quote → nested blocks literal; inline still renders.
//   - Callout     → everything renders (recursive sub-render).

private func isMonospaced(_ f: NSFont?) -> Bool {
    f?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false
}

private func isBold(_ f: NSFont?) -> Bool {
    guard let f else { return false }
    return NSFontManager.shared.traits(of: f).contains(.boldFontMask)
}

private func decorationList(at offset: Int, in s: NSAttributedString) -> BlockDecorationList? {
    guard offset < s.length else { return nil }
    return s.attribute(.blockDecoration, at: offset, effectiveRange: nil) as? BlockDecorationList
}

@Suite("Nested — plain block quote keeps nested blocks literal")
@MainActor
struct PlainQuoteNestedTests {

    @Test("Inline emphasis inside a quote still renders")
    func inlineStillRenders() {
        let s = makeEditor().styleBlock("> **important** text")
        let loc = (s.string as NSString).range(of: "important").location
        #expect(isBold(s.attribute(.font, at: loc, effectiveRange: nil) as? NSFont))
    }

    @Test("A fenced code block inside a quote stays literal (not monospaced)")
    func nestedCodeLiteral() {
        let s = makeEditor().styleBlock("> intro\n> ```swift\n> let x = 1\n> ```")
        let loc = (s.string as NSString).range(of: "let x").location
        #expect(!isMonospaced(s.attribute(.font, at: loc, effectiveRange: nil) as? NSFont))
    }

    @Test("A list item inside a quote stays literal (no bullet overlay, marker visible)")
    func nestedListLiteral() {
        let s = makeEditor().styleBlock("> intro\n> - item")
        let ns = s.string as NSString
        // No list bullet/overlay is emitted anywhere in the block.
        var hasOverlay = false
        s.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in if v != nil { hasOverlay = true; stop.pointee = true } }
        #expect(!hasOverlay)
        // The raw "-" marker is still visible text, not a hidden marker.
        let dash = ns.range(of: "- item").location
        #expect(!isHidden(at: dash, in: s))
    }

    @Test("A heading inside a quote stays literal (not enlarged/bold)")
    func nestedHeadingLiteral() {
        let s = makeEditor().styleBlock("> intro\n> # Heading")
        let loc = (s.string as NSString).range(of: "Heading").location
        let f = s.attribute(.font, at: loc, effectiveRange: nil) as? NSFont
        #expect(!isBold(f))
    }
}

@Suite("Nested — callout renders inner blocks")
@MainActor
struct CalloutNestedTests {

    @Test("A code block inside a callout renders (closing fence detected, monospaced)")
    func codeInCallout() {
        let s = makeEditor().styleBlock(
            "> [!note] Note\n> Body\n> ```python\n> def f():\n>     pass\n> ```")
        let ns = s.string as NSString
        #expect(isMonospaced(s.attribute(.font, at: ns.range(of: "def f").location,
                                         effectiveRange: nil) as? NSFont))
        // The closing fence must be recognized: `pass` is inside the code, also mono.
        #expect(isMonospaced(s.attribute(.font, at: ns.range(of: "pass").location,
                                         effectiveRange: nil) as? NSFont))
    }

    @Test("A plain block quote inside a callout draws a left bar inside the box")
    func quoteInCallout() {
        let s = makeEditor().styleBlock("> [!note] Note\n> > quoted line\n> > more")
        let loc = (s.string as NSString).range(of: "quoted line").location
        let list = decorationList(at: loc, in: s)
        #expect(list != nil)
        // Outer callout box plus the inner quote's left bar.
        #expect(list?.decorations.contains { if case .box = $0.kind { return true }; return false } == true)
        #expect(list?.decorations.contains { if case .leftBar = $0.kind { return true }; return false } == true)
    }

    @Test("A callout inside a callout stacks two boxes, the inner one inset")
    func calloutInCallout() {
        let editor = makeEditor()
        let s = editor.styleBlock("> [!note] Outer\n> > [!tip] Inner\n> > tip body")
        let loc = (s.string as NSString).range(of: "tip body").location
        let list = decorationList(at: loc, in: s)
        #expect(list != nil)
        let boxes = list?.decorations.filter { if case .box = $0.kind { return true }; return false } ?? []
        #expect(boxes.count == 2)
        // Outermost box at inset 0, inner box inset by one marker step.
        #expect(boxes.first?.inset == 0)
        #expect((boxes.last?.inset ?? 0) > 0)
    }

    @Test("A nested callout at the parent's last line keeps both boxes' bottom padding")
    func nestedBottomPadding() {
        // The last line carries the inner Tip box *and* the outer Note box, each
        // with its own bottomPad, so the drawing can show the Tip's padding and
        // then the Note's padding below it (summed frame growth).
        let s = makeEditor().styleBlock("> [!note] Note\n> Hello\n> > [!tip] Tip\n> > nested")
        let loc = (s.string as NSString).range(of: "nested").location
        let list = s.attribute(.blockDecoration, at: loc, effectiveRange: nil) as? BlockDecorationList
        #expect(list != nil)
        let pads = (list?.decorations ?? []).compactMap { d -> CGFloat? in
            if case .box(_, _, _, _, let bp) = d.kind { return bp }
            return nil
        }
        #expect(pads.count == 2)
        #expect(pads.allSatisfy { $0 > 0 })
    }

    @Test("A checklist inside a callout renders its checkbox as an overlay")
    func checklistInCallout() {
        let s = makeEditor().styleBlock("> [!note] Note\n> - [ ] task")
        var hasOverlay = false
        s.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in if v != nil { hasOverlay = true; stop.pointee = true } }
        #expect(hasOverlay)
    }

    @Test("A table inside a callout renders table-row chrome")
    func tableInCallout() {
        let s = makeEditor().styleBlock(
            "> [!note] Note\n> | a | b |\n> | --- | --- |\n> | 1 | 2 |")
        let loc = (s.string as NSString).range(of: "1").location
        let list = decorationList(at: loc, in: s)
        #expect(list?.decorations.contains {
            if case .tableRow = $0.kind { return true }; return false
        } == true)
    }

    @Test("Display math inside a callout renders an overlay image")
    func mathInCallout() {
        let s = makeEditor().styleBlock("> [!note] Note\n> $$x^2$$")
        var hasOverlay = false
        s.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in if v != nil { hasOverlay = true; stop.pointee = true } }
        #expect(hasOverlay)
    }

    @Test("An active callout shows raw '>' source for editing (no box, no overlay)")
    func activeCalloutShowsRawSource() {
        let editor = makeEditor()
        // cursorPosition inside the callout → editing form: raw `>` visible
        // (dimmed), no box decoration, no header overlay.
        let s = editor.styleBlock("> [!note] Note\n> body\n> > [!tip] Tip\n> > tip body",
                                  cursorPosition: 3)
        // No callout box anywhere.
        var hasBox = false
        s.enumerateAttribute(.blockDecoration, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in
            let kinds = (v as? BlockDecorationList)?.decorations ?? [v as? BlockDecoration].compactMap { $0 }
            if kinds.contains(where: { if case .box = $0.kind { return true }; return false }) {
                hasBox = true; stop.pointee = true
            }
        }
        #expect(!hasBox)
        // No header overlay (icon/title image).
        var hasOverlay = false
        s.enumerateAttribute(.fragmentOverlay, in: NSRange(location: 0, length: s.length),
                             options: []) { v, _, stop in if v != nil { hasOverlay = true; stop.pointee = true } }
        #expect(!hasOverlay)
        // The leading `>` of the active callout is visible (dimmed), not hidden.
        #expect(!isHidden(at: 0, in: s))
        // The `[!note]` marker text is present and visible (editable).
        let bracket = (s.string as NSString).range(of: "[!note]").location
        #expect(!isHidden(at: bracket, in: s))
    }

    @Test("A heading inside a callout renders (bold/enlarged)")
    func headingRendersInCallout() {
        let editor = makeEditor()
        let s = editor.styleBlock("> [!note] Note\n> # Inside\n> body")
        let f = s.attribute(.font, at: (s.string as NSString).range(of: "Inside").location,
                            effectiveRange: nil) as? NSFont
        #expect(isBold(f))
        #expect((f?.pointSize ?? 0) > editor.bodyFont.pointSize)
    }

    @Test("Strict membership: a single-'>' line is not part of a '> >' nested callout")
    func nestedMembershipStrict() {
        // `> note body` carries one `>`, so it belongs to the Note, not the Tip
        // (which needs `> >`). It must render with only the Note box.
        let s = makeEditor().styleBlock("> [!note] Note\n> > [!tip] Tip\n> note body")
        let loc = (s.string as NSString).range(of: "note body").location
        let deco = s.attribute(.blockDecoration, at: loc, effectiveRange: nil)
        // A single decoration (the Note box) — not a stack that includes the Tip box.
        if let list = deco as? BlockDecorationList {
            #expect(list.decorations.count == 1)
        } else {
            #expect(deco is BlockDecoration)
        }
    }

    @Test("A heading inside a callout is NOT a document heading")
    func headingInCalloutNotDocumentHeading() {
        let editor = makeEditor()
        editor.loadContent("intro\n\n> [!note] Note\n> # Inside\n> body\n\n## After")
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.scrollToHeading("Inside")        // not a real heading block
        #expect(editor.selectedRange().location == 2)   // caret unmoved
        // A genuine top-level heading is still found.
        editor.scrollToHeading("After")
        let after = (editor.rawSource as NSString).range(of: "## After").location
        #expect(editor.selectedRange().location == after)
    }
}

@Suite("Nested — decoration model")
struct DecorationModelTests {

    private func box(inset: CGFloat) -> BlockDecoration {
        BlockDecoration(.box(background: .clear, borderColor: nil,
                             borderEdges: [], borderWidth: 0, bottomPad: 0), inset: inset)
    }

    @Test("Box inset participates in equality")
    func boxInsetEquality() {
        #expect(box(inset: 0) == box(inset: 0))
        #expect(box(inset: 0) != box(inset: 5))
    }

    @Test("BlockDecorationList compares its decorations by value")
    func listEquality() {
        let a = BlockDecorationList([box(inset: 0), box(inset: 5)])
        let b = BlockDecorationList([box(inset: 0), box(inset: 5)])
        let c = BlockDecorationList([box(inset: 0)])
        #expect(a == b)
        #expect(a != c)
    }
}
