import AppKit

// MARK: - Popup table-cell editor
//
// Clicking a rendered table cell opens its markdown in a popover instead of
// putting a caret in the table. The popover has its own layout and its own text
// storage, which is what makes it worth the trouble:
//
//   - A cell that overflows its column is drawn from a detached scratch layout
//     (`.tableCellWraps`), so a caret in the host storage cannot follow the
//     glyphs the reader sees.
//   - A cell's structural pipes are hidden zero-width glyphs, so caret motion
//     across them has to be hand-built.
//   - IME composition would land on the document's own storage, which is the
//     delete-drift bug class (ARCHITECTURE §8).
//
// None of those apply to a separate text view. Write-back is then one
// contiguous range replacement through `applyFormattingEdit`, the same
// primitive the Format menu uses.
//
// Escape cancels; ⏎ and clicking away commit (`.transient` gives Esc and
// click-outside dismissal for free — same as the Format popover).

extension EditorTextView {

    /// Smallest the popup is allowed to be, so a narrow column still gets a
    /// usable field.
    private static let cellEditorMinWidth: CGFloat = 220

    // MARK: - Geometry

    /// The on-screen rect of a cell's content (view coordinates).
    ///
    /// The cell's characters are all present in storage — hiding a delimiter is
    /// attribute-only — so its own text segments give the rect, and no column
    /// geometry has to be persisted out of `styleTableSpan` for this. That holds
    /// for an overflowing cell too: its characters are hidden but its trailing
    /// character carries a `.kern` of the column's full slack, so the segments
    /// still span the column.
    func tableCellRect(for cell: TableCellRef) -> NSRect? {
        guard let tlm = textLayoutManager,
              let range = blockTextRange(cell.contentRange, tlm) else { return nil }
        let origin = textContainerOrigin
        var union: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            let r = frame.offsetBy(dx: origin.x, dy: origin.y)
            union = union.map { $0.union(r) } ?? r
            return true
        }
        return union
    }

    // MARK: - Opening

    /// The cell a click would edit, or nil if the click isn't on an editable
    /// cell of a *rendered* table.
    ///
    /// A table showing its raw markdown is excluded: the caret is already in it,
    /// the user is already editing the source, and a popover on top of that
    /// would be two editors for one piece of text.
    func tableCellForCellEditor(at event: NSEvent) -> TableCellRef? {
        guard let offset = wrappedCellCharIndex(at: event) ?? clickCharIndex(at: event),
              let cell = tableCell(atRawOffset: offset),
              activeBlockIndex != cell.blockIndex else { return nil }
        return cell
    }

    /// Opens the popup editor on `cell`.
    func openTableCellEditor(_ cell: TableCellRef) {
        closeTableCellEditor(commit: false)
        guard let anchor = tableCellRect(for: cell) else { return }

        editingTableCell = cell

        let text = (rawSource as NSString).substring(with: cell.contentRange)
        let controller = TableCellEditorController(
            text: text,
            width: max(Self.cellEditorMinWidth, anchor.width),
            font: bodyFont,
            onCommit: { [weak self] in self?.closeTableCellEditor(commit: true) },
            onCancel: { [weak self] in self?.closeTableCellEditor(commit: false) })

        let popover = NSPopover()
        popover.behavior = .transient      // Esc + click-outside dismissal, free
        popover.contentViewController = controller
        popover.delegate = self
        tableCellPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        controller.focus()
    }

    // MARK: - Closing and write-back

    /// Closes the popup, writing its text back when `commit`.
    ///
    /// Called both from the popover's own dismissal and from Esc/⏎, so it has to
    /// be safe to call twice — `editingTableCell` is cleared first and guards
    /// the re-entry `popover.close()` triggers.
    func closeTableCellEditor(commit: Bool) {
        guard let cell = editingTableCell else { return }
        let controller = tableCellPopover?.contentViewController as? TableCellEditorController
        editingTableCell = nil

        let popover = tableCellPopover
        tableCellPopover = nil
        popover?.delegate = nil
        popover?.close()

        guard commit, let controller else { return }
        commitTableCell(cell, text: controller.committedText())
    }

    /// Writes `text` back into `cell`, as one undoable step.
    func commitTableCell(_ cell: TableCellRef, text: String) {
        guard cell.blockIndex < blocks.count,
              blocks[cell.blockIndex].kind == .table,
              cell.contentRange.upperBound <= (rawSource as NSString).length else { return }
        let replacement = Self.sanitizedTableCellText(text)
        let existing = (rawSource as NSString).substring(with: cell.contentRange)
        guard replacement != existing else { return }

        // Keep the caret where it was. Anywhere inside the table would make it
        // the active block and render it raw, undoing the popover's whole point.
        // The live selection *is* the pre-edit one: opening the popover consumes
        // the click before `super.mouseDown`, so AppKit never moved the caret.
        let delta = (replacement as NSString).length - cell.contentRange.length
        var caret = selectedRange()
        if caret.location >= cell.contentRange.upperBound {
            caret.location += delta
        }
        applyFormattingEdit(rawRange: cell.contentRange, replacement: replacement, select: caret)
    }

    /// Makes `text` safe to drop between two pipes.
    ///
    /// A GFM cell cannot span lines, and an unescaped `|` would silently split
    /// the cell in two — so both are neutralised rather than allowed to corrupt
    /// the table's shape. `\|` is content the parser already understands (GFM
    /// Example 200, honoured by `cellRanges`/`splitTableRow`).
    static func sanitizedTableCellText(_ text: String) -> String {
        var out = ""
        var prevWasBackslash = false
        for ch in text {
            switch ch {
            // `isNewline`, not a list of literals: "\r\n" is a single Swift
            // Character, so matching "\n" and "\r" separately misses it and
            // lets a CRLF through into the row.
            case let ch where ch.isNewline:
                out.append(" ")
            case "|" where !prevWasBackslash:
                out.append("\\|")
            default:
                out.append(ch)
            }
            prevWasBackslash = (ch == "\\") && !prevWasBackslash
        }
        // Single spaces around the content keep the raw markdown readable, and
        // match how a table written by hand looks.
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? " " : " \(trimmed) "
    }
}

