import Testing
import AppKit
@testable import edmd
@testable import EdmundCore

// The toolbar's *composition*: that it offers the documented items in the
// documented order, and that every command in its popups is one of the existing
// Format commands rather than a second implementation. Interaction (clicking a
// row, the Link item's secondary click) is not reachable headlessly — see the
// live checks in the PR description.

@MainActor private func toolbar() -> (FormatToolbar, Document) {
    let doc = Document()
    return (FormatToolbar(document: doc), doc)
}

/// Titles of a menu's real items, separators rendered as "-".
@MainActor private func titles(_ menu: NSMenu) -> [String] {
    menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
}

@MainActor @Suite struct FormatToolbarLayoutTests {

    private let viewMode = NSToolbarItem.Identifier("viewMode")

    @Test func defaultOrderMatchesTheSpec() {
        let ids = FormatToolbar.defaultIdentifiers(viewMode: viewMode).map(\.rawValue)
        #expect(ids == ["format", "checklist", "table", "image", "link",
                        "NSToolbarFlexibleSpaceItem", "viewMode", "share"])
    }

    /// Centring is `centeredItemIdentifiers`, not flexible space — measured, a
    /// leading flexible space swallowed all the slack and the group stayed right.
    @Test func theFormattingGroupIsTheCentredSet() {
        let ids = FormatToolbar.defaultIdentifiers(viewMode: viewMode)
        #expect(FormatToolbar.centeredIdentifiers == Set(ids.prefix(5)))
        #expect(!FormatToolbar.centeredIdentifiers.contains(viewMode))
        #expect(!FormatToolbar.centeredIdentifiers.contains(FormatToolbar.share))
    }

    @Test func everyDefaultItemIsAlsoAllowed() {
        let allowed = Set(FormatToolbar.allowedIdentifiers(viewMode: viewMode))
        for id in FormatToolbar.defaultIdentifiers(viewMode: viewMode) {
            #expect(allowed.contains(id), "\(id.rawValue) is a default but not allowed")
        }
    }

    @Test func vendsEveryItemItDeclares() {
        let (bar, doc) = toolbar()
        for id in FormatToolbar.allowedIdentifiers(viewMode: viewMode)
        where id != viewMode && id != .space && id != .flexibleSpace {
            #expect(bar.makeItem(id) != nil, "no item vended for \(id.rawValue)")
        }
        _ = doc
    }

    /// `validate()` gates formatting commands on the caret. The Format item's
    /// action only opens a popover, so nothing in the responder chain answers it
    /// — gating it there disabled the button permanently.
    @Test func theFormatButtonIsNotGatedOnAFormattingAction() {
        let (bar, doc) = toolbar()
        let item = bar.makeItem(FormatToolbar.format) as? FormatButtonItem
        let button = item?.view as? NSButton
        button?.isEnabled = false
        item?.validate()
        #expect(button?.isEnabled == true)
        _ = doc
    }

    /// The other custom-view item is a real command and must still be gated,
    /// or the fix above would have blanket-enabled everything.
    @Test func theLinkButtonIsStillGated() {
        let (bar, doc) = toolbar()
        let item = bar.makeItem(FormatToolbar.link) as? FormatButtonItem
        let button = item?.view as? NSButton
        button?.isEnabled = true
        item?.validate()   // no editor is first responder here
        #expect(button?.isEnabled == false)
        _ = doc
    }

    /// The view-mode item stays with `Document`; FormatToolbar must decline it
    /// rather than vend an empty replacement.
    @Test func declinesTheViewModeItem() {
        let (bar, doc) = toolbar()
        #expect(bar.makeItem(viewMode) == nil)
        _ = doc
    }
}

@MainActor @Suite struct FormatPopupTests {

