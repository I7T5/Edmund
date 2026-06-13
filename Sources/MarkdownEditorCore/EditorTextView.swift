import AppKit

/// A single NSTextView with word-level inline preview.
///
/// ## Architecture
///
/// `rawSource` is the **sole source of truth** for document content.
/// The text storage always contains rawSource — no delimiter stripping.
/// All formatting is achieved through NSAttributedString attributes:
///   - Inline delimiters (`**`, `*`, `` ` ``, etc.) are hidden via near-zero
///     font size when the cursor is not inside the token.
///   - Block-level markers (`#`, `>`, `-`, etc.) are always visible and dimmed.
///   - Content gets rich text styling (bold, italic, colors, etc.).
///
/// **Edits** flow through NSTextView's normal path:
///   1. `shouldChangeText` records an undo snapshot (coalesced), returns `true`
///   2. NSTextView applies the edit to the text storage
///   3. `didChangeText` fires — we sync `rawSource` and re-style the block
///
/// **Cursor movement** is detected via `didChangeSelectionNotification`.
/// When the cursor moves to a different block, we restyle both blocks.
/// When it moves within a block, we update which token's delimiters
/// are visible (the "active token").
///
/// **Undo/Redo** uses custom stacks of `rawSource` snapshots, completely
/// bypassing NSTextView's built-in undo.
public class EditorTextView: NSTextView {

    // MARK: - Document Link

    /// Weak reference to the owning NSDocument, used for dirty-state tracking.
    /// Set by Document.makeWindowControllers(). Not available in unit tests.
    public weak var document: NSDocument?

    // MARK: - State (internal for @testable import)

    public var rawSource: String = ""
    /// Columns of leading whitespace that make up one list-nesting level,
    /// detected from the document (the smallest indent used, or one tab).
    /// Defaults to 4. Used to map a list item's indentation to a nesting depth.
    /// Maintained incrementally from `listIndentState` on the edit path;
    /// rebuilt by the whole-document paths (load, undo, indent).
    public var listIndentUnit: Int = 4
    /// Histogram of indented-list-line indents (see ListIndentState) backing
    /// the incremental `listIndentUnit`.
    var listIndentState = ListIndentState()

    /// Rebuilds the indent histogram from the whole document. O(n) — for the
    /// paths that rebuilt rawSource anyway; the edit path updates per block.
    func rebuildListIndentState() {
        listIndentState = ListIndentState.build(from: rawSource)
        listIndentUnit = listIndentState.unit
    }
    /// Line ending of the most recently loaded content. The buffer itself is
    /// always LF; this is remembered so saves preserve the file's style.
    public var originalLineEnding: LineEnding = .lf
    var blocks: [Block] = []
    var activeBlockIndex: Int? = nil
    var isUpdating = false
    var displayRanges: [NSRange] = []
    private var pendingRecompose = false
    /// Coalesces idle-drain scheduling (see EditorTextView+LazyStyling).
    var progressiveStylingScheduled = false
    /// Coalesces scroll-driven promotion onto the next run-loop turn, off the
    /// scroll notification (see EditorTextView+LazyStyling).
    var pendingPromotion = false
    /// Where the idle drain resumes scanning for unstyled blocks (a hint;
    /// it wraps around and self-corrects after edits shift indices).
    var drainCursor = 0

    // MARK: - Custom Undo/Redo State

    struct UndoSnapshot {
        let rawSource: String
        let cursorInRaw: Int
    }

    enum EditType { case insert, delete, other }

    var undoStack: [UndoSnapshot] = []
    var redoStack: [UndoSnapshot] = []
    var lastEditBlockIndex: Int? = nil
    var lastEditType: EditType = .other
    var isUndoRedoing = false

    /// The separator between blocks in the display.
    /// Must match what BlockParser splits on.
    let blockSeparator = "\n"

    // MARK: - Theme (user-configurable visual settings)

