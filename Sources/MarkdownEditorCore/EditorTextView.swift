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

    public var rawSource: String = "" {
        didSet { listIndentUnit = Self.detectListIndentUnit(rawSource) }
    }
    /// Columns of leading whitespace that make up one list-nesting level,
    /// detected from the document (the smallest indent used, or one tab).
    /// Defaults to 4. Used to map a list item's indentation to a nesting depth.
    public var listIndentUnit: Int = 4
    /// Line ending of the most recently loaded content. The buffer itself is
    /// always LF; this is remembered so saves preserve the file's style.
    public var originalLineEnding: LineEnding = .lf
    var blocks: [Block] = []
    var activeBlockIndex: Int? = nil
    var isUpdating = false
    var displayRanges: [NSRange] = []
    private var pendingRecompose = false

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

    /// Apply a new theme, persist it, and recompose.
    public func applyTheme(_ newTheme: EditorTheme) {
        theme = newTheme
        theme.save(to: themeDefaults)
        typingAttributes = baseAttributes
        recompose(cursorInRaw: currentCursorInRaw())
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
        blocks = BlockParser.parse(rawSource)
        recompose(cursorInRaw: 0)

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
        recompose(cursorInRaw: currentCursorInRaw())
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
        applyBlockStyle()
        document?.updateChangeCount(.changeDone)
        scrollCursorToCenter()
    }

    /// Syncs rawSource from the text storage and re-parses blocks.
    /// With word-level rendering, text storage = rawSource, so this is simple.
    private func syncRawSourceFromDisplay() {
        guard let ts = textStorage else { return }

        rawSource = ts.string
        let sel = selectedRange()
        let cursorRaw = min(sel.location, (rawSource as NSString).length)

        let previousBlockCount = blocks.count
        blocks = BlockParser.parse(rawSource, previous: blocks)
        recalcDisplayRanges()

        // If the number of blocks changed, an edit split or merged blocks (e.g. a
        // callout/code fence/quote gaining or losing lines). Incremental recompose
        // only restyles the active block, so a neighbor whose meaning changed —
        // such as a former callout body line left with a stale background — would
        // keep its old styling. Do a full recompose to keep the document correct.
        if blocks.count != previousBlockCount {
            recompose(cursorInRaw: cursorRaw)
            return
        }

        let newBlockIndex = blockIndexForRawOffset(cursorRaw)
        if newBlockIndex != activeBlockIndex {
            recomposeIncremental(cursorInRaw: cursorRaw)
        }
    }

    // MARK: - Selection Change Detection

    @objc private func selectionDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        // Don't restyle while an input method is composing (see didChangeText).
        guard !hasMarkedText() else { return }

        let sel = selectedRange()
        let rawOffset = sel.location
        let newActiveIndex = blockIndexForRawOffset(rawOffset)

        if newActiveIndex != activeBlockIndex && !pendingRecompose {
            pendingRecompose = true
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.isUpdating else { return }
                self.pendingRecompose = false

                let currentSel = self.selectedRange()
                let rawStart = currentSel.location
                let rawEnd = currentSel.location + currentSel.length
                let rawSel = NSRange(location: rawStart, length: rawEnd - rawStart)
                self.recomposeIncremental(cursorInRaw: rawStart, selectionInRaw: rawSel)
            }
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

    /// Scrolls the view so the cursor's line fragment is vertically centered
    /// in the visible area.
    private func scrollCursorToCenter() {
        guard typewriterModeEnabled else { return }
        guard let lm = layoutManager,
              let scrollView = enclosingScrollView else { return }

        let sel = selectedRange()
        let glyphRange = lm.glyphRange(forCharacterRange: NSRange(location: sel.location, length: 0),
                                        actualCharacterRange: nil)
        guard glyphRange.location != NSNotFound else { return }
        let lineRect = lm.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        let cursorY = lineRect.midY + textContainerOrigin.y

        let visibleHeight = scrollView.contentView.bounds.height
        let targetY = cursorY - visibleHeight / 2
        let maxY = max(0, frame.height - visibleHeight)
        let clampedY = min(max(0, targetY), maxY)

        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clampedY))
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
        guard let lm = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }

        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y

        let glyphIndex = lm.glyphIndex(for: point, in: container)
        // Reject clicks past the end of a line (which still resolve to a glyph).
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: container)
        guard glyphRect.contains(point) else { return nil }

        let charIndex = lm.characterIndexForGlyph(at: glyphIndex)
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

    private static func startsWithListMarker(_ s: Substring) -> Bool {
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
