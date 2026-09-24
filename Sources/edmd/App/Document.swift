import AppKit
import UniformTypeIdentifiers
import EdmundCore

/// NSDocument subclass that provides standard macOS document lifecycle:
/// file open/save, dirty-dot indicator, click-to-rename in the titlebar,
/// recent documents, and more — all for free.
///
/// The actual editing is delegated entirely to `EditorTextView`.
class Document: NSDocument, HeadingNavigable {

    var editor: EditorTextView!
    private var statusBar: StatusBarView!
    /// The view-mode toolbar item. Its image, label and tooltip follow the mode.
    private weak var viewModeItem: NSToolbarItem?
    private static let viewModeItemID = NSToolbarItem.Identifier("viewMode")

    /// Builds and owns the formatting toolbar items (see `FormatToolbar`).
    private var formatToolbar: FormatToolbar!

    /// Session-only zoom scale (View ▸ Actual Size/Zoom In/Zoom Out), applied on
    /// top of the persisted font size and content width. Not saved — each new
    /// window starts back at 100%.
    private var zoomFactor: CGFloat = 1.0
    private static let zoomStep: CGFloat = 0.1
    private static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0

    /// Editor scroll view and its container, held so Read mode can swap the
    /// editor out for a `ReadModeWebView` (created lazily on first read).
    private var scrollView: NSScrollView!
    private var containerView: NSView!
    private var findController: FindController!
    private var formatBar: FormatBarView!
    private var readView: ReadModeWebView?

    /// Editor character offset captured when entering Read mode (the topmost
    /// visible line at the moment of the switch), used to scroll the editor
    /// back to roughly the same place if leaving Read mode returns no anchor
    /// (e.g. the rendered document had no top-level blocks).
    private var lastReadAnchorOffset: Int?

    /// Content loaded from disk before the editor window exists.
    /// `nonisolated(unsafe)` because `read(from:ofType:)` may be called
    /// off the main actor, but the value is only consumed on main via
    /// `adoptPendingContent`.
    nonisolated(unsafe) var pendingContent: String?

    /// Content already in the editor but not yet checked for mixed line endings —
    /// the check shows a sheet, so it waits until the window is on screen.
    private var contentPendingWarning: String?

    // MARK: - Type Registration
    //
    // Without an Info.plist (SPM executable), NSDocument's default readableTypes
    // and writableTypes are empty, which causes NSDocumentController to disable
    // Open/Save entirely. We override them here.

    override class var readableTypes: [String] {
        ["public.plain-text", "net.daringfireball.markdown"]
    }

    override class var writableTypes: [String] {
        ["net.daringfireball.markdown", "public.plain-text"]
    }

    override class var autosavesInPlace: Bool {
        AppSettings.autoSaveWithVersions
    }

    override class func isNativeType(_ name: String) -> Bool {
        return readableTypes.contains(name)
    }

