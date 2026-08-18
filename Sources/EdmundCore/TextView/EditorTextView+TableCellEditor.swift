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
// The popup is as wide as the table and keeps that width from cell to cell, so
// only its arrow travels as the user moves along a row — the field itself never
// jumps out from under them. It grows downward as the text gets longer.
//
// Dragging it off tears it out into a small floating window with a close box,
// the way a Calendar event's popover detaches.
//
// Dismissal is hand-rolled (`.applicationDefined`) rather than `.transient`,
// because transient closes on the very click that should have moved the popup
// to the next cell.

extension EditorTextView {

    /// Smallest the popup is allowed to be, so a narrow table still gets a
    /// usable field.
    static let cellEditorMinWidth: CGFloat = 220

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
        return unionOfSegments(in: range, tlm)
    }

    /// The on-screen rect of a whole table (view coordinates).
    func tableRect(blockIndex: Int) -> NSRect? {
        guard blockIndex < blocks.count,
              let tlm = textLayoutManager,
              let range = blockTextRange(blocks[blockIndex].range, tlm) else { return nil }
        return unionOfSegments(in: range, tlm)
    }

    private func unionOfSegments(in range: NSTextRange, _ tlm: NSTextLayoutManager) -> NSRect? {
        let origin = textContainerOrigin
        var union: NSRect?
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            let r = frame.offsetBy(dx: origin.x, dy: origin.y)
            union = union.map { $0.union(r) } ?? r
            return true
        }
        return union
    }

    /// The width the popup takes for a table: the table's own width, so moving
    /// between cells slides the arrow without resizing the field.
    func cellEditorWidth(blockIndex: Int) -> CGFloat {
        max(Self.cellEditorMinWidth, tableRect(blockIndex: blockIndex)?.width ?? 0)
    }

    /// Re-resolves a cell by position rather than by range.
    ///
    /// Ranges shift the moment a commit changes a cell's length, so moving from
    /// one cell to the next has to name the target by where it sits in the
    /// table, not by the offsets that were valid before the write.
    func tableCell(blockIndex: Int, row: Int, column: Int) -> TableCellRef? {
        guard blockIndex < blocks.count, blocks[blockIndex].kind == .table else { return nil }
        let block = blocks[blockIndex]
        let lines = block.content.components(separatedBy: "\n")
        guard row >= 0, row < lines.count, row != 1 else { return nil }
        var lineStart = 0
        for (i, line) in lines.enumerated() {
            let lineNS = line as NSString
            if i == row {
                let cells = cellRanges(in: lineNS)
                guard column >= 0, column < cells.count else { return nil }
                let cell = cells[column]
                return TableCellRef(
                    blockIndex: blockIndex, row: row, column: column,
                    contentRange: NSRange(location: block.range.location + lineStart + cell.start,
                                          length: cell.end - cell.start))
            }
            lineStart += lineNS.length + 1
        }
        return nil
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

    /// Opens the popup editor on `cell`, or slides an open one over to it.
    func openTableCellEditor(_ cell: TableCellRef) {
        // Same table: keep the popup, commit what's in it, and move the arrow.
        if let current = editingTableCell, current.blockIndex == cell.blockIndex,
           tableCellPopover != nil, !isCellEditorDetached {
            moveTableCellEditor(toRow: cell.row, column: cell.column)
            return
        }
        closeTableCellEditor(commit: true)
        guard let anchor = tableCellRect(for: cell) else { return }

        editingTableCell = cell
        let controller = TableCellEditorController(
            text: (rawSource as NSString).substring(with: cell.contentRange),
            width: cellEditorWidth(blockIndex: cell.blockIndex),
            font: bodyFont,
            onCommit: { [weak self] in self?.closeTableCellEditor(commit: true) },
            onCancel: { [weak self] in self?.closeTableCellEditor(commit: false) },
            onTear: { [weak self] event in self?.detachCellEditor(with: event) },
            onStep: { [weak self] delta in self?.stepTableCellEditor(by: delta) })

        let popover = NSPopover()
        // Not `.transient`: that would close on the very click meant to move the
        // popup to the next cell. Dismissal is handled here instead — see
        // `mouseDown` and `windowDidResignKey`.
        popover.behavior = .applicationDefined
        popover.contentViewController = controller
        tableCellPopover = popover
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        controller.focus()
        observeKeyLossForCellEditor()
    }

    /// Commits the open cell and re-anchors on another cell of the same table.
    /// Only the arrow moves: the popup keeps the table's width, so the field
    /// stays exactly where the user is already looking.
    func moveTableCellEditor(toRow row: Int, column: Int) {
        guard let current = editingTableCell,
              let controller = cellEditorController else { return }
        commitTableCell(current, text: controller.committedText())

        // After the commit the table has been reparsed and relaid out, so the
        // target has to be found again by position — its old range is stale.
        guard let target = tableCell(blockIndex: current.blockIndex, row: row, column: column),
              let anchor = tableCellRect(for: target) else {
            closeTableCellEditor(commit: false)
            return
        }
        editingTableCell = target
        controller.load(text: (rawSource as NSString).substring(with: target.contentRange),
                        width: cellEditorWidth(blockIndex: target.blockIndex))
        tableCellPopover?.positioningRect = anchor
        controller.focus()
    }

    /// The cell one step along the current row, for Tab / Shift-Tab.
    func stepTableCellEditor(by delta: Int) {
        guard let current = editingTableCell,
              tableCell(blockIndex: current.blockIndex,
                        row: current.row, column: current.column + delta) != nil else { return }
        moveTableCellEditor(toRow: current.row, column: current.column + delta)
    }

    var cellEditorController: TableCellEditorController? {
        (tableCellPopover?.contentViewController as? TableCellEditorController)
            ?? detachedCellEditor?.editorController
    }

    var isCellEditorDetached: Bool { detachedCellEditor != nil }

    // MARK: - Tear-off

    /// Pulls the popup out into a small floating window, the way a Calendar
    /// event's popover detaches when you drag it.
    ///
    /// The controller's view is moved rather than rebuilt, so the text, the
    /// selection and the field's own undo all survive the transition.
    func detachCellEditor(with event: NSEvent) {
        guard let popover = tableCellPopover,
              let controller = popover.contentViewController as? TableCellEditorController,
              let screenOrigin = popover.contentViewController?.view.window?.frame.origin
        else { return }
        let size = controller.view.frame.size

        controller.view.removeFromSuperview()
        popover.contentViewController = nil
        tableCellPopover = nil
        popover.close()

        let panel = DetachedCellEditorPanel(
            contentRect: NSRect(origin: screenOrigin, size: size))
        panel.editorController = controller
        controller.setDetached(true)
        panel.contentView = controller.view
        panel.makeKeyAndOrderFront(nil)
        detachedCellEditor = panel
        controller.focus()
        // Continue the same gesture, so the window comes away under the pointer
        // instead of appearing and waiting for a second drag.
        panel.performDrag(with: event)
    }

    // MARK: - Closing and write-back

    /// Closes the popup, writing its text back when `commit`.
    ///
    /// Safe to call twice: `editingTableCell` is cleared first, which guards the
    /// re-entry that closing can itself provoke.
    func closeTableCellEditor(commit: Bool) {
        guard let cell = editingTableCell else { return }
        let controller = cellEditorController
        editingTableCell = nil
        stopObservingKeyLossForCellEditor()

        let popover = tableCellPopover
        tableCellPopover = nil
        popover?.close()

        let panel = detachedCellEditor
        detachedCellEditor = nil
        panel?.editorController = nil
        panel?.close()

        guard commit, let controller else { return }
        commitTableCell(cell, text: controller.committedText())
    }

    /// A click anywhere that isn't a cell of the table being edited ends the
    /// edit. `.applicationDefined` popovers don't do this for themselves.
    func dismissCellEditorIfClickIsOutside(_ event: NSEvent) {
        guard editingTableCell != nil, !isCellEditorDetached else { return }
        if let cell = tableCellForCellEditor(at: event),
           cell.blockIndex == editingTableCell?.blockIndex { return }
        closeTableCellEditor(commit: true)
    }

    private func observeKeyLossForCellEditor() {
        stopObservingKeyLossForCellEditor()
        guard let window else { return }
        cellEditorKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCellEditorDetached else { return }
                self.closeTableCellEditor(commit: true)
            }
        }
    }

    private func stopObservingKeyLossForCellEditor() {
        if let token = cellEditorKeyObserver {
            NotificationCenter.default.removeObserver(token)
            cellEditorKeyObserver = nil
        }
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

// MARK: - The detached window

/// The torn-off cell editor. Borderless so it reads as a small floating card
/// rather than a document window, which means `canBecomeKey` has to be granted
/// by hand — a borderless window is refused key status otherwise, and this one
/// has to take typing.
@MainActor
final class DetachedCellEditorPanel: NSPanel {
    weak var editorController: TableCellEditorController?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .windowBackgroundColor
        isOpaque = false
        level = .floating
    }

    override var canBecomeKey: Bool { true }
}

