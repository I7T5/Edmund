import Testing
import AppKit
@testable import EdmundCore

// MARK: - Coordinate Mapping

@Suite("EditorTextView — Coordinate Mapping")
struct EditorCoordinateTests {

    @Test("blockIndexForRawOffset returns correct index")
    @MainActor func blockIndexMapping() {
        let editor = makeEditor()
        editor.rawSource = "hello\nworld"
        editor.blocks = BlockParser.parse(editor.rawSource)
        editor.recompose(cursorInRaw: 0)

        #expect(editor.blockIndexForRawOffset(0) == 0)
        #expect(editor.blockIndexForRawOffset(3) == 0)
        #expect(editor.blockIndexForRawOffset(5) == 0)
        #expect(editor.blockIndexForRawOffset(6) == 1)
        #expect(editor.blockIndexForRawOffset(11) == 1)
    }

    @Test("blockIndexForRawOffset clamps to last block")
    @MainActor func blockIndexClamp() {
        let editor = makeEditor()
        editor.rawSource = "abc"
        editor.blocks = BlockParser.parse(editor.rawSource)
        editor.recompose(cursorInRaw: 0)

        #expect(editor.blockIndexForRawOffset(100) == 0)
    }
}

// MARK: - Word-Level Styling

@Suite("EditorTextView — Word-Level Styling")
struct EditorStylingTests {

    // MARK: - String Preservation

