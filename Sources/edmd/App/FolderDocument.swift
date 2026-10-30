import AppKit
import EdmundCore

/// A folder opened in Edmund: one window with the folder's files in a sidebar
/// and the selected file's editor beside it, modelled on CotEditor's
/// directory documents.
///
/// Each file is an ordinary `Document`, registered with the document
/// controller but without a window of its own. The folder's one window
/// controller moves to whichever file is showing, so Save, Revert, menu
/// validation and sheets reach that file through the usual
/// `windowControllers.first` route, with no forwarding here. A file switched
/// away from stays open, in `files`, only while it has unsaved changes; the
/// window asks about each of those when it closes (`FolderWindow`).
final class FolderDocument: NSDocument {

    static let typeName = "public.folder"

    override class var readableTypes: [String] { [typeName] }
    override class var writableTypes: [String] { [] }
    override class func isNativeType(_ name: String) -> Bool { name == typeName }

    private(set) var root: FolderItem!
    /// Open files: the one showing and any left with unsaved changes.
    private(set) var files: [Document] = []
    private(set) weak var current: Document?
    /// Each open file's editor pane and toolbar, built once and reused when
    /// the window switches back to it.
    private var views: [ObjectIdentifier: (pane: NSSplitViewController, toolbar: NSToolbar)] = [:]
    private(set) var windowController: FolderWindowController!
    private var watcher: FSEventStreamRef?