// MARK: - The popup itself

/// A one-cell markdown editor: a plain `NSTextView`, deliberately not an
/// `EditorTextView`. It wants none of the block pipeline — there is one block,
/// it is a few dozen characters, and it is not the document.
@MainActor
final class TableCellEditorController: NSViewController {

    private let field = CellTextView()
    private let scroll = NSScrollView()
    private let closeButton = NSButton()
    private let grip = GripView()
    private var initialText: String
    private var width: CGFloat
    private let font: NSFont
    private let onTear: (NSEvent) -> Void

    /// Height of the drag strip along the top. It is the only place a drag can
    /// start a tear-off — a drag on the text itself has to stay a selection.
    private static let gripHeight: CGFloat = 16

    init(text: String, width: CGFloat, font: NSFont,
         onCommit: @escaping () -> Void, onCancel: @escaping () -> Void,
         onTear: @escaping (NSEvent) -> Void, onStep: @escaping (Int) -> Void) {
        self.initialText = text
        self.width = width
        self.font = font
        self.onTear = onTear
        super.init(nibName: nil, bundle: nil)
        field.onCancel = onCancel
        field.onCommit = onCommit
        field.onResize = { [weak self] in self?.resizeToFitText() }
        field.onStep = onStep
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
        field.textContainerInset = NSSize(width: 6, height: 6)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.textContainer?.widthTracksTextView = true
        field.autoresizingMask = [.width]

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = field

        grip.onDrag = { [weak self] event in self?.onTear(event) }

        closeButton.isHidden = true          // only the torn-off window shows it
        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.target = field
        closeButton.action = #selector(CellTextView.commitFromButton)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        container.addSubview(grip)
        container.addSubview(scroll)
        container.addSubview(closeButton)
        view = container
        layOutContents()
        resizeToFitText()
    }

