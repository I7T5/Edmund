// The version-history tree, as a real NSOutlineView wrapped for SwiftUI.
//
// AppKit gives us the parts SwiftUI would have needed hand-rolling: disclosure
// hierarchy, resizable header columns, and native tri-state checkboxes (an
// NSButton with allowsMixedState draws the mixed dash for free).

import SwiftUI
import AppKit
import EdmundCore

/// One outline row. NSOutlineView identifies items by object identity, so the
/// value-type tree is projected into these reference nodes once per data change
/// (never per SwiftUI body pass — new objects would reset expansion state).
final class VersionOutlineItem: NSObject {
    let title: String
    let symbol: String
    /// Versions beneath this row; 0 for a version row itself (column shows "—").
    let versionCount: Int
    let size: Int64
    /// The version ids this row owns — the unit of selection.
    let ids: [URL]
    let children: [VersionOutlineItem]

    init(title: String, symbol: String, versionCount: Int, size: Int64,
         ids: [URL], children: [VersionOutlineItem] = []) {
        self.title = title
        self.symbol = symbol
        self.versionCount = versionCount
        self.size = size
        self.ids = ids
        self.children = children
    }
}

/// Project folder → file → version nodes into outline rows.
func versionOutlineItems(_ folders: [FolderNode]) -> [VersionOutlineItem] {
    folders.map { folder in
        VersionOutlineItem(
            title: folder.displayPath, symbol: "folder",
            versionCount: folder.versionCount, size: folder.size,
            ids: folder.files.flatMap { $0.versions.map(\.id) },
            children: folder.files.map { file in
                VersionOutlineItem(
                    title: file.name, symbol: "doc.text",
                    versionCount: file.versionCount, size: file.size,
                    ids: file.versions.map(\.id),
                    children: file.versions.map { v in
                        VersionOutlineItem(
                            title: v.date.formatted(date: .abbreviated, time: .shortened),
                            symbol: "clock", versionCount: 0, size: v.size, ids: [v.id])
                    })
            })
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let itemColumn = Self("item")
    static let versionsColumn = Self("versions")
    static let sizeColumn = Self("size")
}

struct VersionOutline: NSViewRepresentable {
    let roots: [VersionOutlineItem]
    @Binding var selection: Set<URL>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .inset
        outline.rowHeight = 22
        outline.usesAlternatingRowBackgroundColors = true
        outline.indentationPerLevel = 14
        // Item absorbs the slack; the two value columns are capped, so the
        // default (last-column) autoresizing would leave a dead strip.
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator

        let item = NSTableColumn(identifier: .itemColumn)
        item.title = "Item"
        item.minWidth = 220
        item.resizingMask = .autoresizingMask
        let versions = NSTableColumn(identifier: .versionsColumn)
        versions.title = "Versions"
        versions.width = 70
        versions.minWidth = 60
        versions.maxWidth = 100
        let size = NSTableColumn(identifier: .sizeColumn)
        size.title = "Size"
        size.width = 90
        size.minWidth = 70
        size.maxWidth = 140
        for column in [item, versions, size] { outline.addTableColumn(column) }
        outline.outlineTableColumn = item

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.selection = $selection
        if coordinator.roots.map(ObjectIdentifier.init) != roots.map(ObjectIdentifier.init) {
            coordinator.roots = roots
            coordinator.outline?.reloadData()
            for root in roots { coordinator.outline?.expandItem(root) }
        } else {
            coordinator.refreshCheckboxes()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var roots: [VersionOutlineItem] = []
        var selection: Binding<Set<URL>>?
        weak var outline: NSOutlineView?

        // MARK: Data source

        func outlineView(_ view: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? VersionOutlineItem)?.children.count ?? roots.count
        }

        func outlineView(_ view: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? VersionOutlineItem)?.children[index] ?? roots[index]
        }

        func outlineView(_ view: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? VersionOutlineItem)?.children.isEmpty ?? true)
        }

        // MARK: Delegate

        func outlineView(_ view: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? VersionOutlineItem, let id = tableColumn?.identifier else { return nil }
            switch id {
            case .itemColumn:
                let cell = view.makeView(withIdentifier: id, owner: self) as? ItemCell ?? ItemCell(identifier: id)
                cell.configure(node, state: state(for: node), target: self, action: #selector(toggle(_:)))
                return cell
            case .versionsColumn:
                return valueCell(view, id, node.versionCount > 0 ? "\(node.versionCount)" : "—")
            default:
                return valueCell(view, id, ByteCountFormatter.string(fromByteCount: node.size, countStyle: .file))
            }
        }

        private func valueCell(_ view: NSOutlineView, _ id: NSUserInterfaceItemIdentifier, _ text: String) -> NSView {
            let cell = view.makeView(withIdentifier: id, owner: self) as? ValueCell ?? ValueCell(identifier: id)
            cell.label.stringValue = text
            return cell
        }

        // MARK: Selection

        func state(for node: VersionOutlineItem) -> NSControl.StateValue {
            let selected = selection?.wrappedValue ?? []
            let hits = node.ids.filter(selected.contains).count
            return hits == 0 ? .off : (hits == node.ids.count ? .on : .mixed)
        }

        @objc func toggle(_ sender: CheckBox) {
            guard let node = sender.item, let selection else { return }
            // Mixed and off both mean "not fully selected" → select all.
            if state(for: node) == .on {
                selection.wrappedValue.subtract(node.ids)
            } else {
                selection.wrappedValue.formUnion(node.ids)
            }
            refreshCheckboxes()
        }

        /// Re-derive every visible checkbox: one click changes ancestors and
        /// descendants too, and AppKit has no notion of the dependency.
        func refreshCheckboxes() {
            guard let outline else { return }
            let column = outline.column(withIdentifier: .itemColumn)
            guard column >= 0 else { return }
            for row in 0..<outline.numberOfRows {
                guard let cell = outline.view(atColumn: column, row: row, makeIfNecessary: false) as? ItemCell,
                      let node = cell.check.item else { continue }
                cell.check.state = state(for: node)
            }
        }
    }
}

/// Checkbox that remembers which row it belongs to, so the action knows what to toggle.
final class CheckBox: NSButton {
    var item: VersionOutlineItem?
}

private final class ItemCell: NSTableCellView {
    let check = CheckBox()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        check.setButtonType(.switch)
        check.title = ""
        icon.contentTintColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [check, icon, label])
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }

    func configure(_ node: VersionOutlineItem, state: NSControl.StateValue,
                   target: AnyObject, action: Selector) {
        check.item = node
        check.allowsMixedState = !node.children.isEmpty
        check.state = state
        check.target = target
        check.action = action
        icon.image = NSImage(systemSymbolName: node.symbol, accessibilityDescription: nil)
        label.stringValue = node.title
    }
}

private final class ValueCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unused") }
}
