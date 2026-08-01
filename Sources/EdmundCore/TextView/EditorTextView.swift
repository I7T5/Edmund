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

    // MARK: - Find

    /// Character ranges of the current search's matches, in raw/display index
    /// space (identity). Drawn as highlights by `drawBackground(in:)` while
    /// `findActive`. Never written into storage — draw-only, to hold the
    /// storage == rawSource invariant. See EditorTextView+Find.
    public var findMatches: [NSRange] = []
    /// Index into `findMatches` of the current match (drawn stronger), or nil.
    public var currentMatchIndex: Int?
    /// True while the find bar is open; gates highlight drawing.
    public var findActive = false
    /// The match currently being emphasised (the newly-navigated hit), and how
    /// far its yellow→grey settle animation has progressed (0…1). Drives the
    /// CotEditor-style pop; nil when nothing is animating. See EditorTextView+Find.
    var emphasisRange: NSRange?
    var emphasisProgress: CGFloat = 0
    var emphasisLink: CADisplayLink?
    /// Routes menu/keyboard find commands to the app-side find controller.
    /// Weak; mirrors the module decoupling of `contextFontMenuProvider` so
    /// EdmundCore need not know about edmd's FindController.
    public weak var findHandler: EditorFindHandling?

    // MARK: - State (internal for @testable import)

    /// Drops the line-start table and repaints the gutter on every write. This
    /// is the one hook that covers all of rawSource's assignment sites (load,
    /// undo, didChangeText, formatting, indentation, renumbering) — none of
    /// them rebuild anything here, the next lookup does it lazily.
    public var rawSource: String = "" {
        didSet {
            lineStartsCache = nil
            lineNumberRuler?.needsDisplay = true
        }
    }
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

    /// Document-wide link reference definitions (`[label]: url`), fed into each
    /// block's parse so GFM reference links resolve across blocks. Maintained
    /// incrementally on the edit path; rebuilt by the whole-document paths.
    var linkDefState = LinkDefinitionState()

    func rebuildLinkDefState() {
        linkDefState = LinkDefinitionState.build(from: rawSource)
    }
    /// Line ending of the most recently loaded content. The buffer itself is
    /// always LF; this is remembered so saves preserve the file's style.
    public var originalLineEnding: LineEnding = .lf
    var blocks: [Block] = []
    var activeBlockIndex: Int? = nil
    var isUpdating = false
    /// Coalesces the async active-block restyle scheduled from a caret move
    /// (internal so EditorTextView+SelectionTracking can clear it).
    var pendingRecompose = false
    /// Coalesces idle-drain scheduling (see EditorTextView+LazyStyling).
    var progressiveStylingScheduled = false
    /// Coalesces scroll-driven promotion onto the next run-loop turn, off the
    /// scroll notification (see EditorTextView+LazyStyling).
    var pendingPromotion = false
    /// Coalesces the didChangeText-bypass check scheduled from
    /// shouldChangeText (see EditorTextView+EditFlow).
    var bypassedEditCheckScheduled = false
    /// Where the idle drain resumes scanning for unstyled blocks (a hint;
    /// it wraps around and self-corrects after edits shift indices).
    var drainCursor = 0
    /// Coalesces the deferred full-document layout settle for small documents
    /// (see EditorTextView+LazyStyling `scheduleFullLayoutSettle`).
    var fullLayoutSettleScheduled = false
    /// Documents at or below this UTF-16 length are laid out in full once
    /// styling converges, eliminating TextKit 2 height estimates (and the
    /// scroll jumps they cause). See `scheduleFullLayoutSettle`.
    static let fullLayoutMaxLength = 100_000

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
        didSet {
            cachedBodyFont = nil
            cachedBodyParagraphStyle = nil
            cachedMonospaceFont = nil
            cachedHiddenFont = nil
            textAntialias = theme.antialias
            codeBlockLabelFont = theme.monospaceFont(ofSize: max(9, theme.monospaceFontSize - 3))
        }
    }

    /// Styling touches these values for every block. Reusing the immutable
    /// objects avoids feeding thousands of short-lived, equivalent attribute
    /// values into Foundation's process-wide attribute-dictionary interner.
    var cachedBodyFont: NSFont?
    var cachedBodyParagraphStyle: NSParagraphStyle?
    var cachedMonospaceFont: NSFont?
    var cachedHiddenFont: NSFont?

    /// Mirror of `theme.antialias`, readable from the `nonisolated`
    /// layout-fragment vendor.
    nonisolated(unsafe) var textAntialias = true

    /// The code-block language label's font — a smaller cut of the theme's
    /// monospace font. Mirrored like `textAntialias` so the `nonisolated`
    /// layout-fragment vendor can hand it to the fragment.
    nonisolated(unsafe) var codeBlockLabelFont: NSFont =
        .monospacedSystemFont(ofSize: 10, weight: .regular)

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

    /// Scrolls the Read-mode web view to a 1-indexed source line, set by the
    /// owning document. Invoked when an internal `[[link]]`/`[[#^blockid]]` is
    /// followed while `viewMode == .reading` (the editor itself is hidden then,
    /// so it can't scroll the visible surface). nil in Edit/Source.
    public var onReadScrollToLine: ((Int) -> Void)?

    /// User overrides for callout styles, keyed by lowercased type. Lets a
    /// settings layer customize a built-in type's color / icon / border /
    /// background (or add new types). Empty by default (GitHub styles).
    public var calloutStyleOverrides: [String: CalloutStyle] = [:]

    /// When true (the default), edits and cursor moves keep the current line
    /// vertically centered (typewriter scrolling); when false, scrolling falls
    /// back to "keep the cursor visible". Toggled from the View menu. The
    /// scrolling logic lives in EditorTextView+TypewriterScroll.
    public var typewriterModeEnabled: Bool = true

    /// Set to true for the duration of a mouse-down event so that the
    /// resulting selection change does not trigger typewriter centering.
    /// Clicks position the caret where the user clicked — centering there
    /// would be jarring and is the root cause of the "glitchy" feeling.
    var suppressTypewriterCentering = false

    /// Physical maximum text-column width in points. Windows wider than this
    /// cap get symmetric side margins; narrower windows fill edge-to-edge.
    /// `.greatestFiniteMagnitude` means no cap (fill always). Set from the
    /// persisted cm value converted via the window's screen PPI. See
    /// EditorTextView+ContentWidth.
    public var maxContentWidthPoints: CGFloat = .greatestFiniteMagnitude {
        didSet {
            guard oldValue != maxContentWidthPoints else { return }
            // Anchored: a narrower column re-wraps every paragraph, so the
            // content above the viewport changes height and the unchanged clip
            // origin lands elsewhere (measured at 1641 characters on a
            // 120-paragraph file). Only here, not in `updateContentInset`
            // itself — that also runs from `setFrameSize` during a live window
            // resize, which must not scroll the clip view from inside layout.
            preservingViewportAnchor { updateContentInset() }
        }
    }

    /// Whether a remote (`https`) image referenced by `![alt](url)` may load
    /// inline while editing. Mirrors Read mode's `allowRemoteImages`; set from
    /// `AppSettings.blockExternalImages`. Defaults off (the safe default until
    /// the app layer pushes the real setting in). See
    /// EditorTextView+ImageRendering for the load path.
    public var allowRemoteImages: Bool = false {
        didSet {
            guard oldValue != allowRemoteImages else { return }
            recomposeAllDirty()
        }
    }

    /// Which Markdown extensions are recognized (highlight, callouts, wikilinks,
    /// math, …). Set from the app's `AppSettings` markdown toggles; a cleared
    /// flag makes that syntax render as plain text. Defaults to `.all` so the
    /// editor behaves fully until the app layer pushes the real settings in.
    public var markdownFeatures: MarkdownFeatures = .all {
        didSet {
            guard oldValue != markdownFeatures else { return }
            recomposeAllDirty()
        }
    }

    // MARK: - Editing Behavior (pushed from AppSettings ▸ Edit)
    //
    // EdmundCore can't see `AppSettings` (it lives in the app target), so every
    // Edit-pane behavior is an instance property the app pushes in — the same
    // shape as `markdownFeatures` and `allowRemoteImages` above. Each default is
    // the behavior the editor had before the setting existed.

    /// Whether Return inside a list item continues the list with the next
    /// marker. Off → Return inserts a plain newline. See
    /// EditorTextView+ListContinuation.
    public var listContinuationEnabled = true

    /// Whether typing an opening bracket or quote inserts its closing partner.
    /// See EditorTextView+AutoPairs.
    public var autoCloseBracketsEnabled = true

    /// Whether one indent unit is a tab character rather than `indentWidth`
    /// spaces. See EditorTextView+Indentation.
    public var indentUsesTabs = false

    /// One indent unit's width in spaces (ignored when `indentUsesTabs`).
    /// Clamped on read, so a garbage value can't produce an empty indent unit.
    public var indentWidth = 2

    /// Whether this document arrived hard-wrapped — opening it actually joined
    /// lines — in which case saving re-wraps it so the file keeps its shape.
    /// A file that was never wrapped is never wrapped on your behalf, so the
    /// setting can't reformat a document that didn't ask for it. Set only by
    /// `loadContent(_:unwrapHardWrapping:)`: it describes the file on disk, not
    /// the buffer, so editing — including Hard Wrap Paragraphs — never changes
    /// it. See EditorTextView+HardWrap.
    public internal(set) var wasHardWrapped = false

    /// The column this document is wrapped at. Detected from the file when it
    /// opens (Settings ▸ Edit ▸ Document ▸ "Detect max line length"), so a file
    /// wrapped at 72 is written back at 72 instead of being reflowed to 80 on
    /// its first save. Falls back to `HardWrap.column` when detection is off or
    /// the file isn't consistently wrapped.
    public internal(set) var hardWrapColumn = HardWrap.column

    /// Invisible-character marks (whitespace made visible), or nil = off (the
    /// default). Editor-only; Read mode never shows these. `nonisolated(unsafe)`
    /// like `textAntialias` because the (nonisolated) layout-fragment delegate
    /// reads it at vend time; always set from the main actor. After changing it,
    /// call `refreshOverdraw()` — it alters no attributes, so a restyle won't
    /// re-vend the fragments. See EditorTextView+Invisibles.
    nonisolated(unsafe) public var invisibles: InvisiblesConfig?

    /// Draw the vertical indent guides on nested list items — default off. The
    /// guide columns are baked into the text by the list renderer regardless
    /// (`.listGuides`); this only gates the drawing, so flipping it needs a
    /// `refreshOverdraw()` and never a restyle. `nonisolated(unsafe)` like
    /// `invisibles`, and for the same reason: the vend delegate reads it.
    nonisolated(unsafe) public var showListIndentGuides = false

    /// Dim everything but the lines the selection touches — default off. Purely
    /// a draw-time fade (no attribute changes), so flipping it needs a
    /// `refreshOverdraw()` and never a restyle. `nonisolated(unsafe)` like
    /// `invisibles`, and for the same reason: the vend delegate reads it.
    /// See EditorTextView+FocusMode.
    nonisolated(unsafe) public var focusMode = false

    /// Show source line numbers — default off. They sit in the reading column's
    /// own margin, or in a window-edge gutter when that margin is too narrow to
    /// hold them; the placement is chosen for you, not configured. See
    /// EditorTextView+LineNumbers.
    public var showLineNumbers = false {
        didSet {
            guard oldValue != showLineNumbers else { return }
            // Anchored for the same reason as `maxContentWidthPoints`: adding
            // or removing the gutter narrows the text and re-wraps it.
            preservingViewportAnchor { updateLineNumberRuler() }
        }
    }

    /// Set while a placement re-check is waiting on the runloop, so a burst of
    /// resize callbacks queues one hop rather than dozens. See
    /// `scheduleLineNumberPlacementUpdate`.
    var lineNumberPlacementUpdateScheduled = false

    /// The installed gutter, or nil unless the numbers are on *and* don't fit
    /// beside the text.
    var lineNumberRuler: LineNumberRulerView?

    /// UTF-16 offsets of each line's first character; see `lineStarts`.
    var lineStartsCache: [Int]?

    // MARK: - Derived Visual Properties

    /// The app accent: the macOS system accent (`controlAccentColor`), which
    /// resolves to the app's AccentColor asset — our brown — when the bundle
    /// ships the compiled asset catalog, and to the user's System Settings accent
    /// otherwise. Drives links, the checked-checkbox icon, the insertion point,
    /// and the selection tint so the editor matches the native AppKit controls.
    var accentColor: NSColor { .controlAccentColor }

    /// Foreground color for all body text — and, through `mathOverlay`, for the
    /// math bitmaps drawn alongside it. Defined once in `EditorTheme` so Read
    /// mode's `--fg` and its embedded equations use the identical ink; see the
    /// rationale there.
    var foregroundColor: NSColor {
        EditorTheme.bodyTextColor(dark: isDarkAppearance)
    }

    /// Background tint for text selection. Uses system orange so selections read
    /// as warm amber rather than tracking the (potentially red) brand accent.
    var selectionHighlightColor: NSColor { .systemOrange.withAlphaComponent(0.3) }

    /// Background color for the editor surface. Light appearance keeps the
    /// standard `.textBackgroundColor` semantic; dark appearance uses `#292929`,
    /// matching Read mode's page background. Built with `srgbRed:` rather than
    /// the shared `NSColor(hex:)` helper (which uses `calibratedRed:`) — the
    /// calibrated color space renders visibly lighter than the sRGB hex value
    /// once composited on screen.
    /// Internal rather than private: the line-number gutter fills itself with
    /// this so the two surfaces read as one (the scroll view draws no
    /// background of its own).
    var editorBackgroundColor: NSColor {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard dark else { return .textBackgroundColor }
        return NSColor(srgbRed: 0x29 / 255.0, green: 0x29 / 255.0, blue: 0x29 / 255.0, alpha: 1.0)
    }

    // MARK: - Font & Paragraph Style (derived from theme)

    public var bodyFont: NSFont {
        if let cachedBodyFont { return cachedBodyFont }
        let font = theme.bodyFont
        cachedBodyFont = font
        return font
    }

    var bodyParagraphStyle: NSParagraphStyle {
        if let cachedBodyParagraphStyle { return cachedBodyParagraphStyle }
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = theme.lineSpacing
        ps.paragraphSpacingBefore = theme.paragraphSpacingBefore
        ps.paragraphSpacing = 0
        let style = ps.copy() as! NSParagraphStyle
        cachedBodyParagraphStyle = style
        return style
    }

    /// Apply a new theme and restyle every block in place. `persist: false`
    /// (used for zoom, which scales font sizes without changing the saved
    /// preference) applies the theme live without writing it to defaults.
    public func applyTheme(_ newTheme: EditorTheme, persist: Bool = true) {
        let antialiasChanged = theme.antialias != newTheme.antialias
        theme = newTheme
        if persist { theme.save(to: themeDefaults) }
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
        // Completion and inline predictions inject provisional MARKED text as you
        // type (not just CJK/accent/emoji input). If such a composition is
        // interrupted — a caret move, a focus change — it can be left stranded
        // (`hasMarkedText()` stuck true), which permanently breaks the
        // storage==rawSource sync in `didChangeText` and drifts the caret on every
        // edit (see docs/investigations/delete-drift-investigation.md). A live-preview markdown
        // editor needs neither, and we already disable the other auto-substitutions
        // above — so close this marked-text source too.
        isAutomaticTextCompletionEnabled = false
        if #available(macOS 14.0, *) { inlinePredictionType = .no }
        allowsUndo = false

        textAntialias = theme.antialias
        codeBlockLabelFont = theme.monospaceFont(ofSize: max(9, theme.monospaceFontSize - 3))
        backgroundColor = editorBackgroundColor
        insertionPointColor = accentColor
        selectedTextAttributes = [
            .backgroundColor: selectionHighlightColor,
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes

        rawSource = ""
        rebuildListIndentState()
        rebuildLinkDefState()
        blocks = BlockParser.parse(rawSource, features: markdownFeatures)
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

        // The user switched math engines (or an install finished): re-style
        // every block so on-screen equations pick up the new renderer. Rare,
        // deliberate event — same "restyle everything, viewport-first"
        // recomposeDirty used by a view-mode switch, not a full recompose
        // (which would reset every fragment to a height estimate).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(renderEngineDidChange(_:)),
            name: .renderEngineChanged,
            object: nil
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

    @objc private func renderEngineDidChange(_ note: Notification) {
        guard !blocks.isEmpty else { return }
        recomposeDirty(IndexSet(integersIn: 0..<blocks.count),
                      cursorInRaw: selectedRange().location)
    }

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
            .backgroundColor: selectionHighlightColor,
            .foregroundColor: foregroundColor,
        ]
        typingAttributes = baseAttributes
        recomposeAllDirty()
    }

    // MARK: - Link Following

    #if DEBUG
    /// Repro hook (ReproScript `clickoff`): move the caret to `offset` on the
    /// mouse path — i.e. with `suppressTypewriterCentering` set during the
    /// selection change, exactly as `mouseDown` does — so the caret-move
    /// restyle captures `fromMouse=true`. Lets a scripted replay reproduce the
    /// mouse-click branch without synthesizing HID events at screen coordinates.
    public func reproClickSelect(_ offset: Int) {
        suppressTypewriterCentering = true
        setSelectedRange(NSRange(location: min(offset, (rawSource as NSString).length), length: 0))
        suppressTypewriterCentering = false
    }
    #endif

    /// Cmd+click on a link's text follows it: a `[[wikilink]]` resolves to a
    /// file / heading, a regular link opens its URL. Any other click edits.
    /// Sets `suppressTypewriterCentering` for the duration of the super call so
    /// that the resulting selection change does not re-center the viewport —
    /// centering when the user merely clicks somewhere feels glitchy.
    public override func mouseDown(with event: NSEvent) {
        // Field diagnostics for the intermittent "click/drag to select does
        // nothing" report (backlog, 7/14 occurrences): AppKit suppresses
        // selection notifications while `stillSelecting`, so a failed drag
        // leaves NO trace in `selectionDidChange` — the before/after pair here
        // is the only place the failure is observable. The entry line's
        // hit-vs-selection relation discriminates the two candidate
        // mechanisms: a hit index inside a non-empty prior selection means
        // AppKit ran its drag-*move* gesture (no new selection by design); a
        // sane hit with an unchanged selection at exit means the click never
        // anchored (hit-test / tracking dead zone).
        traceEdit("mouseDown hit=\(clickCharIndex(at: event).map(String.init) ?? "nil") "
            + "pendingRecompose=\(pendingRecompose ? "Y" : "N") "
            + "firstResponder=\(window?.firstResponder === self ? "Y" : "N") "
            + "clicks=\(event.clickCount)")
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
        suppressTypewriterCentering = true
        super.mouseDown(with: event)
        suppressTypewriterCentering = false
        // `super.mouseDown` returns only after the whole tracking loop (drag +
        // mouse-up) finishes; `sel` in this line is the gesture's net result.
        traceEdit("mouseDown done")
    }

    /// Drag ticks: while a drag-select is in flight AppKit updates the
    /// selection with `stillSelecting == true` and suppresses the delegate
    /// notification, so `selectionDidChange` never sees a failed or clamped
    /// drag. Tracing the ticks shows whether the tracking loop is computing
    /// ranges at all, and where the endpoint lands while sweeping hidden
    /// (zero-width) delimiter runs — e.g. rendered math (see
    /// `misc/bug-repros/selection-doesnot-fully-expand-math-so-copies-less-characters.mov`).
    /// Only `stillSelecting` calls are traced: final calls surface through
    /// `selectionDidChange`, and tracing every caret move would double the log.
    public override func setSelectedRanges(_ ranges: [NSValue],
                                           affinity: NSSelectionAffinity,
                                           stillSelecting: Bool) {
        if stillSelecting, let first = ranges.first?.rangeValue {
            traceEdit("dragTick sel'={\(first.location),\(first.length)}")
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// The range actually copied, for the "selection over rendered math copies
    /// fewer characters than highlighted" report — the highlight is drawn over
    /// the overlay while the underlying character range can stop at the hidden
    /// run's boundary; this line shows the truth at ⌘C time.
    public override func copy(_ sender: Any?) {
        traceEdit("copy")
        super.copy(sender)
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

    // MARK: - Stranded-Composition Recovery

    /// Regaining first-responder status: recover from any stranded input-method
    /// composition. If a marked-text (IME / accent / emoji) composition is ever
    /// left uncommitted, `didChangeText` keeps bailing on its `hasMarkedText()`
    /// guard, so the text storage drifts away from `rawSource` and every edit
    /// then does offset math against a frozen block model — the "delete drift"
    /// bug. Returning focus is a reliable "composition is over" signal (the view
    /// can't become first responder while it already holds an active
    /// composition), so when the invariant is broken here we commit any stranded
    /// marked text and resync the model from the storage the user actually sees.
    /// This formalizes the focus-switch recovery users already stumble into.
    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { recoverFromStrandedCompositionIfNeeded() }
        return became
    }

    func recoverFromStrandedCompositionIfNeeded() {
        guard let ts = textStorage, ts.string != rawSource else { return }
        // Rare and high-signal: this only fires when focus returns to a desynced
        // editor. The flag snapshot tells us *why* the sync was stranded the next
        // time the bug appears (marked text vs a leaked isUpdating/isUndoRedoing).
        Log.info("""
            recovered stranded desync on focus regain: hasMarked=\(hasMarkedText()) \
            isUpdating=\(isUpdating) isUndoRedoing=\(isUndoRedoing) \
            storageΔ=\((ts.string as NSString).length - (rawSource as NSString).length)
            """, category: .compose)
        if hasMarkedText() { unmarkText() }
        rawSource = ts.string
        rebuildListIndentState()
        rebuildLinkDefState()
        blocks = BlockParser.parse(rawSource, previous: blocks, features: markdownFeatures)
        recompose(cursorInRaw: min(selectedRange().location, (rawSource as NSString).length))
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
    ///
    /// `unwrapHardWrapping` joins each paragraph's soft-broken lines so editing
    /// works on one long logical line. It runs *after* the line ending is
    /// detected and normalized — unwrapping in the caller instead would hand
    /// `LineEnding.detect` text whose `\r\n`s had already been rewritten and
    /// silently turn every CRLF file into LF.
    public func loadContent(_ content: String, unwrapHardWrapping: Bool = false) {
        Log.measure("Loaded document (\(content.count) chars)", category: .document) {
            // Remember the file's line ending, then normalize the buffer to LF so
            // block parsing and rendering never see a stray `\r`. A file that mixes
            // styles is normalized to LF on save too (rather than its dominant style),
            // so its endings become consistent.
            originalLineEnding = LineEnding.isInconsistent(in: content) ? .lf : LineEnding.detect(in: content)
            let normalized = LineEnding.normalize(content)
            // The join changing nothing *is* the detection that this file has no
            // hard wrapping — so it keeps its shape and save leaves it alone.
            // Both readings come off one parse: the column has to be detected
            // from the breaks the file actually has, which the join is about to
            // remove, and parsing twice would double the cost of opening a
            // wrapped file (parsing is ~95% of the work here).
            let joined = unwrapHardWrapping
                ? HardWrap.unwrapDetectingColumn(normalized, features: markdownFeatures)
                : (text: normalized, column: nil)
            wasHardWrapped = joined.text != normalized
            hardWrapColumn = (wasHardWrapped ? joined.column : nil) ?? HardWrap.column
            rawSource = joined.text
            rebuildListIndentState()
            rebuildLinkDefState()
            blocks = BlockParser.parse(rawSource, features: markdownFeatures)
            Log.blockStructure(blocks)
            undoStack.removeAll()
            redoStack.removeAll()
            recompose(cursorInRaw: 0)
        }
    }
}

// MARK: - String UTF-16 Index Helper

extension String {
    func utf16Index(at offset: Int) -> String.Index {
        return String.Index(utf16Offset: offset, in: self)
    }
}
