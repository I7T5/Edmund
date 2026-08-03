import Testing
import AppKit
@testable import EdmundCore

/// Each table carries a `</>` button in the reading column's left margin that
/// puts the caret in the table — which is what renders it as raw markdown.
/// Leaving raw editing is the existing active-block behaviour (the caret moves
/// out), so there is nothing here to test for it.

@Suite("Table raw-editing button")
@MainActor
struct TableRawButtonTests {

    private let table = "| a | b |\n|---|---|\n| x | y |"

    @Test("The button hangs left of the text column")
    func sitsInTheMargin() {
        let x = EditorTextView.tableRawButtonX(textStartX: 100, reservedForLineNumbers: 0)
        #expect(x + EditorTextView.tableRawButtonSize <= 100)
    }

    @Test("Line numbers in the same margin push the button further left")
    func stepsLeftOfLineNumbers() {
        let bare = EditorTextView.tableRawButtonX(textStartX: 100, reservedForLineNumbers: 0)
        let shared = EditorTextView.tableRawButtonX(textStartX: 100, reservedForLineNumbers: 20)
        #expect(shared == bare - 20)
    }

    @Test("A margin too tight to hold both keeps the button on screen")
    func clampedIntoView() {
        let x = EditorTextView.tableRawButtonX(textStartX: 10, reservedForLineNumbers: 40)
        #expect(x >= 0)
    }

    @Test("A table gets one button, level with its header row")
    func oneButtonPerTable() {
        let editor = makeEditor()
        // The reading column's base inset is what opens the margin the button
        // hangs in; a freshly built editor hasn't computed it yet.
        editor.updateContentInset()
        editor.loadContent("lead paragraph\n\n\(table)\n\ntrailing\n")
        ensureFullLayout(editor)
        layOutViewport(editor)

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

    @Test("A document without tables draws no buttons")
    func noTablesNoButtons() {
        let editor = makeEditor()
        editor.loadContent("just a paragraph\n\nand another\n")
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleTableRawButtons().isEmpty)
    }

    @Test("Two tables get a button each")
    func oneButtonEachTable() {
        let editor = makeEditor()
        editor.loadContent("\(table)\n\nbetween\n\n\(table)\n")
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleTableRawButtons().count == 2)
    }

    /// Only the caret placement is asserted. Making the table the *active*
    /// block — the restyle that reveals its raw markdown — is AppKit-async
    /// (`selectionDidChange` hops through `DispatchQueue.main.async`), and that
    /// hop belongs to the existing active-block machinery, not to the button.
    @Test("Activating puts the caret at the start of the table")
    func activationEntersRawEditing() {
        let editor = makeEditor()
        editor.loadContent("lead paragraph\n\n\(table)\n\ntrailing\n")
        ensureFullLayout(editor)
        layOutViewport(editor)

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