    @Test func rowOrderMatchesTheSpec() {
        let (bar, doc) = toolbar()
        // Icon rows are views, not items — the popover stacks them above these.
        #expect(titles(bar.formatPopupMenu()) == [
            "Heading 1", "Heading 2", "Heading 3", "Thematic Break",
            "•  Bulleted List", "1.  Numbered List", "-",
            "```  Code Block", "$  Math Block", "▎ Block Quote",
            "Alert / Callout", "Footnote",
        ])
        _ = doc
    }

    /// Checklist and Table are top-level toolbar items, so listing them in the
    /// popup too would be a second route to the same command.
    @Test func popupOmitsChecklistAndTable() {
        let (bar, doc) = toolbar()
        let names = titles(bar.formatPopupMenu())
        #expect(!names.contains("Checklist"))
        #expect(!names.contains("Table"))
        _ = doc
    }

    /// The popup is the quick path, not a mirror of the Format menu: flat, with
    /// headings stopping at 3 and one callout form.
    @Test func popupIsEntirelyFlat() {
        let (bar, doc) = toolbar()
        for item in bar.formatPopupMenu().items {
            #expect(item.submenu == nil, "\(item.title) still has a submenu")
        }
        _ = doc
    }

    @Test func headingRowsCarryTheirLevelAndStopAtThree() {
        let (bar, doc) = toolbar()
        let headings = bar.formatPopupMenu().items.filter {
            $0.action == #selector(EditorTextView.formatHeading(_:))
        }
        #expect(headings.map(\.tag) == [1, 2, 3])
        // formatHeading reads the level off the sender's tag, so it must survive
        // the attributedTitle styling.
        #expect(headings.allSatisfy { $0.attributedTitle != nil })
        _ = doc
    }

    @Test func theSingleCalloutRowInsertsANote() {
        let (bar, doc) = toolbar()
        let callout = bar.formatPopupMenu().items.first {
            $0.action == #selector(EditorTextView.formatCallout(_:))
        }
        #expect(callout?.representedObject as? String == "NOTE")
        _ = doc
    }

    /// The full H1–H6 range and all 20 callout types stay reachable in the menu
    /// bar — the popup trimming them must not have trimmed those too.
    @Test func theMenuBarStillOffersTheFullRange() {
        #expect(FormatMenu.headingSubmenuItem().submenu?.items.count == 6)
        #expect((FormatMenu.calloutSubmenuItem().submenu?.items.count ?? 0) > 15)
    }

    @Test func iconRowsCarryTheDocumentedCommands() {
        let (bar, doc) = toolbar()
        let rows = bar.iconRowViews()
        #expect(rows.count == 2)

        // Every row button funnels through the same forwarding target…
        let buttons = rows.map { $0.arrangedSubviews.compactMap { $0 as? NSButton } }
        #expect(buttons.allSatisfy { $0.allSatisfy { NSStringFromSelector($0.action!) == "fire:" } })
        // …so the real command lives on the target, not the button.
        let targets = rows.map { row in
            row.arrangedSubviews.compactMap { ($0 as? NSButton)?.target as? FormatIconTarget }
                .map { NSStringFromSelector($0.action) }
        }
        #expect(targets[0] == ["formatBold:", "formatItalic:", "formatUnderline:",
                               "formatStrikethrough:", "formatHighlight:"])
        #expect(targets[1] == ["formatCode:", "formatInlineMath:",
                               "formatSubscript:", "formatSuperscript:"])
        _ = doc
    }

    /// Every command the popup offers must be a known formatting action —
    /// the guard against the toolbar growing its own private commands.
    @Test func everyPopupCommandIsAKnownFormattingAction() {
        let (bar, doc) = toolbar()
        func check(_ menu: NSMenu) {
            for item in menu.items {
                if let sub = item.submenu { check(sub); continue }
                guard let action = item.action else { continue }
                #expect(EditorTextView.formattingActions.contains(action),
                        "\(item.title) uses unregistered action \(action)")
            }
        }
        check(bar.formatPopupMenu())
        _ = doc
    }
}

@MainActor @Suite struct FormatPopoverTests {

    /// The popover renders the same items the command table produces — the rows
    /// are a view over them, not a second declaration.
    @Test func buildsARowForEveryCommandItem() {
        let (bar, doc) = toolbar()
        let items = Array(bar.formatPopupMenu().items)
        let controller = FormatPopoverController(items: items, editor: nil, popover: nil)
        controller.loadView()

        let rows = controller.commandRows
        let expected = items.filter { !$0.isSeparatorItem }
        #expect(rows.count == expected.count)
        #expect(rows.map(\.item.title) == expected.map(\.title))
        _ = doc
    }

    /// The icon rows are passed in as views. Routing them through
    /// `NSMenuItem.view` instead left AppKit owning their layout and they
    /// stacked at y=0 on top of the last command row.
    @Test func iconRowsAreLaidOutAboveTheCommandRows() {
        let (bar, doc) = toolbar()
        let iconRows = bar.iconRowViews()
        let controller = FormatPopoverController(iconRows: iconRows,
                                                 items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        // Every row occupies its own vertical band — no two overlap. The icon rows
        // sit inside the grid block, so their frames need converting first.
        let bands = ((iconRows.map(\.self) as [NSView]) + controller.commandRows)
            .map { $0.convert($0.bounds, to: controller.view) }
            .map { ($0.minY, $0.maxY) }
            .sorted { $0.0 < $1.0 }
        #expect(bands.allSatisfy { $0.1 > $0.0 }, "a row has zero height")
        #expect(zip(bands, bands.dropFirst()).allSatisfy { $0.1 <= $1.0 },
                "rows overlap: \(bands)")
        _ = doc
    }

