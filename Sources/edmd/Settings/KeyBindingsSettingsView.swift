// The Key Bindings settings pane: menu list on the left, that menu's commands
// and their shortcuts on the right. Only Edmund's own commands appear — the
// OS-standard items (New, Save, Cut/Copy/Paste, Undo, Quit, Minimize) are not
// rebindable, so they are not listed.
//
// Editing is CotEditor's model: click the key cell, type the chord. A chord
// already in use anywhere in the menu bar is refused with a beep and an
// explanation, and the cell keeps recording so the user can try another.

import SwiftUI
import AppKit

struct KeyBindingsSettingsView: View {
    @State private var selectedGroup: String?
    /// Submenus the user has opened. Empty to start: like the menu bar, a
    /// submenu shows its commands only once asked for.
    @State private var expandedSubmenus: Set<String> = []
    @State private var error: String?
    /// Bumped after every accepted edit to re-read shortcuts out of the store.
    @State private var revision = 0

    private static let menuColumnWidth: CGFloat = 120
    private static let keyColumnWidth: CGFloat = 90
    /// An empty column after Key, so the shortcuts aren't flush against the box.
    private static let trailingColumnWidth: CGFloat = 60

    private var groups: [String] { KeyBindingCatalog.shared.groups }

    /// A top-level command, or a submenu with the commands it holds.
    private struct Section: Identifiable {
        let row: KeyBindingCatalog.Row
        var children: [KeyBindingCatalog.Row] = []
        var id: String { row.id }
    }

