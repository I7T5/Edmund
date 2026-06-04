import AppKit
import UniformTypeIdentifiers
import MarkdownEditorCore

/// NSDocument subclass that provides standard macOS document lifecycle:
/// file open/save, dirty-dot indicator, click-to-rename in the titlebar,
/// recent documents, and more — all for free.
///
/// The actual editing is delegated entirely to `EditorTextView`.
class Document: NSDocument {

    var editor: EditorTextView!
    private var statusBar: StatusBarView!

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
        window.center()
        window.minSize = NSSize(width: 320, height: 400)
        window.backgroundColor = NSColor.textBackgroundColor

        // Empty toolbar gives the titlebar extra height (roomy traffic lights).
        let toolbar = NSToolbar(identifier: "MainToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .line

        // Build the text system chain:
        //   NSTextStorage → NSLayoutManager → NSTextContainer → NSTextView
        let textStorage = EditorTextStorage()
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let contentSize = NSSize(width: windowWidth, height: CGFloat.greatestFiniteMagnitude)
        let textContainer = NSTextContainer(size: contentSize)
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        editor = EditorTextView(
            frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            textContainer: textContainer
        )
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 18)
        editor.document = self

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
        }
        updateStatusBar()
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

// MARK: - Status Bar View

/// Floating status bar. Hidden by default and revealed when the pointer enters
/// its strip (or pinned visible via the context menu). It draws everything
/// itself — a vertical gradient from the editor background fading to transparent,
/// the enabled document-count fields on the left, and the line ending on the
/// right — so there are no subviews to truncate the text.
private final class StatusBarView: NSView {

    static let labelFont = NSFont.systemFont(ofSize: 11)

    private var prefs = StatusBarPrefs.load()

    // Latest metrics pushed from the document.
    private var words = 0
    private var characters = 0
    private var location = 0
    private var lineNumber = 1
    private var lineEnding = "LF"

    private var trackingArea: NSTrackingArea?
    private var isHovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        alphaValue = prefs.autoHide ? 0 : 1
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Data

    func setMetrics(words: Int, characters: Int, location: Int, line: Int, lineEnding: String) {
        self.words = words
        self.characters = characters
        self.location = location
        self.lineNumber = line
        self.lineEnding = lineEnding
        needsDisplay = true
    }

    // MARK: - Visibility

    private var shouldBeVisible: Bool { !prefs.autoHide || isHovering }

    private func refreshVisibility(animated: Bool) {
        let target: CGFloat = shouldBeVisible ? 1 : 0
        guard abs(alphaValue - target) > 0.001 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.3
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    // MARK: - Hover Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeInActiveApp],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        refreshVisibility(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        refreshVisibility(animated: true)
    }

    /// When the bar is hidden, let clicks fall through to the text view beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if !shouldBeVisible && alphaValue < 0.01 { return nil }
        return super.hitTest(point)
    }

    // MARK: - Context Menu (double- or right-click)

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            NSMenu.popUpContextMenu(buildMenu(), with: event, for: self)
        } else {
            super.mouseDown(with: event)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let autoHide = NSMenuItem(title: "Auto-hide",
                                  action: #selector(toggleAutoHide), keyEquivalent: "")
        autoHide.target = self
        autoHide.state = prefs.autoHide ? .on : .off
        menu.addItem(autoHide)

        menu.addItem(.separator())
        let header = NSMenuItem(title: "Show Fields", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let fields: [(title: String, key: String, on: Bool)] = [
            ("Words", "words", prefs.showWords),
            ("Characters", "characters", prefs.showCharacters),
            ("Location", "location", prefs.showLocation),
            ("Line", "line", prefs.showLine),
            ("Line Ending", "lineEnding", prefs.showLineEnding),
        ]
        for field in fields {
            let item = NSMenuItem(title: field.title,
                                  action: #selector(toggleField(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = field.key
            item.state = field.on ? .on : .off
            item.indentationLevel = 1
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleAutoHide() {
        prefs.autoHide.toggle()
        prefs.save()
        refreshVisibility(animated: true)
    }

    @objc private func toggleField(_ sender: NSMenuItem) {
        switch sender.representedObject as? String {
        case "words":      prefs.showWords.toggle()
        case "characters": prefs.showCharacters.toggle()
        case "location":   prefs.showLocation.toggle()
        case "line":       prefs.showLine.toggle()
        case "lineEnding": prefs.showLineEnding.toggle()
        default: return
        }
        prefs.save()
        needsDisplay = true
    }

    // MARK: - Drawing

    private var labelAttrs: [NSAttributedString.Key: Any] {
        [.font: Self.labelFont, .foregroundColor: NSColor.secondaryLabelColor]
    }
    private var valueAttrs: [NSAttributedString.Key: Any] {
        [.font: Self.labelFont, .foregroundColor: NSColor.labelColor]
    }

    override func draw(_ dirtyRect: NSRect) {
        // Vertical gradient: the editor background, fully opaque at the bottom and
        // softening only slightly toward the top so the bar reads clearly even
        // when overlaid on text. textBackgroundColor is semantic (light/dark).
        let base = NSColor.textBackgroundColor
        if let gradient = NSGradient(starting: base, ending: base.withAlphaComponent(0.85)) {
            gradient.draw(in: bounds, angle: 90)   // 90° = bottom → top
        }

        let hMargin: CGFloat = 12

        // Left: enabled count fields ("Label: value", label dimmed, value bold-ish).
        let info = NSMutableAttributedString()
        func field(_ name: String, _ value: String) {
            if info.length > 0 {
                info.append(NSAttributedString(string: "   ", attributes: labelAttrs))
            }
            info.append(NSAttributedString(string: "\(name): ", attributes: labelAttrs))
            info.append(NSAttributedString(string: value, attributes: valueAttrs))
        }
        if prefs.showWords      { field("Words", "\(words)") }
        if prefs.showCharacters { field("Characters", "\(characters)") }
        if prefs.showLocation   { field("Location", "\(location)") }
        if prefs.showLine       { field("Line", "\(lineNumber)") }

        if info.length > 0 {
            let size = info.size()
            info.draw(at: NSPoint(x: hMargin, y: (bounds.height - size.height) / 2))
        }

        // Right: line ending, preceded by a short vertical divider.
        if prefs.showLineEnding {
            let value = NSAttributedString(string: lineEnding, attributes: valueAttrs)
            let size = value.size()
            let x = bounds.maxX - hMargin - size.width
            value.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))

            if info.length > 0 {
                NSColor.separatorColor.setStroke()
                let dx = round(x - 12) + 0.5
                let divider = NSBezierPath()
                divider.move(to: NSPoint(x: dx, y: 5))
                divider.line(to: NSPoint(x: dx, y: bounds.height - 5))
                divider.lineWidth = 1
                divider.stroke()
            }
        }
    }
}