    /// Notes gives every row the same height whatever type it previews; ours used
    /// to size each row to its own font, so the heading rows towered over the rest.
    @Test func everyCommandRowIsTheSameHeight() {
        let (bar, doc) = toolbar()
        let controller = FormatPopoverController(iconRows: bar.iconRowViews(),
                                                 items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        let heights = Set(controller.commandRows.map(\.frame.height))
        #expect(heights == [FormatPopoverRow.rowHeight], "ragged rows: \(heights.sorted())")
        _ = doc
    }

    /// The popover is as wide as its widest band and no wider, the dividers stop
    /// short of both sides, and the icon grid — which is that widest band — keeps
    /// its two rows on a shared left edge.
    @Test func thePopoverFitsItsContentAndInsetsItsDividers() {
        let (bar, doc) = toolbar()
        let iconRows = bar.iconRowViews()
        let controller = FormatPopoverController(iconRows: iconRows,
                                                 items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        let stack = controller.view.subviews.first as? NSStackView
        let bands = stack?.arrangedSubviews ?? []
        // Snug: no band is cut off, and none of the width is unclaimed either.
        let widest = bands.map(\.fittingSize.width).max() ?? 0
        #expect(controller.view.frame.width == ceil(widest),
                "popover is \(controller.view.frame.width) for a \(widest) widest band")
        #expect(widest >= (controller.commandRows.map(\.fittingSize.width).max() ?? 0))

        // Separator containers span the popover; the hairline inside does not.
        let separators = bands
            .filter { $0.subviews.first is NSBox }
        #expect(separators.count == 2)
        for separator in separators {
            let box = separator.subviews[0]
            #expect(box.frame.minX > separator.frame.minX)
            #expect(box.frame.maxX < separator.frame.maxX)
        }

        #expect(Set(iconRows.map(\.frame.minX)).count == 1,
                "icon rows are not on a shared left edge")
        _ = doc
    }

    /// The hover tint is the accent colour on an inset view, so it stops short of
    /// the popover's rounded sides the way the dividers do.
    @Test func theHoverHighlightIsInsetAndAccentTinted() {
        let (bar, doc) = toolbar()
        let controller = FormatPopoverController(items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        let row = try! #require(controller.commandRows.first)
        #expect(row.highlight.layer?.backgroundColor == nil, "tinted before hover")

        row.isHovered = true
        controller.view.layoutSubtreeIfNeeded()
        var accent: CGColor?
        row.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        }
        #expect(row.highlight.layer?.backgroundColor == accent)
        #expect(row.highlight.frame.minX > row.frame.minX)
        #expect(row.highlight.frame.maxX < row.frame.maxX)
        _ = doc
    }

    /// Notes reserves the tick's gutter whether or not a row is ticked. Hiding the
    /// checkmark instead dropped it out of the stack and the titles slid left.
    @Test func everyTitleSitsOnTheSameLeftEdgeUnticked() {
        let (bar, doc) = toolbar()
        let controller = FormatPopoverController(items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        controller.view.layoutSubtreeIfNeeded()

        // The callout row carries an icon of its own, so it is legitimately inset
        // further; every other title shares one edge.
        let edges = Set(controller.commandRows
            .filter { $0.item.image == nil }
            .compactMap { row in
                row.subviews.compactMap { $0 as? NSStackView }.first?
                    .arrangedSubviews.compactMap { $0 as? NSTextField }.first?.frame.minX
            })
        #expect(edges.count == 1, "titles do not share a left edge: \(edges.sorted())")

        // A wrapping label reports no intrinsic width; the marked rows laid out
        // 4pt wide and drew nothing until the cell was forced back to one line.
        for row in controller.commandRows {
            let label = row.subviews.compactMap { $0 as? NSStackView }.first?
                .arrangedSubviews.compactMap { $0 as? NSTextField }.first
            #expect((label?.frame.width ?? 0) >= (label?.intrinsicContentSize.width ?? 0),
                    "'\(row.item.title)' is squeezed below its intrinsic width")
        }
        _ = doc
    }

