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

    let outlineView = NSOutlineView()
    let filterField = NSSearchField()
    /// Items the filter shows, or nil when it is empty and everything shows.
    private(set) var filtered: Set<ObjectIdentifier>?
    private var showsHidden: Bool { AppSettings.folderShowsHiddenFiles }

    init(root: FolderItem) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.allowsMultipleSelection = false
        let column = NSTableColumn(identifier: .init("main"))
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

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        filterField.placeholderString = "Filter"
        filterField.sendsSearchStringImmediately = false
        filterField.sendsWholeSearchString = false
        filterField.delegate = self
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.controlSize = .small
        filterField.translatesAutoresizingMaskIntoConstraints = false
        // The filter glyph, not the magnifier: this narrows the list in view
        // rather than searching (Finder's and Xcode's sidebar filters). After
        // `controlSize`, which resets the cell's button images.
        if let button = (filterField.cell as? NSSearchFieldCell)?.searchButtonCell {
            let glyph = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                accessibilityDescription: "Filter")
            button.image = glyph
            button.alternateImage = glyph
        }

        let view = NSView()
        view.addSubview(scroll)
        view.addSubview(filterField)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: filterField.topAnchor, constant: -6),
            filterField.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            filterField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            filterField.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
        self.view = view
        outlineView.reloadData()
    }

    // MARK: - Updates

    /// Re-lists `item`'s children (nil: the whole tree) after a change on disk.
    func reload(_ item: FolderItem?) {
        guard isViewLoaded else { return }
        if filtered != nil {
            applyFilter()
        } else {
            outlineView.reloadItem(item, reloadChildren: true)
        }
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
        outlineView.reloadData()
        // Every match in view, so the filter is a search and not a puzzle.
        if filtered != nil { outlineView.expandItem(nil, expandChildren: true) }
    }

    private func children(of item: Any?) -> [FolderItem] {
        let folder = item as? FolderItem ?? root
        let all = folder.children(showingHidden: showsHidden)
        guard let filtered else { return all }
        return all.filter { filtered.contains(ObjectIdentifier($0)) }
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        children(of: item).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        children(of: item)[index]
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
        // Dimmed as a whole rather than recoloured: a source list tints its
        // own text in an inactive window, and a fixed secondary colour came
        // out darker there than the rows it was meant to sit behind.
        cell.alphaValue = !item.isDirectory && !item.isEditable ? 0.45 : 1
        return cell
    }

    /// Symbols, as a sidebar's icons are, rather than Finder's file icons.
    static func symbol(for item: FolderItem) -> String {
        if item.isDirectory { return "folder" }
        if item.isEditable { return "doc.text" }
        let type = UTType(filenameExtension: item.url.pathExtension)
        return type?.conforms(to: .image) == true ? "photo" : "doc"
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
        NSLayoutConstraint.activate([
            image.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 16),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
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
        menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Open in New Window", action: #selector(openInNewWindow(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Hidden Files", action: #selector(toggleHiddenFiles(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
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
            folder.windowController?.fileBrowser.reload(nil)
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
        case #selector(showInFinder(_:)):
            return clickedItem != nil
        default:
            return true
        }
    }
}
