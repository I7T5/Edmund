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
    /// Defaults to 4. Maintained incrementally from `listIndentState` on the
    /// edit path; rebuilt by the whole-document paths (load, undo, indent).
    ///
    /// Document-global, so it is deliberately **not** what a list item in the
    /// document is drawn at any more — see `listDepths`. Dividing by it made
    /// one Tab that wrote a narrower indent re-depth every other list on
    /// screen. It survives as the fallback for `styleBlock` calls that have no
    /// block index (a list inside a table cell or a callout, and the styling
    /// tests), where there are no preceding lines to stack.
    ///
    /// Still logged on change: rare (a few per session at most), and it says
    /// the document's indent convention shifted under the user.
    public var listIndentUnit: Int = 4 {
        didSet {
            guard listIndentUnit != oldValue else { return }
            Log.info("list indent unit \(oldValue) → \(listIndentUnit) "
                     + "(histogram=\(listIndentState.histogram) "
                     + "tabLines=\(listIndentState.tabLines))", category: .edit)
        }
    }
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
    var blocks: [Block] = [] {
        didSet { listDepthsCache = nil }
    }
    var listDepthsCache: [Int]?

    /// Nesting depth of each block's list line, or `ListDepthMap.notAList`.
    /// Built lazily and dropped by `blocks`' `didSet`, the one hook covering
    /// every reparse. This — not `listIndentUnit` — is what the renderer draws
    /// list indentation from, so a line's depth depends only on the lines above
    /// it and indenting one list can't move another.
    // ponytail: recomputed whole on the next read after any reparse. O(blocks),
    // and only the leading whitespace of each block, so it costs about what
    // `rebuildListIndentState` already does per edit. Upgrade path if it shows
    // up in a profile: rebuild forward from the changed block and stop once the
    // stack matches the old one, since everything past that point is unchanged.
    var listDepths: [Int] {
        if let listDepthsCache { return listDepthsCache }
        let depths = ListDepthMap.build(from: blocks)
        listDepthsCache = depths
        return depths
    }

    /// Depth to draw block `index` at, or nil when it has no list line — the
    /// document-context answer `styleBlock` uses in place of its whitespace
    /// fallback.
    func listDepth(ofBlock index: Int) -> Int? {
        let depths = listDepths
        guard index >= 0, index < depths.count, depths[index] != ListDepthMap.notAList else {
            return nil
        }
        return depths[index]
    }

    /// List blocks whose depth differs from `old` — the depths captured before
    /// this reparse — so a caller can restyle exactly them. Depth is a column
    /// stack over the preceding lines, so changing one list line's indent
    /// re-depths the lines below it, which is why an edit's own dirty set isn't
    /// enough on its own.
    ///
    /// The two arrays are matched by common prefix and suffix, so inserting or
    /// deleting a block shifts indices without reporting everything below it as
    /// changed — an ordinary keystroke reports nothing.
    func listDepthChanges(from old: [Int]) -> IndexSet {
        let new = listDepths
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        guard prefix < old.count || prefix < new.count else { return IndexSet() }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        var changed = IndexSet()
        for i in prefix..<(new.count - suffix) where new[i] != ListDepthMap.notAList {
            changed.insert(i)
        }
        return changed
    }
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
    /// Image files dropped on an untitled document, held while the Save sheet
    /// runs (see EditorTextView+ImageDrop). Only one sheet can be up at a time,
    /// so a single slot is enough.
    var pendingDroppedImages: [URL] = []
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
            syncCascadeResolver()
        }
    }

    /// Pushes the theme's per-script font choices into the text storage.
    /// Called from theme.didSet (live changes via applyTheme — which already
    /// recomposes, so no extra layout invalidation is needed here) and once
    /// from commonInit, since didSet does not fire for the initial value.
    private func syncCascadeResolver() {
        (textStorage as? EditorTextStorage)?.cascadeResolver =
            FontCascadeResolver(cascade: theme.fontCascade,
                                sizeRatios: theme.fontCascadeSizeRatios)
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
    public var typewriterModeEnabled: Bool = true {
        didSet {
            guard oldValue != typewriterModeEnabled else { return }
            // The space above the first line is what makes centering reachable
            // at the document's start (see updateScrollOverscroll); reserve it
            // before centering, or the first center after switching on clamps.
            updateScrollOverscroll()
            if typewriterModeEnabled { centerViewportOnCaret() }
        }
    }

    /// Combined height of the chrome bars the app layer stacks over the top of
    /// the scroll view (format bar, find bar). `Document.layoutTopBars` is the
    /// only writer.
    ///
    /// Applied as the scroll view's `contentInsets.top`, *not* as overscroll:
    /// the document is pushed down out from under the bars without gaining any
    /// scrollable emptiness above its first line. See `updateScrollOverscroll`.
    public var additionalTopInset: CGFloat = 0 {
        didSet {
            guard abs(oldValue - additionalTopInset) > 0.5 else { return }
            updateScrollOverscroll()
        }
    }

    /// Dedupe flag for `scheduleOverscrollUpdate`.
    var overscrollUpdateScheduled = false

    /// Blank space reserved above the first line by typewriter mode (half the
    /// viewport) and below the last line (half the viewport, always). Applied
    /// through `textContainerInset` + `textContainerOrigin` — see
    /// `updateScrollOverscroll` for why not `NSScrollView.contentInsets`.
    var overscrollTopPad: CGFloat = 0
    var overscrollBottomPad: CGFloat = 0

    /// Places the text container within the frame ourselves. AppKit's default
    /// splits the frame-vs-container leftover evenly, which (a) can't express
    /// the asymmetric reserve below — `textContainerInset` is symmetric, so the
    /// room it buys arrives half at each end — and (b) is not the inset it was
    /// given, nor the same on every OS (macOS 15 returned inset 160 as origin
    /// 160; macos-14 returned 135). Owning the value makes the padding exact
    /// and identical everywhere; TextKit 2 lays fragments out against it.
    public override var textContainerOrigin: NSPoint {
        let pad = overscrollTopPad + overscrollBottomPad
        let base = textContainerInset.height - pad / 2
        return NSPoint(x: super.textContainerOrigin.x, y: base + overscrollTopPad)
    }

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

    /// Block index of the table the pointer is over, or nil. Together with the
    /// caret being inside a table, this is what reveals the `</>` button — the
    /// margin stays empty until one of the two is true. See
    /// EditorTextView+TableRawButton.
    var hoveredTableBlock: Int?

    /// Whether the pointer is on the revealed `</>` button itself, which draws
    /// its hover highlight.
    var tableRawButtonHovered = false

    /// The row/column handle under the pointer, and the bands the handles were
    /// last drawn in — the handles follow the caret, so a caret move has to
    /// repaint where they were as well as where they now are.
    /// See EditorTextView+TableHandles.
    var hoveredTableHandle: TableHandle?
    var lastTableHandleBands: [NSRect] = []

    /// The bands the `</>` buttons were last drawn in. The button steps aside
    /// for the row pill when the header row is active, so a caret move relocates
    /// it — and where it was has to repaint too, or the old position ghosts.
    /// See EditorTextView+TableRawButton.
    var lastTableRawButtonBands: [NSRect] = []

    /// The active table cell at the last selection change, as `block.row.column`.
    /// Used to force a full repaint when the caret crosses into a different cell
    /// — the one moment table chrome (pills, cell outline) moves — so nothing is
    /// left behind even when the grid is briefly unavailable mid-restyle. Bounded
    /// to cell transitions, so typing inside a cell never triggers it.
    var lastActiveTableCellKey: String?

    /// Whether a multi-cell table selection was up at the last selection
    /// change, so the box can be repainted away when it goes.
    /// See EditorTextView+TableHandles.
    var tableCellSelectionWasActive = false

    /// A block of cells is marked by its box alone, so AppKit's text highlight
    /// is switched off while one is up. These hold the attributes to put back,
    /// and whether they are currently swapped out.
    lazy var defaultSelectedTextAttributes: [NSAttributedString.Key: Any]
        = selectedTextAttributes
    var tableCellHighlightSuppressed = false

    /// Whether the drag in progress has left the cell it started in. Once it
    /// has, coming back to a single cell selects that cell whole rather than
    /// reverting to a character selection. Reset at every `mouseDown`.
    var tableDragCrossedCells = false

    /// Set while `activateRawTableEditing` is placing the caret at a table's
    /// first character. That character is a pipe, and the rules below move a
    /// caret off a pipe — but this one is deliberate, and the table is about to
    /// stop being rendered anyway.
    var activatingRawTable = false

    /// How many clicks the gesture in flight is, and which character AppKit
    /// hit — held for the same span as `tableClickPoint`, and for the same
    /// reason: `setSelectedRanges` is where a selection can still be corrected
    /// before anyone sees it, and it knows neither on its own.
    var tableClickCount = 0
    var tableClickHit: Int?
    /// Where the click in flight lands in a wrapped cell's *drawn* text, when
    /// it lands in one — resolved against the scratch layout before the gesture
    /// runs, since AppKit's own hit test can only find the hidden characters.
    var tableClickWrappedCaret: Int?

    /// Set while a keystroke is being inserted. The table caret-resting rule
    /// pulls a caret out of a cell's trailing pad, which is right for a click
    /// or an arrow but wrong for typing: a space typed at the end of a cell's
    /// text lands in that pad, and yanking the caret back off it meant the
    /// space could never be typed at all. A caret an insertion just placed is
    /// where the user put it, so resting stands down while this is set.
    var isInsertingText = false

    /// Where the click now in flight landed, in view coordinates, for as long
    /// as `mouseDown` is running. It is what lets `setSelectedRanges` keep a
    /// caret in the cell the user aimed at: only the point knows which cell
    /// that was, and by then the point is long gone from the call stack.
    /// See `tableCellCaretSnap(at:offset:)`.
    var tableClickPoint: NSPoint?

    /// The pointer-tracking area behind `hoveredTableBlock`.
    var tableHoverTrackingArea: NSTrackingArea?

    /// The open popup cell editor, and the cell it is editing. See
    /// EditorTextView+TableCellEditor.
    var cellEditorPanel: CellEditorPanel?
    var editingTableCell: TableCellRef?

    /// Set once the popup has been dragged off the table into a free-floating
    /// window: it stops tracking the table and grows its own close box.
    var isCellEditorDetached = false

    /// True while a table is deliberately showing its raw markdown, which the
    /// `</>` button asks for. A caret inside a table no longer implies raw —
    /// the table stays rendered and the cell is edited in place — so this is
    /// the only way back to the pipes, for the structural edits (adding a
    /// column, fixing a separator row) that in-place editing cannot express.
    var rawTableEditing = false

    /// The caret Edmund draws itself, inside a table cell too wide for its
    /// column: its blink phase, where it was last drawn (so the old position
    /// can be invalidated when it moves) and the timer running the blink.
    /// AppKit's own caret is switched off while this one is up — it would draw
    /// at the column's left edge, where the cell's hidden characters are.
    /// See EditorTextView+TableCellCaret.
    var wrappedCaretOn = false
    var wrappedCaretRect: NSRect?
    var wrappedCaretTimer: Timer?

    /// The card's top edge in view coordinates, fixed for as long as it points
    /// at one cell. Nil re-reads it from the row on the next placement.
    var cellEditorAnchorY: CGFloat?

    /// True once this popup session has pushed its undo snapshot. Typing in the
    /// popup rewrites the cell on every keystroke so the table reflows live, and
    /// without this every keystroke would also be its own undo step.
    var cellEditorDidSnapshot = false

    /// Ends the edit when the document window stops being key, and keeps the
    /// attached popup under its table while the view scrolls.
    var cellEditorKeyObserver: NSObjectProtocol?
    var cellEditorScrollObserver: NSObjectProtocol?

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
        syncCascadeResolver()
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

        // Register the dragged types from our overridden `acceptableDragTypes`
        // (see EditorTextView+ImageDrop), so image files can be dropped in.
        // Explicitly, not via `updateDragTypeRegistration()`: that one is a
        // no-op this early (measured — `registeredDraggedTypes` stays empty),
        // and the drop would then only start working once something toggled
        // `isEditable`. AppKit does re-register on its own when isEditable
        // flips (the viewMode setter does that), and it reads the same
        // overridden `acceptableDragTypes`, so this registration survives
        // edit/read mode switches.
        registerForDraggedTypes(acceptableDragTypes)

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
            selector: #selector(mathEngineDidChange(_:)),
            name: .mathEngineChanged,
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

    @objc private func mathEngineDidChange(_ note: Notification) {
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
        // A table's `</>` button hangs in the margin outside the text column,
        // where AppKit has nothing to select — so this takes the click whole and
        // never reaches `super`. See EditorTextView+TableRawButton.
        if let tableBlock = tableRawButtonHit(at: event) {
            activateRawTableEditing(blockIndex: tableBlock)
            return
        }
        // A row/column handle hangs in the same margin, and in the band above
        // the table. Same reasoning: nothing there to select, so it takes the
        // click whole. See EditorTextView+TableHandles.
        if let handle = tableHandleHit(at: event) {
            showTableHandleMenu(handle, with: event)
            return
        }
        // A dot on a cell selection's corner drags the selection wider. AppKit's
        // tracking would anchor on the click and start a fresh selection, so
        // this takes the gesture whole. See EditorTextView+TableHandles.
        if let grab = tableCellSelectionAnchor(at: convert(event.locationInWindow, from: nil)) {
            trackTableCellSelection(from: grab.anchor, blockIndex: grab.block.blockIndex)
            return
        }
        // An open popup ends on any click that isn't on its own table. The
        // popover is `.applicationDefined`, so nothing else does this.
        dismissCellEditorIfClickIsOutside(event)
        // EXPERIMENT (inline table editing): the popover no longer takes the
        // click. A table now stays rendered with the caret inside it, so the
        // click falls through to ordinary caret placement in the real text.
        if false, let cell = tableCellForCellEditor(at: event) {
            openTableCellEditor(cell)
            return
        }
        // A single click/drag on a wrapped cell's drawn text is taken whole:
        // its own tracking loop reads each drag event's location (so drag-select
        // works there), and it never lets `super.mouseDown` place AppKit's caret
        // on the hidden characters first (so the caret does not flash to the
        // cell's start). A double-click falls through to the handling below.
        if handleWrappedCellDrag(with: event) { return }
        // A wrapped table cell is drawn from a detached layout, so AppKit's own
        // hit-testing can only ever land on the hidden characters underneath it
        // (all of which sit at one x). Resolve the click against the drawn text
        // instead — before `super`, while the table is still rendered — and put
        // the caret there once the gesture is over. The offset stays valid
        // across the click's activate-the-table restyle because it is a raw
        // source offset (storage == rawSource).
        let wrappedCellCaret = wrappedCellCharIndex(at: event)
        // Kill AppKit's own caret *before* `super.mouseDown` gets to paint it.
        // Every hidden character of a wrapped cell sits at the same left-edge x,
        // so AppKit would draw its insertion point there — the visible "jump to
        // the start of the cell" — and clearing the colour only afterwards was
        // too late, the paint had already happened. Our own caret is drawn from
        // `drawWrappedCellChrome`; `updateWrappedCaret` restores AppKit's colour
        // the moment the caret is somewhere it can handle.
        if wrappedCellCaret != nil {
            insertionPointColor = .clear
            setAppKitCaretHidden(true)
        }
        // AppKit's own answer to "which character is under the pointer", taken
        // before the gesture runs and moves the selection out from under it.
        let clickHit = clickCharIndex(at: event)
        // A fresh gesture starts inside whatever cell it lands in.
        tableDragCrossedCells = false
        // Held for the whole gesture so that every selection AppKit installs —
        // the first one included — is corrected as it goes in rather than
        // afterwards. `super.mouseDown` does not return until the mouse comes
        // up, and it paints while it tracks, so a correction made after it
        // returns is a correction the user watches happen.
        tableClickPoint = convert(event.locationInWindow, from: nil)
        tableClickCount = event.clickCount
        tableClickHit = clickHit
        tableClickWrappedCaret = wrappedCellCaret
        suppressTypewriterCentering = true
        super.mouseDown(with: event)
        suppressTypewriterCentering = false
        let clickPoint = tableClickPoint ?? convert(event.locationInWindow, from: nil)
        let wasDoubleClick = tableClickCount == 2
        tableClickPoint = nil
        tableClickCount = 0
        tableClickHit = nil
        tableClickWrappedCaret = nil
        // Every single-click correction — the wrapped-cell caret, the snap out
        // of a cell's padding, the resting rule — is applied *in flight* by
        // `setSelectedRanges` while `super.mouseDown` tracks, so the final
        // placement is installed exactly once and there is nothing to re-apply
        // here. Re-applying it after the gesture fired a second selection change
        // and the caret visibly jumped from one to the other. Only the
        // double-click scroll survives: it moves nothing, just brings the cell
        // it already selected into view.
        if wasDoubleClick, selectedRange().length > 0,
           let cell = tableCellEmptySpace(at: clickPoint, hit: clickHit) {
            scrollRangeToVisible(tableCellSelectionRange(cell))
        }
        // A click that lands in a table restyles it, and in a table with a
        // wrapped cell the rows are not laid out again until after this gesture
        // returns — so the grid was unavailable when `selectionDidChange`
        // invalidated the handles, and the old pill was left on screen while the
        // new one never drew. Re-invalidate once layout has settled, when the
        // grid is back: the kept `lastTableHandleBands` clears the old pill and
        // the fresh handles draw the new one. Cheap and idempotent off a table.
        if blockIndexForRawOffset(selectedRange().location)
            .map({ $0 < blocks.count && blocks[$0].kind == .table }) == true {
            DispatchQueue.main.async { [weak self] in
                self?.invalidateTableHandles()
                self?.invalidateTableRawButtons()
            }
        }
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
        // A drag that crosses from one table cell into another selects whole
        // cells, the way Notes does: a selection that stops mid-cell cannot say
        // which cells a Copy would take. It is installed as one range per row —
        // see EditorTextView+TableHandles for why that matters.
        var ranges = ranges
        // A double-click out in a cell's empty space takes the cell, and takes
        // it here rather than once the gesture is over: `super.mouseDown` does
        // not return until the mouse comes up and it paints while it tracks, so
        // a selection installed afterwards is one the user watches replace
        // whatever AppKit put there first. See `tableCellEmptySpace`.
        if let point = tableClickPoint, tableClickCount == 2, !activatingRawTable,
           let cell = tableCellEmptySpace(at: point, hit: tableClickHit) {
            ranges = [NSValue(range: tableCellSelectionRange(cell))]
        }
        // A click on a wrapped cell's drawn text goes to the character it
        // landed on there. Installed in flight for the same reason as
        // everything else here: applied after the gesture it was a second
        // answer, and the caret visibly jumped from the first one to it.
        if let wrapped = tableClickWrappedCaret, !activatingRawTable, ranges.count == 1,
           let caret = ranges[0].rangeValue as NSRange?, caret.length == 0 {
            ranges = [NSValue(range: NSRange(location: wrapped, length: 0))]
        }
        // (A drag within a wrapped cell is taken whole by `handleWrappedCellDrag`
        // in `mouseDown`, which reads each drag event's own location — not the
        // stale `mouseLocationOutsideOfEventStream` this override would see — so
        // there is nothing to rebuild here.)
        // A caret placed by the click in flight belongs to the cell that click
        // landed in. Corrected here, where the selection is installed, so no
        // other placement is ever painted — and so that it holds for every path
        // that sets a selection during the gesture, not just the one that
        // returns through `mouseDown`.
        if let point = tableClickPoint, !activatingRawTable, ranges.count == 1,
           let caret = ranges[0].rangeValue as NSRange?, caret.length == 0,
           let snapped = tableCellCaretSnap(at: point, offset: caret.location) {
            ranges = [NSValue(range: NSRange(location: snapped, length: 0))]
        }
        // A selection inside one cell covers that cell's text and nothing else:
        // not the pad, not the hidden pipe. See `tableCellSelectionTrimmed`.
        if ranges.count == 1, let selection = ranges[0].rangeValue as NSRange?,
           selection.length > 0, let trimmed = tableCellSelectionTrimmed(selection) {
            ranges = [NSValue(range: trimmed)]
        }
        // And wherever it came from — except a keystroke — a caret never rests
        // in a cell's padding or on a pipe, before or after it. Typing is the
        // exception: a space typed at a cell's end lands in the trailing pad,
        // and pulling the caret back off it would eat the space. See
        // `tableCellCaretResting` and `isInsertingText`.
        if !activatingRawTable, !isInsertingText, ranges.count == 1,
           let caret = ranges[0].rangeValue as NSRange?, caret.length == 0,
           let moved = tableCellCaretResting(caret.location, from: selectedRange().location) {
            ranges = [NSValue(range: NSRange(location: moved, length: 0))]
        }
        // A drag across cells is a rectangle between where it started and where
        // the pointer is now — read off the grid rather than off the character
        // range it happens to have swept. See `tableCellBlock(fromPoint:toPoint:)`.
        if let anchorPoint = tableClickPoint, ranges.count == 1,
           let first = ranges[0].rangeValue as NSRange?, first.length > 0,
           let window,
           case let pointer = convert(window.mouseLocationOutsideOfEventStream, from: nil),
           let block = tableCellBlock(fromPoint: anchorPoint, toPoint: pointer) {
            tableDragCrossedCells = true
            let perRow = tableCellSelectionRanges(block)
            if !perRow.isEmpty { ranges = perRow }
        }
        if ranges.count == 1, let first = ranges[0].rangeValue as NSRange? {
            if let block = tableCellBlock(for: first) {
                tableDragCrossedCells = true
                let perRow = tableCellSelectionRanges(block)
                if !perRow.isEmpty { ranges = perRow }
            } else if tableDragCrossedCells, first.length > 0,
                      let cell = tableCell(atRawOffset: first.location) {
                // Back inside a single cell after having left it: Notes
                // reselects that cell whole rather than the sliver the pointer
                // happens to be over, so the gesture reads as picking cells
                // throughout rather than switching back to picking characters.
                ranges = [NSValue(range: cell.contentRange)]
            }
        }
        // Before `super`: AppKit resolves the highlight's colour as it installs
        // the selection, so attributes set afterwards only land at the *next*
        // change.
        // Suppress AppKit's own highlight for a cell block, and also for a
        // selection inside a single wrapped cell: there the real characters are
        // hidden at one x, so AppKit's highlight is a stray sliver at the left
        // edge on top of the custom one drawn over the visible text.
        let wrappedSelection = ranges.count == 1
            && (ranges[0].rangeValue as NSRange).length > 0
            && !wrappedCellRects(for: ranges[0].rangeValue).isEmpty
        setTableCellHighlight(
            suppressed: tableCellBlock(forRanges: ranges) != nil || wrappedSelection)
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        updateTableCellSelectionChrome()
        // AppKit suppresses `selectionDidChange` while a click or drag is still
        // in flight (`stillSelecting`), so the wrapped-cell caret upkeep that
        // rides that notification never runs during a mouse-button hold. In a
        // wrapped cell that left AppKit's own insertion point drawn on the
        // cell's hidden characters — bunched at the top-left — for the length of
        // the press, then it jumped to where our caret really is once the button
        // came up. Running the upkeep here too keeps the caret honest throughout.
        //
        // `tableClickPoint` covers a plain click's *final* install too: that call
        // is `stillSelecting == false`, but it happens inside `super.mouseDown`,
        // before the click's `selectionDidChange` is delivered — so without it
        // AppKit's caret still flashes at the hidden-character left edge (the
        // "jumps to the start of the cell, then back") until the gesture returns.
        if stillSelecting || tableClickPoint != nil { updateWrappedCaret() }
    }

    /// The range actually copied, for the "selection over rendered math copies
    /// fewer characters than highlighted" report — the highlight is drawn over
    /// the overlay while the underlying character range can stop at the hidden
    /// run's boundary; this line shows the truth at ⌘C time.
    public override func copy(_ sender: Any?) {
        traceEdit("copy")
        // A table's storage is its markdown, so an ordinary copy hands the next
        // app a row of pipes. See EditorTextView+TableCopy for the two cases
        // that are worth more than that.
        if let text = tableCopyText() {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return
        }
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

    /// The storage character index under a mouse event when it lands on the
    /// drawn text of a wrapped (overflowing) table cell, else nil — see
    /// `DecoratedTextLayoutFragment.cellWrapCharacterIndex`.
    func wrappedCellCharIndex(at event: NSEvent) -> Int? {
        wrappedCellCharIndex(atViewPoint: convert(event.locationInWindow, from: nil))
    }

    /// The character under a view-coordinate point when it falls on a wrapped
    /// cell's drawn text, mapped through the scratch layout — the drag-select
    /// counterpart of the event version, for the pointer sampled mid-drag.
    func wrappedCellCharIndex(atViewPoint viewPoint: NSPoint) -> Int? {
        guard let tlm = textLayoutManager,
              let storage = textStorage, storage.length > 0 else { return nil }

        var point = viewPoint
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y

        guard let fragment = tlm.textLayoutFragment(for: point)
                as? DecoratedTextLayoutFragment else { return nil }
        let frame = fragment.layoutFragmentFrame
        let inFragment = CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
        guard let indexInParagraph = fragment.cellWrapCharacterIndex(for: inFragment),
              let paraStart = fragment.textElement?.elementRange?.location else { return nil }
        let charIndex = tlm.offset(from: tlm.documentRange.location, to: paraStart) + indexInParagraph
        return charIndex <= storage.length ? charIndex : nil
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