    // A single writable type keeps the save panel from showing a file-format
    // popup. Everything we write is markdown, so there's nothing to choose.
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        ["net.daringfireball.markdown"]
    }

    // The `net.daringfireball.markdown` UTI prefers the ".markdown" extension;
    // force ".md" instead, which is what people actually expect.
    override func fileNameExtension(forType typeName: String,
                                    saveOperation: NSDocument.SaveOperationType) -> String? {
        "md"
    }

    // `fileNameExtension(forType:…)` alone isn't enough: for an untitled save
    // the panel still seeds its name field from the markdown UTI's preferred
    // extension (".markdown"). Force the default name to end in ".md" and let
    // the user type any other extension if they really want one.
    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        savePanel.allowedContentTypes = []
        savePanel.allowsOtherFileTypes = true
        let base = (savePanel.nameFieldStringValue as NSString).deletingPathExtension
        savePanel.nameFieldStringValue = (base.isEmpty ? "Untitled" : base) + ".md"
        return true
    }

    // MARK: - Window Setup

    /// Whether this document has anything a restored window could hand back: a
    /// file on disk, or unsaved edits. False only for an untitled document
    /// nobody has typed into.
    private var isWorthRestoring: Bool { fileURL != nil || isDocumentEdited }

    /// Every edit funnels through here (`EditorTextView+EditFlow.swift`), as does
    /// saving, so this is where a window becomes worth restoring — or stops
    /// being, if the last edit is undone away.
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        let restorable = isWorthRestoring
        for controller in windowControllers where controller.window?.isRestorable != restorable {
            controller.window?.isRestorable = restorable
        }
    }

    override func makeWindowControllers() {
        // Default content size for first launch. Any saved size is applied as a
        // full window frame at the end of setup (below), once the toolbar is in
        // place — so the frame round-trips exactly and doesn't drift by the
        // title bar + toolbar height each time.
        //
        // Sized so the *window* lands on a canonical 800x600: the height is the
        // content area, and the title bar + unified toolbar add 80pt on top.
        // The width also leaves the reading column (12cm / 5in physical, ~605pt
        // on a 14" display) balanced margins rather than being arbitrary.
        let windowWidth: CGFloat = 800
        let windowHeight: CGFloat = 520

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        // Restorable for the whole session, whatever "Reopen windows from last
        // session" says: state restoration is also how AppKit hands back a
        // document that was open when the app died, and unsaved work should
        // survive a crash regardless of that preference. A *clean* quit is where
        // the preference applies — AppDelegate.applicationShouldTerminate turns
        // this off before terminating when it is disabled, so nothing is archived
        // and the next launch starts fresh.
        //
        // A blank untitled document is the exception: there is nothing in it for
        // a crash to hand back, and archiving it means the next launch restores
        // it — through `NSDocumentController`'s own restoration path, which
        // neither `reopenDocument` nor `applicationShouldOpenUntitledFile` gates,
        // so it lands *on top of* the startup document as a second blank window
        // with "Reopen windows" off. It earns the flag on its first edit
        // (`updateChangeCount`).
        window.isRestorable = isWorthRestoring
        window.minSize = NSSize(width: 320, height: 400)
        window.backgroundColor = NSColor.textBackgroundColor

        // Build the TextKit 2 text system chain (viewport-based layout).
        editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            containerSize: NSSize(width: windowWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24,
                                           height: EditorTextView.contentBaseVerticalInset)
        // Centered reading column (see EditorTextView+ContentWidth). Convert the
        // persisted cm value to points using the main screen PPI at window-creation
        // time; recomputed on resize (setFrameSize), when the window first becomes
        // key, and when it moves to a different display (windowDidChangeScreen).
        let initScreen = NSScreen.main
        editor.maxContentWidthPoints = initScreen?.cmToPoints(AppSettings.maxContentWidthCm) ?? 1000
        editor.updateContentInset()
        editor.allowRemoteImages = !AppSettings.blockExternalImages
        editor.markdownFeatures = AppSettings.markdownFeatures
        editor.typewriterModeEnabled = AppDelegate.typewriterModeEnabled()
        AppSettings.applyEditSettings(to: editor)
        editor.document = self
        // Pasting/dropping an image into an unsaved document triggers the save
        // flow first — the assets folder is a sibling of the document file, so
        // there is nowhere to put it until the document has a path.
        editor.requestSaveForAttachment = { [weak self] completion in
            guard let self else { completion(false); return }
            self.saveForAttachment(then: completion)
        }
        // Following an internal link while in Read mode scrolls the visible web
        // view (the editor is hidden), not the editor itself.
        editor.onReadScrollToLine = { [weak self] line in
            self?.readView?.setScrollPosition(line: line, fraction: 0)
        }

        // Toolbar holds the formatting items plus the right-aligned view-mode
        // toggle (and gives the titlebar extra height for roomy traffic lights).
        // Set it only after `editor` exists — assigning the toolbar synchronously
        // vends its items.
        //
        // The identifier is versioned: `autosavesConfiguration` persists the item
        // layout per identifier, so every window that ever ran the one-item
        // toolbar has `[flexibleSpace, viewMode]` on disk, and that saved set
        // wins over any new defaults. Bumping the identifier is what makes the
        // format items appear for existing users; the only customization it
        // discards is the ordering of a single item.
        formatToolbar = FormatToolbar(document: self)
        let toolbar = NSToolbar(identifier: "MainToolbar2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true   // persists layout per "MainToolbar2"
        // Flexible space alone does not centre the group: measured on a 1500pt
        // window, the leading one absorbed all 1077pt of slack and the trailing
        // one got nothing. This is the API that actually centres.
        toolbar.centeredItemIdentifiers = FormatToolbar.centeredIdentifiers
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        let statusBarHeight: CGFloat = 22
        let contentBounds = window.contentView!.bounds

        // The text view fills the whole window; the status bar floats over its
        // bottom edge, revealed on hover.
        scrollView = NSScrollView(frame: contentBounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = editor
        // The overscroll past the document's ends is half the clip view's
        // height, so it can only be computed once the editor has an enclosing
        // scroll view — the content-inset call above ran before this line.
        editor.updateScrollOverscroll()

        // Floating status bar: hidden by default, fades in when the pointer
        // enters its strip. Counts on the left, line ending on the right.
        statusBar = StatusBarView(frame: NSRect(
            x: 0, y: 0, width: contentBounds.width, height: statusBarHeight
        ))
        statusBar.autoresizingMask = [.width]

        containerView = NSView(frame: contentBounds)
        containerView.autoresizesSubviews = true
        containerView.addSubview(scrollView)
        containerView.addSubview(statusBar)   // overlay, on top of the text

        window.contentView = containerView

        findController = FindController(editor: editor, scrollView: scrollView,
                                       container: containerView, statusBar: statusBar)
        findController.onLayoutNeeded = { [weak self] in self?.layoutTopBars() }

        // The format bar: a chrome strip across the top of the editor, above
        // the find bar. Parked exactly like the find bar — sized to the
        // container *before* `addSubview`, because a flexible-width autoresizing
        // view only grows by the delta from the width it was added at, and a
        // zero-width bar would inflate the window's opening frame (the
        // contentMinSize scar documented at FindController.init).
        formatBar = FormatBarView(frame: .zero)
        formatBar.isHidden = true
        formatBar.autoresizingMask = [.width, .minYMargin]   // pinned to the top edge
        formatBar.setFrameSize(NSSize(width: containerView.bounds.width, height: formatBar.preferredHeight))
        // Below the floating status bar so counts stay on top.
        containerView.addSubview(formatBar, positioned: .below, relativeTo: statusBar)

        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidChange(_:)),
            name: NSText.didChangeNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidResize(_:)),
            name: NSWindow.didResizeNotification, object: window
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didChangeScreenNotification, object: window
        )
        // The initial cap above was converted with NSScreen.main's PPI because
        // the window isn't on any screen yet. A window that first appears on a
        // secondary display doesn't reliably get didChangeScreen, so re-apply
        // once it's key (cheap: the setter no-ops on an unchanged value).
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidChangeScreen(_:)),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
        // Auto-hide is a full-screen-only affair, and applyToolbarAutoHide may
        // have hidden the toolbar outright to honour it. Put it back on the way
        // out, or a window that left full screen with auto-hide on keeps a
        // toolbar that Show/Hide Toolbar says is showing.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidExitFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification, object: window
        )

        // Restore the last window's frame size (the toolbar is now installed, so
        // the frame is final). Applied as a frame, not a contentRect, so it
        // round-trips exactly with what windowDidResize saves. Then center.
        if let savedSize = AppSettings.lastWindowSize {
            window.setFrame(NSRect(origin: window.frame.origin, size: savedSize), display: false)
        }
        window.center()

        let wc = DocumentWindowController(window: window)
        addWindowController(wc)
        // Assigned by hand: NSWindowController only makes itself the window's
        // delegate on the nib-loading path, and this window is built in code, so
        // `init(window:)` leaves `delegate` nil — which silently killed the
        // full-screen toolbar auto-hide (the delegate method below was never
        // called). Safe to point at the controller: NSWindowController itself
        // implements none of NSWindowDelegate, so nothing else changes hands —
        // in particular the undo manager still comes from the window, not the
        // document.
        window.delegate = wc
        window.makeFirstResponder(editor)
        applyToolbarVisibility()
        refreshFormatBar()
        // Before the source-mode switch below, which reads the editor's text.
        adoptPendingContent()
        // Honor the persisted source-mode preference for the editing view.
        if AppSettings.sourceMode { setViewMode(.source) }
        updateStatusBar()
    }

    @objc private func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Save the full frame size; it's restored verbatim via setFrame on the
        // next window, so the size round-trips exactly (no title-bar/toolbar drift).
        AppSettings.lastWindowSize = window.frame.size
    }

    /// Reapply the content-width cap in points when the window moves to a
    /// display with a different physical PPI (e.g. external monitor).
    @objc private func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let screen = window.screen else { return }
        editor?.maxContentWidthPoints = screen.cmToPoints(AppSettings.maxContentWidthCm) * zoomFactor
    }

    @objc private func windowDidExitFullScreen(_ notification: Notification) {
        applyToolbarVisibility()
    }

    // MARK: - Zoom (View ▸ Actual Size / Zoom In / Zoom Out)

    @objc func zoomIn(_ sender: Any?) { setZoom(zoomFactor + Self.zoomStep) }
    @objc func zoomOut(_ sender: Any?) { setZoom(zoomFactor - Self.zoomStep) }
    @objc func actualSize(_ sender: Any?) { setZoom(1.0) }

    /// Scales font size (standard + code) and max content width together by
    /// `factor`, off the persisted base values — never off the currently
    /// applied (possibly already-zoomed) theme, so repeated zooming doesn't
    /// compound rounding error and Actual Size always returns to the true base.
    private func setZoom(_ factor: CGFloat) {
        guard let editor else { return }
        zoomFactor = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, factor))

        editor.setZoom(zoomFactor)

        let screen = editor.window?.screen ?? NSScreen.main
        editor.maxContentWidthPoints = (screen?.cmToPoints(AppSettings.maxContentWidthCm) ?? 1000) * zoomFactor

        refreshReadView()
    }

    @objc private func editorDidChange(_ notification: Notification) {
        updateStatusBar()
        // An edit can add or remove the delimiters around the caret without
        // moving the selection, so the bar's on-state has to follow edits too.
        refreshFormatBarState()
        // Keep an open Read view in sync with edits (it renders a snapshot).
        refreshReadView()
    }

    @objc private func editorSelectionDidChange(_ notification: Notification) {
        updateStatusBar()
        refreshFormatBarState()
    }

    private func updateStatusBar() {
        guard let editor = editor, let statusBar = statusBar else { return }
        let text = editor.rawSource
        let nsText = text as NSString
        let wordCount = text.split { $0.isWhitespace || $0.isNewline }.count
        let charCount = text.count

        // Cursor position: 0-based character location and 1-based line number.
        let cursorOffset = editor.selectedRange().location
        let location = min(cursorOffset, nsText.length)
        let upToCursor = nsText.substring(to: location)
        let line = upToCursor.isEmpty ? 1 : upToCursor.components(separatedBy: "\n").count

        // The buffer is always LF; show the file's remembered original ending.
        statusBar.setMetrics(words: wordCount, characters: charCount,
                             location: location, line: line,
                             lineEnding: editor.originalLineEnding.displayName)
    }

    // MARK: - Reading

    override nonisolated func read(from data: Data, ofType typeName: String) throws {
        guard let contents = String(data: data, encoding: .utf8) else {
            Log.error("Read failed: \(data.count) bytes not valid UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "The file couldn’t be opened because it isn’t UTF-8 text."])
        }
        Log.info("Read \(data.count) bytes from disk", category: .io)
        pendingContent = contents
    }

    /// Moves what `read(from:)` parked in `pendingContent` into the editor.
    ///
    /// Called from `makeWindowControllers`, not only from `showWindows`: window
    /// restoration reopens a document with `display: false` and never calls
    /// `showWindows`, so hanging the load off that alone left restored — and
    /// crash-recovered — windows showing an empty buffer while the text sat
    /// unread in `pendingContent`. Saving such a window wrote that emptiness back
    /// over the file, since `data(ofType:)` serializes `editor.rawSource`.
    /// Idempotent: whichever path reaches it first does the work.
    private func adoptPendingContent() {
        guard let content = pendingContent, let editor else { return }
        editor.loadContent(content, unwrapHardWrapping: AppSettings.hardWrapLongLines)
        // Learn this document's indent from what it actually uses, overriding
        // the global style for this window only (never writes the setting).
        if AppSettings.detectIndent, let detected = EditorTextView.detectIndent(in: content) {
            editor.indentUsesTabs = detected.usesTabs
            if !detected.usesTabs { editor.indentWidth = detected.width }
        }
        pendingContent = nil
        contentPendingWarning = content
    }

    /// Called after makeWindowControllers when opening an existing file.
    override func showWindows() {
        super.showWindows()
        adoptPendingContent()
        // Deferred to here because the warning is a sheet: by the time the content
        // is adopted (in makeWindowControllers) there is no window to attach it to.
        if let content = contentPendingWarning {
            contentPendingWarning = nil
            warnIfInconsistentLineEndings(in: content)
        }
        updateStatusBar()
    }

    /// Every reload of the file on disk lands here: AppKit's silent re-read when
    /// another app changes a document that has no unsaved edits, the Revert
    /// button on its "changed by another application" sheet, and File ▸ Revert
    /// To. `read(from:ofType:)` only parks the text in `pendingContent` and
    /// nothing after the window is up ever adopted it — so the revert cleared
    /// the change count while the editor kept the old text, and the next save
    /// wrote that stale buffer over the other app's changes (#293).
    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        let caret = editor?.selectedRange().location ?? 0
        try super.revert(toContentsOf: url, ofType: typeName)
        adoptPendingContent()
        // The line-ending sheet is an open-time warning only.
        contentPendingWarning = nil
        guard let editor else { return }
        // `loadContent` recomposes at offset 0; put the caret back where it was
        // (clamped — the file may have shrunk) so a reload doesn't jump to the top.
        let offset = min(caret, (editor.rawSource as NSString).length)
        editor.setSelectedRange(NSRange(location: offset, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        refreshReadView()
        Log.info("Reloaded from disk", category: .io)
    }

    // MARK: - Watching the file on disk

    /// AppKit only hears about *coordinated* writes (other Cocoa apps going
    /// through NSFileCoordinator). Command-line tools, git, vim, VS Code and
    /// friends write without coordination, so a document kept showing stale
    /// text however often the file changed underneath it (#293). kqueue sees
    /// every write; what happens next is still AppKit's own policy — a clean
    /// document reloads, a dirty one gets AppKit's "changed by another
    /// application" sheet at its next (auto)save because the modification
    /// date no longer matches.
    private var fileWatcher: DispatchSourceFileSystemObject?

    override nonisolated var fileURL: URL? {
        // The setter is nonisolated (AppKit may set it off-main); the watch
        // lives on main. Hop only when actually off-main: a queued hop runs
        // after the caller's run-loop turn, which is too late for a
        // synchronous test — and for a `Save As` that is about to write.
        didSet {
            if Thread.isMainThread {
                MainActor.assumeIsolated { watchFile() }
            } else {
                Task { @MainActor in self.watchFile() }
            }
        }
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = nil
        guard let url = fileURL else { return }
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        // Events land on a private queue and hop to main through the run loop
        // rather than `DispatchQueue.main`: a run-loop block is drained by
        // `RunLoop.main.run(until:)`, which is what a synchronous test spins.
        nonisolated(unsafe) let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete],
            queue: DispatchQueue(label: "edmund.file-watch"))
        // The handler holds `source` (it needs `.data`); `close()` cancels
        // the source, which drops the handler and breaks that cycle.
        source.setEventHandler { @Sendable [weak self] in
            let replaced = !source.data.isDisjoint(with: [.rename, .delete])
            RunLoop.main.perform {
                MainActor.assumeIsolated { self?.fileDidChangeOnDisk(replaced: replaced) }
            }
        }
        source.setCancelHandler { @Sendable in Darwin.close(fd) }
        source.resume()
        fileWatcher = source
    }

    override func close() {
        fileWatcher?.cancel()
        fileWatcher = nil
        super.close()
    }

    private func fileDidChangeOnDisk(replaced: Bool) {
        // An atomic save (most editors) replaces the file, so the watched
        // inode is gone: re-arm on the path, which now names the new file.
        // ponytail: a delete-then-recreate loses the watch; reopening the
        // document restores it.
        if replaced { watchFile() }
        guard let url = fileURL, !isDocumentEdited,
              let onDisk = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              onDisk != fileModificationDate else { return }
        try? revert(toContentsOf: url, ofType: fileType ?? "net.daringfireball.markdown")
    }

    /// Warn (once, suppressibly) when an opened file mixed line-ending styles.
    /// The buffer has already been normalized to a single style for editing.
    private func warnIfInconsistentLineEndings(in content: String) {
        guard LineEnding.isInconsistent(in: content),
              !AppSettings.suppressInconsistentLineEndingWarning,
              let window = windowControllers.first?.window else { return }

        let alert = NSAlert()
        alert.messageText = "Inconsistent Line Endings"
        alert.informativeText = "This document mixes different line endings. "
            + "It will be saved using \(editor?.originalLineEnding.displayName ?? "LF") throughout."
        alert.addButton(withTitle: "OK")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Do not warn about inconsistent line endings"
        alert.beginSheetModal(for: window) { _ in
            if alert.suppressionButton?.state == .on {
                AppSettings.suppressInconsistentLineEndingWarning = true
            }
        }
    }

    /// Cross-file link following: scroll this document's editor to a heading
    /// once it's on screen (the content has already loaded in showWindows).
    func navigateToHeading(_ heading: String) {
        editor?.scrollToHeading(heading)
    }

    // MARK: - Rename & Move (manual — NSDocument's built-in versions
    //         are disabled without Info.plist / .app bundle)

    override func rename(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.prompt = "Rename"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let newURL = panel.url else { return }
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self.fileURL = newURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    override func move(_ sender: Any?) {
        guard let url = fileURL, let window = windowControllers.first?.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Move"
        panel.message = "Choose a new location for “\(url.lastPathComponent)”"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destDir = panel.url else { return }
            let newURL = destDir.appendingPathComponent(url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: newURL)
                self.fileURL = newURL
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    // MARK: - View Mode (edit / reading / source)

    private func icon(for mode: EditorTextView.ViewMode) -> NSImage? {
        let name: String
        switch mode {
        // Source is a raw-text view of the same editing mode as Edit, so it
        // shares the pencil icon rather than getting a distinct glyph.
        case .edit, .source: name = "pencil"
        case .reading:       name = "book"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: label(for: mode))
    }

    private func label(for mode: EditorTextView.ViewMode) -> String {
        switch mode {
        case .edit:    return "Edit"
        case .reading: return "Read"
        case .source:  return "Source"
        }
    }

    /// Shows the active mode's icon on the button and keeps the tooltip in sync.
    private func refreshViewModeButton() {
        guard let editor else { return }
        // 15pt matches the formatting glyphs beside it (FormatToolbar.symbol).
        // `book` is sized down from that: its intrinsic box is taller than
        // `pencil`'s, so at a shared point size it draws visibly bigger (measured
        // 17.5pt tall against the pencil's 15.0pt) and the button appears to
        // change size when the mode flips. These two numbers are chosen so the
        // *drawn* glyphs match, which is what the eye compares.
        let pointSize: CGFloat = editor.viewMode == .reading ? 12.9 : 15
        viewModeItem?.image = icon(for: editor.viewMode)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        // Names what the click does, in the ⌘E menu item's words, so one
        // control has one name for its action; the label below states the
        // mode. Source is a display option *of* the editing view, not a third
        // destination, so it is still "Show Editor".
        viewModeItem?.toolTip = editor.viewMode == .reading ? "Show Editor" : "Show Reader"
        // The label (shown under Icon and Text) states the current mode, the
        // way the button's icon does; the palette keeps the item's generic name.
        viewModeItem?.label = editor.viewMode == .reading ? "Read" : "Edit"
    }

    private func setViewMode(_ mode: EditorTextView.ViewMode) {
        // Capture the Read-entry anchor BEFORE the `viewMode` setter runs: the
        // setter's full recompose defers every far-from-viewport block back to
        // base-height estimates, so a capture taken after it reads collapsed
        // geometry (~17pt/line instead of styled heights) and lands the read
        // view ~100+ lines too deep — the "viewport drifts down every toggle"
        // bug. The pre-setter geometry is exactly what's on screen.
        if mode == .reading { captureReadEntryAnchor() }
        editor.viewMode = mode
        applyViewMode(mode)
        refreshViewModeButton()
    }

    /// The Edit→Read entry position, captured by `setViewMode` while the
    /// editor's on-screen geometry is still settled, consumed by
    /// `applyViewMode(.reading)`.
    private var pendingReadEntryRestore: (line: Int, fraction: Double)?

    /// Captures the topmost visible source line (+ fraction into its block)
    /// while the scroll view is the visible view; no-op when Read mode is
    /// already showing (re-render case — the webview preserves its own scroll).
    private func captureReadEntryAnchor() {
        pendingReadEntryRestore = nil
        guard !scrollView.isHidden, let offset = editor.topmostVisibleCharacterOffset() else { return }
        let visibleLine = editor.line(forOffset: offset)
        let spans = ReadModeAnchors.topLevelBlockSpans(for: editor.rawSource)
        guard !spans.isEmpty else { return }
        let span = spans.last(where: { $0.startLine <= visibleLine }) ?? spans[0]
        // Clamped: `visibleLine` can sit on a blank line *between* blocks
        // (past `span.endLine`), which would push the raw ratio above 1. Same
        // denominator as the reverse mapping in `applyViewMode` — the two must
        // stay exact inverses in line space or every round trip drifts a line.
        let lineCount = Double(span.endLine - span.startLine + 1)
        let fraction = min(1, Double(visibleLine - span.startLine) / max(1, lineCount))
        pendingReadEntryRestore = (line: span.startLine, fraction: fraction)
        lastReadAnchorOffset = offset
    }

    /// Swaps the on-screen view for the mode: Read mode shows the rendered-HTML
    /// `ReadModeWebView`; Edit and Source stay on the editor's scroll view.
    private func applyViewMode(_ mode: EditorTextView.ViewMode) {
        guard let containerView else { return }
        if mode == .reading {
            // Entry anchor: captured by `setViewMode` before the `viewMode`
            // setter's recompose could collapse far geometry to estimates; nil
            // when Read mode was already showing (re-render case — the
            // webview's own scroll-preserving reload carries the position).
            let pendingRestore = pendingReadEntryRestore
            pendingReadEntryRestore = nil

            let read = readView ?? {
                let v = ReadModeWebView()
                v.frame = scrollView.frame
                v.autoresizingMask = [.width, .height]
                // Below the floating status bar so counts stay visible.
                containerView.addSubview(v, positioned: .below, relativeTo: statusBar)
                // Route internal navigation through the editor's link resolver
                // (which resolves against this document's directory and opens via
                // NSDocumentController) instead of navigating the webview.
                v.onOpenWikiLink = { [weak self] in self?.editor.followWikiLink($0) }
                v.onOpenInternalLink = { [weak self] in self?.editor.followLinkDestination($0) }
                // A checkbox click edits the (hidden) editor, then the page is
                // patched in place rather than re-rendered: a reload flashes and
                // only approximately keeps the scroll position. Formatting edits
                // post no text-change notification, so nothing else refreshes.
                v.onToggleTask = { [weak self] line in
                    guard let self, let checked = self.editor.toggleTask(atLine: line) else { return }
                    self.readView?.setTaskChecked(line: line, checked: checked,
                                                  markdown: self.editor.rawSource)
                }
                // The ONLY place the Edit→Read view swap happens: the editor
                // stays on screen (and interactive) until the rendered
                // document is actually ready, so there's never a blank gap.
                // Set once, at creation — every later render (re-entry, live
                // re-render) reuses this same webview and callback.
                v.onLoadFinished = { [weak self] in
                    guard let self, self.editor.viewMode == .reading, let read = self.readView else { return }
                    read.isHidden = false
                    self.scrollView.isHidden = true
                    self.editor.window?.makeFirstResponder(read)
                }
                readView = v
                return v
            }()

            if let pendingRestore {
                read.setPendingScrollRestore(line: pendingRestore.line, fraction: pendingRestore.fraction)
            }
            // Cache hit inside the webview (HTML unchanged) fires
            // `onLoadFinished` synchronously here → instant swap, no reload.
            read.render(markdown: editor.rawSource,
                        theme: editor.theme,
                        callouts: mergedCallouts,
                        baseURL: documentDirectory,
                        options: renderOptions)
        } else {
            if let read = readView, !read.isHidden {
                // While the webview is still alive, capture where the user
                // actually scrolled to in Read mode and map it back onto the
                // editor's source lines. The view swap waits for this
                // completion: swapping immediately showed the editor at its
                // stale position for a few frames before the scroll landed —
                // a visible up-then-down hop. Positioning while hidden and
                // swapping after keeps the hop off-screen; the JS round trip
                // is a few ms, and the completion fires exactly once even on
                // error, so the swap can't be dropped.
                read.readScrollPosition { [weak self] pos in
                    // Still in edit/source when this lands? A rapid toggle
                    // back into Read mode means the editor is hidden again —
                    // don't scroll it (or swap).
                    guard let self, self.editor.viewMode != .reading else { return }
                    var targetOffset: Int?
                    if let pos {
                        let spans = ReadModeAnchors.topLevelBlockSpans(for: self.editor.rawSource)
                        let span = spans.first(where: { $0.startLine == pos.line })
                            ?? spans.last(where: { $0.startLine <= pos.line })
                        if let span {
                            // Exact inverse of the entry mapping above (same
                            // `lineCount` denominator): an untouched round trip
                            // returns to the same source line instead of
                            // drifting. Clamped — fraction ≈ 1 would otherwise
                            // land on the line after the block.
                            let lineCount = Double(span.endLine - span.startLine + 1)
                            let targetLine = min(span.endLine,
                                span.startLine + Int((pos.fraction * lineCount).rounded()))
                            targetOffset = self.editor.offset(forLine: targetLine)
                        }
                    }
                    if let offset = targetOffset ?? self.lastReadAnchorOffset {
                        self.editor.scrollCharacterToTop(offset)
                    }
                    self.swapToEditor()
                }
            } else {
                swapToEditor()
            }
        }
        // The bar hides in Reading mode (a read-only editor has no formatting
        // commands) and returns on the way back — refresh on every mode change.
        refreshFormatBar()
    }

    /// Reveals the editor's scroll view (hiding any read view) and repairs
    /// TextKit 2 state: nothing else forces viewport layout/redraw when a
    /// hidden scroll view is unhidden — a click used to supply the missing
    /// event, leaving the editor blank until one arrived.
    private func swapToEditor() {
        // The inspector inspects the read view; leaving it up over the editor
        // would show a document that is no longer on screen.
        readView?.hideWebInspector(nil)
        readView?.isHidden = true
        scrollView.isHidden = false
        editor.window?.makeFirstResponder(editor)
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        editor.needsDisplay = true
    }

    /// Re-renders an open Read view from the editor's current source + theme.
    /// No-op unless Read mode is the active, visible view — so settings/edit
    /// broadcasts stay cheap when the user is in Edit or Source mode.
    func refreshReadView() {
        guard let read = readView, !read.isHidden, editor?.viewMode == .reading else { return }
        read.render(markdown: editor.rawSource,
                    theme: editor.theme,
                    callouts: mergedCallouts,
                    baseURL: documentDirectory,
                    options: renderOptions)
    }

    /// The opened file's directory, used to resolve relative image paths for
    /// inlining (nil for an unsaved document).
    private var documentDirectory: URL? {
        fileURL?.deletingLastPathComponent()
    }

    /// Built-in callout styles merged with the editor's user overrides, so Read
    /// mode and the PDF match exactly what the editor draws.
    private var mergedCallouts: [String: CalloutStyle] {
        var m = Callout.defaultStyles
        for (k, v) in editor.calloutStyleOverrides { m[k] = v }
        return m
    }

    /// Read-mode/export render options derived from user settings. Reuses the
    /// editor's own `maxContentWidthPoints` (already the cm setting converted via
    /// the window's screen PPI) so Read mode's column matches Edit mode's.
    private var renderOptions: ReadRenderOptions {
        ReadRenderOptions(preserveBlankLines: AppSettings.renderBlankLinesAsBreaks,
                         allowRemoteImages: !AppSettings.blockExternalImages,
                         maxContentWidthPoints: Double(editor.maxContentWidthPoints),
                         features: AppSettings.markdownFeatures,
                         strictLineBreaks: AppSettings.strictLineBreaks)
    }

    // MARK: - Export / Print

    /// Runs the standard save flow (save panel for an untitled document) so an
    /// image attachment has a document directory to land in, then reports
    /// whether the document ended up saved. Called via the editor's
    /// `requestSaveForAttachment` hook.
    func saveForAttachment(then completion: @escaping (Bool) -> Void) {
        guard let window = windowControllers.first?.window else { completion(false); return }
        let panel = NSSavePanel()
        _ = prepareSavePanel(panel)   // seeds the "Untitled.md" name like a real save
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { completion(false); return }
            self.save(to: url, ofType: "net.daringfireball.markdown",
                      for: .saveOperation) { error in
                if let error {
                    NSAlert(error: error).runModal()
                    completion(false)
                } else {
                    completion(true)
                }
            }
        }
    }

    @objc func exportToPDF(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        MarkdownPrinter.exportPDF(markdown: editor.rawSource,
                                  theme: editor.theme,
                                  callouts: mergedCallouts,
                                  baseURL: documentDirectory,
                                  options: renderOptions,
                                  suggestedName: name.isEmpty ? "Untitled" : name,
                                  window: windowControllers.first?.window)
    }

    /// File ▸ Export To ▸ HTML…: the self-contained themed page Read mode shows
    /// (images and math inlined), written to a single .html file.
    @objc func exportToHTML(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        DocumentExporter.exportHTML(markdown: editor.rawSource,
                                    theme: editor.theme,
                                    callouts: mergedCallouts,
                                    baseURL: documentDirectory,
                                    options: renderOptions,
                                    suggestedName: name.isEmpty ? "Untitled" : name,
                                    window: windowControllers.first?.window)
    }

    /// File ▸ Export To ▸ Markdown with Embedded Images…: a share copy with
    /// local images inlined as data URIs, for handing someone a single .md file.
    @objc func exportSelfContainedMarkdown(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        DocumentExporter.exportSelfContainedMarkdown(markdown: editor.rawSource,
                                                     baseURL: documentDirectory,
                                                     features: AppSettings.markdownFeatures,
                                                     suggestedName: name.isEmpty ? "Untitled" : name,
                                                     window: windowControllers.first?.window)
    }

    /// File ▸ Export To ▸ Rich Text Format…: RTF, or RTFD when the document has pictures.
    @objc func exportToRichText(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        DocumentExporter.exportRichText(markdown: editor.rawSource,
                                        theme: editor.theme,
                                        callouts: mergedCallouts,
                                        baseURL: documentDirectory,
                                        options: renderOptions,
                                        suggestedName: name.isEmpty ? "Untitled" : name,
                                        window: windowControllers.first?.window)
    }

    /// File ▸ Export To ▸ Plain Text…: the words without the Markdown syntax.
    @objc func exportToPlainText(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        DocumentExporter.exportPlainText(markdown: editor.rawSource,
                                         features: AppSettings.markdownFeatures,
                                         suggestedName: name.isEmpty ? "Untitled" : name,
                                         window: windowControllers.first?.window)
    }

    // MARK: - Copy As

    /// Edit ▸ Copy As ▸ Plain Text: the selection without its Markdown syntax.
    @objc func copyAsPlainText(_ sender: Any?) {
        DocumentExporter.copyPlainText(markdown: selectedMarkdown, features: AppSettings.markdownFeatures)
    }

    /// Edit ▸ Copy As ▸ Rich Text: the selection formatted, for pasting into
    /// Mail, Pages, Word or a browser.
    @objc func copyAsRichText(_ sender: Any?) {
        do {
            try DocumentExporter.copyRichText(markdown: selectedMarkdown, theme: editor.theme,
                                              callouts: mergedCallouts, baseURL: documentDirectory,
                                              options: renderOptions)
        } catch {
            Log.error("Copy as Rich Text failed: \(error.localizedDescription)", category: .io)
            NSSound.beep()
        }
    }

    /// The editor's selection as Markdown. Storage is the raw source, so the
    /// selected range indexes `rawSource` directly.
    private var selectedMarkdown: String {
        (editor.rawSource as NSString).substring(with: editor.selectedRange())
    }

    @objc override func printDocument(_ sender: Any?) {
        let name = (displayName as NSString).deletingPathExtension
        MarkdownPrinter.print(markdown: editor.rawSource,
                              theme: editor.theme,
                              callouts: mergedCallouts,
                              baseURL: documentDirectory,
                              options: renderOptions,
                              suggestedName: name.isEmpty ? "Untitled" : name,
                              window: windowControllers.first?.window)
    }

    /// File ▸ Page Setup…, as a sheet on this window. It edits the *shared*
    /// print info, not NSDocument's per-document `printInfo`: printing starts
    /// from a copy of the shared one (MarkdownPrinter.makePrintInfo), so that
    /// is the only layout that reaches the printer.
    @objc override func runPageLayout(_ sender: Any?) {
        guard let window = windowControllers.first?.window else { return }
        NSPageLayout().beginSheet(using: .shared, on: window) { _ in }
    }

    /// The editing-side view: Source when source mode is on, otherwise Edit.
    /// Read is the other half of the toggle.
    private var editingMode: EditorTextView.ViewMode {
        AppSettings.sourceMode ? .source : .edit
    }

    /// View ▸ Show Source in Editor.
    /// Persists the setting and, if we're in the editing view, swaps it to
    /// the new editing mode right away.
    @objc func toggleSourceMode(_ sender: Any?) {
        AppSettings.sourceMode.toggle()
        applySourceMode()
    }

    /// Swaps the editing view to whatever the source-mode setting now says.
    /// Called after `toggleSourceMode` flips it.
    func applySourceMode() {
        if editor.viewMode != .reading { setViewMode(editingMode) }
    }

    /// The View menu's Show/Hide Toolbar item. Goes through the setting rather
    /// than AppKit's own `toggleToolbarShown(_:)` so the menu and the
    /// Settings ▸ Edit ▸ Display checkbox can't drift apart.
    @objc func toggleToolbarShown(_ sender: Any?) {
        AppSettings.showToolbar.toggle()
        AppSettings.applyEditSettingsToOpenDocuments()
    }

    /// Shows or hides this window's toolbar per the setting.
    func applyToolbarVisibility() {
        let window = windowControllers.first?.window
        window?.toolbar?.isVisible = AppSettings.showToolbar
    }

    /// View ▸ Always Show Toolbar in Full Screen, unchecked: in full screen,
    /// slide the toolbar away with the menu bar until the pointer reaches the
    /// top of the screen. The menu item is the inverse of `autoHideToolbar`.
    @objc func toggleAutoHideToolbar(_ sender: Any?) {
        AppSettings.autoHideToolbar.toggle()
        for case let document as Document in NSDocumentController.shared.documents {
            document.applyToolbarAutoHide()
        }
    }

    /// Applies the setting to a window that is *already* full screen.
    ///
    /// The presentation-option route does not work here, which is worth knowing
    /// before anyone tries it again: full screen is window-managed, so the
    /// window's own options — fixed when it entered, from the delegate method
    /// below — outrank the app's. Measured live while full screen with
    /// auto-hide on: `currentSystemPresentationOptions` reads
    /// `fullScreen|autoHideToolbar` (3072), and assigning `NSApp
    /// .presentationOptions` a set without `.autoHideToolbar` leaves it at
    /// 3072 — the flag is simply re-imposed.
    ///
    /// So show or hide the toolbar outright instead. That is the visible half
    /// of the setting; the reveal-on-pointer behaviour itself is whatever the
    /// window picked up on entry, and follows on the next one.
    func applyToolbarAutoHide() {
        guard let window = windowControllers.first?.window,
              window.styleMask.contains(.fullScreen) else { return }
        window.toolbar?.isVisible = AppSettings.showToolbar && !AppSettings.autoHideToolbar
    }

    // MARK: - Format bar (top of the editor, above the find bar)

    /// View ▸ Show Format Bar. Goes through the setting rather than a direct
    /// `isHidden` flip so the menu item and any future Settings ▸ Edit checkbox
    /// can't drift apart — the same idiom as `toggleToolbarShown`.
    @objc func toggleFormatBar(_ sender: Any?) {
        AppSettings.showFormatBar.toggle()
        AppSettings.applyEditSettingsToOpenDocuments()
    }

    /// View ▸ Show/Hide Status Bar and Always Show Status Bar. App-wide, like the
    /// toolbar pair: saving posts `StatusBarPrefs.didChangeNotification`, which
    /// every window's bar observes.
    @objc func toggleStatusBarShown(_ sender: Any?) {
        var prefs = StatusBarPrefs.load()
        prefs.isShown.toggle()
        prefs.save()
    }

    @objc func toggleAlwaysShowStatusBar(_ sender: Any?) {
        var prefs = StatusBarPrefs.load()
        prefs.autoHide.toggle()
        prefs.save()
    }

    /// Applies the format bar's visibility rule (hidden in Reading mode or when
    /// the Show Format Bar setting is off — the latter also removes any chance
    /// of a click reaching a read-only editor), refreshes its controls' enabled
    /// state, and re-stacks the top bars. Called on show, on view-mode change
    /// and from `AppSettings.applyEditSettingsToOpenDocuments()`.
    func refreshFormatBar() {
        formatBar.isHidden = !AppSettings.showFormatBar || editor.viewMode == .reading
        formatBar.refreshEnabledState(editor: editor)
        refreshFormatBarState()
        layoutTopBars()
    }

    /// Just the lit/unlit state of the bar's buttons. Split out from
    /// `refreshFormatBar` because this one runs on every caret move and every
    /// keystroke, where re-deciding visibility and re-stacking the bars would be
    /// wasted work.
    private func refreshFormatBarState() {
        guard let formatBar, !formatBar.isHidden, let editor else { return }
        formatBar.refreshActiveState(editor: editor)
    }

    /// Stacks the visible top bars under the toolbar and hands the editor their
    /// combined height. The sole writer of `additionalTopInset` — the find bar
    /// used to write it directly, and a second writer (this bar) would clobber
    /// whichever ran last. Order in the array is the on-screen order (top
    /// first): format bar above find bar.
    func layoutTopBars() {
        var y = containerView.bounds.height
        for bar in [formatBar!, findController.barView] where !bar.isHidden {
            let h = bar.preferredHeight
            y -= h
            bar.frame = NSRect(x: 0, y: y, width: containerView.bounds.width, height: h)
        }
        editor.additionalTopInset = containerView.bounds.height - y
    }

    /// File ▸ Duplicate (⇧⌘S). With Auto Save off there are no versions to
    /// duplicate from, so the same item is the classic Save As…, as in TextEdit.
    @objc func duplicateOrSaveAs(_ sender: Any?) {
        if Self.autosavesInPlace { duplicate(sender) } else { saveAs(sender) }
    }

    /// Keeps the View-menu "Show Source in Editor" checkmark and the
    /// Show/Hide Toolbar title in sync with the settings.
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleSourceMode(_:)) {
            item.state = AppSettings.sourceMode ? .on : .off
        }
        if item.action == #selector(toggleToolbarShown(_:)) {
            item.title = AppSettings.showToolbar ? "Hide Toolbar" : "Show Toolbar"
        }
        if item.action == #selector(toggleViewMode(_:)) {
            // Names the destination, like Safari's Show Reader. Source is a
            // display option of the editor, so it is still "Show Editor".
            item.title = editor?.viewMode == .reading ? "Show Editor" : "Show Reader"
        }
        if item.action == #selector(toggleFormatBar(_:)) {
            // Title, not a checkmark — the same idiom as Hide Toolbar above.
            item.title = AppSettings.showFormatBar ? "Hide Format Bar" : "Show Format Bar"
        }
        if item.action == #selector(save(_:)) {
            // Pages' idiom: the ellipsis only while untitled, when Save opens
            // the save panel; a document already on disk just saves.
            item.title = fileURL == nil ? "Save\u{2026}" : "Save"
        }
        if item.action == #selector(duplicateOrSaveAs(_:)) {
            item.title = Self.autosavesInPlace ? "Duplicate" : "Save As\u{2026}"
        }
        if item.action == #selector(saveAs(_:)), item.isAlternate {
            // Without Auto Save the item above already is Save As….
            item.isHidden = !Self.autosavesInPlace
        }
        if item.action == #selector(toggleStatusBarShown(_:)) {
            item.title = StatusBarPrefs.load().isShown ? "Hide Status Bar" : "Show Status Bar"
        }
        if item.action == #selector(toggleAlwaysShowStatusBar(_:)) {
            let prefs = StatusBarPrefs.load()
            item.state = prefs.autoHide ? .off : .on
            // Nothing to pin with the bar switched off entirely.
            return prefs.isShown
        }
        if item.action == #selector(toggleAutoHideToolbar(_:)) {
            item.state = AppSettings.autoHideToolbar ? .off : .on
            // Nothing to pin with the toolbar switched off entirely.
            return AppSettings.showToolbar
        }
        if item.action == #selector(copyAsPlainText(_:)) || item.action == #selector(copyAsRichText(_:)) {
            // Greyed out with nothing selected — and outside the editor: in
            // Read mode the web view has focus, and its own Copy is already rich.
            return editor.window?.firstResponder === editor && editor.selectedRange().length > 0
        }
        return super.validateMenuItem(item)
    }

    /// Toggle the editing view ↔ Read (the View-menu ⌘E item and the toolbar
    /// button). With source mode on the editing view is Source, so this flips
    /// Source ↔ Read; otherwise Edit ↔ Read.
    @objc func toggleViewMode(_ sender: Any?) {
        setViewMode(toggledViewMode)
    }

    /// Where `toggleViewMode` would land — also what the button's tooltip names,
    /// so the two can't say different things.
    private var toggledViewMode: EditorTextView.ViewMode {
        editor?.viewMode == .reading ? editingMode : .reading
    }

    /// "Inspect Reader" (⌥⌘I) — a semi-toggle, so one shortcut always gets you
    /// to "reading with the inspector open": from Edit (or from Read with the
    /// inspector closed) it lands in Read mode with the inspector up; pressed
    /// again in that state it closes the inspector and leaves you in Read mode.
    @objc func toggleReaderInspector(_ sender: Any?) {
        if editor.viewMode == .reading, readView?.isWebInspectorVisible == true {
            readView?.hideWebInspector(nil)
            return
        }
        if editor.viewMode != .reading { setViewMode(.reading) }
        // The read view is created (and its HTML rendered) by `setViewMode`, so
        // by here `readView` exists even on the first entry into Read mode.
        readView?.showWebInspector(nil)
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        // The buffer is always LF; restore the file's original line ending on
        // write so opening, then saving, doesn't silently rewrite every line.
        //
        // A hard-wrapped file is held joined for editing, so it has to be
        // re-wrapped on the way out. Only files that arrived wrapped are
        // wrapped — `wasHardWrapped` says the join on open actually did
        // something — so saving never imposes a reflow on a document that
        // wasn't written that way. The buffer itself is untouched: no caret
        // move, no undo entry, no dirty flag.
        var normalized = editor?.rawSource ?? ""
        if let editor, editor.wasHardWrapped, AppSettings.hardWrapLongLines {
            normalized = HardWrap.wrap(normalized, features: editor.markdownFeatures,
                                       column: editor.hardWrapColumn)
        }
        let ending = editor?.originalLineEnding ?? .lf
        let text = ending == .lf
            ? normalized
            : normalized.replacingOccurrences(of: "\n", with: ending.string)
        guard let data = text.data(using: .utf8) else {
            Log.error("Save failed: could not encode \(text.count) chars as UTF-8", category: .io)
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "The document couldn’t be saved as UTF-8 text."])
        }
        Log.info("Saving \(data.count) bytes (\(ending.displayName))", category: .io)
        return data
    }
}

