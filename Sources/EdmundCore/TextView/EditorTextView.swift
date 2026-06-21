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
    /// Coalesces the async active-block restyle scheduled from a caret move
    /// (internal so EditorTextView+SelectionTracking can clear it).
    var pendingRecompose = false
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

    public var theme: EditorTheme = .load() {
        didSet { textAntialias = theme.antialias }
    }

    /// Mirror of `theme.antialias`, readable from the `nonisolated`
    /// layout-fragment vendor.
    nonisolated(unsafe) var textAntialias = true

    /// How the document is presented:
    ///   - `edit`    — live preview; the block under the caret reveals its raw
    ///                 markdown (the default editing experience).
    ///   - `reading` — everything rendered, no raw ever revealed; read-only.
    ///   - `source`  — plain monospaced raw markdown, no styling.
    public enum ViewMode: Sendable { case edit, reading, source }

    public var viewMode: ViewMode = .edit {
        didSet {
            guard oldValue != viewMode else { return }
            isEditable = (viewMode != .reading)
            // Re-style every block under the new mode (viewport-first for big docs).
            guard !blocks.isEmpty else { return }
            recomposeDirty(IndexSet(integersIn: 0..<blocks.count),
                           cursorInRaw: selectedRange().location)
        }
    }

    /// User overrides for callout styles, keyed by lowercased type. Lets a
    /// settings layer customize a built-in type's color / icon / border /
    /// background (or add new types). Empty by default (GitHub styles).
    public var calloutStyleOverrides: [String: CalloutStyle] = [:]

    /// When true (the default), edits and cursor moves keep the current line
    /// vertically centered (typewriter scrolling); when false, scrolling falls
    /// back to "keep the cursor visible". Toggled from the View menu. The
    /// scrolling logic lives in EditorTextView+TypewriterScroll.
    public var typewriterModeEnabled: Bool = true

    /// Fraction of the available width the text column occupies, in `0...1`.
    /// `1` fills the width (the base inset only — today's look); lower values
    /// give a narrower, centered column with symmetric margins that grow on
    /// wide/full-screen windows, down to a mobile-ish minimum. Applied as a
    /// symmetric `textContainerInset.width`, recomputed on resize. See
    /// EditorTextView+ContentWidth.
    public var contentWidthFraction: CGFloat = 1.0 {
        didSet {
            guard oldValue != contentWidthFraction else { return }
            updateContentInset()
        }
    }

    // MARK: - Derived Visual Properties

    /// The app accent: the macOS system accent (`controlAccentColor`), which
    /// resolves to the app's AccentColor asset — our brown — when the bundle
    /// ships the compiled asset catalog, and to the user's System Settings accent
    /// otherwise. Drives links, the checked-checkbox icon, the insertion point,
    /// and the selection tint so the editor matches the native AppKit controls.
    var accentColor: NSColor { .controlAccentColor }

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
        let antialiasChanged = theme.antialias != newTheme.antialias
        theme = newTheme
        theme.save(to: themeDefaults)
        typingAttributes = baseAttributes
        recomposeAllDirty()
        // Antialiasing isn't a text attribute, so a recompose alone won't re-vend
        // the layout fragments — force a full re-layout when it changes.
        if antialiasChanged, let tlm = textLayoutManager {
            tlm.invalidateLayout(for: tlm.documentRange)
        }
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

        textAntialias = theme.antialias
        backgroundColor = editorBackgroundColor
        insertionPointColor = accentColor
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
        insertionPointColor = accentColor
        selectedTextAttributes = [
            .backgroundColor: accentColor.withAlphaComponent(0.3),
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes
        recomposeAllDirty()
    }

    // MARK: - Link Following

    /// Cmd+click on a link's text follows it: a `[[wikilink]]` resolves to a
    /// file / heading, a regular link opens its URL. Any other click edits.
    public override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            if let target = wikiTarget(at: event) {
                followWikiLink(target)
                return
            }
            if let dest = linkDestination(at: event) {
                followLinkDestination(dest)
                return
            }
        }
        super.mouseDown(with: event)
    }

    /// The storage character index directly under a mouse event, or nil if the
    /// click doesn't land on a laid-out glyph (e.g. past the end of a line).
    func clickCharIndex(at event: NSEvent) -> Int? {
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
        return charIndex < storage.length ? charIndex : nil
    }

    /// The raw destination string of the regular link under a mouse event, or
    /// nil if the click doesn't land directly on link text. The destination is
    /// resolved by `followLinkDestination` (external URL, `#heading`, or file).
    private func linkDestination(at event: NSEvent) -> String? {
        guard let storage = textStorage, let charIndex = clickCharIndex(at: event) else { return nil }
        return storage.attribute(.editorLinkURL, at: charIndex, effectiveRange: nil) as? String
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
        // block parsing and rendering never see a stray `\r`. A file that mixes
        // styles is normalized to LF on save too (rather than its dominant style),
        // so its endings become consistent.
        originalLineEnding = LineEnding.isInconsistent(in: content) ? .lf : LineEnding.detect(in: content)
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
