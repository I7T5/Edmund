import Testing
import AppKit
@testable import EdmundCore

/// Each table carries a `</>` button in the line numbers' slot, level with its
/// header row. It puts the caret in the table — which is what renders it as raw
/// markdown. Leaving raw editing is the existing active-block behaviour (the
/// caret moves out), so there is nothing here to test for it.
///
/// The button is revealed by hover or by the caret being inside the table; the
/// margin is empty otherwise.

@Suite("Table raw-editing button")
@MainActor
struct TableRawButtonTests {

    private let table = "| a | b |\n|---|---|\n| x | y |"

    /// The reading column's base inset is what opens the margin the button
    /// hangs in; a freshly built editor hasn't computed it yet.
    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    @Test("A table gets one button, level with its header row")
    func oneButtonPerTable() {
        let editor = loadEditor("lead paragraph\n\n\(table)\n\ntrailing\n")

        let buttons = editor.visibleTableRawButtons()
        #expect(buttons.count == 1)
        guard let button = buttons.first else { return }
        #expect(editor.blocks[button.blockIndex].kind == .table)

        // Level with the header row, not with the table's top edge: the header's
        // line box carries the table's leading paragraph spacing.
        let headerStart = editor.blocks[button.blockIndex].range.location
        guard let headerRect = editor.lineRect(forCharacterAt: headerStart) else {
            Issue.record("header row has no laid-out rect")
            return
        }
        #expect(abs(button.rect.midY - headerRect.midY) < editor.bodyFont.pointSize)
        // And outside the text column.
        #expect(button.rect.maxX <= editor.textContainerOrigin.x
            + (editor.textContainer?.lineFragmentPadding ?? 0))
    }

    /// The whole point of the placement rework: the button occupies the slot the
    /// line number for that row would, so it shares the numbers' right edge.
    @Test("The button sits in the line numbers' slot")
    func sitsInTheLineNumberSlot() {
        // With the caret outside the table: inside it, the row pill takes the
        // margin and the button steps aside by exactly that band.
        let editor = loadEditor("lead\n\n\(table)\n")
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        guard let button = editor.visibleTableRawButtons().first else {
            Issue.record("no button")
            return
        }
        let rightEdge = editor.textContainerOrigin.x
            + (editor.textContainer?.lineFragmentPadding ?? 0)
            - EditorTextView.lineNumberPadding
        #expect(abs(button.rect.maxX - rightEdge) < 0.5)
    }

    /// The slot comes from `enumerateVisibleLineNumbers`, which is not gated on
    /// the setting — so the button lands identically with the numbers off.
    @Test("Placement does not depend on the line-number setting")
    func placementIndependentOfLineNumbers() {
        let editor = loadEditor(table)
        editor.showLineNumbers = false
        let off = editor.visibleTableRawButtons().first?.rect
        editor.showLineNumbers = true
        let on = editor.visibleTableRawButtons().first?.rect
        #expect(off != nil)
        #expect(off == on)
    }

    @Test("A document without tables draws no buttons")
    func noTablesNoButtons() {
        let editor = loadEditor("just a paragraph\n\nand another\n")
        #expect(editor.visibleTableRawButtons().isEmpty)
    }

    @Test("Two tables get a button each")
    func oneButtonEachTable() {
        let editor = loadEditor("\(table)\n\nbetween\n\n\(table)\n")
        #expect(editor.visibleTableRawButtons().count == 2)
    }

    // MARK: - Reveal

    @Test("Nothing shows until the table is hovered or holds the caret")
    func hiddenAtRest() {
        let editor = loadEditor("lead\n\n\(table)\n")
        #expect(!editor.visibleTableRawButtons().isEmpty)   // it exists
        #expect(editor.revealedTableRawButtons().isEmpty)   // but doesn't show
    }

    @Test("Hovering a table reveals its button")
    func hoverReveals() {
        let editor = loadEditor("lead\n\n\(table)\n")
        guard let button = editor.visibleTableRawButtons().first else {
            Issue.record("no button")
            return
        }
        editor.hoveredTableBlock = button.blockIndex
        #expect(editor.revealedTableRawButtons().count == 1)
    }

    @Test("Only the hovered table's button shows")
    func hoverRevealsOnlyItsOwn() {
        let editor = loadEditor("\(table)\n\nbetween\n\n\(table)\n")
        let buttons = editor.visibleTableRawButtons()
        #expect(buttons.count == 2)
        guard let first = buttons.first else { return }
        // Out of both tables: a caret inside one hides that one's button (see
        // below), which would otherwise mask what this is checking.
        editor.setSelectedRange(NSRange(
            location: (editor.rawSource as NSString).range(of: "between").location, length: 0))
        editor.hoveredTableBlock = first.blockIndex
        #expect(editor.revealedTableRawButtons().map(\.blockIndex) == [first.blockIndex])
    }

    /// It used to hide itself for the table the caret was in, so the row pill
    /// could have the margin. That also took it away from anyone editing a cell
    /// who wanted the raw markdown — and the hit test only considers a revealed
    /// button, so it was not clickable either. They share the margin now.
    @Test("The caret inside a table keeps its button")
    func caretInsideKeepsTheButton() {
        let editor = loadEditor("lead\n\n\(table)\n")
        guard let button = editor.visibleTableRawButtons().first else {
            Issue.record("no button")
            return
        }
        editor.hoveredTableBlock = button.blockIndex
        #expect(editor.revealedTableRawButtons().count == 1)
        editor.hoveredTableBlock = nil
        editor.setSelectedRange(NSRange(
            location: editor.blocks[button.blockIndex].range.location, length: 0))
        #expect(editor.revealedTableRawButtons().count == 1)
    }

    @Test("A hidden button is not clickable")
    func hiddenButtonIsNotATarget() {
        let editor = loadEditor("lead\n\n\(table)\n")
        // Same predicate the hit test applies, minus the event plumbing.
        #expect(editor.revealedTableRawButtons().isEmpty)
        editor.hoveredTableBlock = editor.visibleTableRawButtons().first?.blockIndex
        #expect(!editor.revealedTableRawButtons().isEmpty)
    }

    @Test("The header row's number gives way to a revealed button")
    func revealedButtonTakesTheNumbersSlot() {
        let editor = loadEditor("lead\n\n\(table)\n")
        #expect(editor.linesCoveredByTableRawButtons().isEmpty)

        guard let button = editor.visibleTableRawButtons().first else {
            Issue.record("no button")
            return
        }
        editor.hoveredTableBlock = button.blockIndex
        let headerLine = editor.line(forOffset: editor.blocks[button.blockIndex].range.location)
        #expect(editor.linesCoveredByTableRawButtons() == [headerLine])
    }

    // MARK: - Activation

    /// Only the caret placement is asserted. Making the table the *active*
    /// block — the restyle that reveals its raw markdown — is AppKit-async
    /// (`selectionDidChange` hops through `DispatchQueue.main.async`), and that
    /// hop belongs to the existing active-block machinery, not to the button.
    @Test("Activating puts the caret at the start of the table")
    func activationEntersRawEditing() {
        let editor = loadEditor("lead paragraph\n\n\(table)\n\ntrailing\n")

        guard let button = editor.visibleTableRawButtons().first else {
            Issue.record("no button to activate")
            return
        }
        editor.activateRawTableEditing(blockIndex: button.blockIndex)

        let tableStart = editor.blocks[button.blockIndex].range.location
        #expect(editor.selectedRange().location == tableStart)
        #expect(editor.blockIndexForRawOffset(tableStart) == button.blockIndex)
    }
}