// MARK: - Toolbar (view-mode toggle)

extension Document: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        FormatToolbar.defaultIdentifiers(viewMode: Self.viewModeItemID)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        FormatToolbar.allowedIdentifiers(viewMode: Self.viewModeItemID)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        // Everything but the view-mode toggle belongs to FormatToolbar.
        guard itemIdentifier == Self.viewModeItemID else {
            return formatToolbar.makeItem(itemIdentifier)
        }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.paletteLabel = "View Mode"
        item.visibilityPriority = .high
        viewModeItem = item
        // A plain bordered item, like every formatting item: AppKit sizes it,
        // lays out its label and highlights it. No right-click menu — both of
        // its entries (the other mode, Show Source in Editor) are in View, and
        // a toolbar's secondary click belongs to AppKit's own toolbar menu.
        item.isBordered = true
        item.target = self
        item.action = #selector(toggleViewMode(_:))
        refreshViewModeButton()
        return item
    }
}

// MARK: - Document Window Controller

/// The document window's controller. Exists only to answer the full-screen
/// presentation query — `.autoHideToolbar` can only be requested from the
/// window's delegate, which `makeWindowControllers` wires to this object by
/// hand (see the note there).
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
    -> NSApplication.PresentationOptions {
        guard AppSettings.autoHideToolbar else { return proposedOptions }
        return proposedOptions.union([.autoHideToolbar])
    }
}
