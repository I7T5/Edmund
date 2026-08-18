import AppKit

// MARK: - Popup table-cell editor
//
// Clicking a rendered table cell opens its markdown in a small panel below the
// table. The panel has its own layout and its own text storage, which is what
// makes it worth the trouble:
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
// It is deliberately *not* an NSPopover. A popover centres its body on its
// positioning rect, so the body always travels with the arrow — and the whole
// point here is the opposite: the panel spans the table and holds still while
// only the arrow slides to the column being edited. Owning the drawing also
// means the same class serves the attached and the torn-off states.
//
// The panel is a child window of the document window, so it follows the window
// for free; only scrolling and resizing need repositioning by hand.

extension EditorTextView {

    /// Smallest the popup is allowed to be, so a narrow table still gets a
    /// usable field.
    static let cellEditorMinWidth: CGFloat = 220

    /// Air between the table's bottom edge and the panel's arrow.
    private static let cellEditorGap: CGFloat = 4

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

    /// How far along the card the arrow sits: the cell's centre, measured from
    /// the table's left edge. This is the *only* thing that changes as the user
    /// moves along a row — the card itself spans the table and holds still.
    func cellEditorArrowX(for cell: TableCellRef) -> CGFloat? {
        guard let table = tableRect(blockIndex: cell.blockIndex),
              let cellRect = tableCellRect(for: cell) else { return nil }
        return cellRect.midX - table.minX
    }

    /// Where the panel goes, in screen coordinates, and where its arrow points.
    ///
    /// The frame spans the table and sits under it; only `arrowX` changes as the
    /// user moves along a row. Returns nil when the table isn't laid out.
    func cellEditorPlacement(for cell: TableCellRef, height: CGFloat)
        -> (frame: NSRect, arrowX: CGFloat)? {
        guard let window,
              let table = tableRect(blockIndex: cell.blockIndex),
              let cellRect = tableCellRect(for: cell) else { return nil }
        // The view is flipped, so the table's bottom edge is its maxY.
        let bottomLeftInView = NSPoint(x: table.minX, y: table.maxY)
        let inWindow = convert(bottomLeftInView, to: nil)
        let onScreen = window.convertPoint(toScreen: inWindow)
        let width = max(Self.cellEditorMinWidth, table.width)
        let frame = NSRect(x: onScreen.x,
                           y: onScreen.y - Self.cellEditorGap - height,
                           width: width, height: height)
        return (frame, cellRect.midX - table.minX)
    }

    // MARK: - Opening

    /// The cell a click would edit, or nil if the click isn't on an editable
    /// cell of a *rendered* table.
    ///
    /// A table showing its raw markdown is excluded: the caret is already in it,
    /// the user is already editing the source, and a second editor on top of
    /// that would be two editors for one piece of text.
    func tableCellForCellEditor(at event: NSEvent) -> TableCellRef? {
        guard let offset = wrappedCellCharIndex(at: event) ?? clickCharIndex(at: event),
              let cell = tableCell(atRawOffset: offset),
              activeBlockIndex != cell.blockIndex else { return nil }
        return cell
    }

