import AppKit
import EdmundCore
import UniformTypeIdentifiers

// MARK: - File browser

/// A folder window's sidebar: the folder's files as a source-list outline,
/// with a filename filter along the bottom. One click on a file the editor
/// can open shows it; anything else (images, PDFs) is dimmed and opens in its
/// own app on double-click.
@MainActor
final class FileBrowserViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                       NSMenuItemValidation, NSSearchFieldDelegate {

    let root: FolderItem
    /// Called with a clicked file the editor can open.
    var onOpen: ((URL) -> Void)?
    /// The folder window's document: which files are open, for Move to Trash.
    weak var folder: FolderDocument?

    let outlineView = FileOutlineView()
    let filterField = NSSearchField()
    /// Items the filter shows, or nil when it is empty and everything shows.
    private(set) var filtered: Set<ObjectIdentifier>?
    private(set) lazy var addButton = makeAddButton()
    private var showsHidden: Bool { AppSettings.folderShowsHiddenFiles }

    init(root: FolderItem) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The bar along the bottom: the add button and the filter field, laid
    /// over the list (which scrolls under it) on the sidebar's material, as
    /// Xcode's navigator filter and CotEditor's file browser have it.
    private let footer = NSVisualEffectView()
    /// Shown only while rows are hidden under the footer.
    private let footerSeparator = NSBox()
    private let scroll = NSScrollView()