    @Test("Rendered marker cache reuses matches and separates visual variants")
    @MainActor func renderedMarkerOverlayReuse() throws {
        let editor = makeEditor()

        let firstBullet = try #require(
            editor.styleBlock("- first")
                .attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                as? FragmentOverlay
        )
        let secondBullet = try #require(
            editor.styleBlock("- second")
                .attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                as? FragmentOverlay
        )
        #expect(firstBullet === secondBullet)

        func calloutOverlay(
            _ source: String,
            in editor: EditorTextView
        ) throws -> FragmentOverlay {
            let styled = editor.styleBlock(source)
            var overlay: FragmentOverlay?
            styled.enumerateAttribute(
                .fragmentOverlay,
                in: NSRange(location: 0, length: styled.length)
            ) { value, _, stop in
                guard let value = value as? FragmentOverlay else { return }
                overlay = value
                stop.pointee = true
            }
            return try #require(overlay)
        }

        let firstCallout = try calloutOverlay("> [!note]\n> first", in: editor)
        let secondCallout = try calloutOverlay("> [!note]\n> second", in: editor)
        #expect(firstCallout === secondCallout)

        let firstMath = try #require(editor.mathOverlay(
            latex: "x_1 = y",
            display: true,
            fontSize: editor.bodyFont.pointSize
        ))
        let secondMath = try #require(editor.mathOverlay(
            latex: "x_1 = y",
            display: true,
            fontSize: editor.bodyFont.pointSize
        ))
        #expect(firstMath === secondMath)

        let nextEditor = makeEditor()
        let nextBullet = try #require(
            nextEditor.styleBlock("- next")
                .attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                as? FragmentOverlay
        )
        #expect(firstBullet === nextBullet)

        let nextCallout = try calloutOverlay("> [!note]\n> next", in: nextEditor)
        #expect(firstCallout === nextCallout)

        let nextMath = try #require(nextEditor.mathOverlay(
            latex: "x_1 = y",
            display: true,
            fontSize: nextEditor.bodyFont.pointSize
        ))
        #expect(firstMath === nextMath)

        let largerEditor = makeEditor()
        var largerTheme = largerEditor.theme
        largerTheme.fontSize += 4
        largerEditor.theme = largerTheme
        let largerBullet = try #require(
            largerEditor.styleBlock("- larger")
                .attribute(.fragmentOverlay, at: 0, effectiveRange: nil)
                as? FragmentOverlay
        )
        #expect(firstBullet !== largerBullet)
        #expect(firstBullet.bounds != largerBullet.bounds)

        let lightEditor = makeEditor()
        lightEditor.appearance = NSAppearance(named: .aqua)
        let lightCallout = try calloutOverlay("> [!important]\n> light", in: lightEditor)
        let darkEditor = makeEditor()
        darkEditor.appearance = NSAppearance(named: .darkAqua)
        let darkCallout = try calloutOverlay("> [!important]\n> dark", in: darkEditor)
        #expect(lightCallout !== darkCallout)

        let customColorEditor = makeEditor()
        customColorEditor.calloutStyleOverrides["note"] = CalloutStyle(
            iconName: "pencil",
            colorHex: "#E11900"
        )
        let customColorCallout = try calloutOverlay(
            "> [!note] Custom title\n> body",
            in: customColorEditor
        )
        let defaultColorCallout = try calloutOverlay(
            "> [!note] Custom title\n> body",
            in: editor
        )
        #expect(customColorCallout !== defaultColorCallout)
        #expect(customColorCallout.pathColor != defaultColorCallout.pathColor)

        let noLigatureEditor = makeEditor()
        var noLigatureTheme = noLigatureEditor.theme
        noLigatureTheme.standardLigatures = false
        noLigatureEditor.theme = noLigatureTheme
        let noLigatureCallout = try calloutOverlay(
            "> [!note]\n> body",
            in: noLigatureEditor
        )
        #expect(firstCallout !== noLigatureCallout)

        let wideLatex = "a_{10}x^{10}+a_9x^9+a_8x^8+a_7x^7+a_6x^6+a_5x^5+a_4x^4+a_3x^3+a_2x^2+a_1x+a_0"
        let wideMathEditor = makeEditor()
        wideMathEditor.textContainer?.widthTracksTextView = false
        wideMathEditor.textContainer?.size = NSSize(
            width: 500,
            height: CGFloat.greatestFiniteMagnitude
        )
        let wideMath = try #require(wideMathEditor.mathOverlay(
            latex: wideLatex,
            display: true,
            fontSize: 24
        ))
        let narrowMathEditor = makeEditor()
        narrowMathEditor.textContainer?.widthTracksTextView = false
        narrowMathEditor.textContainer?.size = NSSize(
            width: 240,
            height: CGFloat.greatestFiniteMagnitude
        )
        let narrowMath = try #require(narrowMathEditor.mathOverlay(
            latex: wideLatex,
            display: true,
            fontSize: 24
        ))
        #expect(wideMath !== narrowMath)
        #expect(wideMath.bounds.width > narrowMath.bounds.width)
    }

    @Test("Custom attribute values do not collapse into constant hash buckets")
    @MainActor func customAttributeHashDispersion() {
        let decorations = (0..<32).map { index in
            BlockDecoration(.box(
                background: NSColor(
                    srgbRed: CGFloat(index) / 31,
                    green: 0.25,
                    blue: 0.75,
                    alpha: 1
                ),
                borderColor: nil,
                borderEdges: [],
                borderWidth: 3,
                bottomPad: CGFloat(index)
            ))
        }
        #expect(Set(decorations.map(\.hash)).count > 28)

        let overlays = (0..<32).map { index in
            FragmentOverlay(
                image: NSImage(size: NSSize(width: index + 1, height: index + 1)),
                bounds: CGRect(x: 0, y: 0, width: 16, height: 16)
            )
        }
        #expect(Set(overlays.map(\.hash)).count > 28)

        let pathOverlays = (0..<32).map { index in
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: CGPoint(x: index + 1, y: index * 2 + 1))
            return FragmentOverlay(
                path: path,
                color: .systemBlue,
                lineWidth: 2,
                bounds: CGRect(x: 0, y: 0, width: 16, height: 16)
            )
        }
        #expect(Set(pathOverlays.map(\.hash)).count > 28)

        let geometryWraps = (0..<32).map {
            TableCellWrap(
                styled: NSAttributedString(
                    string: "cell",
                    attributes: [.font: NSFont.systemFont(ofSize: 14)]
                ),
                x: CGFloat($0),
                contentWidth: 120
            )
        }
        #expect(Set(geometryWraps.map(\.hash)).count > 28)

        let styleWraps = (0..<32).map { index in
            TableCellWrap(
                styled: NSAttributedString(
                    string: "cell",
                    attributes: [
                        .foregroundColor: NSColor(
                            srgbRed: CGFloat(index) / 31,
                            green: 0.25,
                            blue: 0.75,
                            alpha: 1
                        ),
                    ]
                ),
                x: 20,
                contentWidth: 120
            )
        }
        #expect(Set(styleWraps.map(\.hash)).count > 28)
    }

    @Test("Equal custom attribute values have equal hashes")
    @MainActor func customAttributeHashEqualityContract() {
        let firstDecoration = BlockDecoration(.leftBar(color: .systemBlue, width: 2))
        let secondDecoration = BlockDecoration(.leftBar(color: .systemBlue, width: 2))
        #expect(firstDecoration == secondDecoration)
        #expect(firstDecoration.hash == secondDecoration.hash)

        func makePathOverlay() -> FragmentOverlay {
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addCurve(
                to: CGPoint(x: 8, y: 12),
                control1: CGPoint(x: 2, y: 4),
                control2: CGPoint(x: 6, y: 10)
            )
            return FragmentOverlay(
                path: path,
                color: .systemBlue,
                lineWidth: 2,
                bounds: CGRect(x: 0, y: 0, width: 16, height: 16)
            )
        }
        let firstOverlay = makePathOverlay()
        let secondOverlay = makePathOverlay()
        #expect(firstOverlay == secondOverlay)
        #expect(firstOverlay.hash == secondOverlay.hash)

        let mutablePath = CGMutablePath()
        mutablePath.move(to: .zero)
        mutablePath.addLine(to: CGPoint(x: 8, y: 12))
        let frozenOverlay = FragmentOverlay(
            path: mutablePath,
            color: .systemBlue,
            lineWidth: 2,
            bounds: CGRect(x: 0, y: 0, width: 16, height: 16)
        )
        let frozenHash = frozenOverlay.hash
        mutablePath.addLine(to: CGPoint(x: 16, y: 24))
        #expect(frozenOverlay.hash == frozenHash)
        #expect(frozenOverlay.path != mutablePath)

        let firstStyled = NSAttributedString(
            string: "cell",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let secondStyled = NSAttributedString(
            string: "cell",
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        )
        let firstWrap = TableCellWrap(styled: firstStyled, x: 20, contentWidth: 120)
        let secondWrap = TableCellWrap(styled: secondStyled, x: 20, contentWidth: 120)
        #expect(firstWrap == secondWrap)
        #expect(firstWrap.hash == secondWrap.hash)

        let differentlyStyled = TableCellWrap(
            styled: NSAttributedString(
                string: "cell",
                attributes: [.font: NSFont.boldSystemFont(ofSize: 14)]
            ),
            x: 20,
            contentWidth: 120
        )
        #expect(firstWrap != differentlyStyled)
        #expect(firstWrap.hash != differentlyStyled.hash)

        let mutableStyled = NSMutableAttributedString(string: "cell")
        let frozenWrap = TableCellWrap(styled: mutableStyled, x: 20, contentWidth: 120)
        let frozenWrapHash = frozenWrap.hash
        mutableStyled.addAttribute(
            .foregroundColor,
            value: NSColor.systemRed,
            range: NSRange(location: 0, length: mutableStyled.length)
        )
        #expect(frozenWrap.hash == frozenWrapHash)
        #expect(frozenWrap.styled != mutableStyled)
    }

    @Test("styleBlock preserves raw text (no stripping)")
    @MainActor func preservesRawText() {
        let editor = makeEditor()
        #expect(editor.styleBlock("**bold**").string == "**bold**")
        #expect(editor.styleBlock("*italic*").string == "*italic*")
        #expect(editor.styleBlock("`code`").string == "`code`")
        #expect(editor.styleBlock("# Heading").string == "# Heading")
        #expect(editor.styleBlock("> quote").string == "> quote")
        #expect(editor.styleBlock("- item").string == "- item")
    }

    @Test("Plain text renders unchanged")
    @MainActor func plainText() {
        let editor = makeEditor()
        let styled = editor.styleBlock("just plain text")
        #expect(styled.string == "just plain text")
    }

    @Test("Empty string produces empty attributed string")
    @MainActor func emptyString() {
        let editor = makeEditor()
        #expect(editor.styleBlock("").string == "")
    }

    // MARK: - Inline Delimiter Hiding (no cursor)

    @Test("Bold delimiters are hidden when cursor is outside")
    @MainActor func boldDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("**bold**")
        // ** at positions 0,1 and 6,7 should be hidden
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 6, in: styled))
        #expect(isHidden(at: 7, in: styled))
    }

    @Test("Bold content has bold font")
    @MainActor func boldContentFont() {
        let editor = makeEditor()
        let styled = editor.styleBlock("**bold**")
        let f = styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
    }

    @Test("Italic delimiters are hidden when cursor is outside")
    @MainActor func italicDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("*italic*")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 7, in: styled))
    }

    @Test("Italic content has italic font")
    @MainActor func italicContentFont() {
        let editor = makeEditor()
        let styled = editor.styleBlock("*italic*")
        let f = styled.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(NSFontManager.shared.traits(of: f!).contains(.italicFontMask))
    }

    @Test("Bold-italic delimiters are hidden when cursor is outside")
    @MainActor func boldItalicDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("***both***")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 2, in: styled))
        #expect(isHidden(at: 7, in: styled))
    }

    @Test("Strikethrough delimiters are hidden when cursor is outside")
    @MainActor func strikethroughDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("~~deleted~~")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 9, in: styled))
        #expect(isHidden(at: 10, in: styled))
    }

    @Test("Strikethrough content has strikethrough attribute")
    @MainActor func strikethroughAttribute() {
        let editor = makeEditor()
        let styled = editor.styleBlock("~~deleted~~")
        let val = styled.attribute(.strikethroughStyle, at: 2, effectiveRange: nil)
        #expect(val != nil)
    }

    @Test("Highlight delimiters are hidden when cursor is outside")
    @MainActor func highlightDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("==important==")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 1, in: styled))
        #expect(isHidden(at: 11, in: styled))
        #expect(isHidden(at: 12, in: styled))
    }

    @Test("Highlight content has background color")
    @MainActor func highlightBackground() {
        let editor = makeEditor()
        let styled = editor.styleBlock("==important==")
        let val = styled.attribute(.backgroundColor, at: 2, effectiveRange: nil)
        #expect(val != nil)
    }

    @Test("Code delimiters are hidden when cursor is outside")
    @MainActor func codeDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("`code`")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 5, in: styled))
    }

    @Test("Inline code content uses body text color")
    @MainActor func codeColor() {
        let editor = makeEditor()
        let styled = editor.styleBlock("`code`")
        let color = styled.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        #expect(color == editor.foregroundColor)
    }

    @Test("Inline code content has monospace font")
    @MainActor func codeMonospace() {
        let editor = makeEditor()
        let styled = editor.styleBlock("`code`")
        let f = styled.attribute(.font, at: 1, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(f!.isFixedPitch)
    }

    @Test("Inline code content has background color")
    @MainActor func codeBackground() {
        let editor = makeEditor()
        let styled = editor.styleBlock("`code`")
        let bg = styled.attribute(.backgroundColor, at: 1, effectiveRange: nil) as? NSColor
        #expect(bg != nil)
    }

    @Test("Link delimiters are hidden when cursor is outside")
    @MainActor func linkDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("[text](url)")
        // "[" at 0 should be hidden
        #expect(isHidden(at: 0, in: styled))
        // "](url)" at 5-10 should be hidden
        #expect(isHidden(at: 5, in: styled))
    }

    @Test("Link content has accent color and underline")
    @MainActor func linkStyling() {
        let editor = makeEditor()
        let styled = editor.styleBlock("[text](url)")
        // "text" is at positions 1-4
        let color = styled.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor
        #expect(color != nil)
        let underline = styled.attribute(.underlineStyle, at: 1, effectiveRange: nil)
        #expect(underline != nil)
    }

    @Test("Link text carries its destination URL for cmd+click")
    @MainActor func linkCarriesURL() {
        let editor = makeEditor()
        let styled = editor.styleBlock("[text](https://example.com)")
        // "text" is at positions 1-4; the URL attribute should cover it.
        let dest = styled.attribute(.editorLinkURL, at: 1, effectiveRange: nil) as? String
        #expect(dest == "https://example.com")
        // The delimiters/destination source carry no URL attribute.
        #expect(styled.attribute(.editorLinkURL, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Image delimiters are hidden when cursor is outside")
    @MainActor func imageDelimitersHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("![alt](url)")
        // "![" at 0-1 should be hidden
        #expect(isHidden(at: 0, in: styled))
    }

    @Test("Image content has accent color and italic font while its load is pending")
    @MainActor func imageStyling() {
        // A resolvable-but-unresolved destination (a `.notFound`/`.notAnImage`/
        // `.blockedBySetting` one) now gets a placeholder overlay instead — see
        // ImageRenderingTests. Alt-text-as-link styling remains for the one
        // case with nothing to show yet: a remote fetch still in flight.
        let editor = makeEditor()
        editor.allowRemoteImages = true
        let styled = editor.styleBlock("![photo](https://example.invalid/\(UUID().uuidString).png)")
        // "photo" is at positions 2-6
        let color = styled.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        #expect(color != nil)
        let f = styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(NSFontManager.shared.traits(of: f!).contains(.italicFontMask))
    }

    @Test("Line break backslash is hidden when cursor is outside")
    @MainActor func lineBreakHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("hello\\")
        #expect(isHidden(at: 5, in: styled))
    }

    // MARK: - Heading & Blockquote Markers (hidden when no cursor, dimmed when active)

    @Test("Heading # is hidden when cursor is outside")
    @MainActor func headingMarkerHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("# Hello")
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 1, in: styled))  // space after #
    }

    @Test("Heading # is dimmed when cursor is inside")
    @MainActor func headingMarkerDimmedActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("# Hello", cursorPosition: 3)
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Heading # stays dimmed when cursor is in trailing whitespace")
    @MainActor func headingMarkerDimmedOnActiveLine() {
        let editor = makeEditor()
        let styled = editor.styleBlock("# Hello   ", cursorPosition: 9)
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Heading content has bold scaled font")
    @MainActor func headingContentFont() {
        let editor = makeEditor()
        let styled = editor.styleBlock("# Hello")
        let f = styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(NSFontManager.shared.traits(of: f!).contains(.boldFontMask))
        #expect(f!.pointSize > editor.bodyFont.pointSize)
    }

    @Test("Blockquote > is invisible (color-only) when cursor is outside")
    @MainActor func blockquoteMarkerHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> text")
        // Blockquote delimiters preserve width (font not shrunk), only color is clear
        #expect(isInvisible(at: 0, in: styled))
        #expect(isInvisible(at: 1, in: styled))  // space after >
    }

    @Test("Blockquote > is dimmed when cursor is inside")
    @MainActor func blockquoteMarkerDimmedActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> text", cursorPosition: 3)
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Blockquote content has secondary label color")
    @MainActor func blockquoteColor() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> text")
        // Content starts after "> " (position 2)
        let color = styled.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor
        #expect(color == NSColor.secondaryLabelColor)
    }

    @Test("Blockquote carries a left-bar decoration")
    @MainActor func blockquoteTextBlock() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> text")
        guard let deco = blockDecoration(at: 0, in: styled),
              case .leftBar = deco.kind else {
            Issue.record("expected a .leftBar BlockDecoration on the quote")
            return
        }
    }

    @Test("List bullet marker renders as a dot attachment")
    @MainActor func listMarkerDot() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- hello")
        // The `-` carries the bullet dot attachment.
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) is FragmentOverlay)
        // The trailing space after the bullet is dimmed.
        #expect(isDimmed(at: 1, in: styled))
    }

    @Test("Unchecked checkbox [ ] has circle attachment")
    @MainActor func uncheckedCheckboxAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- [ ] task")
        // "- " at 0-1 is hidden (zero-width + clear)
        #expect(isHidden(at: 0, in: styled))
        // "[" at 2 has a text attachment
        let a = styled.attributes(at: 2, effectiveRange: nil)
        #expect(a[.fragmentOverlay] is FragmentOverlay)
        // " ]" at 3-4 are hidden
        #expect(isHidden(at: 3, in: styled))
    }

    @Test("Checked checkbox [x] has circle attachment")
    @MainActor func checkedCheckboxAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- [x] done")
        // "- " at 0-1 is hidden (zero-width + clear)
        #expect(isHidden(at: 0, in: styled))
        // "[" at 2 has a text attachment
        let a = styled.attributes(at: 2, effectiveRange: nil)
        #expect(a[.fragmentOverlay] is FragmentOverlay)
        // "x]" at 3-4 are hidden
        #expect(isHidden(at: 3, in: styled))
    }

    @Test("Indented checkbox (4 spaces, beyond level 2) has circle attachment")
    @MainActor func indentedCheckboxAttachment() {
        let editor = makeEditor()
        let styled = editor.styleBlock("    - [ ] task")
        // "    - " prefix (positions 0-5) is hidden
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 4, in: styled))
        // "[" at position 6 has the circle attachment
        let a = styled.attributes(at: 6, effectiveRange: nil)
        #expect(a[.fragmentOverlay] is FragmentOverlay)
        // " ]" after the bracket is hidden
        #expect(isHidden(at: 7, in: styled))
    }

    @Test("Nested bullet (2 spaces) renders as a dot attachment")
    @MainActor func nestedBulletDot() {
        let editor = makeEditor()
        let styled = editor.styleBlock("  - nested")
        // Leading spaces have base text color (not part of delimiter)
        #expect(!isDimmed(at: 0, in: styled))
        // The `-` at offset 2 carries the bullet dot attachment
        #expect(styled.attribute(.fragmentOverlay, at: 2, effectiveRange: nil) is FragmentOverlay)
    }

    @Test("List items have hanging indent paragraph style")
    @MainActor func listIndentation() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- hello")
        var hasHangingIndent = false
        styled.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: styled.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle, ps.headIndent > 0 {
                hasHangingIndent = true
            }
        }
        #expect(hasHangingIndent)
    }

    @Test("All list types share one content indent (Apple Notes alignment)")
    @MainActor func listContentIndentsMatch() {
        let editor = makeEditor()
        func contentIndent(_ s: String) -> CGFloat {
            let st = editor.styleBlock(s)
            let ps = st.attribute(.paragraphStyle, at: st.length - 1, effectiveRange: nil) as? NSParagraphStyle
            return ps?.headIndent ?? -1
        }
        let bullet = contentIndent("- item")
        let number = contentIndent("1. item")
        let todo = contentIndent("- [ ] item")
        #expect(bullet > 0)
        #expect(abs(bullet - number) < 0.5)
        #expect(abs(bullet - todo) < 0.5)
    }

    @Test("Numbered marker is right-aligned into the icon slot")
    @MainActor func numberedMarkerRightAligned() {
        let editor = makeEditor()
        let styled = editor.styleBlock("1. hello")
        let ps = styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
        // The number sits in the slot: first-line indent is less than the
        // shared content indent, so "1." right-aligns before the text.
        #expect(ps != nil)
        #expect(ps!.firstLineHeadIndent < ps!.headIndent)
    }

    @Test("Indent unit is detected from the document")
    @MainActor func indentUnitDetection() {
        #expect(EditorTextView.detectListIndentUnit("- a\n  - b") == 2)
        #expect(EditorTextView.detectListIndentUnit("- a\n    - b") == 4)
        #expect(EditorTextView.detectListIndentUnit("- a\n- b") == 4)      // no nesting → default
        #expect(EditorTextView.detectListIndentUnit("- a\n\t- b") == 4)    // tab → one level
    }

    @Test("A nested list item's marker sits under its parent's content")
    @MainActor func nestedMarkerUnderParentContent() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        func style(_ s: String) -> NSParagraphStyle? {
            let st = editor.styleBlock(s)
            return st.attribute(.paragraphStyle, at: st.length - 1, effectiveRange: nil) as? NSParagraphStyle
        }
        let parent = style("- parent")
        let child = style("  - child")
        #expect(parent != nil && child != nil)
        // The child's marker (firstLineHeadIndent) lands at the parent's content
        // (headIndent), within a small tolerance.
        #expect(abs(child!.firstLineHeadIndent - parent!.headIndent) < 1.0)
    }

    @Test("Nested item hides leading whitespace so first line aligns with hanging indent")
    @MainActor func nestedHangingIndentAligns() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        // A 2-space item is parsed by swift-markdown (walker path), whose
        // delimiter range starts at the marker and excludes the leading
        // indentation. That whitespace must still be hidden, or the visible
        // spaces push the first line right and break its alignment with the
        // wrapped-line (hanging) indent.
        let styled = editor.styleBlock("  - [ ] wraps onto the next line")
        // Leading spaces (offsets 0,1) are hidden: near-zero font + clear color.
        for i in 0..<2 {
            let a = styled.attributes(at: i, effectiveRange: nil)
            #expect((a[.font] as? NSFont).map { $0.pointSize < 1.0 } == true)
            #expect(a[.foregroundColor] as? NSColor == NSColor.clear)
        }
        // First-line content lands at the hanging indent: firstLineHeadIndent
        // plus one marker slot (icon + space) equals headIndent.
        let ps = styled.attribute(.paragraphStyle, at: styled.length - 1, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil)
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        let slot = editor.bodyFont.pointSize + spaceWidth
        #expect(abs((ps!.firstLineHeadIndent + slot) - ps!.headIndent) < 1.0)
    }

    // MARK: - Active list item alignment

    /// The paragraph style of the (only) paragraph in a styled block.
    @MainActor private func listPS(_ editor: EditorTextView, _ s: String, cursor: Int?) -> NSParagraphStyle? {
        let st = editor.styleBlock(s, cursorPosition: cursor)
        return st.attribute(.paragraphStyle, at: st.length - 1, effectiveRange: nil) as? NSParagraphStyle
    }

    @Test("Active list item shares the rendered item's content indent")
    @MainActor func activeContentIndentMatchesInactive() {
        let editor = makeEditor()
        // Cursor inside the item makes it active (raw marker shown).
        for marker in ["- item", "1. item", "- [ ] item"] {
            let active = listPS(editor, marker, cursor: 4)
            let inactive = listPS(editor, marker, cursor: nil)
            #expect(active != nil && inactive != nil)
            // Content (hanging indent) is identical whether active or not, so the
            // text doesn't shift when you click into the item.
            #expect(abs(active!.headIndent - inactive!.headIndent) < 0.5)
            // The raw marker is right-aligned into its slot (first line < content).
            #expect(active!.firstLineHeadIndent < active!.headIndent)
        }
    }

    @Test("Active list marker stays visible and editable (not hidden)")
    @MainActor func activeMarkerVisible() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- hello", cursorPosition: 3)
        // The `-` marker is shown (dimmed), not replaced by an attachment nor
        // hidden with the near-zero clear font.
        #expect(styled.attribute(.fragmentOverlay, at: 0, effectiveRange: nil) == nil)
        let f = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect((f?.pointSize ?? 0) >= 1.0)
        #expect(isDimmed(at: 0, in: styled))           // marker is dimmed, visible
        #expect(styled.string == "- hello")            // raw text intact (editable)
    }

    @Test("Active nested item aligns with its depth (leading whitespace hidden)")
    @MainActor func activeNestedAligns() {
        let editor = makeEditor()
        editor.listIndentUnit = 2
        // A nested item, active. Its content indent must match the rendered
        // (inactive) nested item at the same depth — not collapse to top level.
        let active = listPS(editor, "  - child", cursor: 6)
        let inactive = listPS(editor, "  - child", cursor: nil)
        #expect(active != nil && inactive != nil)
        #expect(abs(active!.headIndent - inactive!.headIndent) < 0.5)

        // And the active nested item is deeper than an active top-level item.
        let topLevel = listPS(editor, "- top", cursor: 3)
        #expect(active!.headIndent > topLevel!.headIndent + 1.0)

        // Leading whitespace (offsets 0,1) is hidden so the indent comes from the
        // paragraph style, not the visible spaces.
        let styled = editor.styleBlock("  - child", cursorPosition: 6)
        for i in 0..<2 {
            let a = styled.attributes(at: i, effectiveRange: nil)
            #expect((a[.font] as? NSFont).map { $0.pointSize < 1.0 } == true)
            #expect(a[.foregroundColor] as? NSColor == NSColor.clear)
        }
    }

    @Test("Ordered list keeps its number and dims it")
    @MainActor func orderedListDimmed() {
        let editor = makeEditor()
        let styled = editor.styleBlock("1. hello")
        #expect(styled.string == "1. hello")
        #expect(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
                == editor.listMarkerColor)
    }

    @Test("Indented list (4 spaces) has wider hanging indent than top-level")
    @MainActor func indentedListDeeper() {
        let editor = makeEditor()
        let topLevel = editor.styleBlock("- hello")
        let indented = editor.styleBlock("    - hello")

        var topHanging: CGFloat = 0
        topLevel.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: topLevel.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle { topHanging = ps.headIndent }
        }

        var subHanging: CGFloat = 0
        indented.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: indented.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle { subHanging = ps.headIndent }
        }

        #expect(subHanging > topHanging)
    }

    @Test("Wrapped list lines have deeper indent than first line (hanging indent)")
    @MainActor func hangingIndent() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- hello")

        var wrapped: CGFloat = 0
        styled.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: styled.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle {
                wrapped = ps.headIndent
            }
        }

        #expect(wrapped > 0)
    }

    @Test("Checkbox list has narrower hanging indent than raw text width")
    @MainActor func checkboxHangingIndent() {
        let editor = makeEditor()
        let bullet = editor.styleBlock("- hello")
        let checkbox = editor.styleBlock("- [ ] hello")

        var bulletIndent: CGFloat = 0
        bullet.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: bullet.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle { bulletIndent = ps.headIndent }
        }

        var cbIndent: CGFloat = 0
        checkbox.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: checkbox.length)) { val, _, _ in
            if let ps = val as? NSParagraphStyle { cbIndent = ps.headIndent }
        }

        // Checkbox indent should be based on visual width (circle + space),
        // not raw text width of "- [ ] ". It should be comparable to bullet indent.
        let rawWidth = ("- [ ] " as NSString).size(withAttributes: [.font: editor.bodyFont]).width
        #expect(cbIndent < editor.listPadding + rawWidth)
    }

    @Test("Table header is bold, separator has border, pipes are hidden")
    @MainActor func tableStyling() {
        let editor = makeEditor()
        let styled = editor.styleBlock("| A | B |\n| --- | --- |\n| 1 | 2 |")
        // Header "A" at offset 2 is bold
        let hf = styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(hf != nil)
        let traits = NSFontManager.shared.traits(of: hf!)
        #expect(traits.contains(.boldFontMask))
        // Separator row (offset 10 = start of "| --- | --- |") is hidden
        #expect(isHidden(at: 10, in: styled))
        // Separator row carries a separator .tableRow decoration
        if let deco = blockDecoration(at: 10, in: styled),
           case .tableRow(_, _, _, let separator, _) = deco.kind {
            #expect(separator)
        } else {
            Issue.record("expected a .tableRow decoration on the separator row")
        }
        // All pipes are hidden (vertical borders drawn by the decoration)
        #expect(isHidden(at: 0, in: styled))
        #expect(isHidden(at: 4, in: styled))
        // Each row carries a .tableRow decoration for the borders
        if let deco = blockDecoration(at: 0, in: styled),
           case .tableRow = deco.kind {} else {
            Issue.record("expected a .tableRow decoration on the header row")
        }
    }

    @Test("Table without outer pipes renders with borders and hidden pipes")
    @MainActor func tableNoOuterPipes() {
        let editor = makeEditor()
        let styled = editor.styleBlock("col1 | col2\n---- | ----\nc11 | c12")
        // Header "col1" at offset 0 is bold
        let hf = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(hf != nil)
        #expect(NSFontManager.shared.traits(of: hf!).contains(.boldFontMask))
        // Inner pipe at offset 5 is hidden
        #expect(isHidden(at: 5, in: styled))
        // Header row carries a .tableRow decoration for the borders
        if let deco = blockDecoration(at: 0, in: styled),
           case .tableRow = deco.kind {} else {
            Issue.record("expected a .tableRow decoration on the header row")
        }
    }

    @Test("Non-active thematic break is hidden with horizontal line style")
    @MainActor func thematicBreakHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("---")
        #expect(styled.string == "---")
        // Characters are hidden (the rule is a .horizontalRule decoration)
        #expect(isHidden(at: 0, in: styled))
        if let deco = blockDecoration(at: 0, in: styled),
           case .horizontalRule = deco.kind {} else {
            Issue.record("expected a .horizontalRule decoration")
        }
    }

    @Test("Active thematic break is dimmed, not hidden")
    @MainActor func thematicBreakActiveDimmed() {
        let editor = makeEditor()
        let styled = editor.styleBlock("---", cursorPosition: 1)
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Non-active code block fences draw no ink at normal size; a background box decorates it; content is monospace and syntax-highlighted")
    @MainActor func codeBlockStyling() {
        let editor = makeEditor()
        let styled = editor.styleBlock("```swift\nlet hello = 1\n```")
        #expect(styled.string == "```swift\nlet hello = 1\n```")
        // Fence: clear color, normal-size monospace (blockquote-marker
        // treatment — the fence line's height is the box's breathing room).
        #expect(styled.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor.clear)
        let fenceFont = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(fenceFont?.isFixedPitch == true)
        #expect((fenceFont?.pointSize ?? 0) > 1.0)
        if let deco = blockDecoration(at: 0, in: styled), case .box = deco.kind {} else {
            Issue.record("expected a .box decoration")
        }
        let ns = styled.string as NSString
        let kwLoc = ns.range(of: "let").location
        let plainLoc = ns.range(of: "hello").location
        // Content is monospace.
        let f = styled.attribute(.font, at: plainLoc, effectiveRange: nil) as? NSFont
        #expect(f?.isFixedPitch == true)
        // The keyword is colored distinctly from a plain identifier.
        let kw = styled.attribute(.foregroundColor, at: kwLoc, effectiveRange: nil) as? NSColor
        let plain = styled.attribute(.foregroundColor, at: plainLoc, effectiveRange: nil) as? NSColor
        #expect(kw != nil && plain != nil)
        #expect(kw != plain)
    }

    @Test("Active code block fences are dimmed, not hidden, and not boxed")
    @MainActor func codeBlockStylingActive() {
        let editor = makeEditor()
        let source = "```swift\nlet hello = 1\n```"
        let styled = editor.styleBlock(source, cursorPosition: 12)   // caret inside "let hello = 1"
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
        #expect(blockDecoration(at: 0, in: styled) == nil)
    }

    @Test("Indented code block renders monospace, with no box and no fence treatment")
    @MainActor func indentedCodeBlockStyling() {
        let editor = makeEditor()
        let source = "    let hello = 1\n    let x = 2"
        let styled = editor.styleBlock(source)
        #expect(styled.string == source)
        // Whole block (indentation included) is monospace.
        let first = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let last = styled.attribute(.font, at: styled.length - 1, effectiveRange: nil) as? NSFont
        #expect(first?.isFixedPitch == true)
        #expect(last?.isFixedPitch == true)
        // No box: only fenced blocks get one (no fence lines exist here to
        // serve as the box's breathing room).
        #expect(blockDecoration(at: 0, in: styled) == nil)
    }

    @Test("Code block label attr: capitalized language on the fence line only (\"\" when the fence names none)")
    @MainActor func codeBlockLabelAttribute() {
        let editor = makeEditor()
        let styled = editor.styleBlock("```swift\nlet x = 1\n```")
        let ns = styled.string as NSString
        let contentLoc = ns.range(of: "let x").location
        #expect(styled.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) as? String == "Swift")
        #expect(styled.attribute(.codeBlockLabel, at: contentLoc, effectiveRange: nil) == nil)
        // The second row (first content line) anchors the drawn label.
        #expect(styled.attribute(.codeBlockLabelAnchor, at: contentLoc, effectiveRange: nil) as? String == "Swift")
        #expect(styled.attribute(.codeBlockLabelAnchor, at: 0, effectiveRange: nil) == nil)

        // No fence language → "" (marks the fence line for the top-padding
        // shave; no label drawn).
        let plain = editor.styleBlock("```\ncode\n```")
        #expect(plain.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) as? String == "")
        let plainContent = (plain.string as NSString).range(of: "code").location
        #expect(plain.attribute(.codeBlockLabelAnchor, at: plainContent, effectiveRange: nil) == nil)

        // Indented block: no label plumbing at all.
        let indented = editor.styleBlock("    let y = 2")
        #expect(indented.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) == nil)

        // Active block: raw fences shown, no label.
        let active = editor.styleBlock("```swift\nlet x = 1\n```", cursorPosition: 12)
        #expect(active.attribute(.codeBlockLabel, at: 0, effectiveRange: nil) == nil)
    }

    @Test("A fenced code block inside a callout still boxes, nested under the callout's own box")
    @MainActor func codeBlockInsideCalloutStacks() {
        let editor = makeEditor()
        let source = "> [!note]\n> ```swift\n> let x = 1\n> ```"
        let styled = editor.styleBlock(source)
        // The callout's own box is the outer decoration at offset 0.
        if let outer = blockDecoration(at: 0, in: styled), case .box = outer.kind {} else {
            Issue.record("expected the callout's own box at offset 0")
        }
        // Somewhere inside, the nested code block's box should also be
        // present (as part of a BlockDecorationList once spliced in).
        let ns = styled.string as NSString
        let fenceLoc = ns.range(of: "```swift").location
        #expect(fenceLoc != NSNotFound)
        let value = styled.attribute(.blockDecoration, at: fenceLoc, effectiveRange: nil)
        let boxes: [BlockDecoration]
        if let list = value as? BlockDecorationList { boxes = list.decorations }
        else if let single = value as? BlockDecoration { boxes = [single] }
        else { boxes = [] }
        #expect(boxes.filter { if case .box = $0.kind { return true }; return false }.count == 2)
    }

    // MARK: - Active Token (cursor inside)

    @Test("Bold delimiters are dimmed (not hidden) when cursor is inside")
    @MainActor func boldDelimitersDimmedWhenActive() {
        let editor = makeEditor()
        // Cursor at position 3 = inside "**bold**"
        let styled = editor.styleBlock("**bold**", cursorPosition: 3)
        #expect(isDimmed(at: 0, in: styled))
        #expect(isDimmed(at: 1, in: styled))
        #expect(isDimmed(at: 6, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Code delimiters are dimmed when cursor is inside")
    @MainActor func codeDelimitersDimmedWhenActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("`code`", cursorPosition: 2)
        #expect(isDimmed(at: 0, in: styled))
        #expect(isDimmed(at: 5, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Line break backslash is dimmed when cursor is inside")
    @MainActor func lineBreakDimmedWhenActive() {
        let editor = makeEditor()
        let styled = editor.styleBlock("hello\\", cursorPosition: 5)
        #expect(isDimmed(at: 5, in: styled))
        #expect(!isHidden(at: 5, in: styled))
    }

    @Test("Heading markers: hidden without cursor, dimmed with cursor")
    @MainActor func headingMarkerVisibility() {
        let editor = makeEditor()
        // Without cursor → hidden
        let noActive = editor.styleBlock("# Hello")
        #expect(isHidden(at: 0, in: noActive))
        // With cursor inside → dimmed
        let active = editor.styleBlock("# Hello", cursorPosition: 3)
        #expect(isDimmed(at: 0, in: active))
    }

    // MARK: - Edge Cases

    @Test("**hi* mismatched: italic delimiters hidden, extra * stays visible")
    @MainActor func mismatchedBoldItalic() {
        let editor = makeEditor()
        let styled = editor.styleBlock("**hi*")
        // cmark parses this as: literal *, then italic *hi*
        // The first * at position 0 is literal (no span), the * at 1 is italic open, * at 4 is italic close
        // Content "hi" at 2-3 should have italic font
        let f = styled.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(NSFontManager.shared.traits(of: f!).contains(.italicFontMask))
    }

    @Test("Single-line blockquote: > invisible (color-only) when no cursor")
    @MainActor func singleLineBlockquoteHidden() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> some quote")
        // Blockquote delimiters preserve width, only color is clear
        #expect(isInvisible(at: 0, in: styled))
        #expect(isInvisible(at: 1, in: styled))
    }

    @Test("Single-line blockquote: > dimmed when cursor inside")
    @MainActor func singleLineBlockquoteDimmed() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> some quote", cursorPosition: 3)
        #expect(isDimmed(at: 0, in: styled))
        #expect(!isHidden(at: 0, in: styled))
    }

    @Test("Checked task item has strikethrough on content")
    @MainActor func checkedTaskStrikethrough() {
        let editor = makeEditor()
        let styled = editor.styleBlock("- [x] done")
        let val = styled.attribute(.strikethroughStyle, at: 6, effectiveRange: nil)
        #expect(val != nil)
    }
}

