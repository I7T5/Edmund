import AppKit
import EdmundCore

// MARK: - Inspector

/// The window's right-hand inspector, CotEditor's layout: a row of icon tabs
/// under the toolbar, then the selected pane. Outline is the document's
/// heading tree in a source-list `NSOutlineView`, every heading with
/// sub-headings getting its own disclosure triangle; it opens expanded, except
/// that a long outline opens folded to its top two levels. Info shows the
/// document's front matter, if any, then Count and Text Settings (the status
/// bar's fields), each section its own name/value grid.
@MainActor
final class InspectorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    /// In tab order: Info first, as CotEditor's file tab. Outline is still
    /// the default pane until the user picks another (`AppSettings.inspectorPane`).
    enum Pane: String, CaseIterable {
        case info, outline

        /// Filled when selected, Xcode's inspector-tab convention. Info is
        /// the plain `doc` rather than the toolbar's `info.circle`, which
        /// already means "the inspector" one row up. `list.bullet.indent` has
        /// no filled variant.
        func symbol(selected: Bool) -> String {
            switch self {
            case .outline: return "list.bullet.indent"
            case .info:    return selected ? "doc.fill" : "doc"
            }
        }
        var title: String { self == .outline ? "Outline" : "Info" }
    }

    private static let noHeadings = "No Headings"

    /// Called with the clicked heading's index in the document's heading list.
    var onSelectHeading: ((Int) -> Void)?

    private(set) var roots: [OutlineNode] = []
    /// Every node of `roots`, in heading order (`nodes[i].index == i`).
    private var nodes: [OutlineNode] = []
    /// The (level, title) list `roots` was built from, so an edit that leaves
    /// the headings alone doesn't rebuild the tree.
    private var shownHeadings: [String] = []
    /// Headings the user collapsed, by level and title, re-applied after a
    /// rebuild — the rebuilt nodes are new objects.
    private var collapsedKeys: Set<String> = []
    /// Set while this code expands or reloads rows itself, so the collapse and
    /// expand notifications that fires are not recorded in `collapsedKeys` as
    /// the user's own choices.
    private var isReloading = false
    /// Past this many headings the outline opens folded to two levels. Applied
    /// once, the first time there are headings, so an outline that grows past
    /// it while being written never folds under the writer.
    static let foldThreshold = 20
    /// Most headings `setHeadings` retitles row by row before it rebuilds
    /// instead (see there). An unmeasured guess: time a 1,509-heading Replace
    /// All on both paths before tuning it.
    static let maxInPlaceRetitles = 50
    private var hasAppliedDefaultFold = false

    private static let infoNames = ["Words", "Characters", "Location", "Line", "Line Ending"]
    private let infoFields = ["0", "0", "0", "1", "LF"].map { NSTextField(labelWithString: $0) }
    /// The Info pane's rows, front matter first, for ReproScript and tests.
    var infoValues: [(name: String, value: String)] {
        frontMatter.map { ($0.key, $0.value) }
            + zip(Self.infoNames, infoFields.map(\.stringValue)).map { ($0, $1) }
    }
    private var frontMatter: [(key: String, value: String)] = []
    private let frontMatterHeader = InspectorViewController.sectionHeader("Front Matter")
    private let frontMatterGrid = NSGridView()

    let outlineView: NSOutlineView = InspectorOutlineView()
    private let outlineScroll = NSScrollView()
    private var infoPane: NSView!
    private var tabButtons: [Pane: NSButton] = [:]
    private(set) var pane = Pane(rawValue: AppSettings.inspectorPane) ?? .outline
    /// The strip's top: the toolbar's height in a document window, where the
    /// inspector runs up behind it; 0 in a folder window, where it doesn't.
    private var stripTop: NSLayoutConstraint!

    override func loadView() {
        outlineView.style = .sourceList
        // Opaque window grey, as Xcode's and CotEditor's inspectors, rather
        // than the source list's translucent material: an inspector is not a
        // sidebar, and in dark mode the grey sits back where the text
        // background's near-black stood out. Set after `style`, which
        // installs the material's clear background.
        outlineView.backgroundColor = .windowBackgroundColor
        outlineView.headerView = nil
        let column = NSTableColumn(identifier: .init("main"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.dataSource = self
        outlineView.delegate = self
        // Navigation is on click rather than on selection change, so clicking
        // the heading that is already selected still goes back to it.
        outlineView.target = self
        outlineView.action = #selector(rowClicked(_:))

        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        // With "always show scroll bars" a legacy scroller otherwise keeps
        // its empty track down the inspector's edge when nothing scrolls.
        outlineScroll.autohidesScrollers = true
        outlineScroll.backgroundColor = .windowBackgroundColor

        infoPane = makeInfoPane()

        let tabs = NSStackView(views: Pane.allCases.map(makeTabButton))
        tabs.spacing = 14
        // The format bar's hairline, so the two strips read as one across
        // the split when the format bar is showing.
        let separator = HairlineView()

        // The view runs full height, under the toolbar (the window has
        // `.fullSizeContentView`), so the tabs hang below the toolbar and the
        // window grey shows through the titlebar above them — the colour
        // change at the inspector's edge. By `toolbarInset`, not the safe
        // area, which misses the toolbar inside a split item on macOS 14.
        let root = BackgroundView()
        // An empty guide marking the strip's top, moved by `viewDidLayout`.
        let strip = NSLayoutGuide()
        root.addLayoutGuide(strip)
        stripTop = strip.topAnchor.constraint(equalTo: root.topAnchor)
        for view in [tabs, separator, outlineScroll, infoPane!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            // The format bar's height, its hairline on the same bottom edge;
            // centred in the strip the way the format bar centres on its
            // `interior` (below the toolbar separator, above the hairline).
            stripTop,
            separator.topAnchor.constraint(equalTo: strip.topAnchor,
                                           constant: FormatBarView.barHeight - ChromeBarView.hairlineHeight),
            separator.heightAnchor.constraint(equalToConstant: ChromeBarView.hairlineHeight),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabs.centerYAnchor.constraint(equalTo: strip.topAnchor,
                                          constant: (FormatBarView.barHeight + 1 - ChromeBarView.hairlineHeight) / 2),
            tabs.centerXAnchor.constraint(equalTo: root.centerXAnchor),
        ])
        for content in [outlineScroll, infoPane!] {
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: separator.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        view = root
        showPane(pane)

        outlineView.reloadData()
        isReloading = true
        for root in roots { expand(root) }
        isReloading = false
    }

    /// Follows the toolbar as it shows, hides or changes size.
    override func viewDidLayout() {
        super.viewDidLayout()
        let inset = view.toolbarInset
        if stripTop.constant != inset { stripTop.constant = inset }
    }

    // MARK: - Panes

    /// Shows `pane` and remembers it for every window and the next launch.
    func selectPane(_ pane: Pane) {
        self.pane = pane
        AppSettings.inspectorPane = pane.rawValue
        if isViewLoaded { showPane(pane) }
    }

    private func showPane(_ pane: Pane) {
        outlineScroll.isHidden = pane != .outline
        infoPane.isHidden = pane != .info
        for (p, button) in tabButtons {
            button.state = p == pane ? .on : .off
            button.image = Self.tabImage(p, selected: p == pane)
            // Accent for the selected tab, as CotEditor's and Xcode's
            // inspector tabs; a borderless button draws no on-state of its own.
            button.contentTintColor = p == pane ? .controlAccentColor : .secondaryLabelColor
        }
    }

    @objc private func tabClicked(_ sender: NSButton) {
        guard let pane = tabButtons.first(where: { $0.value === sender })?.key else { return }
        selectPane(pane)
    }

    private func makeTabButton(_ pane: Pane) -> NSButton {
        let button = NSButton(image: Self.tabImage(pane, selected: false), target: self,
                              action: #selector(tabClicked(_:)))
        button.isBordered = false
        // The format bar's control footprint (22×18) and glyph size.
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 22),
            button.heightAnchor.constraint(equalToConstant: 18),
        ])
        button.setButtonType(.toggle)
        button.toolTip = pane.title
        button.setAccessibilityLabel(pane.title)
        // One choice of two, announced as such rather than as two toggles.
        button.setAccessibilityRole(.radioButton)
        tabButtons[pane] = button
        return button
    }

    private static func tabImage(_ pane: Pane, selected: Bool) -> NSImage {
        NSImage(systemSymbolName: pane.symbol(selected: selected), accessibilityDescription: pane.title)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))!
    }

    /// Front matter (when the document has any), Count, then Text Settings
    /// (CotEditor's section name): names right-aligned in the secondary
    /// colour against their values, each section its own grid.
    private func makeInfoPane() -> NSView {
        // The last field, the line ending, is a text setting, not a count.
        let rows = zip(Self.infoNames, infoFields).map { ($0, $1) }
        let textGrid = Self.grid(Array(rows.suffix(1)))
        let countGrid = Self.grid(Array(rows.dropLast()))
        for grid in [textGrid, countGrid] { grid.column(at: 0).xPlacement = .trailing }
        for grid in [frontMatterGrid, textGrid, countGrid] {
            grid.rowSpacing = 6
            grid.columnSpacing = 8
        }
        frontMatterHeader.isHidden = true
        frontMatterGrid.isHidden = true
        let stack = NSStackView(views: [frontMatterHeader, frontMatterGrid,
                                        Self.sectionHeader("Count"), countGrid,
                                        Self.sectionHeader("Text Settings"), textGrid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: frontMatterGrid)
        stack.setCustomSpacing(16, after: countGrid)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // Scrolls, as the outline does: long front matter or a short window
        // would otherwise clip the Count rows with no way to reach them.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .windowBackgroundColor
        let clip = scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
        ])
        return scroll
    }

    private static func sectionHeader(_ title: String) -> NSTextField {
        let header = NSTextField(labelWithString: title)
        header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        header.textColor = .secondaryLabelColor
        return header
    }

    private static func grid(_ rows: [(String, NSTextField)]) -> NSGridView {
        NSGridView(views: rows.map { name, value in
            let label = NSTextField(labelWithString: name)
            label.textColor = .secondaryLabelColor
            return [label, value]
        })
    }

    // MARK: - Updates

    func setHeadings(_ headings: [OutlineHeading]) {
        let keys = headings.map(Self.key)
        guard keys != shownHeadings else { return }
        shownHeadings = keys
        // Same count and levels is the same tree: typing in a heading only
        // retitles it. Update those nodes in place and reload their rows,
        // rather than rebuild — which re-expanded every node, cost 6–7.5ms a
        // pause on a 1,509-heading document, and dropped the selection. Past
        // `maxInPlaceRetitles` (a Replace All across headings) one rebuild is
        // cheaper than that many single-row reloads.
        if isViewLoaded, headings.count == nodes.count,
           zip(headings, nodes).allSatisfy({ $0.level == $1.heading.level }) {
            let retitled = zip(headings, nodes).filter { $0.title != $1.heading.title }
            if retitled.count <= Self.maxInPlaceRetitles {
                for (heading, node) in retitled {
                    // A collapsed heading stays collapsed under its new title;
                    // the old key stays too while a same-titled twin keeps it.
                    let oldKey = Self.key(node.heading)
                    if collapsedKeys.contains(oldKey) {
                        collapsedKeys.insert(Self.key(heading))
                        if !keys.contains(oldKey) { collapsedKeys.remove(oldKey) }
                    }
                    node.heading = heading
                    outlineView.reloadItem(node)
                }
                return
            }
        }
        roots = OutlineNode.tree(headings)
        nodes = []
        var stack = roots.reversed() as [OutlineNode]
        while let node = stack.popLast() {
            nodes.append(node)
            stack.append(contentsOf: node.children.reversed())
        }
        if !hasAppliedDefaultFold, !headings.isEmpty {
            hasAppliedDefaultFold = true
            if headings.count > Self.foldThreshold { for root in roots { foldBelow(root) } }
        }
        guard isViewLoaded else { return }
        isReloading = true
        outlineView.reloadData()
        for root in roots { expand(root) }
        isReloading = false
    }

    func setMetrics(words: Int, characters: Int, location: Int, line: Int, lineEnding: String) {
        let values = ["\(words)", "\(characters)", "\(location)", "\(line)", lineEnding]
        // Only the fields that changed — a caret move changes two of five.
        for (field, value) in zip(infoFields, values) where field.stringValue != value {
            field.stringValue = value
        }
    }

    /// Rebuilds the Front Matter rows; a no-op while the pairs are unchanged,
    /// which is every edit outside the front matter.
    func setFrontMatter(_ pairs: [(key: String, value: String)]) {
        guard !pairs.elementsEqual(frontMatter, by: { $0 == $1 }) else { return }
        frontMatter = pairs
        while frontMatterGrid.numberOfRows > 0 { frontMatterGrid.removeRow(at: 0) }
        for (key, value) in pairs {
            let name = NSTextField(labelWithString: key)
            name.textColor = .secondaryLabelColor
            name.toolTip = key   // a key wider than the inspector is clipped
            let field = NSTextField(labelWithString: value)
            // One line, truncated: a long list or description would
            // otherwise widen the grid past the inspector.
            field.lineBreakMode = .byTruncatingTail
            // Just above the stack's own hugging (`.defaultLow`): at a tie
            // Auto Layout truncated values that had room.
            field.setContentCompressionResistancePriority(.init(NSLayoutConstraint.Priority.defaultLow.rawValue + 1),
                                                          for: .horizontal)
            field.toolTip = value
            frontMatterGrid.addRow(with: [name, field])
        }
        // Empty, the grid has no columns to place.
        if frontMatterGrid.numberOfColumns > 0 { frontMatterGrid.column(at: 0).xPlacement = .trailing }
        frontMatterHeader.isHidden = pairs.isEmpty
        frontMatterGrid.isHidden = pairs.isEmpty
    }

    nonisolated private static func key(_ heading: OutlineHeading) -> String { "\(heading.level)|\(heading.title)" }

    /// Marks every heading under `node` that has sub-headings as collapsed —
    /// all of them, not just the first level, so opening one shows only its
    /// own children.
    private func foldBelow(_ node: OutlineNode) {
        for child in node.children where !child.children.isEmpty {
            collapsedKeys.insert(Self.key(child.heading))
            foldBelow(child)
        }
    }

    /// Expands `node` and its descendants, except those the user collapsed.
    private func expand(_ node: OutlineNode) {
        guard !node.children.isEmpty, !collapsedKeys.contains(Self.key(node.heading)) else { return }
        outlineView.expandItem(node)
        for child in node.children { expand(child) }
    }

    /// A click on a heading, or Return on the selected one (`clickedRow` is -1
    /// for a key press, see `InspectorOutlineView.keyDown`).
    @objc private func rowClicked(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard let node = outlineView.item(atRow: row) as? OutlineNode else { return }
        onSelectHeading?(node.index)
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil:                      return max(roots.count, 1)
        case let node as OutlineNode:  return node.children.count
        default:                       return 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case nil:                      return roots.isEmpty ? Self.noHeadings : roots[index]
        case let node as OutlineNode:  return node.children[index]
        default:                       return ""
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? OutlineNode)?.children.isEmpty == false
    }

    // MARK: - Delegate

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is OutlineNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let node = item as? OutlineNode {
            // Secondary label colour, like the Info names: full label colour read
            // too stark for a column of navigation.
            let cell = textCell(node.heading.title.isEmpty ? " " : node.heading.title, id: "heading",
                                color: .secondaryLabelColor)
            cell.toolTip = node.heading.title
            return cell
        }
        return textCell(Self.noHeadings, id: "empty", color: .secondaryLabelColor)
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
    /// given.
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
}

/// Draws its disclosure chevrons at the weight of the secondary label colour,
/// alongside the heading titles, instead of the full label colour AppKit
/// gives them. Faded rather than tinted: the disclosure button's cell ignores
/// `contentTintColor` (set, template image, still drawn in label colour), and
/// secondary label is label colour at about half opacity anyway. Not faded
/// under Increase Contrast, where secondary label colour darkens instead.
///
/// Return or Enter on the selected heading goes to it, as a click does:
/// otherwise a keyboard user could arrow to a heading but never reach it.
private final class InspectorOutlineView: NSOutlineView {
    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        let view = super.makeView(withIdentifier: identifier, owner: owner)
        if identifier == NSOutlineView.disclosureButtonIdentifier,
           !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            view?.alphaValue = 0.5
        }
        return view
    }

    override func keyDown(with event: NSEvent) {
        // 36 is Return, 76 the keypad's Enter.
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let action {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }
}

/// Window grey behind the tabs and up through the titlebar.
private final class BackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A one-pixel separator-coloured line, the format bar's bottom hairline.
private final class HairlineView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}

/// Top-down layout for the Info pane's scrolled content.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