    override func loadView() {
        outlineView.style = .sourceList
        // The system's sidebar row size (System Settings ▸ Appearance ▸
        // Sidebar icon size), as CotEditor leaves it, rather than a fixed one.
        outlineView.rowSizeStyle = .default
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("main"))
        // The column tracks the sidebar's width, never the names': a long
        // name truncates in its cell rather than widening the list.
        column.resizingMask = .autoresizingMask
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        // On click rather than selection change, so a click on the selected
        // row still opens it (after Open in New Window took it away).
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))
        outlineView.doubleAction = #selector(rowDoubleClicked(_:))
        outlineView.menu = makeContextMenu()
        outlineView.setAccessibilityLabel("Files")
        outlineView.onRename = { [unowned self] in selectedItem.map(beginRename) }
        outlineView.onTrash = { [unowned self] in selectedItem.map(trash) }
        // Rows drag to another folder here (a move) or out to the Finder (a
        // copy); files dragged in from the Finder are copied in.
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(listDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        filterField.placeholderString = "Filter"
        filterField.sendsSearchStringImmediately = false
        filterField.sendsWholeSearchString = false
        filterField.focusRingType = .none
        filterField.delegate = self
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.setAccessibilityLabel("File browser filter")
        // Small, to fit the footer, which is the status bar's height.
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        // The filter glyph, not the magnifier: this narrows the list in view
        // rather than searching (Finder's and Xcode's sidebar filters). Set
        // after any `controlSize` change, which resets the cell's images.
        if let button = (filterField.cell as? NSSearchFieldCell)?.searchButtonCell {
            // Half-strength against the field, as CotEditor's measures: a
            // template draws in full label color here (contrast 0.8), and
            // the cell halves a palette image's ink, so secondaryLabelColor
            // came out at 0.2. Black at 0.75 lands on CotEditor's 0.5.
            // Increase Contrast gets full ink, as the system's label colors
            // strengthen there.
            let ink = NSColor(name: nil) { appearance in
                switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                   .accessibilityHighContrastDarkAqua]) {
                case .darkAqua: .white.withAlphaComponent(0.68)
                case .accessibilityHighContrastDarkAqua: .white
                case .accessibilityHighContrastAqua: .black
                default: .black.withAlphaComponent(0.75)
                }
            }
            let glyph = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                accessibilityDescription: "Filter")?
                .withSymbolConfiguration(.init(paletteColors: [ink]))
            button.image = glyph
            button.alternateImage = glyph
        }

        // The sidebar's own material, blending behind the window, so the bar
        // reads as more sidebar and the rows scrolling under it disappear.
        footer.material = .sidebar
        footer.blendingMode = .behindWindow
        footer.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSStackView(views: [addButton, filterField])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        // CotEditor's side insets. The bar is the status bar's height
        // (pinned below), so their top lines meet across the window.
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        bar.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(bar)
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerSeparator)

        let view = NSView()
        view.addSubview(scroll)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Document.statusBarHeight),
            bar.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            bar.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
            footerSeparator.topAnchor.constraint(equalTo: footer.topAnchor),
            footerSeparator.leadingAnchor.constraint(equalTo: footer.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: footer.trailingAnchor),
        ])
        self.view = view
        outlineView.reloadData()
    }

    /// The list scrolls under the footer: inset its content by the footer's
    /// height, through the safe area, so the scroll view still adds the
    /// titlebar's inset at the top on its own.
    override func viewDidLayout() {
        super.viewDidLayout()
        // The column to the visible width, by hand: column autoresizing never
        // narrows it once the sidebar shrinks, so long names were clipped at
        // the edge instead of truncated (CotEditor does the same, FB20309978).
        // Less what the outline adds around its column (the source list's
        // row insets, 32pt measured): a column the list's full width still
        // ran the cell 16pt past the visible edge.
        if let column = outlineView.tableColumns.first {
            let overhead = outlineView.frame.width - column.width
            let width = max(column.minWidth, scroll.contentView.frame.width - overhead)
            if column.width != width { column.width = width }
        }
        // The laid-out height, not `fittingSize`, which re-solved the
        // footer's constraints on every pass of a live resize or divider drag.
        let height = footer.frame.height
        if view.additionalSafeAreaInsets.bottom != height {
            view.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: height, right: 0)
        }
        updateFooterSeparator()
    }

    @objc private func listDidScroll(_ notification: Notification) {
        updateFooterSeparator()
    }

    private func updateFooterSeparator() {
        let clip = scroll.contentView
        let hidden = outlineView.frame.height - clip.bounds.maxY + clip.contentInsets.bottom
        footerSeparator.alphaValue = hidden > 0.5 ? 1 : 0
    }

    /// The + pull-down: New File and New Folder.
    private func makeAddButton() -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!,
                              target: self, action: #selector(showAddMenu(_:)))
        button.isBordered = false
        // Full label color: the bar's one action reads brighter than the
        // filter's dimmed glyph beside it.
        button.contentTintColor = .labelColor
        button.setAccessibilityLabel("Add")
        button.toolTip = "New File or Folder"
        return button
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // Text only, like the app's other menus.
        menu.addItem(withTitle: "New File", action: #selector(newFile(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Folder", action: #selector(newFolder(_:)), keyEquivalent: "").target = self
        // Above the button, as CotEditor's. The point is the menu's top-left
        // in the button's flipped coordinates: a menu height above its top
        // (`bounds.maxY` is its bottom edge, which opened the menu below it).
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -menu.size.height - 4), in: sender)
    }

    @objc func newFile(_ sender: Any?) {
        create(named: "Untitled", extension: "md", isFolder: false, near: item(for: sender))
    }

    @objc func newFolder(_ sender: Any?) {
        create(named: "untitled folder", extension: "", isFolder: true, near: item(for: sender))
    }

    /// Creates the file or folder in `item` if it is a folder, beside it if
    /// it is a file, or in the top folder, under the first free name Finder
    /// would give it ("Untitled 2.md"). A new file opens; a new folder is
    /// selected.
    private func create(named base: String, extension ext: String, isFolder: Bool, near item: FolderItem?) {
        let parent = item.map { $0.isDirectory ? $0 : ($0.parent ?? root) } ?? root
        let url = FolderItem.freeURL(in: parent.url, base: base, extension: ext)
        do {
            if isFolder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            } else {
                try Data().write(to: url, options: .withoutOverwriting)
            }
        } catch {
            presentError(error)
            return
        }
        listChanged(in: [parent], select: isFolder ? url : nil)
        if !isFolder { onOpen?(url) }
    }

    /// The row a command acts on: the clicked one for the context menu, the
    /// selected one for the + menu and the keys.
    private func item(for sender: Any?) -> FolderItem? {
        if let menuItem = sender as? NSMenuItem, menuItem.menu === outlineView.menu { return clickedItem }
        return selectedItem
    }

    private var selectedItem: FolderItem? {
        outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FolderItem : nil
    }

    /// Re-lists `folders` now, rather than when FSEvents reports the change
    /// a moment later, and selects `url`.
    private func listChanged(in folders: [FolderItem], select url: URL?) {
        for folder in folders { folder.reload() }
        reload(folders.map { $0 === root ? nil : $0 })
        for folder in folders where folder !== root { outlineView.expandItem(folder) }
        if let url { select(url) }
    }

    // MARK: - Rename, duplicate, trash

    @objc func renameItem(_ sender: Any?) { item(for: sender).map(beginRename) }
    @objc func duplicateItem(_ sender: Any?) { item(for: sender).map(duplicate) }
    @objc func trashItem(_ sender: Any?) { item(for: sender).map(trash) }

    /// The row being renamed, while its name is being edited.
    private var renaming: FolderItem?

    /// Edits the row's name in place, as Finder does: the name without its
    /// extension is selected, Return keeps the change, Escape drops it.
    func beginRename(_ item: FolderItem) {
        let row = outlineView.row(forItem: item)
        guard row >= 0, let field = (outlineView.view(atColumn: 0, row: row, makeIfNecessary: true)
                                      as? NSTableCellView)?.textField else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        renaming = item
        field.isEditable = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.delegate = self
        guard view.window?.makeFirstResponder(field) == true, let editor = field.currentEditor() else { return }
        let stem = item.isDirectory ? item.name : (item.name as NSString).deletingPathExtension
        editor.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    private func endRename(_ field: NSTextField, keeping: Bool) {
        guard let item = renaming else { return }
        renaming = nil   // first: giving up first responder ends editing again
        let name = field.stringValue
        // Before restoring the old name: ending the edit writes the field
        // editor's text back into the field.
        view.window?.makeFirstResponder(outlineView)
        field.isEditable = false
        field.drawsBackground = false
        field.stringValue = item.name
        guard keeping else { return }
        // Once the outline has finished ending the edit: reloading it from
        // inside its own end-editing raised "NSTableView data re-entrancy"
        // in a live window (rows animating), though never headless.
        let source = item.url   // a URL, not the item: the closure must be Sendable
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    let url = try FolderItem.rename(source, to: name)
                    guard url != source else { return }
                    let parent = self.root.item(at: source.deletingLastPathComponent()) ?? self.root
                    self.listChanged(in: [parent], select: url)
                } catch {
                    self.presentError(error)
                }
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== filterField else { return }
        endRename(field, keeping: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(cancelOperation(_:)), control !== filterField,
              let field = control as? NSTextField, renaming != nil else { return false }
        endRename(field, keeping: false)
        return true
    }

    /// Copies the item beside itself ("Notes copy.md") and selects the copy.
    func duplicate(_ item: FolderItem) {
        do {
            let copy = try FolderItem.duplicate(item.url)
            listChanged(in: [item.parent ?? root], select: copy)
        } catch {
            presentError(error)
        }
    }

    /// Moves the item to the Trash, closing any file of it open here first.
    /// Refused while such a file has unsaved changes (the menu item is
    /// disabled then; the key beeps), so no edit goes with it.
    func trash(_ item: FolderItem) {
        guard item !== root, folder?.hasUnsavedFile(under: item.url) != true else { NSSound.beep(); return }
        let row = outlineView.row(forItem: item)
        folder?.closeFiles(under: item.url)
        do {
            try FolderItem.trash(item.url)
        } catch {
            presentError(error)
            return
        }
        listChanged(in: [item.parent ?? root], select: nil)
        // The selection moves to the row that took the trashed one's place.
        let next = min(row, outlineView.numberOfRows - 1)
        if next >= 0 { outlineView.selectRowIndexes([next], byExtendingSelection: false) }
    }

    // MARK: - Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? FolderItem, renaming == nil else { return nil }
        return item.url as NSURL
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return [] }
        // Onto a folder, whichever row the pointer is over: a file's own folder.
        let target = dropFolder(for: item)
        outlineView.setDropItem(target === root ? nil : target, dropChildIndex: NSOutlineViewDropOnItemIndex)
        let local = info.draggingSource as AnyObject? === outlineView
        guard !local else {
            let destination = target.url.standardizedFileURL.path
            let pointless = urls.contains { url in
                let source = url.standardizedFileURL.path
                return url.deletingLastPathComponent().standardizedFileURL.path == destination
                    || destination == source || destination.hasPrefix(source + "/")
            }
            return pointless ? [] : .move
        }
        return .copy
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        let target = dropFolder(for: item)
        let local = info.draggingSource as AnyObject? === outlineView
        var changed = [target]
        var last: URL?
        for url in droppedURLs(info) {
            do {
                if local {
                    last = try FolderItem.move(url, into: target.url)
                    if let source = root.item(at: url.deletingLastPathComponent()) { changed.append(source) }
                } else {
                    let copy = target.url.appendingPathComponent(url.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: copy.path) else {
                        throw FolderItem.OperationError.exists(url.lastPathComponent)
                    }
                    try FileManager.default.copyItem(at: url, to: copy)
                    last = copy
                }
            } catch {
                presentError(error)
                break
            }
        }
        listChanged(in: changed, select: last)
        return last != nil
    }

    private func droppedURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    private func dropFolder(for item: Any?) -> FolderItem {
        guard let item = item as? FolderItem else { return root }
        return item.isDirectory ? item : (item.parent ?? root)
    }

    // MARK: - Updates

    /// Re-lists each item's children (nil: the whole tree) after a change on
    /// disk. A batch at a time: under a filter each reload is a walk of the
    /// whole tree, which a checkout touching hundreds of folders would repeat.
    func reload(_ items: [FolderItem?]) {
        guard isViewLoaded else { return }
        // A reload drops the outline's selection: keep the row that was
        // selected (a new copy, say), else the showing file's.
        let kept = selectedItem?.url ?? folder?.current?.fileURL
        rows = [:]
        if filtered != nil {
            applyFilter()
        } else {
            for item in items { outlineView.reloadItem(item, reloadChildren: true) }
        }
        select(kept)
    }

    /// Reveals and selects `url`'s row, expanding the folders above it.
    func select(_ url: URL?) {
        guard isViewLoaded, let url else { return }
        // Down the path, reading and expanding each folder on the way:
        // `item(at:)` only finds items already read.
        let target = url.standardizedFileURL.path
        var folder = root
        while let next = folder.children(showingHidden: true).first(where: {
            $0.isDirectory && target.hasPrefix($0.url.standardizedFileURL.path + "/")
        }) {
            outlineView.expandItem(next)
            folder = next
        }
        guard let item = root.item(at: url) else { return }
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }
        outlineView.selectRowIndexes([row], byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
    }

    // MARK: - Filter

    func controlTextDidChange(_ obj: Notification) {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(filterChanged(_:)), object: nil)
        perform(#selector(filterChanged(_:)), with: nil, afterDelay: 0.3)
    }

    @objc func filterChanged(_ sender: Any?) {
        applyFilter()
    }

    private func applyFilter() {
        filtered = root.filter(filterField.stringValue, showingHidden: showsHidden)
        rows = [:]
        outlineView.reloadData()
        // Every match in view, so the filter is a search and not a puzzle.
        if filtered != nil { outlineView.expandItem(nil, expandChildren: true) }
    }

    /// Each folder's rows, filtered once: the outline asks for every child
    /// by index. Emptied whenever the listing or the filter changes.
    private var rows: [ObjectIdentifier: [FolderItem]] = [:]

    private func children(of item: Any?) -> [FolderItem] {
        let folder = item as? FolderItem ?? root
        let key = ObjectIdentifier(folder)
        if let cached = rows[key] { return cached }
        let all = folder.children(showingHidden: showsHidden)
        let shown = filtered.map { filtered in all.filter { filtered.contains(ObjectIdentifier($0)) } } ?? all
        rows[key] = shown
        return shown
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
    }

    /// Dimmed files can't be selected: a click on one leaves the current
    /// file's highlight where it is.
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? FolderItem else { return false }
        return item.isDirectory || item.isEditable
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FolderItem)?.isDirectory ?? false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? FolderItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? makeCell(id)
        cell.textField?.stringValue = item.name
        cell.imageView?.image = NSImage(systemSymbolName: Self.symbol(for: item), accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: nil)   // macOS 14 lacks some
        // Dimmed as a whole rather than recolored: a source list tints its
        // own text in an inactive window, and a fixed secondary color came
        // out darker there than the rows it was meant to sit behind.
        cell.alphaValue = !item.isDirectory && !item.isEditable ? 0.45 : 1
        return cell
    }

    /// Symbols, as a sidebar's icons are, rather than Finder's file icons;
    /// CotEditor's set, by kind.
    static func symbol(for item: FolderItem) -> String {
        if item.isDirectory { return "folder" }
        guard let type = UTType(filenameExtension: item.url.pathExtension) else { return "document" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) { return "film" }
        if type.conforms(to: .audio) { return "music.note" }
        if type.conforms(to: .archive) { return "zipper.page" }
        if type.conforms(to: .unixExecutable) { return "apple.terminal.fill" }
        return "document"
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let image = NSImageView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        for view in [image, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = image
        cell.textField = text
        // CotEditor's row (after Apple's sample code): a 17pt icon column
        // sharing the title's baseline, the title a system spacing after it.
        image.imageAlignment = .alignCenter
        // Required, and the title gives way first: AppKit's middle
        // truncation then shortens a name that doesn't fit.
        let trailing = text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -2)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            image.widthAnchor.constraint(equalToConstant: 17),
            image.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
            text.leadingAnchor.constraint(equalToSystemSpacingAfter: image.trailingAnchor, multiplier: 1),
            trailing,
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Clicks

    private var clickedItem: FolderItem? {
        let row = outlineView.clickedRow
        return row >= 0 ? outlineView.item(atRow: row) as? FolderItem : nil
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let item = clickedItem, item.isEditable else { return }
        onOpen?(item.url)
    }

    @objc private func rowDoubleClicked(_ sender: Any?) {
        guard let item = clickedItem else { return }
        if item.isDirectory {
            if outlineView.isItemExpanded(item) { outlineView.collapseItem(item) } else { outlineView.expandItem(item) }
        } else if !item.isEditable {
            NSWorkspace.shared.open(item.url)
        }
    }

    // MARK: - Context menu

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        // CotEditor's order, less its New File and New Folder (the + menu's)
        // and plus Rename (CotEditor renames only by clicking the name).
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open in New Window", action: #selector(openInNewWindow(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Move to Trash", action: #selector(trashItem(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Duplicate", action: #selector(duplicateItem(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Rename", action: #selector(renameItem(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Share…", action: #selector(shareItem(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    /// The system share picker for the clicked row's file, beside the row.
    @objc private func shareItem(_ sender: Any?) {
        guard let item = clickedItem else { return }
        let row = outlineView.row(forItem: item)
        NSSharingServicePicker(items: [item.url])
            .show(relativeTo: outlineView.rect(ofRow: row), of: outlineView, preferredEdge: .maxX)
    }

    @objc private func showInFinder(_ sender: Any?) {
        guard let item = clickedItem else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    /// The file leaves this window for one of its own, so it is closed here
    /// first: one document, one window. A file with unsaved changes would lose
    /// them, so it is offered only for files not open here, or saved.
    @objc private func openInNewWindow(_ sender: Any?) {
        guard let item = clickedItem else { return }
        let controller = NSDocumentController.shared
        if let open = controller.document(for: item.url) as? Document, open.folder != nil {
            guard !open.isDocumentEdited else { return }
            open.folder?.release(open)
        }
        controller.openDocument(withContentsOf: item.url, display: true) { _, _, error in
            if let error { NSAlert(error: error).runModal() }
        }
    }

    @objc private func toggleHiddenFiles(_ sender: Any?) {
        AppSettings.folderShowsHiddenFiles.toggle()
        // Every folder window lists the same way.
        for case let folder as FolderDocument in NSDocumentController.shared.documents {
            folder.windowController?.fileBrowser.reload([nil])
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleHiddenFiles(_:)):
            menuItem.state = showsHidden ? .on : .off
            return true
        case #selector(openInNewWindow(_:)):
            guard let item = clickedItem, item.isEditable else { return false }
            let open = NSDocumentController.shared.document(for: item.url) as? Document
            return !(open?.folder != nil && open?.isDocumentEdited == true)
        case #selector(showInFinder(_:)), #selector(renameItem(_:)), #selector(duplicateItem(_:)),
             #selector(shareItem(_:)):
            return item(for: menuItem) != nil
        case #selector(trashItem(_:)):
            guard let item = item(for: menuItem) else { return false }
            return folder?.hasUnsavedFile(under: item.url) != true
        default:
            return true
        }
    }
}

/// The sidebar's list, with Finder's keys: Return renames the selected row,
/// Command-Delete moves it to the Trash.
final class FileOutlineView: NSOutlineView {
    var onRename: (() -> Void)?
    var onTrash: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch (event.keyCode, modifiers) {
        case (36, []), (76, []): onRename?()        // Return, keypad Enter
        case (51, [.command]): onTrash?()            // Command-Delete
        default: super.keyDown(with: event)
        }
    }
}