// MARK: - Display Composition

@Suite("EditorTextView — Recompose")
struct EditorRecomposeTests {

    @Test("Text storage always contains raw markdown")
    @MainActor func textStorageIsRaw() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)

        // Cursor in block 0
        editor.recompose(cursorInRaw: 0)
        #expect(editor.textStorage!.string == "**bold**\nplain")

        // Cursor in block 1
        editor.recompose(cursorInRaw: 9)
        #expect(editor.textStorage!.string == "**bold**\nplain")
    }

    @Test("activeBlockIndex is set correctly")
    @MainActor func activeBlockIndexCorrect() {
        let editor = makeEditor()
        editor.rawSource = "aaa\nbbb\nccc"
        editor.blocks = BlockParser.parse(editor.rawSource)

        editor.recompose(cursorInRaw: 0)
        #expect(editor.activeBlockIndex == 0)

        editor.recompose(cursorInRaw: 4)
        #expect(editor.activeBlockIndex == 1)

        editor.recompose(cursorInRaw: 8)
        #expect(editor.activeBlockIndex == 2)
    }

    @Test("Non-active block has inline delimiters hidden")
    @MainActor func nonActiveBlockDelimitersHidden() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)
        // Cursor in block 1 — block 0 should have hidden ** delimiters
        editor.recompose(cursorInRaw: 9)

        let ts = editor.textStorage!
        // ** at positions 0,1 should be hidden
        let f = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(f!.pointSize < 1.0)
    }

    @Test("Active block with cursor in token shows delimiters")
    @MainActor func activeBlockTokenDelimitersVisible() {
        let editor = makeEditor()
        editor.rawSource = "**bold**\nplain"
        editor.blocks = BlockParser.parse(editor.rawSource)
        // Cursor at position 3 = inside "**bold**"
        editor.recompose(cursorInRaw: 3)

        let ts = editor.textStorage!
        // ** at position 0 should be dimmed (visible), not hidden
        let color = ts.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == expectedDimColor)
        let f = ts.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(f != nil)
        #expect(f!.pointSize > 1.0)  // Not hidden
    }
}

