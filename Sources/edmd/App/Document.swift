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
    private var viewModeButton: NSButton?
    private static let viewModeItemID = NSToolbarItem.Identifier("viewMode")

    /// Content loaded from disk before the editor window exists.
    /// `nonisolated(unsafe)` because `read(from:ofType:)` may be called
    /// off the main actor, but the value is only consumed on main via `showWindows`.
    nonisolated(unsafe) var pendingContent: String?

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

    override func makeWindowControllers() {
        let windowWidth: CGFloat = 400
        let windowHeight: CGFloat = 500

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        // Don't persist/restore document windows: macOS state restoration
        // otherwise reopens the last-edited file on the next launch, so a fresh
        // start (or File ▸ New) shows that document instead of a blank Untitled.
        window.isRestorable = AppSettings.reopenWindows
        window.center()
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
        editor.textContainerInset = NSSize(width: 24, height: 18)
        editor.typewriterModeEnabled = AppDelegate.typewriterModeEnabled()
        editor.document = self

        // Toolbar holds the right-aligned view-mode toggle (and gives the
        // titlebar extra height for roomy traffic lights). Set it only after
        // `editor` exists — assigning the toolbar synchronously vends its items.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        let statusBarHeight: CGFloat = 22
        let contentBounds = window.contentView!.bounds

        // The text view fills the whole window; the status bar floats over its
        // bottom edge, revealed on hover.
        let scrollView = NSScrollView(frame: contentBounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = editor

        // Floating status bar: hidden by default, fades in when the pointer
        // enters its strip. Counts on the left, line ending on the right.
        statusBar = StatusBarView(frame: NSRect(
            x: 0, y: 0, width: contentBounds.width, height: statusBarHeight
        ))
        statusBar.autoresizingMask = [.width]

        let container = NSView(frame: contentBounds)
        container.autoresizesSubviews = true
        container.addSubview(scrollView)
        container.addSubview(statusBar)   // overlay, on top of the text

        window.contentView = container

        NotificationCenter.default.addObserver(
            self, selector: #selector(editorDidChange(_:)),
            name: NSText.didChangeNotification, object: editor
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(editorSelectionDidChange(_:)),
            name: NSTextView.didChangeSelectionNotification, object: editor
        )

        let wc = NSWindowController(window: window)
        addWindowController(wc)
        window.makeFirstResponder(editor)
        updateStatusBar()
    }

    @objc private func editorDidChange(_ notification: Notification) {
        updateStatusBar()
    }

    @objc private func editorSelectionDidChange(_ notification: Notification) {
        updateStatusBar()
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
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read file as UTF-8"])
        }
        pendingContent = contents
    }

    /// Called after makeWindowControllers when opening an existing file.
    override func showWindows() {
        super.showWindows()
        if let content = pendingContent {
            editor?.loadContent(content)
            pendingContent = nil
            warnIfInconsistentLineEndings(in: content)
        }
        updateStatusBar()
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
        panel.message = "Choose a new location for \"\(url.lastPathComponent)\""
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
        case .edit:    name = "pencil"
        case .reading: name = "book"
        case .source:  name = "chevron.left.forwardslash.chevron.right"
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

    /// Shows the active mode's icon on the button (with the menu chevrons), and
    /// keeps the tooltip in sync.
    private func refreshViewModeButton() {
        guard let editor else { return }
        viewModeButton?.image = viewModeButtonImage(for: editor.viewMode)
        viewModeButton?.toolTip = "View mode: \(label(for: editor.viewMode))"
    }

    private func setViewMode(_ mode: EditorTextView.ViewMode) {
        editor.viewMode = mode
        refreshViewModeButton()
    }

    @objc private func selectEditMode(_ sender: Any?)    { setViewMode(.edit) }
    @objc private func selectReadingMode(_ sender: Any?) { setViewMode(.reading) }
    @objc private func selectSourceMode(_ sender: Any?)  { setViewMode(.source) }

    /// Drops the mode menu down from the chevron button.
    @objc private func showViewModeMenu(_ sender: NSButton) {
        let menu = viewModeMenu()
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// A checklist menu: each mode with its icon, the current one checked.
    private func viewModeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false   // actions always fire on selection
        let entries: [(EditorTextView.ViewMode, Selector)] = [
            (.edit,    #selector(selectEditMode(_:))),
            (.reading, #selector(selectReadingMode(_:))),
            (.source,  #selector(selectSourceMode(_:))),
        ]
        for (mode, action) in entries {
            let item = NSMenuItem(title: label(for: mode), action: action, keyEquivalent: "")
            item.target = self
            item.image = icon(for: mode)
            item.state = (editor?.viewMode == mode) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Writing

    override func data(ofType typeName: String) throws -> Data {
        // The buffer is always LF; restore the file's original line ending on
        // write so opening, then saving, doesn't silently rewrite every line.
        let normalized = editor?.rawSource ?? ""
        let ending = editor?.originalLineEnding ?? .lf
        let text = ending == .lf
            ? normalized
            : normalized.replacingOccurrences(of: "\n", with: ending.string)
        guard let data = text.data(using: .utf8) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not encode text as UTF-8"])
        }
        return data
    }
}

// MARK: - Toolbar (view-mode toggle)

extension Document: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.viewModeItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.viewModeItemID]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard itemIdentifier == Self.viewModeItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = "View Mode"
        item.visibilityPriority = .high

        // A single button — "<active-mode icon> ⌄⌃" — that drops the menu.
        let button = NSButton(image: viewModeButtonImage(for: editor.viewMode),
                              target: self, action: #selector(showViewModeMenu(_:)))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        viewModeButton = button
        item.view = button
        refreshViewModeButton()
        return item
    }

    /// Composes the toolbar button face: the active mode's icon at full toolbar
    /// size with a small `chevron.up.chevron.down` to its right (menu affordance).
    private func viewModeButtonImage(for mode: EditorTextView.ViewMode) -> NSImage {
        // Proportions match Finder's view-mode control: a prominent mode icon
        // with a smaller `chevron.up.chevron.down` tucked close to its right.
        let modeIcon = (icon(for: mode)?.withSymbolConfiguration(
            .init(pointSize: 16, weight: .regular))) ?? NSImage()
        let chevrons = (NSImage(systemSymbolName: "chevron.up.chevron.down",
                                accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))) ?? NSImage()
        let gap: CGFloat = 2
        let size = NSSize(width: modeIcon.size.width + gap + chevrons.size.width,
                          height: max(modeIcon.size.height, chevrons.size.height))
        let image = NSImage(size: size)
        image.lockFocus()
        modeIcon.draw(at: NSPoint(x: 0, y: (size.height - modeIcon.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
        chevrons.draw(at: NSPoint(x: modeIcon.size.width + gap,
                                  y: (size.height - chevrons.size.height) / 2),
                      from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        image.isTemplate = true   // tint with the toolbar's light/dark color
        return image
    }
}