    /// Markers that are literal Markdown syntax are set in the mono font they will
    /// be typed in; the block quote's bar is greyed so it reads as a rule.
    @Test func syntaxMarkersAreMonoAndTheQuoteBarIsGrey() {
        let (bar, doc) = toolbar()
        let items = bar.formatPopupMenu().items

        func marker(_ suffix: String) -> (NSFont?, NSColor?) {
            let item = items.first { $0.title.hasSuffix(suffix) }
            let title = item?.attributedTitle
            let attributes = title?.attributes(at: 0, effectiveRange: nil)
            return (attributes?[.font] as? NSFont, attributes?[.foregroundColor] as? NSColor)
        }

        #expect(items.first { $0.title.hasSuffix("Code Block") }?.title.hasPrefix("```") == true)
        #expect(items.first { $0.title.hasSuffix("Math Block") }?.title.hasPrefix("$") == true)
        #expect(marker("Code Block").0?.isFixedPitch == true)
        #expect(marker("Math Block").0?.isFixedPitch == true)
        #expect(marker("Block Quote").1 == .secondaryLabelColor)
        // The title itself stays in the menu font whatever its marker is.
        let code = items.first { $0.title.hasSuffix("Code Block") }?.attributedTitle
        let tail = code?.attributes(at: (code?.length ?? 1) - 1, effectiveRange: nil)
        #expect((tail?[.font] as? NSFont)?.isFixedPitch == false)
        _ = doc
    }

    /// Mouse-first panel: no key view loop, no focus rings, and no button carries
    /// a tint of its own (the highlighter used to be drawn in yellow).
    @Test func theIconRowIsMouseOnlyAndUntinted() {
        let (bar, doc) = toolbar()
        for row in bar.iconRowViews() {
            for case let button as NSButton in row.arrangedSubviews {
                #expect(button.focusRingType == .none)
                #expect(button.refusesFirstResponder)
                #expect(button.contentTintColor == nil, "\(button.toolTip ?? "?") is tinted")
            }
        }
        _ = doc
    }

    /// `formatHeading` reads its level from `(sender as? NSMenuItem)?.tag` and
    /// `formatCallout` its type from `representedObject`. Rows forward their
    /// item as the sender precisely so those survive — a row sending itself
    /// would silently apply Heading 1 and no callout at all.
    @Test func rowsCarryTheMenuItemSoSenderStateSurvives() {
        let (bar, doc) = toolbar()
        let controller = FormatPopoverController(items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()

        let heading2 = controller.commandRows.first { $0.item.title == "Heading 2" }
        #expect(heading2?.item.tag == 2)

        let callout = controller.commandRows.first { $0.item.title == "Alert / Callout" }
        #expect(callout?.item.representedObject as? String == "NOTE")
        _ = doc
    }

    @Test func rowsAreAccessibleAsButtons() {
        let (bar, doc) = toolbar()
        let controller = FormatPopoverController(items: Array(bar.formatPopupMenu().items),
                                                 editor: nil, popover: nil)
        controller.loadView()
        for row in controller.commandRows {
            #expect(row.accessibilityRole() == .button)
            #expect(row.accessibilityLabel() == row.item.title)
        }
        _ = doc
    }

    @Test func theCalloutRowCarriesTheNoteIcon() {
        let (bar, doc) = toolbar()
        let callout = bar.formatPopupMenu().items.first {
            $0.action == #selector(EditorTextView.formatCallout(_:))
        }
        #expect(callout?.image != nil)
        _ = doc
    }
}

@MainActor @Suite struct CalloutIconTests {

    @Test func noteResolvesToAnIcon() {
        #expect(Callout.icon(for: "note", color: .labelColor, pointSize: 14) != nil)
    }

    /// Case-insensitive, since the toolbar writes `[!NOTE]` uppercase.
    @Test func lookupIsCaseInsensitive() {
        #expect(Callout.icon(for: "NOTE", color: .labelColor, pointSize: 14) != nil)
    }

    @Test func unknownTypeHasNoIcon() {
        #expect(Callout.icon(for: "not-a-callout", color: .labelColor, pointSize: 14) == nil)
    }
}

@MainActor @Suite struct ActiveStateWiringTests {

    /// Every icon-row button must map to a detectable style, or it can never
    /// light up and the affordance silently lies.
    @Test func everyIconRowButtonMapsToAStyle() {
        let (bar, doc) = toolbar()
        let rows = bar.iconRowViews()
        #expect(rows.count == 2)
        for row in rows {
            for case let button as NSButton in row.arrangedSubviews {
                let target = button.target as? FormatIconTarget
                #expect(target.flatMap { FormatToolbar.style(for: $0.styleID) } != nil,
                        "\(target?.styleID ?? "?") has no ActiveInlineStyles mapping")
            }
        }
        _ = doc
    }