    override nonisolated func read(from url: URL, ofType typeName: String) throws {
        guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url])
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        throw CocoaError(.featureUnsupported)
    }

    override func makeWindowControllers() {
        guard let fileURL else { return }
        root = FolderItem(url: fileURL)
        windowController = FolderWindowController(folder: self)
        addWindowController(windowController)
        watch(fileURL)
    }

    /// The window controller may belong to a file by now, so show it directly.
    override func showWindows() {
        windowController?.showWindow(nil)
    }

    // MARK: - Files

    /// Shows `url` in this window, opening it first if need be. A file already
    /// open in a window of its own is brought forward there instead: one
    /// document, one window.
    func open(_ url: URL) {
        if let document = files.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            show(document)
            return
        }
        let controller = NSDocumentController.shared
        if let other = controller.document(for: url) {
            other.showWindows()
            return
        }
        do {
            let document = try Document(contentsOf: url, ofType: DocumentController.contentType(of: url))
            document.folder = self
            controller.addDocument(document)
            files.append(document)
            show(document)
        } catch {
            presentError(error, modalFor: windowController.window!, delegate: nil,
                         didPresent: nil, contextInfo: nil)
        }
    }

    /// Puts `document`'s editor in the window, in place of the current file's.
    func show(_ document: Document) {
        guard document !== current, let window = windowController.window else { return }
        if let old = current {
            old.detach(from: window)
            old.removeWindowController(windowController)
            if !old.isDocumentEdited { old.close() }
        } else {
            removeWindowController(windowController)
        }
        current = document

        let key = ObjectIdentifier(document)
        if views[key] == nil {
            let bounds = windowController.contentBounds
            document.makeEditor(width: bounds.width, height: bounds.height)
            let toolbar = document.makeToolbar(identifier: Document.folderToolbarID)
            views[key] = (document.makeEditorPane(bounds: bounds), toolbar)
        }
        let (pane, toolbar) = views[key]!
        windowController.setContent(pane, toolbar: toolbar)
        document.addWindowController(windowController)
        document.attach(to: window)
        document.showWindows()
        windowController.fileBrowser.select(document.fileURL)
        window.invalidateRestorableState()   // the current file is part of it
        updateEditedState()
    }

    /// Closes `document` here so it can open in a window of its own. The
    /// showing file gives its place back to the placeholder first: closing it
    /// while it owns the window controller would close the window.
    func release(_ document: Document) {
        if document === current, let window = windowController.window {
            document.detach(from: window)
            document.removeWindowController(windowController)
            current = nil
            windowController.showPlaceholder()
            addWindowController(windowController)
        }
        document.close()
    }

    /// Called from `Document.close()`.
    func fileDidClose(_ document: Document) {
        files.removeAll { $0 === document }
        views[ObjectIdentifier(document)] = nil
    }

    /// The close button's dot: on while any file in the window, showing or
    /// not, has unsaved changes. Called from `Document.updateChangeCount`,
    /// after AppKit has set the dot for the showing file alone.
    func updateEditedState() {
        windowController.window?.isDocumentEdited = files.contains(where: \.isDocumentEdited)
    }

    /// Asks about every file with unsaved changes, one at a time and each in
    /// view, the way closing their windows one by one would. `done(false)`
    /// if one was cancelled.
    func reviewUnsavedFiles(then done: @escaping (Bool) -> Void) {
        guard let next = files.first(where: {
            $0.isDocumentEdited && !reviewed.contains(ObjectIdentifier($0))
        }) else {
            reviewed = []
            done(true)
            return
        }
        show(next)
        let review = CloseReview { [weak self] shouldClose in
            guard let self else { return }
            guard shouldClose else { self.reviewed = []; done(false); return }
            // Don't Save leaves the file edited: remember it was asked about.
            self.reviewed.insert(ObjectIdentifier(next))
            self.reviewUnsavedFiles(then: done)
        }
        pendingReview = review
        next.canClose(withDelegate: review,
                      shouldClose: #selector(CloseReview.document(_:shouldClose:contextInfo:)),
                      contextInfo: nil)
    }
    private var pendingReview: CloseReview?
    private var reviewed: Set<ObjectIdentifier> = []

    /// The window has closed: close every file, then the folder. The showing
    /// file is AppKit's to close, as the owner of the window's controller.
    func windowDidClose() {
        stopWatching()
        for document in files where document !== current { document.close() }
        views = [:]
        close()
    }

    // MARK: - Watching
    //
    // FSEvents rather than NSFilePresenter: a presenter only hears about
    // coordinated writes, so a `git checkout` or a file saved by a terminal
    // editor would never reach the sidebar.

    /// What the stream holds: the folder weakly, since an event can still be
    /// in flight on the watch queue as the folder goes away. The stream owns
    /// the box and releases it with itself (the context's `release`).
    private final class WatchTarget: @unchecked Sendable {
        weak var folder: FolderDocument?
        init(_ folder: FolderDocument) { self.folder = folder }
    }

    private func watch(_ url: URL) {
        var context = FSEventStreamContext()
        context.info = Unmanaged.passRetained(WatchTarget(self)).toOpaque()
        context.release = Self.releaseWatchTarget
        guard let stream = FSEventStreamCreate(
            nil, Self.watchCallback, &context, [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "edmund.folder-watch"))
        FSEventStreamStart(stream)
        watcher = stream
    }

    /// Both run on the watch queue. `nonisolated`: a closure written inside
    /// this main-actor class is main-actor isolated, and Swift traps when the
    /// queue calls it.
    private nonisolated static let releaseWatchTarget: CFAllocatorReleaseCallBack = { info in
        guard let info else { return }
        Unmanaged<WatchTarget>.fromOpaque(info).release()
    }

    private nonisolated static let watchCallback: FSEventStreamCallback = { _, info, count, paths, _, _ in
        guard let info else { return }
        let target = Unmanaged<WatchTarget>.fromOpaque(info).takeUnretainedValue()
        let changed = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let urls = changed.prefix(count).map { URL(fileURLWithPath: $0) }
        // RunLoop.main, not DispatchQueue.main, as Document's file watcher:
        // tests spin the run loop, which never drains the main queue.
        RunLoop.main.perform {
            MainActor.assumeIsolated { target.folder?.directoriesDidChange(urls) }
        }
    }

    private func stopWatching() {
        guard let watcher else { return }
        FSEventStreamStop(watcher)
        FSEventStreamInvalidate(watcher)
        FSEventStreamRelease(watcher)
        self.watcher = nil
    }

    /// Each path is a directory whose entries changed. Only directories
    /// already read are reloaded; the rest are read fresh when expanded.
    func directoriesDidChange(_ urls: [URL]) {
        guard let root else { return }
        for url in urls {
            guard let item = root.item(at: url), item.isDirectory else { continue }
            item.reload()
            windowController.fileBrowser.reload(item === root ? nil : item)
        }
        // A reload drops the outline's selection, and saving the showing file
        // is itself a change on disk.
        windowController.fileBrowser.select(current?.fileURL)
    }

    /// Reached twice when the window closes with no file chosen: once from
    /// AppKit, as the window controller's document, and once from
    /// `windowDidClose`.
    override func close() {
        guard !isClosed else { return }
        isClosed = true
        stopWatching()
        super.close()
    }
    private var isClosed = false
}

/// Target for `canClose(withDelegate:shouldClose:contextInfo:)`, which reports
/// through an Objective-C selector.
private final class CloseReview: NSObject {
    let next: (Bool) -> Void
    init(_ next: @escaping (Bool) -> Void) { self.next = next }
    @objc func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        next(shouldClose)
    }
}

// MARK: - Window

/// The folder window: the file browser as a sidebar, and either the current
/// file's editor pane or a "No File Selected" placeholder beside it.
///
/// The content runs full height, so the sidebar's translucent material
/// reaches up behind the toolbar, as in Finder and Mail. The other side
/// (`BelowToolbarController`) keeps the editor below the toolbar, where its
/// status, find and format bars are laid out to be.
final class FolderWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {

    private unowned let folder: FolderDocument
    let fileBrowser: FileBrowserViewController
    private let split = NSSplitViewController()
    private let content = BelowToolbarController()
    private(set) var sidebar: NSSplitViewItem!

