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

        let scrollView = NSScrollView(frame: NSRect(
            x: 0, y: statusBarHeight,
            width: contentBounds.width,
            height: contentBounds.height - statusBarHeight
        ))
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.documentView = editor

        // CotEditor-style status bar at the bottom: a slightly gray strip with a
        // hairline top border, document counts on the left, line ending on the right.
        statusBar = StatusBarView(frame: NSRect(
            x: 0, y: 0, width: contentBounds.width, height: statusBarHeight
        ))
        statusBar.autoresizingMask = [.width]

        let container = NSView(frame: contentBounds)
        container.autoresizesSubviews = true
        container.addSubview(scrollView)
        container.addSubview(statusBar)

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
        let lineCount = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
        let charCount = text.count

        // Cursor position: 0-based character location and 1-based line number.
        let cursorOffset = editor.selectedRange().location
        let location = min(cursorOffset, nsText.length)
        let upToCursor = nsText.substring(to: location)
        let line = upToCursor.isEmpty ? 1 : upToCursor.components(separatedBy: "\n").count

        // CotEditor renders the field labels dimmed and the values prominent.
        let info = NSMutableAttributedString()
        info.append(statusField("Lines", "\(lineCount)"))
        info.append(statusField("Characters", "\(charCount)", leadingGap: true))
        info.append(statusField("Location", "\(location)", leadingGap: true))
        info.append(statusField("Line", "\(line)", leadingGap: true))
        statusBar.infoLabel.attributedStringValue = info

        // The buffer is always LF; show the file's remembered original ending.
        // Encoding is omitted — markdown is effectively always UTF-8, so the
        // indicator would never change.
        statusBar.metaLabel.attributedStringValue = NSAttributedString(
            string: editor.originalLineEnding.displayName,
            attributes: [.font: StatusBarView.labelFont, .foregroundColor: NSColor.labelColor]
        )

        // Manual frame layout: re-run layout() so the right label re-sizes to its
        // new content width (intrinsic-size invalidation alone won't trigger it).
        statusBar.needsLayout = true
    }

    /// Builds a "Label: value" fragment with the label dimmed and the value prominent.
    private func statusField(_ name: String, _ value: String,
                             leadingGap: Bool = false) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let prefix = leadingGap ? "   \(name): " : "\(name): "
        s.append(NSAttributedString(string: prefix, attributes: [
            .font: StatusBarView.labelFont, .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        s.append(NSAttributedString(string: value, attributes: [
            .font: StatusBarView.labelFont, .foregroundColor: NSColor.labelColor,
        ]))
        return s
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

/// CotEditor-style status bar: a slightly gray strip with a hairline top
/// border, left-aligned document counts, and right-aligned file metadata.
private final class StatusBarView: NSView {

    static let labelFont = NSFont.systemFont(ofSize: 11)

    let infoLabel = NSTextField(labelWithString: "")
    let metaLabel = NSTextField(labelWithString: "")

    /// X position of the vertical separator drawn between the info block and the
    /// line-ending value. Set in `layout()`, consumed in `draw()`.
    private var separatorX: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for label in [infoLabel, metaLabel] {
            label.font = StatusBarView.labelFont
            label.textColor = .secondaryLabelColor
            label.isBezeled = false
            label.drawsBackground = false
            label.isEditable = false
            label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        infoLabel.alignment = .left
        metaLabel.alignment = .right
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        // Adaptive system window background (light gray / dark), distinct from
        // the white text area above.
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        NSColor.separatorColor.setStroke()

        // Hairline separating the status bar from the text area above it.
        let top = NSBezierPath()
        let y = bounds.maxY - 0.5
        top.move(to: NSPoint(x: bounds.minX, y: y))
        top.line(to: NSPoint(x: bounds.maxX, y: y))
        top.lineWidth = 1
        top.stroke()

        // Short vertical divider between the info block and the line-ending value.
        let vInset: CGFloat = 5
        let vx = round(separatorX) + 0.5
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: vx, y: bounds.minY + vInset))
        divider.line(to: NSPoint(x: vx, y: bounds.maxY - vInset))
        divider.lineWidth = 1
        divider.stroke()
    }

    override func layout() {
        super.layout()
        let hMargin: CGFloat = 12
        let sepGap: CGFloat = 12   // space on each side of the vertical divider
        let labelHeight = infoLabel.intrinsicContentSize.height
        let y = (bounds.height - labelHeight) / 2

        let metaWidth = min(metaLabel.intrinsicContentSize.width, bounds.width / 2)
        metaLabel.frame = NSRect(x: bounds.maxX - hMargin - metaWidth, y: y,
                                 width: metaWidth, height: labelHeight)

        separatorX = metaLabel.frame.minX - sepGap

        let infoWidth = (separatorX - sepGap) - hMargin
        infoLabel.frame = NSRect(x: hMargin, y: y, width: max(0, infoWidth), height: labelHeight)

        needsDisplay = true   // divider position may have moved
    }
}