    private var sections: [Section] {
        var sections: [Section] = []
        for row in KeyBindingCatalog.shared.rows(inGroup: selectedGroup ?? "") {
            if row.indented, !sections.isEmpty {
                sections[sections.count - 1].children.append(row)
            } else {
                sections.append(Section(row: row))
            }
        }
        return sections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("To change a shortcut, click the key column, then type the new keys.")

            // A hand-built header over two plain Lists rather than SwiftUI
            // `Table`s: Table draws a separator under every row, which this pane
            // (like CotEditor's) doesn't want, and there's no modifier to turn
            // them off.
            VStack(spacing: 0) {
                header
                Divider()
                lists
            }
            .border(Color(nsColor: .separatorColor))
            .frame(height: 250)
            .onAppear { if selectedGroup == nil { selectedGroup = groups.first } }

            HStack {
                Button("Restore Defaults", action: restoreDefaults)
                    .disabled(!KeyBindingStore.hasAnyOverride)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        // Every settings pane is 600 wide, so switching tabs only ever resizes
        // the window vertically.
        .frame(width: 600)
    }

    /// The column titles. The cells here and the list rows below carry the same
    /// widths and insets, so every divider lines up with the column it splits.
    private var header: some View {
        HStack(spacing: 0) {
            Text("Menu")
                .padding(.leading, Self.rowInset + Self.listInset)
                .frame(width: Self.menuColumnWidth, alignment: .leading)
            Divider()
            Text("Command")
                .padding(.leading, Self.rowInset + Self.listInset + Self.disclosureWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Stops short of the header's edges — it separates two labels, it
            // doesn't continue down the lists the way the Menu one does. There
            // is none after Key: nothing follows it but the empty margin.
            Divider().frame(height: 16)
            Text("Key")
                .padding(.trailing, ShortcutRecorderView.trailingInset)
                .frame(width: Self.keyColumnWidth, alignment: .trailing)
            Color.clear
                .frame(width: Self.trailingColumnWidth)
        }
        .font(.subheadline)
        .frame(height: 28)
        .settingsSurfaceBackground()
    }

    /// Leading inset shared by the header cells and the list rows.
    private static let rowInset: CGFloat = 8

    /// A plain List still insets its row content by this much after
    /// `listRowInsets` is zeroed, so the header adds it to keep the column
    /// titles above their values.
    private static let listInset: CGFloat = 7

    /// The disclosure-triangle gutter. Every top-level row reserves it, so their
    /// titles line up whether or not they open a submenu.
    private static let disclosureWidth: CGFloat = 14

    /// Matches the row height the menu list on the left gets from AppKit.
    private static let rowHeight: CGFloat = 24

    private var lists: some View {
        HStack(spacing: 0) {
            List(groups, id: \.self, selection: $selectedGroup) { group in
                Text(group)
                    .listRowInsets(EdgeInsets(top: 0, leading: Self.rowInset,
                                              bottom: 0, trailing: Self.rowInset))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            // A `List` paints its own background, which would cover a plain
            // `.background` behind it — the surface color only shows once the
            // list's own is hidden.
            .scrollContentBackground(.hidden)
            .settingsSurfaceBackground()
            .frame(width: Self.menuColumnWidth)

            Divider()

            // A stack rather than a List: a List on macOS inserts and removes its
            // rows immediately, ignoring the animation the disclosure runs in,
            // so the rows would land before the triangle finished turning.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(sections) { section in
                        row(section.row)
                        // Collapsing clips the children to zero height, so they
                        // slide out from under their submenu rather than fading
                        // in over the rows they push down.
                        VStack(spacing: 0) {
                            ForEach(section.children) { row($0) }
                        }
                        .frame(height: isExpanded(section) ? Self.rowHeight * CGFloat(section.children.count) : 0,
                               alignment: .top)
                        .clipped()
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .settingsSurfaceBackground()
            // ponytail: re-identifying the rows is the blunt way to show an
            // edited shortcut — it also resets the scroll position. Worth
            // replacing if the command lists ever get long enough to scroll far.
            .id(revision)
        }
    }

    private func isExpanded(_ section: Section) -> Bool {
        guard let submenu = section.row.submenu else { return false }
        return expandedSubmenus.contains(submenu)
    }

    private func row(_ row: KeyBindingCatalog.Row) -> some View {
        HStack(spacing: 0) {
            // Submenu commands sit under their submenu's title, as they do in
            // the menu bar, behind a disclosure triangle.
            disclosure(for: row)
            Text(row.title)
            Spacer(minLength: 8)
            if let entry = row.entry {
                ShortcutField(shortcut: shortcut(for: entry),
                              onCommit: { commit($0, to: entry) })
                    .frame(width: Self.keyColumnWidth)
            }
        }
        .padding(.leading, Self.rowInset + Self.listInset)
        .padding(.trailing, Self.trailingColumnWidth)
        .frame(height: Self.rowHeight)
    }

    /// The triangle for a submenu row, or the empty gutter every other row keeps
    /// so titles at the same level start at the same x.
    @ViewBuilder
    private func disclosure(for row: KeyBindingCatalog.Row) -> some View {
        if row.entry == nil, let submenu = row.submenu {
            let isExpanded = expandedSubmenus.contains(submenu)
            Button {
                // Animates both the triangle and the rows appearing under it.
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSubmenus.remove(submenu)
                    } else {
                        expandedSubmenus.insert(submenu)
                    }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.disclosureWidth, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear
                .frame(width: row.indented ? Self.disclosureWidth * 2 : Self.disclosureWidth,
                       height: 1)
        }
    }

    private func shortcut(for entry: KeyBindingCatalog.Entry) -> Shortcut? {
        KeyBindingStore.effective(id: entry.id, default: entry.defaultShortcut)
    }

    /// Validates a typed chord and, if it holds, persists it and retunes the live
    /// menu item. `nil` clears the shortcut, which never conflicts.
    private func commit(_ new: Shortcut?, to entry: KeyBindingCatalog.Entry) {
        if let new, let reason = KeyBindingConflict.rejectionReason(for: new, excluding: entry.item) {
            error = reason
            NSSound.beep()
            return
        }
        error = nil
        KeyBindingStore.setOverride(new, id: entry.id, default: entry.defaultShortcut)
        KeyBindingCatalog.shared.apply(new, toItemWithID: entry.id)
        revision += 1
    }

    private func restoreDefaults() {
        KeyBindingStore.removeAllOverrides()
        KeyBindingCatalog.shared.reapplyAll()
        error = nil
        revision += 1
    }
}

// MARK: - Shortcut field

/// A one-line recorder: shows the current shortcut, and while focused swallows
/// the next chord and reports it.
private struct ShortcutField: NSViewRepresentable {
    let shortcut: Shortcut?
    let onCommit: (Shortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.onCommit = onCommit
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.shortcut = shortcut
        view.onCommit = onCommit
    }
}

/// The recorder itself. Kept as a plain NSView rather than an NSTextField: what
/// is being captured is a key equivalent, not text, and a text field would run
/// the chord through the input context first.
final class ShortcutRecorderView: NSView {
    /// Gap between the shortcut and the right edge of the key column. The
    /// header's "Key" label sits on the same margin.
    static let trailingInset: CGFloat = 8

    var shortcut: Shortcut? { didSet { needsDisplay = true } }
    var onCommit: ((Shortcut?) -> Void)?

    private var isRecording = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return true
    }

    // A chord like ⌘B is dispatched as a key equivalent, so it never reaches
    // keyDown — the window offers it to the view hierarchy here first, ahead of
    // the main menu. Claiming it while recording is what lets the user assign a
    // shortcut that some menu item already owns (and be told so).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return false }
        return handle(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(Shortcut.allowedModifiers)

        switch event.keyCode {
        case 53:  // Escape — abandon the edit, keep the existing shortcut.
            window?.makeFirstResponder(nil)
            return true
        case 51, 117:  // Delete / Forward Delete — clear the shortcut.
            onCommit?(nil)
            window?.makeFirstResponder(nil)
            return true
        default:
            break
        }

        // charactersIgnoringModifiers still folds Shift into the character
        // ("⇧⌘b" arrives as "B"); `normalized` puts the Shift back in the mask
        // so both spellings compare and display the same way.
        guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return false }
        let candidate = Shortcut(key: raw, modifiers: modifiers).normalized
        onCommit?(candidate)
        window?.makeFirstResponder(nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isRecording {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 4, yRadius: 4).fill()
        }
        let text = isRecording ? "Type shortcut" : (shortcut?.displayString ?? "")
        let color: NSColor = isRecording ? .selectedMenuItemTextColor
            : (shortcut == nil ? .tertiaryLabelColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // Right-aligned, like the key equivalents in a menu, but held off the
        // column's edge. Inset here rather than in the row so the field's frame
        // — and the header divider drawn at it — stays put.
        let origin = NSPoint(x: max(0, bounds.maxX - size.width - Self.trailingInset),
                             y: bounds.midY - size.height / 2)
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
