import AppKit
import EdmundCore

/// Owns the find bar and drives search/replace against one document's editor.
/// Created by `Document` after the editor/scroll/container views exist.
///
/// Search is draw-only (highlights via `EditorTextView.setFindMatches`); the
/// only text mutation is Replace / Replace All, done through the editor's
/// sanctioned edit cycle so undo, recompose and storage == rawSource all hold.
@MainActor
final class FindController: NSObject, EditorFindHandling {

    private weak var editor: EditorTextView?
    private weak var scrollView: NSScrollView?
    private weak var container: NSView?
    private let bar = FindBarView()

    /// The scroll view's top content inset before we pushed content down for the
    /// bar (usually the toolbar overlap). Restored on hide.
    private var savedTopInset: CGFloat = 0
    private var isShowing = false

    init(editor: EditorTextView, scrollView: NSScrollView, container: NSView, statusBar: NSView) {
        self.editor = editor
        self.scrollView = scrollView
        self.container = container
        super.init()

        editor.findHandler = self

        bar.isHidden = true
        bar.autoresizingMask = [.width, .minYMargin]   // pinned to the top edge
        // Park it at the container's full width, not the default zero frame.
        // A flexible-width autoresizing view only grows by the *delta* from the
        // width it was added at, so a zero-width bar reaches the minimum width
        // its own (required) constraints demand — the fields and buttons — only
        // once the window is that much wider than it started. AppKit turns that
        // into the window's contentMinSize, which both pins the minimum width to
        // `initial width + bar minimum` and inflates the opening frame to match,
        // leaving `window.minSize` moot. Sized here, the bar tracks the container
        // and the window's own minSize governs again. `layoutBar` positions it
        // (and sets the content inset) on every show.
        bar.setFrameSize(NSSize(width: container.bounds.width, height: bar.preferredHeight))
        // Below the floating status bar so counts stay on top.
        container.addSubview(bar, positioned: .below, relativeTo: statusBar)

        bar.onSearchChanged = { [weak self] in self?.runSearch(resetToFirst: true) }
        bar.onOptionsChanged = { [weak self] in self?.runSearch(resetToFirst: true) }
        bar.onNext = { [weak self] in self?.step(+1) }
        bar.onPrevious = { [weak self] in self?.step(-1) }
        bar.onDone = { [weak self] in self?.editorHideFind() }
        bar.onToggleReplace = { [weak self] _ in self?.layoutBar() }
        bar.onReplace = { [weak self] in self?.replaceCurrent() }
        bar.onReplaceAll = { [weak self] in self?.replaceAll() }
        bar.onToggleFindBar = { [weak self] replace in self?.editorToggleFind(replace: replace) }

        // Live edits while the bar is open: re-run so the count/highlights track.
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorTextChanged),
            name: NSText.didChangeNotification, object: editor)
    }

    // MARK: - EditorFindHandling

    /// ⌘F and ⌥⌘F both toggle. Pressing the shortcut for the bar that is already
    /// up closes it; pressing the other one switches to it, so ⌘F from the
    /// replace bar drops the replace row rather than closing outright.
    func editorToggleFind(replace: Bool) {
        if isShowing && bar.showsReplaceRow == replace {
            editorHideFind()
        } else {
            editorShowFind(replace: replace)
        }
    }

    private func editorShowFind(replace: Bool) {
        guard let editor else { return }
        let firstShow = !isShowing
        if firstShow {
            savedTopInset = scrollView?.contentInsets.top ?? 0
            scrollView?.automaticallyAdjustsContentInsets = false
            isShowing = true
        }
        bar.showsReplaceRow = replace
        layoutBar()
        // Finish the bar's internal layout *before* revealing it, otherwise the
        // first painted frame is pre-layout and controls (the search field's
        // magnifier) visibly settle a pass later.
        bar.layoutSubtreeIfNeeded()
        if firstShow { bar.isHidden = false }

        // Seed from the current selection when it's a single line of text.
        let sel = editor.selectedRange()
        if sel.length > 0 {
            let picked = (editor.string as NSString).substring(with: sel)
            if !picked.contains("\n") { bar.searchField.stringValue = picked }
        }
        editor.window?.makeFirstResponder(bar.searchField)
        runSearch(resetToFirst: true)
    }

    func editorHideFind() {
        guard isShowing else { return }
        isShowing = false
        bar.isHidden = true
        editor?.clearFindMatches()
        scrollView?.automaticallyAdjustsContentInsets = true
        editor?.window?.makeFirstResponder(editor)
    }

    func editorFindNext() {
        if isShowing { step(+1) } else { editorShowFind(replace: false) }
    }

    func editorFindPrevious() {
        if isShowing { step(-1) } else { editorShowFind(replace: false) }
    }

    // MARK: - Layout

    /// Positions the bar under the toolbar and pushes the document content down
    /// by the bar's height (varies with the replace row).
    private func layoutBar() {
        guard let container, let scrollView else { return }
        let h = bar.preferredHeight
        bar.frame = NSRect(x: 0,
                           y: container.bounds.height - savedTopInset - h,
                           width: container.bounds.width, height: h)
        scrollView.contentInsets.top = savedTopInset + h
    }

    // MARK: - Search

    private var matches: [NSRange] = []

    @objc private func editorTextChanged() {
        guard isShowing else { return }
        runSearch(resetToFirst: false)
    }

    /// Recomputes matches from the current source. `resetToFirst` picks the first
    /// match at/after the caret (new search); otherwise keeps the closest index
    /// so a live edit doesn't jump the selection around.
    private func runSearch(resetToFirst: Bool) {
        guard let editor else { return }
        let needle = bar.searchField.stringValue
        matches = FindEngine.matches(of: needle, in: editor.rawSource,
                                     caseSensitive: bar.caseSensitive,
                                     wholeWord: bar.wholeWord)

        guard !matches.isEmpty else {
            bar.setCount(current: nil, total: 0)
            editor.setFindMatches([], current: nil)
            return
        }
        let caret = editor.selectedRange().location
        let current = matches.firstIndex { $0.location >= caret } ?? 0
        bar.setCount(current: current, total: matches.count)
        editor.setFindMatches(matches, current: current)
        if resetToFirst { editor.revealFindMatch(current) }
    }

    private func step(_ delta: Int) {
        guard let editor, !matches.isEmpty,
              let current = editor.currentMatchIndex else { return }
        let next = (current + delta + matches.count) % matches.count
        bar.setCount(current: next, total: matches.count)
        editor.setFindMatches(matches, current: next)
        editor.revealFindMatch(next)
    }

    // MARK: - Replace
    // Both paths go through shouldChangeText → replaceCharacters → didChangeText,
    // the editor's own edit cycle: one undo snapshot each, rawSource re-synced,
    // recompose triggered. Never mutate storage outside this cycle.

    private func replaceCurrent() {
        guard let editor, let idx = editor.currentMatchIndex,
              matches.indices.contains(idx) else { return }
        let range = matches[idx]
        let replacement = bar.replaceField.stringValue
        applyEdit(range: range, replacement: replacement, in: editor)
        // The document changed; recompute and advance to the next hit.
        runSearch(resetToFirst: false)
    }

    private func replaceAll() {
        guard let editor, !matches.isEmpty else { return }
        let replacement = bar.replaceField.stringValue
        // Rebuild the whole source once (back-to-front so earlier offsets stay
        // valid) and apply it as a single edit → a single undo step.
        let source = editor.rawSource as NSString
        let result = NSMutableString(string: source)
        for range in matches.reversed() {
            result.replaceCharacters(in: range, with: replacement)
        }
        applyEdit(range: NSRange(location: 0, length: source.length),
                  replacement: result as String, in: editor)
        runSearch(resetToFirst: false)
    }

    private func applyEdit(range: NSRange, replacement: String, in editor: EditorTextView) {
        guard editor.shouldChangeText(in: range, replacementString: replacement) else { return }
        editor.textStorage?.replaceCharacters(in: range, with: replacement)
        let caret = range.location + (replacement as NSString).length
        editor.setSelectedRange(NSRange(location: min(caret, (editor.string as NSString).length), length: 0))
        editor.didChangeText()
    }
}