// MARK: - Popover dismissal

extension EditorTextView: NSPopoverDelegate {
    /// Click-outside dismissal commits, matching "commit on close".
    public func popoverDidClose(_ notification: Notification) {
        closeTableCellEditor(commit: true)
    }
}

// MARK: - The popup itself

/// A one-cell markdown editor: a plain `NSTextView`, deliberately not an
/// `EditorTextView`. It wants none of the block pipeline — there is one block,
/// it is a few dozen characters, and it is not the document.
@MainActor
final class TableCellEditorController: NSViewController {

    private let field = CellTextView()
    private let initialText: String
    private let width: CGFloat
    private let font: NSFont
    private let onCommit: () -> Void

    init(text: String, width: CGFloat, font: NSFont,
         onCommit: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.initialText = text
        self.width = width
        self.font = font
        self.onCommit = onCommit
        super.init(nibName: nil, bundle: nil)
        field.onCancel = onCancel
        field.onCommit = onCommit
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        field.string = initialText.trimmingCharacters(in: .whitespaces)
        field.font = font
        field.isRichText = false
        field.isAutomaticQuoteSubstitutionEnabled = false
        field.isAutomaticDashSubstitutionEnabled = false
        field.isAutomaticTextReplacementEnabled = false
        // Same reason the main editor disables it: completion injects
        // provisional marked text, and marked text is the hazard here.
        field.isAutomaticTextCompletionEnabled = false
        field.drawsBackground = false
        field.textContainerInset = NSSize(width: 6, height: 8)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.textContainer?.widthTracksTextView = true
        field.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = field
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: 0)
        view = scroll
        resizeToFitText()
    }

    /// Grows the popover with the text, within reason.
    private func resizeToFitText() {
        guard let container = field.textContainer, let tlm = field.textLayoutManager else { return }
        container.size = NSSize(width: width - 2 * field.textContainerInset.width,
                                height: .greatestFiniteMagnitude)
        tlm.ensureLayout(for: tlm.documentRange)
        var height: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            height = max(height, $0.layoutFragmentFrame.maxY)
            return true
        }
        let total = min(max(height + 2 * field.textContainerInset.height, 34), 220)
        preferredContentSize = NSSize(width: width, height: total)
    }

    func focus() {
        view.window?.makeFirstResponder(field)
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
    }

    /// The edited text, with any in-flight IME composition finalised first —
    /// reading `string` mid-composition would capture a half-formed syllable.
    func committedText() -> String {
        if field.hasMarkedText() {
            field.inputContext?.discardMarkedText()
            field.unmarkText()
        }
        return field.string
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focus()
    }
}

/// The popup's text view. Esc cancels, ⏎ commits — a table cell cannot hold a
/// newline, so Return has nothing else to mean here.
@MainActor
private final class CellTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func insertNewline(_ sender: Any?) {
        onCommit?()
    }
}