    /// The UserDefaults domain backing theme persistence. Defaults to the
    /// shared `.standard` store; tests override it to isolate from the real
    /// domain (and from each other under parallel execution).
    public var themeDefaults: UserDefaults = .standard

    public var theme: EditorTheme = .load()

    /// User overrides for callout styles, keyed by lowercased type. Lets a
    /// settings layer customize a built-in type's color / icon / border /
    /// background (or add new types). Empty by default (GitHub styles).
    public var calloutStyleOverrides: [String: CalloutStyle] = [:]

    // MARK: - Derived Visual Properties

    var accentColor: NSColor { theme.accentColor }

    /// Foreground color for all body text. Uses the system text color so it
    /// flips automatically between near-black (light) and near-white (dark).
    var foregroundColor: NSColor { .textColor }

    /// Background color for the editor surface. `.textBackgroundColor` is the
    /// standard semantic color for text-editing backgrounds (white / dark gray).
    private var editorBackgroundColor: NSColor { .textBackgroundColor }

    // MARK: - Font & Paragraph Style (derived from theme)

    public var bodyFont: NSFont { theme.bodyFont }

    var bodyParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = theme.lineSpacing
        ps.paragraphSpacingBefore = theme.paragraphSpacingBefore
        ps.paragraphSpacing = 0
        return ps
    }

    /// Apply a new theme, persist it, and restyle every block in place.
    public func applyTheme(_ newTheme: EditorTheme) {
        theme = newTheme
        theme.save(to: themeDefaults)
        typingAttributes = baseAttributes
        recomposeAllDirty()
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: bodyFont,
            .foregroundColor: foregroundColor,
            .paragraphStyle: bodyParagraphStyle,
        ]
    }

    var separatorLength: Int { (blockSeparator as NSString).length }

    // MARK: - Initialization

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    public override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        allowsUndo = false

        backgroundColor = editorBackgroundColor
        insertionPointColor = foregroundColor
        selectedTextAttributes = [
            .backgroundColor: accentColor.withAlphaComponent(0.3),
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes

        rawSource = ""
        rebuildListIndentState()
        blocks = BlockParser.parse(rawSource)
        recompose(cursorInRaw: 0)

        // Vend decoration-drawing layout fragments (TextKit 2).
        textLayoutManager?.delegate = self

        #if DEBUG
        // TextKit 1 fallback is silent and permanent: it happens when any
        // NSLayoutManager API is touched or an unsupported attribute (e.g.
        // NSTextBlock) enters the storage. Fail loudly instead.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textKit1FallbackTripwire(_:)),
            name: NSTextView.willSwitchToNSLayoutManagerNotification,
            object: self
        )
        #endif

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: self
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    #if DEBUG
    @objc private func textKit1FallbackTripwire(_ note: Notification) {
        assertionFailure("""
        TextKit 1 fallback triggered — an NSLayoutManager API was called or an \
        unsupported attribute (NSTextBlock/NSTextTable?) entered the storage.
        """)
    }
    #endif

    /// Hook up scroll promotion once the editor lands in its scroll view.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installScrollPromotionObserver()
    }

    // MARK: - Appearance

    /// Re-render when the system appearance (light ↔ dark) changes.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = editorBackgroundColor
        insertionPointColor = foregroundColor
        selectedTextAttributes = [
            .backgroundColor: accentColor.withAlphaComponent(0.3),
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes
        recomposeAllDirty()
    }

    // MARK: - Edit Flow

    /// NSTextView copies the attributes next to the caret into `typingAttributes`.
    /// When the caret sits beside a hidden delimiter (our near-zero-size
    /// `hiddenFont` + clear color), newly inserted text inherits that invisible
    /// font. Regular typing self-heals via `applyBlockStyle` on each keystroke,
    /// but IME composition (e.g. Pinyin) is deferred while marked — so the
    /// composing text would render invisibly and input appears broken. Refuse the
    /// invisible font here so composition is always visible; the block restyle
    /// still applies the correct final styling on commit.
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            var attrs = newValue
            if let font = attrs[.font] as? NSFont, font.pointSize < 1.0 {
                attrs[.font] = bodyFont
                if (attrs[.foregroundColor] as? NSColor) == .clear {
                    attrs[.foregroundColor] = foregroundColor
                }
            }
            super.typingAttributes = attrs
        }
    }

    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if isUpdating { return false }
        if let replacement = replacementString {
            if !isUndoRedoing {
                recordUndoIfNeeded(editRange: affectedCharRange, replacement: replacement)
            }
        }
        return true
    }

    public override func didChangeText() {
        super.didChangeText()
        guard !isUpdating, !isUndoRedoing else { return }
        // While an input method is composing (marked text — e.g. emoji search,
        // accent/IME entry), the storage holds provisional text. Re-styling it
        // (setAttributes over the marked range) interferes with the composition
        // and can abort it, so defer all syncing/restyling until the IME commits
        // — which fires didChangeText again with no marked text.
        guard !hasMarkedText() else { return }
        syncRawSourceFromDisplay()
        document?.updateChangeCount(.changeDone)
        scrollCursorToCenter()
    }

    /// Syncs rawSource from the text storage, re-parses blocks, and restyles
    /// exactly the blocks the edit affected: the parser's changed window, the
    /// old and new active blocks, and — when the document-global list indent
    /// unit moved — every list block. One flush, attribute-only; the storage
    /// string is never replaced on the edit path.
    private func syncRawSourceFromDisplay() {
        guard let ts = textStorage else { return }

        let oldIndentUnit = listIndentUnit
        rawSource = ts.string
        let sel = selectedRange()
        let cursorRaw = min(sel.location, (rawSource as NSString).length)

        let oldCount = blocks.count
        let oldActive = activeBlockIndex
        // Incremental parse from the storage's accumulated edit — O(edit);
        // full positional-diff parse as the fallback.
        let newBlocks: [Block]
        let changed: Range<Int>
        if let pending = (ts as? EditorTextStorage)?.consumePendingEdit(),
           let incremental = BlockParser.incrementalParse(text: rawSource,
                                                          old: blocks,
                                                          editedOldRange: pending.oldRange,
                                                          delta: pending.delta) {
            (newBlocks, changed) = incremental
            #if DEBUG
            verifyIncrementalParse(newBlocks)
            #endif
            // Update the indent histogram from exactly the replaced blocks
            // (old) and their replacements (new) — O(edit), same effect as a
            // whole-document rescan.
            let suffixCount = newBlocks.count - changed.upperBound
            for i in changed.lowerBound ..< (oldCount - suffixCount) {
                listIndentState.remove(blocks[i].content)
            }
            for i in changed {
                listIndentState.add(newBlocks[i].content)
            }
            listIndentUnit = listIndentState.unit
        } else {
            (newBlocks, changed) = BlockParser.parseWithDiff(rawSource, previous: blocks)
            rebuildListIndentState()
        }
        blocks = newBlocks

        var dirty = IndexSet(integersIn: changed)

        // Map the old active block through the diff so its deactivation
        // restyle lands on the right index: prefix indices are unchanged,
        // suffix indices shift by the count delta, and anything inside the
        // window is already dirty.
        if let old = oldActive {
            let suffixCount = newBlocks.count - changed.upperBound
            if old < changed.lowerBound {
                dirty.insert(old)
            } else if old >= oldCount - suffixCount {
                dirty.insert(old + (newBlocks.count - oldCount))
            }
        }

        // The block under the cursor gets cursor-aware delimiter styling
        // (this also subsumes the old per-keystroke applyBlockStyle pass).
        if let newActive = blockIndexForRawOffset(cursorRaw) {
            dirty.insert(newActive)
        }

        // listIndentUnit is document-global: when it changes, the rendered
        // indentation of every list block changes with it.
        if listIndentUnit != oldIndentUnit {
            for (i, block) in blocks.enumerated() where block.kind == .listItem {
                dirty.insert(i)
            }
        }

        recomposeDirty(dirty, cursorInRaw: cursorRaw)
    }

    #if DEBUG
    /// Debug oracle for the incremental parser: every incremental result must
    /// equal a from-scratch parse (content, ranges, kinds — IDs are allowed
    /// to differ). Skipped under MD_PERF so measurements stay representative.
    private func verifyIncrementalParse(_ incremental: [Block]) {
        guard ProcessInfo.processInfo.environment["MD_PERF"] == nil else { return }
        let reference = BlockParser.parse(rawSource)
        guard incremental.count == reference.count else {
            assertionFailure("""
            incremental parse diverged: \(incremental.count) blocks \
            vs \(reference.count) reference
            """)
            return
        }
        for (a, b) in zip(incremental, reference) {
            if a.content != b.content || a.range != b.range || a.kind != b.kind {
                assertionFailure("""
                incremental parse diverged at \(a.range): \
                \(String(reflecting: a.content)) [\(a.kind)] vs \
                \(String(reflecting: b.content)) [\(b.kind)] at \(b.range)
                """)
                return
            }
        }
    }
    #endif

    // MARK: - Selection Change Detection

    @objc private func selectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        // NSTextView moves the selection DURING an edit, before didChangeText
        // runs the sync — at that moment `blocks` still has pre-edit ranges.
        // Styling here would apply stale ranges/content against the new text,
        // spilling wrong attributes across block boundaries. The pending edit
        // is exactly the "storage ahead of blocks" signal; didChangeText's
        // flush styles the active block anyway.
        if let storage = textStorage as? EditorTextStorage,
           storage.pendingEdit != nil { return }
        // Don't restyle while an input method is composing (see didChangeText).
        guard !hasMarkedText() else { return }

        let sel = selectedRange()
        let rawOffset = sel.location
        let newActiveIndex = blockIndexForRawOffset(rawOffset)

        if newActiveIndex != activeBlockIndex && !pendingRecompose {
            pendingRecompose = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // Always clear the flag first. If we bail out below (a recompose is
                // mid-flight and will set the active block itself), leaving it set
                // would permanently wedge active-block switching — the cursor could
                // never re-activate a block, so e.g. a callout would stay rendered
                // with un-editable zero-width marker characters.
                self.pendingRecompose = false
                guard !self.isUpdating else { return }

                // Restyle the new active block now. DEFER the old active block
                // if it's off screen: deactivating it (rendered ↔ raw — callout
                // box, checklist marker, …) changes its height, and doing that
                // synchronously while the user is looking elsewhere shifts the
                // whole viewport. Marking it unstyled hands it to the async
                // drain, which TextKit 2 lays out without disturbing the
                // viewport. Don't re-set the selection (that triggers AppKit's
                // autoscroll-to-selection on stale layout).
                let loc = self.selectedRange().location
                let newIdx = self.blockIndexForRawOffset(loc)
                var dirty = IndexSet()
                if let n = newIdx { dirty.insert(n) }
                var deferred = false
                if let old = self.activeBlockIndex, old != newIdx, old < self.blocks.count {
                    if let vis = self.syncStylingBlockRange(), vis.contains(old) {
                        dirty.insert(old)   // visible — restyle in place
                    } else {
                        self.blocks[old].isStyled = false   // off screen — defer
                        deferred = true
                    }
                }
                // Only the new (visible) active block changes height now, so the
                // caret anchor's delta is small and reliable. Typewriter mode
                // centers on the post-restyle layout instead.
                if self.typewriterModeEnabled {
                    self.recomposeDirty(dirty, cursorInRaw: loc)
                    self.scrollCursorToCenter()
                } else {
                    self.preservingCaretScreenPosition {
                        self.recomposeDirty(dirty, cursorInRaw: loc)
                    }
                }
                if deferred { self.scheduleProgressiveStyling() }
            }
            return
        } else if newActiveIndex == activeBlockIndex {
            // Same block — update active token (re-style to show/hide delimiters)
            applyBlockStyle()
        }
        scrollCursorToCenter()
    }

    // MARK: - Typewriter Scroll

    /// When true (the default), edits and cursor moves keep the current line
    /// vertically centered (typewriter scrolling). When false, scrolling is left
    /// to the normal "keep the cursor visible" behavior. Toggled from View menu.
    public var typewriterModeEnabled: Bool = true

    /// The caret line's top in view (scroll-document) coordinates, or nil.
    private func caretViewY() -> CGFloat? {
        caretLineRect().map { $0.minY + textContainerOrigin.y }
    }

    /// Runs `body` (which restyles the active block, changing its height) while
    /// keeping the caret line at the same on-screen position. The caret offset
    /// (`selectedRange().location`) is reliable and the caret is on screen here,
    /// so `lineRect` resolves correctly. With the off-screen old active block
    /// deferred (see selectionDidChange), only the visible new active block
    /// changes height, so the delta is small.
    private func preservingCaretScreenPosition(_ body: () -> Void) {
        guard let scrollView = enclosingScrollView, let before = caretViewY() else {
            body(); return
        }
        let screenOffset = before - scrollView.contentView.bounds.origin.y
        body()
        guard let after = caretViewY() else { return }
        let newY = max(0, after - screenOffset)
        guard abs(newY - scrollView.contentView.bounds.origin.y) > 0.5 else { return }
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: newY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls the view so the cursor's line fragment is vertically centered
    /// in the visible area.
    private func scrollCursorToCenter() {
        guard typewriterModeEnabled else { return }
        guard let scrollView = enclosingScrollView,
              let lineRect = caretLineRect() else { return }
        let cursorY = lineRect.midY + textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = cursorY - visibleHeight / 2
        let maxY = max(0, frame.height - visibleHeight)
        let clampedY = min(max(0, targetY), maxY)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// The caret line's rect in text-container coordinates (TextKit 2: lays
    /// out only the caret's fragment, positions above are estimated).
    private func caretLineRect() -> CGRect? {
        lineRect(forCharacterAt: selectedRange().location)
    }

    /// The line rect for the character at `offset`, in text-container
    /// coordinates. Lays out only the offset's own fragment — forcing layout
    /// from the document start would lay out (and could OOM on) the whole 1–2
    /// MB document for a deep caret. For carets in or near the viewport the
    /// position is exact; for far jumps it may be a TextKit 2 estimate that
    /// the scroll anchoring + promotion settle once the region is reached.
    func lineRect(forCharacterAt offset: Int) -> CGRect? {
        guard let tlm = textLayoutManager else { return nil }
        guard let loc = tlm.location(tlm.documentRange.location, offsetBy: offset)
        else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: loc))
        guard let fragment = tlm.textLayoutFragment(for: loc) else { return nil }
        let frame = fragment.layoutFragmentFrame

        guard let paraStart = fragment.textElement?.elementRange?.location else { return frame }
        let offsetInPara = tlm.offset(from: paraStart, to: loc)
        let line = fragment.textLineFragments.first {
            NSLocationInRange(offsetInPara, $0.characterRange)
        } ?? fragment.textLineFragments.last
        guard let line else { return frame }
        return line.typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
    }

    /// AppKit's TextKit 2 implementation of scroll-to-range kills the process
    /// on large documents (observed reproducibly at ~1.5 MB; silent kill, no
    /// crash report). NSTextView calls it internally after every insertion
    /// (caret autoscroll), so replace it with the minimal fragment-based
    /// scroll: lay out just the target's fragment and move the clip view.
    public override func scrollRangeToVisible(_ range: NSRange) {
        guard let scrollView = enclosingScrollView else { return }
        // Bound the range by its two ends so an extended selection follows the
        // end being modified rather than always its start.
        let visible = scrollView.contentView.bounds
        guard let startRect = lineRect(forCharacterAt: range.location) else { return }
        let endRect = range.length > 0
            ? (lineRect(forCharacterAt: range.upperBound) ?? startRect) : startRect
        let top = min(startRect.minY, endRect.minY) + textContainerOrigin.y
        let bottom = max(startRect.maxY, endRect.maxY) + textContainerOrigin.y
        let margin: CGFloat = 8

        var targetY = visible.origin.y
        if top < visible.minY {
            targetY = top - margin
        } else if bottom > visible.maxY {
            // Prefer keeping the bottom edge visible; fall back to the top if
            // the range is taller than the viewport.
            targetY = min(bottom + margin - visible.height, top - margin)
        } else {
            return  // already visible
        }
        let maxY = max(0, frame.height - visible.height)
        let clampedY = min(max(0, targetY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: visible.origin.x, y: clampedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Link Following

    /// Cmd+click on a link's text follows it; any other click edits normally.
    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let url = linkURL(at: event) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    /// The destination URL of the link under a mouse event, or nil if the click
    /// doesn't land directly on link text.
    private func linkURL(at event: NSEvent) -> URL? {
        guard let tlm = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return nil }

        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y

        guard let fragment = tlm.textLayoutFragment(for: point) else { return nil }
        let frame = fragment.layoutFragmentFrame
        let pointInFragment = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        // Reject clicks past the end of a line: typographic bounds cover only
        // the line's used extent.
        guard let line = fragment.textLineFragments.first(where: {
            $0.typographicBounds.contains(pointInFragment)
        }) else { return nil }

        let indexInParagraph = line.characterIndex(for: pointInFragment)
        guard indexInParagraph >= 0,
              let paraStart = fragment.textElement?.elementRange?.location else { return nil }
        let charIndex = tlm.offset(from: tlm.documentRange.location, to: paraStart) + indexInParagraph
        guard charIndex < storage.length,
              let dest = storage.attribute(.editorLinkURL, at: charIndex, effectiveRange: nil) as? String
        else { return nil }
        return URL(string: dest)
    }

    // MARK: - Helpers

    func currentCursorInRaw() -> Int {
        return selectedRange().location
    }

    /// Detects the indentation unit (columns per nesting level) used by list
    /// items in `source`: the smallest positive leading-space count, or 4 when
    /// tabs are used (a tab counts as one level) or nothing is found.
    static func detectListIndentUnit(_ source: String) -> Int {
        var minSpaces = Int.max
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            var spaces = 0
            var sawTab = false
            for ch in line {
                if ch == " " { spaces += 1 }
                else if ch == "\t" { sawTab = true; break }
                else { break }
            }
            let rest = line.drop(while: { $0 == " " || $0 == "\t" })
            guard startsWithListMarker(rest) else { continue }
            if sawTab { return 4 }
            if spaces > 0 { minSpaces = min(minSpaces, spaces) }
        }
        return minSpaces == Int.max ? 4 : minSpaces
    }

    nonisolated static func startsWithListMarker(_ s: Substring) -> Bool {
        guard let first = s.first else { return false }
        if first == "-" || first == "*" || first == "+" {
            return s.dropFirst().first == " "
        }
        if first.isNumber {
            let afterDigits = s.drop(while: { $0.isNumber })
            if let d = afterDigits.first, d == "." || d == ")" {
                return afterDigits.dropFirst().first == " "
            }
        }
        return false
    }

    // MARK: - Content Loading (called by Document)

    /// Replace the editor's content. Used by NSDocument on file open.
    public func loadContent(_ content: String) {
        // Remember the file's line ending, then normalize the buffer to LF so
        // block parsing and rendering never see a stray `\r`.
        originalLineEnding = LineEnding.detect(in: content)
        rawSource = LineEnding.normalize(content)
        rebuildListIndentState()
        blocks = BlockParser.parse(rawSource)
        undoStack.removeAll()
        redoStack.removeAll()
        recompose(cursorInRaw: 0)
    }
}

// MARK: - String UTF-16 Index Helper

extension String {
    func utf16Index(at offset: Int) -> String.Index {
        return String.Index(utf16Offset: offset, in: self)
    }
}