    init(folder: FolderDocument) {
        self.folder = folder
        fileBrowser = FileBrowserViewController(root: folder.root)
        let window = FolderWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 400)
        // One file at a time, switched from the sidebar; tabs would be a
        // second way to hold several, with nothing to say which a tab is.
        window.tabbingMode = .disallowed
        window.backgroundColor = .textBackgroundColor

        sidebar = NSSplitViewItem(sidebarWithViewController: fileBrowser)
        sidebar.minimumThickness = 160
        sidebar.maximumThickness = 400
        fileBrowser.view.setFrameSize(NSSize(width: 220, height: 600))
        content.show(Self.placeholder())
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "EdmundFolderSidebar"
        split.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 600)
        super.init(window: window)

        window.toolbar = Self.emptyToolbar(delegate: self)
        window.toolbarStyle = .unified
        // Automatic: a line across the content side only, none over the sidebar.
        window.titlebarSeparatorStyle = .automatic
        window.contentViewController = split
        window.setFrameAutosaveName("EdmundFolderWindow")
        if !window.setFrameUsingName("EdmundFolderWindow") { window.center() }
        // See DocumentWindowController: a window built in code gets no delegate.
        window.delegate = self
        window.folder = folder

        fileBrowser.onOpen = { [unowned folder] url in folder.open(url) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The size a file's editor pane is built at.
    var contentBounds: NSRect {
        let bounds = content.view.bounds
        return NSRect(x: 0, y: 0, width: bounds.width,
                      height: bounds.height - content.view.safeAreaInsets.top)
    }

    func setContent(_ pane: NSViewController, toolbar: NSToolbar) {
        guard pane !== content.child else { return }
        content.show(pane)
        window?.toolbar = toolbar
    }

    func showPlaceholder() {
        setContent(Self.placeholder(), toolbar: Self.emptyToolbar(delegate: self))
    }

    /// The folder's name, whichever file is showing; the file is the subtitle.
    override func windowTitle(forDocumentDisplayName displayName: String) -> String {
        window?.subtitle = folder.current?.displayName ?? ""
        return folder.displayName
    }

    // MARK: NSWindowDelegate

    /// Each file keeps its own undo history: the text view asks the window,
    /// and the window would otherwise hand every file the same one.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        folder.current?.undoManager
    }

    func windowWillClose(_ notification: Notification) {
        folder.windowDidClose()
    }

    // MARK: Restoration
    //
    // AppKit restores a document window by its window controller's document,
    // here the file showing, which would come back as a window of its own.
    // So the folder window records the folder itself, and
    // `DocumentController.restoreWindow` looks for it before AppKit's own
    // handling. A security-scoped bookmark, not a path: under the sandbox the
    // folder is reachable only through the grant the Open panel gave.

    static let bookmarkKey = "EdmundFolderBookmark"
    static let currentFileKey = "EdmundFolderCurrentFile"

    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard let url = folder.fileURL,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        state.encode(bookmark as NSData, forKey: Self.bookmarkKey)
        if let file = folder.current?.fileURL {
            let base = url.standardizedFileURL.path + "/"
            let path = file.standardizedFileURL.path
            if path.hasPrefix(base) { state.encode(String(path.dropFirst(base.count)) as NSString, forKey: Self.currentFileKey) }
        }
    }

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
    -> NSApplication.PresentationOptions {
        guard AppSettings.autoHideToolbar else { return proposedOptions }
        return proposedOptions.union([.autoHideToolbar])
    }

    // MARK: Before a file is chosen

    private static func placeholder() -> NSViewController {
        let label = NSTextField(labelWithString: "No File Selected")
        label.font = .systemFont(ofSize: NSFont.systemFontSize + 4)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    private static func emptyToolbar(delegate: NSToolbarDelegate) -> NSToolbar {
        let toolbar = NSToolbar(identifier: "FolderEmptyToolbar")
        toolbar.delegate = delegate
        toolbar.displayMode = .iconOnly
        return toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        nil   // both default items are AppKit's own
    }
}

/// The content side of a folder window: shows one view controller at a time,
/// pinned below the toolbar (the safe area's top) though its own view runs
/// up behind it.
final class BelowToolbarController: NSViewController {
    private(set) var child: NSViewController?

    override func loadView() { view = NSView() }

    func show(_ controller: NSViewController) {
        child?.view.removeFromSuperview()
        child?.removeFromParent()
        addChild(controller)
        let shown = controller.view
        shown.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shown)
        NSLayoutConstraint.activate([
            shown.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            shown.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shown.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shown.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child = controller
    }
}

/// The folder window. Closing it first asks about every file with unsaved
/// changes, not just the one showing, which is all AppKit's own close would
/// ask about.
final class FolderWindow: NSWindow {
    weak var folder: FolderDocument?

    override func performClose(_ sender: Any?) {
        guard let folder else { super.performClose(sender); return }
        folder.reviewUnsavedFiles { [weak self] shouldClose in
            // Everything has been saved or discarded by now; closing directly
            // skips AppKit asking about the showing file a second time.
            if shouldClose { self?.close() }
        }
    }
}
