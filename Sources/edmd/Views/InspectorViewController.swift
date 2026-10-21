import AppKit
import EdmundCore

// MARK: - Inspector

/// The window's right-hand inspector: the document's heading outline, then an
/// Info section repeating the status bar's fields. One source-list
/// `NSOutlineView` whose two sections are group rows, so AppKit supplies their
/// hover Show/Hide; every heading with sub-headings gets its own disclosure
/// triangle. Everything opens expanded.
@MainActor
final class InspectorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// A section's group row. Kept for the controller's lifetime, so its
    /// expanded state survives every reload of its children.
    final class Section {
        let title: String
        init(_ title: String) { self.title = title }
    }

    /// An Info row: a field name and its value.
    final class InfoRow {
        let name: String
        var value: String
        init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    let outlineSection = Section("Outline")
    let infoSection = Section("Info")
    private static let noHeadings = "No Headings"

    /// Called with the clicked heading's index in the document's heading list.
    var onSelectHeading: ((Int) -> Void)?

    private(set) var roots: [OutlineNode] = []
    /// The (level, title) list `roots` was built from, so an edit that leaves
    /// the headings alone doesn't rebuild the tree.
    private var shownHeadings: [String] = []
    /// Headings the user collapsed, by level and title, re-applied after a
    /// rebuild — the rebuilt nodes are new objects.
    private var collapsedKeys: Set<String> = []
    private var isReloading = false

    private(set) var infoRows = [InfoRow("Words", "0"), InfoRow("Characters", "0"),
                                 InfoRow("Location", "0"), InfoRow("Line", "1"),
                                 InfoRow("Line Ending", "LF")]

    let outlineView = NSOutlineView()

    override func loadView() {
        outlineView.style = .sourceList
        outlineView.headerView = nil
        outlineView.floatsGroupRows = false
        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        // Navigation is on click rather than on selection change, so clicking
        // the heading that is already selected still goes back to it.
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        let scroll = NSScrollView()
        scroll.documentView = outlineView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        view = scroll

        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
    }

    // MARK: - Updates

    func setHeadings(_ headings: [OutlineHeading]) {
        let keys = headings.map(Self.key)
        guard keys != shownHeadings else { return }
        shownHeadings = keys
        roots = OutlineNode.tree(headings)
        guard isViewLoaded else { return }
        isReloading = true
        outlineView.reloadItem(outlineSection, reloadChildren: true)
        for root in roots { expand(root) }
        isReloading = false
    }

    func setMetrics(words: Int, characters: Int, location: Int, line: Int, lineEnding: String) {
        let values = ["\(words)", "\(characters)", "\(location)", "\(line)", lineEnding]
        guard values != infoRows.map(\.value) else { return }
        for (row, value) in zip(infoRows, values) { row.value = value }
        guard isViewLoaded else { return }
        outlineView.reloadItem(infoSection, reloadChildren: true)
    }

    nonisolated private static func key(_ heading: OutlineHeading) -> String { "\(heading.level)|\(heading.title)" }

    /// Expands `node` and its descendants, except those the user collapsed.
    private func expand(_ node: OutlineNode) {
        guard !node.children.isEmpty, !collapsedKeys.contains(Self.key(node.heading)) else { return }
        outlineView.expandItem(node)
        for child in node.children { expand(child) }
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard let node = outlineView.item(atRow: outlineView.clickedRow) as? OutlineNode else { return }
        onSelectHeading?(node.index)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil:                      return 2
        case let s as Section where s === outlineSection:
                                       return max(roots.count, 1)
        case is Section:               return infoRows.count
        case let node as OutlineNode:  return node.children.count
        default:                       return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil:                      return index == 0 ? outlineSection : infoSection
        case let s as Section where s === outlineSection:
                                       return roots.isEmpty ? Self.noHeadings : roots[index]
        case is Section:               return infoRows[index]
        case let node as OutlineNode:  return node.children[index]
        default:                       return ""
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is Section || ((item as? OutlineNode)?.children.isEmpty == false)
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Section }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is OutlineNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        switch item {
        case let section as Section:
            return textCell(section.title, id: "group")
        case let node as OutlineNode:
            let cell = textCell(node.heading.title.isEmpty ? " " : node.heading.title, id: "heading")
            cell.toolTip = node.heading.title
            return cell
        case let row as InfoRow:
            return infoCell(row)
        default:
            return textCell(Self.noHeadings, id: "empty", color: .secondaryLabelColor)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
        collapsedKeys.insert(Self.key(node.heading))
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isReloading, let node = notification.userInfo?["NSObject"] as? OutlineNode else { return }
        collapsedKeys.remove(Self.key(node.heading))
    }

    // MARK: - Cells

    /// A one-label cell. `color` is applied once, at creation, and only when
    /// given: a group row's label is styled by the source list itself, and
    /// recolouring it on reuse overrode that.
    private func textCell(_ text: String, id: String, color: NSColor? = nil) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        if let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell.textField?.stringValue = text
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = NSTextField(labelWithString: text)
        if let color { field.textColor = color }
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Name on the left in the secondary colour, value right-aligned — the
    /// status bar's label/value pairing, laid out as a list.
    private func infoCell(_ row: InfoRow) -> NSTableCellView {
        let cell = textCell(row.name, id: "info", color: .secondaryLabelColor)
        let value: NSTextField
        if let existing = cell.subviews.compactMap({ $0 as? NSTextField }).first(where: { $0 !== cell.textField }) {
            value = existing
        } else {
            value = NSTextField(labelWithString: "")
            value.alignment = .right
            value.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(value)
            NSLayoutConstraint.activate([
                value.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                value.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        value.stringValue = row.value
        return cell
    }
}