// MARK: - Quote / Callout Hanging Indent

/// Wrapped/continuation lines of a blockquote or callout must hang after the
/// `> ` marker (like list items), not under the `>`. That is encoded as a
/// paragraph-style hanging indent: headIndent − firstLineHeadIndent ≈ the
/// width of the `> ` marker.
@Suite("Quote/Callout hanging indent")
struct QuoteCalloutHangingIndentTests {

    @Test("Blockquote wrapped lines hang after the marker")
    @MainActor func blockquoteHangingIndent() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> quoted text")
        let ps = styled.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil)
        let hang = (ps?.headIndent ?? 0) - (ps?.firstLineHeadIndent ?? 0)
        #expect(abs(hang - editor.quoteMarkerWidth) < 0.5)
    }

    @Test("Callout body lines are inset one marker width, first and wrapped aligned")
    @MainActor func calloutBodyIndent() {
        let editor = makeEditor()
        let styled = editor.styleBlock("> [!note]\n> body text")
        // Inspect the body line's paragraph style (after the header newline).
        let ns = styled.string as NSString
        let bodyLoc = ns.range(of: "\n").location + 1
        let ps = styled.attribute(.paragraphStyle, at: bodyLoc, effectiveRange: nil) as? NSParagraphStyle
        #expect(ps != nil)
        // The callout body is rendered recursively with the `>` prefix hidden
        // (zero width), so the inset is uniform: content begins one marker width
        // (plus the 2pt bar inset) into the box, and wrapped lines align with
        // the first line rather than hanging.
        let step = 2 + editor.quoteMarkerWidth
        #expect(abs((ps?.firstLineHeadIndent ?? 0) - step) < 0.5)
        #expect(abs((ps?.headIndent ?? 0) - (ps?.firstLineHeadIndent ?? 0)) < 0.5)
    }
}
