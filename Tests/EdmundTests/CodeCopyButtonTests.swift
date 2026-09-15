import Testing
import AppKit
@testable import EdmundCore

/// Each fenced code block carries a copy button in the line numbers' slot,
/// level with its opening fence, revealed by hovering the block. It puts the
/// lines between the fences on the pasteboard. Edit mode only.
@Suite("Code block copy button")
@MainActor
struct CodeCopyButtonTests {

    private let fence = "```swift\nlet x = 1\nlet y = 2\n```"

    private func loadEditor(_ text: String) -> EditorTextView {
        let editor = makeEditor()
        editor.updateContentInset()
        editor.loadContent(text)
        ensureFullLayout(editor)
        layOutViewport(editor)
        return editor
    }

    @Test("A fence gets one button, level with its opening fence line")
    func oneButtonPerFence() {
        let editor = loadEditor("lead\n\n\(fence)\n\ntrailing\n")
        let buttons = editor.visibleCodeCopyButtons()
        #expect(buttons.count == 1)
        guard let button = buttons.first else { return }
        #expect(editor.blocks[button.blockIndex].kind == .fence)
        let fenceStart = editor.blocks[button.blockIndex].range.location
        guard let lineRect = editor.lineRect(forCharacterAt: fenceStart) else {
            Issue.record("fence line has no laid-out rect")
            return
        }
        #expect(abs(button.rect.midY - lineRect.midY) < editor.bodyFont.pointSize)
        // Outside the text column, in the numbers' slot.
        #expect(button.rect.maxX <= editor.textContainerOrigin.x
            + (editor.textContainer?.lineFragmentPadding ?? 0))
    }

    /// The same slot the `</>` button uses — a number's own right edge, and the
    /// same square — so the two line up in a document that has both.
    @Test("The button sits in the line numbers' slot, like `</>`")
    func sitsInTheLineNumberSlot() {
        let editor = loadEditor("lead\n\n\(fence)\n")
        guard let copy = editor.visibleCodeCopyButtons().first else {
            Issue.record("no button")
            return
        }
        let rightEdge = editor.textContainerOrigin.x
            + (editor.textContainer?.lineFragmentPadding ?? 0)
            - EditorTextView.lineNumberPadding
            - editor.lineNumberStyle.digitWidth
        #expect(abs(copy.rect.maxX - rightEdge) < 0.5)
        #expect(copy.rect.width == EditorTextView.tableRawButtonSize)
    }

    @Test("Indented code and Source mode get no button")
    func onlyFencesInEditMode() {
        let indented = loadEditor("para\n\n    let x = 1\n")
        #expect(indented.visibleCodeCopyButtons().isEmpty)

        let source = loadEditor(fence)
        source.viewMode = .source
        #expect(source.visibleCodeCopyButtons().isEmpty)
    }

    @Test("Hover is the only reveal")
    func revealedByHover() {
        let editor = loadEditor(fence)
        #expect(editor.revealedCodeCopyButtons().isEmpty)
        editor.hoveredCodeBlock = editor.visibleCodeCopyButtons().first?.blockIndex
        #expect(editor.revealedCodeCopyButtons().count == 1)
    }

    /// The press writes the pasteboard and holds the button up, filled, for
    /// the flash — even with the pointer gone — until the timer clears it.
    @Test("Pressing the button copies and flashes it filled")
    func pressCopiesAndFlashes() {
        let editor = loadEditor(fence)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("CodeCopyButtonTests"))
        editor.copyCodeBlock(blockIndex: 0, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "let x = 1\nlet y = 2")
        #expect(editor.copiedCodeBlock == 0)
        #expect(editor.revealedCodeCopyButtons().count == 1)   // no hover needed
        editor.endCopiedFlash()
        #expect(editor.copiedCodeBlock == nil)
        #expect(editor.revealedCodeCopyButtons().isEmpty)
    }

    /// The blink is on at the click and gone well before the fill releases.
    @Test("The copied blink is full at once and gone early")
    func blinkShape() {
        let end = EditorTextView.codeCopiedBlinkEnd
        #expect(EditorTextView.copiedPulseAlpha(at: 0) == 1)
        #expect(EditorTextView.copiedPulseAlpha(at: end / 2) < 0.2)
        #expect(EditorTextView.copiedPulseAlpha(at: end) == 0)
        #expect(EditorTextView.copiedPulseAlpha(at: 1) == 0)
    }

    @Test("The button scales with the zoom")
    func scalesWithZoom() {
        let editor = loadEditor(fence)
        let base = editor.visibleCodeCopyButtons().first?.rect.width
        editor.setZoom(1.5)
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleCodeCopyButtons().first?.rect.width == base.map { $0 * 1.5 })
        editor.setZoom(1)
        ensureFullLayout(editor)
        layOutViewport(editor)
        #expect(editor.visibleCodeCopyButtons().first?.rect.width == base)
    }

    @Test("The copied text is the lines between the fences")
    func fenceContentStripsTheFences() {
        let editor = loadEditor("intro\n\n\(fence)\n\n~~~\ntilde\n~~~\n\n```\nopen\nended")
        let fences = editor.blocks.indices.filter { editor.blocks[$0].kind == .fence }
        #expect(fences.count == 3)
        #expect(editor.fenceContent(blockIndex: fences[0]) == "let x = 1\nlet y = 2")
        #expect(editor.fenceContent(blockIndex: fences[1]) == "tilde")
        // An unterminated fence runs to the end of the document: nothing to drop.
        #expect(editor.fenceContent(blockIndex: fences[2]) == "open\nended")
    }
}