    private func layOutContents() {
        let h = view.frame.height
        grip.frame = NSRect(x: 0, y: h - Self.gripHeight, width: width, height: Self.gripHeight)
        grip.autoresizingMask = [.width, .minYMargin]
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: max(0, h - Self.gripHeight))
        scroll.autoresizingMask = [.width, .height]
        closeButton.frame = NSRect(x: 3, y: h - Self.gripHeight + 1, width: 14, height: 14)
        closeButton.autoresizingMask = [.minYMargin]
    }

    /// Swaps in another cell's text without rebuilding the popup.
    func load(text: String, width: CGFloat) {
        self.width = width
        self.initialText = text
        field.string = text.trimmingCharacters(in: .whitespaces)
        resizeToFitText()
    }

    /// Grows downward with the text, within reason. The width never changes —
    /// it is the table's — so only the bottom edge moves.
    private func resizeToFitText() {
        guard let container = field.textContainer, let tlm = field.textLayoutManager else { return }
        container.size = NSSize(width: width - 2 * field.textContainerInset.width,
                                height: .greatestFiniteMagnitude)
        tlm.ensureLayout(for: tlm.documentRange)
        var textHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            textHeight = max(textHeight, $0.layoutFragmentFrame.maxY)
            return true
        }
        let body = min(max(textHeight + 2 * field.textContainerInset.height, 26), 260)
        let total = body + Self.gripHeight
        preferredContentSize = NSSize(width: width, height: total)
        if let window = view.window as? DetachedCellEditorPanel {
            // A torn-off window is not driven by `preferredContentSize`; keep
            // its top edge pinned so it too grows downward.
            var frame = window.frame
            frame.origin.y += frame.height - total
            frame.size = NSSize(width: width, height: total)
            window.setFrame(frame, display: true)
        } else {
            view.setFrameSize(NSSize(width: width, height: total))
        }
        layOutContents()
    }

    func setDetached(_ detached: Bool) {
        closeButton.isHidden = !detached
        grip.showsBackground = detached
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

/// The strip along the top of the popup. A drag here tears the popup off; a
/// drag on the text below stays a text selection.
@MainActor
private final class GripView: NSView {
    var onDrag: ((NSEvent) -> Void)?
    var showsBackground = false { didSet { needsDisplay = true } }
    private var down: NSPoint?

    override func mouseDown(with event: NSEvent) { down = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = down else { return }
        let moved = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
        // A few points of slop, so a twitch on mouse-down doesn't tear it off.
        guard moved > 4 else { return }
        down = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { down = nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsBackground else { return }
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
    }
}

/// The popup's text view. Esc cancels, ⏎ commits, Tab steps along the row — a
/// table cell cannot hold a newline or a tab, so neither key has anything else
/// to mean here.
@MainActor
private final class CellTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onResize: (() -> Void)?
    var onStep: ((Int) -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func insertTab(_ sender: Any?) { onStep?(1) }
    override func insertBacktab(_ sender: Any?) { onStep?(-1) }

    @objc func commitFromButton() { onCommit?() }

    override func didChangeText() {
        super.didChangeText()
        onResize?()
    }
}