    @Test func blockRowsMapToTheStyleTheyApply() {
        let (bar, doc) = toolbar()
        let menu = bar.formatPopupMenu()
        // Matched on the suffix: a marked row's `title` carries its marker, since
        // AppKit syncs `title` from whatever `attributedTitle` is set to.
        func style(ofRowTitled title: String) -> ActiveBlockStyle? {
            menu.items.first { $0.title.hasSuffix(title) }.flatMap(FormatToolbar.blockStyle(for:))
        }
        #expect(style(ofRowTitled: "Heading 2") == .heading(level: 2))
        #expect(style(ofRowTitled: "•  Bulleted List") == .bulletedList)
        #expect(style(ofRowTitled: "▎ Block Quote") == .blockQuote)
        #expect(style(ofRowTitled: "Alert / Callout") == .callout)
        #expect(style(ofRowTitled: "Code Block") == .codeBlock)
        // Footnote is not a block style — it must not claim a checkmark.
        #expect(style(ofRowTitled: "Footnote") == nil)
        _ = doc
    }
}

// MARK: - View-mode glyph sizing
//
// `pencil` and `book` have different intrinsic boxes, so a shared point size
// draws the book visibly larger and the toolbar button appears to resize when
// the mode flips. Document compensates with a smaller point size for the book;
// these lock the two constants to the property that actually matters — the
// height of the *drawn* glyph, which is what the eye compares.

/// Height in points of the ink in `image` (its drawn extent, not its layout box).
@MainActor private func inkHeight(_ image: NSImage) -> Int {
    let side = 64
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = image.size
    image.draw(in: NSRect(x: (CGFloat(side) - size.width) / 2,
                          y: (CGFloat(side) - size.height) / 2,
                          width: size.width, height: size.height))
    NSGraphicsContext.restoreGraphicsState()

    var top: Int?, bottom: Int?
    for y in 0..<side {
        var inked = false
        for x in 0..<side where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 {
            inked = true; break
        }
        if inked { if top == nil { top = y }; bottom = y }
    }
    guard let t = top, let b = bottom else { return 0 }
    return b - t + 1
}

@MainActor @Suite struct ViewModeGlyphSizeTests {

    private func symbol(_ name: String, _ pointSize: CGFloat) throws -> NSImage {
        try #require(NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular)))
    }

    /// The pair Document actually uses. Tolerance of 1pt: they only have to look
    /// the same, and SF Symbol outlines will never match to the pixel.
    @Test func pencilAndBookDrawTheSameHeight() throws {
        let pencil = inkHeight(try symbol("pencil", 15))
        let book = inkHeight(try symbol("book", 12.9))
        #expect(abs(pencil - book) <= 1, "pencil \(pencil)pt vs book \(book)pt")
    }

    /// The reason the compensation exists — guards against someone "simplifying"
    /// the two constants back into one.
    @Test func aSharedPointSizeWouldDrawTheBookLarger() throws {
        let pencil = inkHeight(try symbol("pencil", 15))
        let book = inkHeight(try symbol("book", 15))
        #expect(book > pencil + 1, "book \(book)pt vs pencil \(pencil)pt")
    }
}

@MainActor @Suite struct ImageAndLinkMenuTests {

    @Test func imageMenuOffersEverySourceWithOnlyFileEnabled() {
        let (bar, doc) = toolbar()
        let menu = bar.imagePopupMenu()
        #expect(titles(menu) == ["Attach File…", "Photos…", "-", "Take Photo", "Scan Documents"])

        let attach = menu.items.first { $0.title == "Attach File…" }
        #expect(attach?.action == #selector(EditorTextView.formatAttachImage(_:)))

        // Placeholders must not dispatch even if AppKit enables them.
        for item in menu.items where !item.isSeparatorItem && item.title != "Attach File…" {
            #expect(item.action == nil, "\(item.title) is a placeholder but has an action")
        }
        _ = doc
    }

    @Test func onlyFileSourceIsAvailable() {
        #expect(ImageSource.allCases.filter(\.isAvailable) == [.file])
    }

    /// The Link item's secondary-click menu — Image has its own toolbar item.
    @Test func linkMenuIsLinkAndWikilink() {
        let (bar, doc) = toolbar()
        let menu = bar.linkMenu()
        #expect(titles(menu) == ["Link", "Wikilink"])
        #expect(menu.items[0].action == #selector(EditorTextView.formatLink(_:)))
        #expect(menu.items[1].action == #selector(EditorTextView.formatWikilink(_:)))
        _ = doc
    }
}