    /// Opens the popup editor on `cell`, or slides an open one over to it.
    func openTableCellEditor(_ cell: TableCellRef) {
        if let current = editingTableCell, current.blockIndex == cell.blockIndex,
           cellEditorPanel != nil, !isCellEditorDetached {
            moveTableCellEditor(toRow: cell.row, column: cell.column)
            return
        }
        closeTableCellEditor(commit: true)
        guard let window else { return }

        editingTableCell = cell
        let controller = TableCellEditorController(
            text: (rawSource as NSString).substring(with: cell.contentRange),
            font: bodyFont,
            style: { [weak self] text, caret in
                self?.styleBlock(text, cursorPosition: caret)
            },
            onCommit: { [weak self] in self?.closeTableCellEditor(commit: true) },
            onCancel: { [weak self] in self?.closeTableCellEditor(commit: false) },
            onTear: { [weak self] event in self?.detachCellEditor(with: event) },
            onStep: { [weak self] delta in self?.stepTableCellEditor(by: delta) })
        controller.onHeightChange = { [weak self] in self?.repositionCellEditor() }

        let panel = CellEditorPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 60))
        panel.controller = controller
        panel.contentView = controller.view
        cellEditorPanel = panel
        isCellEditorDetached = false

        repositionCellEditor()
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        controller.focus()
        observeForCellEditor()
    }

    /// Puts the panel back under its table at its current height, and moves the
    /// arrow to the column being edited. The frame is recomputed from scratch,
    /// so a table that changed width (a commit can redistribute the columns)
    /// carries the panel with it.
    func repositionCellEditor() {
        guard let panel = cellEditorPanel, let controller = panel.controller,
              let cell = editingTableCell, !isCellEditorDetached else { return }
        guard let placement = cellEditorPlacement(for: cell,
                                                  height: controller.fittingHeight(width: nil))
        else {
            closeTableCellEditor(commit: true)
            return
        }
        controller.setArrowX(placement.arrowX)
        // Height is measured against the width the panel is about to have, then
        // the frame is built from that height — otherwise a width change and a
        // wrap change chase each other by one frame.
        let height = controller.fittingHeight(width: placement.frame.width)
        var frame = placement.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    /// Commits the open cell and re-anchors on another cell of the same table.
    /// Only the arrow moves — the panel spans the table, so the field stays
    /// exactly where the user is already looking.
    func moveTableCellEditor(toRow row: Int, column: Int) {
        guard let current = editingTableCell,
              let controller = cellEditorController else { return }
        commitTableCell(current, text: controller.committedText())

        // After the commit the table has been reparsed and relaid out, so the
        // target has to be found again by position — its old range is stale.
        guard let target = tableCell(blockIndex: current.blockIndex, row: row, column: column)
        else {
            closeTableCellEditor(commit: false)
            return
        }
        editingTableCell = target
        controller.load(text: (rawSource as NSString).substring(with: target.contentRange))
        repositionCellEditor()
        controller.focus()
    }

    /// The cell one step along the current row, for Tab / Shift-Tab.
    func stepTableCellEditor(by delta: Int) {
        guard let current = editingTableCell,
              tableCell(blockIndex: current.blockIndex,
                        row: current.row, column: current.column + delta) != nil else { return }
        moveTableCellEditor(toRow: current.row, column: current.column + delta)
    }

    var cellEditorController: TableCellEditorController? { cellEditorPanel?.controller }

    // MARK: - Tear-off

    /// Pulls the panel off the table into a free-floating window, the way a
    /// Calendar event's popover detaches when you drag it. Nothing is rebuilt —
    /// the same window stops being a child and stops tracking.
    func detachCellEditor(with event: NSEvent) {
        guard let panel = cellEditorPanel, !isCellEditorDetached else { return }
        isCellEditorDetached = true
        window?.removeChildWindow(panel)
        panel.level = .floating
        panel.controller?.setDetached(true)
        panel.makeKeyAndOrderFront(nil)
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
        stopObservingForCellEditor()

        let panel = cellEditorPanel
        cellEditorPanel = nil
        isCellEditorDetached = false
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.controller = nil
            panel.close()
        }

        guard commit, let controller else { return }
        commitTableCell(cell, text: controller.committedText())
    }

    /// A click anywhere that isn't a cell of the table being edited ends the
    /// edit. Nothing dismisses this panel for us.
    func dismissCellEditorIfClickIsOutside(_ event: NSEvent) {
        guard editingTableCell != nil, !isCellEditorDetached else { return }
        if let cell = tableCellForCellEditor(at: event),
           cell.blockIndex == editingTableCell?.blockIndex { return }
        closeTableCellEditor(commit: true)
    }

    private func observeForCellEditor() {
        stopObservingForCellEditor()
        guard let window else { return }
        let center = NotificationCenter.default
        cellEditorKeyObserver = center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isCellEditorDetached else { return }
                self.closeTableCellEditor(commit: true)
            }
        }
        // The panel is a child window, so it follows the window on its own; it
        // does not follow the *content* scrolling under it.
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            cellEditorScrollObserver = center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.repositionCellEditor() }
            }
        }
    }

    private func stopObservingForCellEditor() {
        for token in [cellEditorKeyObserver, cellEditorScrollObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(token)
        }
        cellEditorKeyObserver = nil
        cellEditorScrollObserver = nil
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
        // the active block and render it raw, undoing the popup's whole point.
        // The live selection *is* the pre-edit one: opening the popup consumes
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

// MARK: - The window

/// Borderless so it reads as a card rather than a document window, which means
/// `canBecomeKey` has to be granted by hand — a borderless window is refused key
/// status otherwise, and this one has to take typing.
@MainActor
public final class CellEditorPanel: NSPanel {
    var controller: TableCellEditorController?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
    }

    public override var canBecomeKey: Bool { true }
}

// MARK: - The bubble

/// Draws the card and its arrow. The arrow's x is the only thing that changes
/// as the user moves along a row.
@MainActor
final class CellEditorChrome: NSView {
    static let arrowHeight: CGFloat = 7
    static let arrowHalfWidth: CGFloat = 7
    static let cornerRadius: CGFloat = 7

    var arrowX: CGFloat = 20 { didSet { needsDisplay = true } }
    var showsArrow = true { didSet { needsDisplay = true } }

    /// A drag starting on the card's own surface — the padding above the text,
    /// never the text itself, which has to keep its selection drag — tears the
    /// card off the table.
    var onDrag: ((NSEvent) -> Void)?
    private var dragOrigin: NSPoint?

    override func mouseDown(with event: NSEvent) { dragOrigin = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragOrigin else { return }
        let moved = hypot(event.locationInWindow.x - start.x,
                          event.locationInWindow.y - start.y)
        // A few points of slop, so a twitch on mouse-down doesn't tear it off.
        guard moved > 4 else { return }
        dragOrigin = nil
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { dragOrigin = nil }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 0.5
        let top = bounds.maxY - (showsArrow ? Self.arrowHeight : 0)
        let body = NSRect(x: bounds.minX + inset, y: bounds.minY + inset,
                          width: bounds.width - 2 * inset, height: top - bounds.minY - inset)
        let path = NSBezierPath(roundedRect: body,
                                xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        if showsArrow {
            let x = min(max(arrowX, Self.cornerRadius + Self.arrowHalfWidth),
                        bounds.maxX - Self.cornerRadius - Self.arrowHalfWidth)
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x - Self.arrowHalfWidth, y: top))
            arrow.line(to: NSPoint(x: x, y: bounds.maxY))
            arrow.line(to: NSPoint(x: x + Self.arrowHalfWidth, y: top))
            arrow.close()
            path.append(arrow)
        }
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - The editor itself

/// A one-cell markdown editor: a plain `NSTextView`, deliberately not an
/// `EditorTextView`. It wants none of the block pipeline — there is one block,
/// it is a few dozen characters, and it is not the document.
@MainActor
public final class TableCellEditorController: NSViewController {

    private let field = CellTextView()
    private let scroll = NSScrollView()
    private let closeButton = NSButton()
    private let chrome = CellEditorChrome()
    private var initialText: String
    private let font: NSFont

    /// Air above the text. Doubles as the only place a drag can start a
    /// tear-off — a drag on the text itself has to stay a selection.
    private static let topPadding: CGFloat = 18
    private static let bottomPadding: CGFloat = 6

    var onHeightChange: (() -> Void)?

    init(text: String, font: NSFont,
         style: @escaping (String, Int?) -> NSAttributedString?,
         onCommit: @escaping () -> Void, onCancel: @escaping () -> Void,
         onTear: @escaping (NSEvent) -> Void, onStep: @escaping (Int) -> Void) {
        self.initialText = text
        self.font = font
        super.init(nibName: nil, bundle: nil)
        field.onCancel = onCancel
        field.onCommit = onCommit
        field.onStep = onStep
        field.style = style
        field.onTextChanged = { [weak self] in self?.onHeightChange?() }
        chrome.onDrag = onTear
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override func loadView() {
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
        field.textContainerInset = NSSize(width: 8, height: 0)
        field.isVerticallyResizable = true
        field.isHorizontallyResizable = false
        field.textContainer?.widthTracksTextView = true
        field.textContainer?.lineFragmentPadding = 0

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.documentView = field

        closeButton.isHidden = true          // only the torn-off window shows it
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Close")
        closeButton.target = field
        closeButton.action = #selector(CellTextView.commitFromButton)

        chrome.addSubview(scroll)
        chrome.addSubview(closeButton)
        view = chrome
        field.restyle()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        layOutContents()
    }

    private func layOutContents() {
        let arrow = chrome.showsArrow ? CellEditorChrome.arrowHeight : 0
        let h = chrome.bounds.height
        let top = h - arrow - Self.topPadding
        scroll.frame = NSRect(x: 0, y: Self.bottomPadding,
                              width: chrome.bounds.width,
                              height: max(0, top - Self.bottomPadding))
        closeButton.frame = NSRect(x: 6, y: h - arrow - 15, width: 13, height: 13)
    }

    /// Height the card needs for its text at `width` (nil = the current width).
    func fittingHeight(width: CGFloat?) -> CGFloat {
        let w = width ?? max(chrome.bounds.width, EditorTextView.cellEditorMinWidth)
        let inner = max(10, w - 2 * field.textContainerInset.width)
        guard let container = field.textContainer, let tlm = field.textLayoutManager else {
            return 44
        }
        container.size = NSSize(width: inner, height: .greatestFiniteMagnitude)
        tlm.ensureLayout(for: tlm.documentRange)
        var textHeight: CGFloat = 0
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.location, options: []) {
            textHeight = max(textHeight, $0.layoutFragmentFrame.maxY)
            return true
        }
        let arrow = chrome.showsArrow ? CellEditorChrome.arrowHeight : 0
        let body = min(max(textHeight, font.pointSize + 6), 260)
        return arrow + Self.topPadding + body + Self.bottomPadding
    }

    /// Swaps in another cell's text without rebuilding the card.
    func load(text: String) {
        initialText = text
        field.string = text.trimmingCharacters(in: .whitespaces)
        field.restyle()
    }

    func setArrowX(_ x: CGFloat) { chrome.arrowX = x }

    func setDetached(_ detached: Bool) {
        closeButton.isHidden = !detached
        chrome.showsArrow = !detached
        layOutContents()
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
}

// MARK: - The field

/// Esc cancels, ⏎ commits, Tab steps along the row — a table cell cannot hold a
/// newline or a tab, so none of those keys has anything else to mean here.
///
/// The text renders with the document's own inline styling, live. That is a
/// single `styleBlock` call because the card holds exactly one block of a few
/// dozen characters: none of the incremental machinery the main editor needs
/// (block diffing, dirty sets, lazy styling, viewport layout) applies at this
/// size, so a full restyle per keystroke is the cheap option as well as the
/// simple one.
@MainActor
private final class CellTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?
    var onStep: ((Int) -> Void)?
    var onTextChanged: (() -> Void)?
    var style: ((String, Int?) -> NSAttributedString?)?

    private var isRestyling = false

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func insertTab(_ sender: Any?) { onStep?(1) }
    override func insertBacktab(_ sender: Any?) { onStep?(-1) }

    @objc func commitFromButton() { onCommit?() }

    override func didChangeText() {
        super.didChangeText()
        restyle()
        onTextChanged?()
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity,
                                    stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Which delimiters show depends on where the caret is, exactly as it
        // does in the document.
        guard !stillSelecting, !isRestyling else { return }
        restyle()
    }

    /// Re-applies the document's inline styling to the whole field.
    func restyle() {
        // Never while an IME is composing: storage holds provisional marked text
        // then, and restyling through it is what strands the composition
        // (ARCHITECTURE §8).
        guard !isRestyling, !hasMarkedText(), let style,
              let storage = textStorage else { return }
        let text = storage.string
        guard let styled = style(text, selectedRange().location),
              styled.length == (text as NSString).length else { return }
        isRestyling = true
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        styled.enumerateAttributes(in: full) { attrs, range, _ in
            // Paragraph style is the card's own business — the document's block
            // spacing and indents would push the single line around.
            var attrs = attrs
            attrs.removeValue(forKey: .paragraphStyle)
            storage.setAttributes(attrs, range: range)
        }
        storage.endEditing()
        isRestyling = false
    }
}
