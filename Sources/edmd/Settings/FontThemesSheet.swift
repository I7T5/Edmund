// The Manage Font Themes sheet, opened from the Appearance pane: the font
// themes in a list, and the selected one's fonts, line height and per-script
// fonts beside it.

import SwiftUI
import AppKit
import EdmundCore

struct FontThemesSheet: View {
    @ObservedObject var fonts: FontSettings
    /// The pane's own selection. Choosing a row here is choosing the theme,
    /// as the pane's picker is: FontSettings edits only the live preset, so
    /// the detail can show nothing but the one in force.
    @Binding var fontTheme: String
    @Binding var fontThemes: [FontTheme]
    @Environment(\.dismiss) private var dismiss

    /// The theme whose row is a name field, as Finder renames in place.
    @State private var renaming: String?
    @State private var newThemeName = ""
    /// The list has focus: Return renames the selected theme, as in Finder,
    /// so Done gives up the Return key while it does.
    @FocusState private var listFocused: Bool
    /// The script row the pointer last picked. Selection, not state: nothing
    /// reads it but the highlight, which is what tells a reader the box is a
    /// table and a double click will do something.
    @State private var selectedScript: FontCascadeScript?

    /// Fits "Monospaced font:" and "Fonts by script:", the widest labels here.
    static let labelColumnWidth: CGFloat = 110
    /// Starts narrow and drags wider for a long name. Never remembered, as
    /// the Themes pane's is not.
    @State private var sidebarWidth: CGFloat = 140
    @State private var dragStartWidth: CGFloat?
    @State private var confirmingDelete = false
    /// The theme the confirmation is for, when a row menu named one other
    /// than the selection; nil means the selected theme.
    @State private var deleting: String?

    /// A source list down the sheet's leading edge and the selected theme
    /// beside it — the shape of CotEditor's syntax editor sheet, and of any
    /// macOS editor of a list of things.
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay { resizeHandle }
            VStack(alignment: .leading, spacing: 16) {
                detail
                Spacer(minLength: 0)
                HStack {
                    HelpLink(anchor: HelpAnchor.appearance)
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(listFocused || renaming != nil ? nil : .defaultAction)
                }
            }
            .padding(20)
            // The sheet's size comes from here: a sidebar List has no ideal
            // size of its own, and left to it the sheet collapses.
            .fixedSize()
        }
        // Editing a theme is what the sheet is for, so its edits are written
        // into the selected one. Opened on Custom, the first edit saves the
        // whole screen into it, Custom changes included.
        .onAppear {
            fonts.writesPreset = true
            #if DEBUG
            // Puts the selected row into rename for a live capture of the field
            // (`-debug.renameFontTheme YES`; see SettingsRender).
            if UserDefaults.standard.bool(forKey: "debug.renameFontTheme") { beginRename() }
            #endif
        }
        .onDisappear {
            fonts.writesPreset = false
            // The pane compares the screen against these to decide Custom.
            fontThemes = ThemeStore.shared.fontThemes()
        }
        // The Themes pane's confirmation, for the same irreversible act.
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteTheme)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the theme’s file. You can’t undo this.")
        }
    }

    // MARK: Theme list

    /// The native sidebar: its own material, a section header, and the
    /// accent-filled selection. The footer rides on the same material.
    private var sidebar: some View {
        List(selection: Binding<String?>(
            get: { fontTheme },
            // A list can be clicked empty; the pane always names one.
            set: { if let name = $0 { fontTheme = name } })) {
            Section("Font Themes") {
                ForEach(fontThemes, id: \.name) { theme in
                    Group {
                        if renaming == theme.name {
                            // Return or clicking away keeps the name; Esc
                            // leaves the old one, as in Finder.
                            RenameField(text: $newThemeName,
                                        commit: commitRename,
                                        cancel: { renaming = nil })
                                .fixedSize()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(theme.displayName)
                        }
                    }
                    .tag(theme.name)
                }
            }
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        // Focus is for Return, not for show: a sidebar draws no ring of its
        // own, and the row's selection already marks it.
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard renaming == nil, !ThemeStore.shared.isBuiltIn(fontTheme) else { return .ignored }
            beginRename()
            return .handled
        }
        // A row's own commands on its secondary click, as Finder's sidebar has
        // them; the footer keeps the same set for the pointer-only reader.
        .contextMenu(forSelectionType: String.self) { names in
            if let name = names.first {
                Button("Rename") { fontTheme = name; beginRename() }
                    .disabled(ThemeStore.shared.isBuiltIn(name))
                // Selecting only for Rename, which needs the row in edit; the
                // others act on the clicked row and leave the theme in force
                // alone, as Finder leaves the selection on a secondary click.
                Button("Duplicate") { duplicateTheme(name) }
                Divider()
                Button("Delete…") { confirmDelete(name) }
                    .disabled(!ThemeStore.shared.isUserTheme(name) || fontThemes.count < 2)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                footer
            }
        }
        .frame(width: sidebarWidth)
    }

    /// The divider doubles as the drag target that resizes the sidebar, as
    /// the gap between the Themes pane's boxes does. Wider than the line it
    /// sits on, so it can be found.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        // Latched: `translation` runs from where the drag began.
                        let base = dragStartWidth ?? sidebarWidth
                        dragStartWidth = base
                        sidebarWidth = min(max(base + drag.translation.width, 110), 260)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityHidden(true)
    }

    /// The square the glyphs span (11pt, measured), and no more.
    private static let footerHitSize: CGFloat = 12

    /// A footer glyph centred in its whole hit square, all of it clickable.
    private func footerGlyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: Self.footerHitSize, height: Self.footerHitSize)
            .contentShape(Rectangle())
    }

    private var deleteTitle: String {
        let target = deleting ?? fontTheme
        let name = fontThemes.first { $0.name == target }?.displayName
        return name.map { "Delete “\($0)”?" } ?? "Delete this font theme?"
    }

    /// Preview's sidebar footer: small bare glyphs under a rule, close to
    /// the edge — the list's controls, not a toolbar of their own.
    ///
    /// Each control answers anywhere in the square its glyph spans, not only
    /// on the glyph's ink:
    /// a borderless button hit-tests the symbol's own ink, and a thin minus
    /// was a few pixels tall to aim at.
    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: newTheme) { footerGlyph("plus") }
                .help("New font theme, copied from the selected one")
            Button { confirmDelete(fontTheme) } label: { footerGlyph("minus") }
                .help("Delete the selected font theme")
                // A bundled theme lives inside the app: there is nothing to
                // delete, and removing the last one would leave the picker with
                // nothing to name.
                .disabled(!ThemeStore.shared.isUserTheme(fontTheme) || fontThemes.count < 2)
            Menu {
                Button("Rename", action: beginRename)
                    // A built-in keeps the name it ships under; Duplicate is the
                    // way to one with your own name on it.
                    .disabled(ThemeStore.shared.isBuiltIn(fontTheme))
                Button("Duplicate", action: duplicateTheme)
            } label: {
                // Circled, as every other Settings list's footer has it.
                Image(systemName: "ellipsis.circle")
            }
            .help("Rename or duplicate the selected font theme")
            .accessibilityLabel("More")
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Grey like + and −: a borderless menu button draws its label in
            // the control tint.
            .tint(.secondary)
            // The pop-up button's frame is its hit area.
            .frame(width: Self.footerHitSize, height: Self.footerHitSize)
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .controlSize(.small)
        // Less than before by the hit squares' own margin, so the glyphs —
        // and the bar's height — stay where they were.
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private func beginRename() {
        newThemeName = fontThemes.first { $0.name == fontTheme }?.displayName ?? ""
        renaming = fontTheme
    }

    private func commitRename() {
        defer { renaming = nil }
        let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var theme = fontThemes.first(where: { $0.name == renaming }) else { return }
        // The display name only: `name` is the filename and the value stored in
        // settings, so moving it would orphan the selection.
        theme.displayName = trimmed
        try? ThemeStore.shared.save(theme)
        fontThemes = ThemeStore.shared.fontThemes()
    }

    /// "New Theme", or "New Theme 2" and on when that is taken — the name a
    /// new theme carries until it is given one.
    static func untitledName(among themes: [FontTheme]) -> String {
        let taken = Set(themes.map(\.displayName))
        var name = "New Theme"
        var n = 2
        while taken.contains(name) {
            name = "New Theme \(n)"
            n += 1
        }
        return name
    }

    /// The + button's new theme: a copy of the selected one, named as the
    /// pane's New Font Theme… names it, but put straight into rename.
    private func newTheme() {
        guard let copy = try? ThemeStore.shared.duplicate(fontTheme),
              var made = ThemeStore.shared.fontThemes().first(where: { $0.name == copy })
        else { return }
        made.displayName = Self.untitledName(among: fontThemes)
        try? ThemeStore.shared.save(made)
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
        beginRename()
    }

    /// The footer's Duplicate: a copy of the selected theme, selected — the
    /// same typography, so nothing repaints.
    private func duplicateTheme() {
        guard let copy = try? ThemeStore.shared.duplicate(fontTheme) else { return }
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
    }

    /// A row menu's Duplicate: a copy of that row's theme, the selection left
    /// alone, as Finder leaves it on a secondary click. Selecting the copy of
    /// a theme not in force would put it in force.
    private func duplicateTheme(_ name: String) {
        guard (try? ThemeStore.shared.duplicate(name)) != nil else { return }
        fontThemes = ThemeStore.shared.fontThemes()
    }

    /// Puts the confirmation up for `name`, which a row menu may name without
    /// selecting it.
    private func confirmDelete(_ name: String) {
        deleting = name
        confirmingDelete = true
    }

    private func deleteTheme() {
        let going = deleting ?? fontTheme
        deleting = nil
        // Only the theme in force has to hand over to another; deleting any
        // other leaves the selection where it is.
        if going == fontTheme {
            guard let next = fontThemes.first(where: { $0.name != going }) else { return }
            // The pane's onChange applies it; applying here too repainted twice.
            fontTheme = next.name
        }
        try? ThemeStore.shared.deleteUserTheme(named: going)
        fontThemes = ThemeStore.shared.fontThemes()
    }

    // MARK: Detail

    /// The theme's fonts as Xcode's theme editor shows them, each with its
    /// Ligatures switch beside it. No Antialias: it is a display setting the
    /// pane keeps, and it never reaches a theme.
    private var detail: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 12) {
            GridRow {
                Text("Standard font:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                HStack(spacing: 12) {
                    fontWell(summary: fonts.standardSummary, font: fonts.standardFont,
                             role: "standard", select: fonts.selectStandardFont)
                    // Small, like the Themes pane's switches beside a value.
                    Toggle("Ligatures", isOn: $fonts.standardLigatures)
                        .controlSize(.small)
                }
            }

            GridRow {
                Text("Monospaced font:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                HStack(spacing: 12) {
                    fontWell(summary: fonts.monospaceSummary, font: fonts.monospaceFont,
                             role: "monospaced", select: fonts.selectMonospaceFont)
                    Toggle("Ligatures", isOn: $fonts.monospaceLigatures)
                        .controlSize(.small)
                }
            }

            GridRow {
                Text("Line height:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                AppearanceSettingsView.lineHeightField(fonts)
            }

            fontCascadeSection
        }
        .fixedSize()
    }

    /// Xcode's font row: the font drawn in itself, with the button onto the
    /// font panel inside the same bezel, and no stepper — the panel sets the
    /// size, as it does there. Leading-aligned, so a long name runs toward the
    /// button rather than under it from both sides.
    /// `role` names the well for VoiceOver and the tooltip ("standard",
    /// "monospaced"): two buttons both called Choose Font left a VoiceOver
    /// reader unable to tell them apart.
    private func fontWell(summary: String, font: NSFont, role: String,
                          select: @escaping () -> Void) -> some View {
        // The face at the control's size, as Xcode draws it: the size is in
        // the summary, and drawn at it a long name would not fit beside its
        // Ligatures switch.
        let shown = NSFont(descriptor: font.fontDescriptor, size: NSFont.systemFontSize) ?? font
        // The capitals centered in the field, whatever the face: a shared
        // baseline, which suits the script list's column of samples, put a
        // tall-capped face high and a short-capped one low. Exact here; the
        // cell rounds the line box to device pixels.
        let baseline = (AntialiasingText.plainHeight + shown.capHeight) / 2
        return HStack(spacing: 0) {
            // The row's text baseline. SwiftUI reads the field's bottom edge
            // as its baseline, which hangs the row label a descender low; this
            // hidden text sits on the control's center line instead.
            Text(" ").hidden().frame(width: 0)
            HStack(spacing: 4) {
                AntialiasingText(summary)
                    .plain()
                    .antialiasDisabled(!fonts.antialias)
                    .font(nsFont: shown)
                    .baseline(baseline)
                    .alignment(.left)
                    .padding(.leading, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: select) { FontPanelGlyph() }
                    .buttonStyle(.borderless)
                    .help("Choose the \(role) font")
                    .accessibilityLabel("Choose \(role) font")
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background { FieldBezel() }
            // The script box's width, so the wells and the box share both edges.
            .frame(width: scriptBoxWidth)
        }
    }
}

/// The in-place rename field: an AppKit `NSTextField`, borderless on a white
/// ground, with AppKit's own exterior focus ring — square inside, rounded
/// outside, following Increase Contrast — hugging the name. Finder's list view
/// renames with exactly this.
///
/// Not a SwiftUI `TextField`: `.squareBorder` gets the native ring but pads the
/// text ~3pt inside its bezel, which Finder's field does not; `.plain` has no
/// padding but SwiftUI turns its ring off. SwiftUI's List also offers no way
/// into the table view's own cell editing, which is what Finder uses.
///
/// Return or losing focus commits; Esc cancels.
private struct RenameField: NSViewRepresentable {
    @Binding var text: String
    let commit: () -> Void
    let cancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = FocusingTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.focusRingType = .exterior
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.lineBreakMode = .byClipping
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.currentEditor() == nil, field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: RenameField
        /// Set by Esc, so the end of editing that follows does not commit.
        private var cancelled = false
        init(parent: RenameField) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
            // The field hugs the name, so it grows and shrinks with it.
            field.invalidateIntrinsicContentSize()
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                cancelled = true
                parent.cancel()
                return true
            }
            return false
        }

        func controlTextDidEndEditing(_ note: Notification) {
            // The window's shared field editor, back to AppKit's padding for
            // whichever field it serves next.
            (note.userInfo?["NSFieldEditor"] as? NSTextView)?.textContainer?.lineFragmentPadding = 2
            guard !cancelled else { return }
            // Return and a click away both land here, once.
            cancelled = true
            // Next turn, not now: a click on − (or any footer button) is what
            // ends the editing, from inside that click's mouse-down, and
            // committing then reloads the list mid-click, which made SwiftUI
            // drop the press — − took a second click to delete a theme just
            // made with +.
            let commit = parent.commit
            Task { @MainActor in commit() }
        }
    }
}

/// Takes focus with its text selected as soon as it is in a window, as
/// Finder's rename field does.
private final class FocusingTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { NormalStyleCell.self }
        set { _ = newValue }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // The row is still being built when this is called, and the list
        // takes focus as the sheet settles; so try over the next few frames
        // until the field holds it.
        Task { @MainActor [weak self] in
            for _ in 0..<10 {
                guard let self, let window = self.window else { return }
                if self.currentEditor() != nil, window.isKeyWindow { return }
                if window.makeFirstResponder(self) {
                    // Finder's selection runs to the field's edge: no line
                    // padding. The field editor is the window's, shared, so
                    // the coordinator puts its padding back when editing ends.
                    (self.currentEditor() as? NSTextView)?.textContainer?.lineFragmentPadding = 0
                    self.currentEditor()?.selectAll(nil)
                    self.invalidateIntrinsicContentSize()
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    /// The name's width and 2pt for the caret after it — Finder's field is
    /// that and no more (measured) — so `fixedSize` hugs the name and tracks
    /// what is typed.
    override var intrinsicContentSize: NSSize {
        let text = (currentEditor() as? NSTextView)?.string ?? stringValue
        let width = NSAttributedString(string: text, attributes: [.font: font as Any]).size().width
        return NSSize(width: ceil(width) + 2, height: super.intrinsicContentSize.height)
    }
}

/// A selected table row hands its cells the emphasized background style,
/// under which a text field draws white text and no background: the name read
/// as plain row text, with no field at all. The rename field is a field
/// whatever row it sits in.
private final class NormalStyleCell: NSTextFieldCell {
    override var backgroundStyle: NSView.BackgroundStyle {
        get { .normal }
        set { _ = newValue }
    }

    /// AppKit's ring straddles its mask's edge, so on the field's own frame
    /// its inner 1.5pt lay over the white fill as a pale band. Finder's ring
    /// starts where the fill stops (measured, 2x: 6px ring, 1px blended edge,
    /// then fill), so the mask stands 1pt outside the frame. Still AppKit's
    /// ring, drawn by AppKit; only where it is drawn moves.
    private static let ringOutset: CGFloat = 1

    /// No inset of the cell's own: the field editor's line padding is all the
    /// room Finder's field gives the text, and the selection runs to the edge.
    /// The title rect is where the field editor is placed.
    override func titleRect(forBounds rect: NSRect) -> NSRect { rect }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }

    override func focusRingMaskBounds(forFrame cellFrame: NSRect, in controlView: NSView) -> NSRect {
        cellFrame.insetBy(dx: -Self.ringOutset, dy: -Self.ringOutset)
    }

    override func drawFocusRingMask(withFrame cellFrame: NSRect, in controlView: NSView) {
        NSBezierPath(rect: cellFrame.insetBy(dx: -Self.ringOutset, dy: -Self.ringOutset)).fill()
    }
}

/// The genuine AppKit text-field bezel, borrowed from an empty `NSTextField`
/// rather than stroked by hand: it follows dark mode and Increase Contrast,
/// which a drawn border does not.
private struct FieldBezel: NSViewRepresentable {
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: "")
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.isEditable = false
        field.isSelectable = false
        field.refusesFirstResponder = true
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {}
}

// MARK: - Fonts by script (per-script cascade)

extension FontThemesSheet {

    /// The "Fonts by script" group: a bordered, scrolling list of one row per
    /// script, in the shape of the Syntax pane's "Available syntaxes" box.
    ///
    /// A list rather than nine more form rows. Per-script fonts are overrides
    /// to the Standard/Monospaced fonts above, not nine more top-level
    /// settings, and nine right-aligned form labels made them read as the
    /// latter. Inside the box the script name is the row's first column, so
    /// the group reads as one object beside a single label.
    @ViewBuilder
    var fontCascadeSection: some View {
        GridRow(alignment: .top) {
            Text("Fonts by script:")
                .frame(width: Self.labelColumnWidth, alignment: .trailing)
                // Pull the label onto the box's first row of text.
                .padding(.top, 5)
            scriptFontBox
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Fonts for scripts the standard font does not cover")
        }
    }

    /// Box width, and one script row's height. Five rows are visible and the
    /// remaining four scroll — the same 5-row window the Syntax pane's box uses.
    /// The font wells above take this width too; one edge for all three.
    private var scriptBoxWidth: CGFloat { 240 }
    /// The Syntax pane's row height, so the two boxes read as the same kind
    /// of list. 28 was sized to a body-size sample; the sample is drawn small
    /// now, and the tooltip carries the size.
    private var scriptRowHeight: CGFloat { 20 }

    /// Column widths and the leading/trailing inset, shared by the header cells
    /// and the rows beneath them so each title sits over its own column. Same
    /// arrangement as the Key Bindings pane's hand-built header.
    private static let ligatureColumnWidth: CGFloat = 56
    /// Sized to its title; the checkbox sits at the column's leading edge under
    /// the D, the way a checkbox column reads in a table.
    private static let defaultColumnWidth: CGFloat = 44
    private static let scriptRowInset: CGFloat = 6

    /// A plain List still insets its row content by this much after
    /// `listRowInsets` is set, so the header adds it to keep the column titles
    /// above their values. Key Bindings' hand-built header carries the same
    /// constant for the same reason.
    private static let scriptListInset: CGFloat = 8

    /// Header over the list. A hand-built one rather than a `Table`, for the
    /// reason Key Bindings gives: `Table` draws a separator under every row and
    /// offers no way to turn them off.
    private var scriptFontBox: some View {
        VStack(spacing: 0) {
            scriptListHeader
            Divider()
            scriptFontList
        }
        .frame(width: scriptBoxWidth)
        .settingsSurfaceBackground()
        .border(.separator)
    }

    private var scriptListHeader: some View {
        HStack(spacing: 8) {
            Text("Default")
                .frame(width: Self.defaultColumnWidth, alignment: .leading)
            Text("Script")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Ligatures")
                .frame(width: Self.ligatureColumnWidth, alignment: .trailing)
        }
        // The rows carry 4pt of their own for the selection highlight to inset
        // into; the titles take the same so they stay over their columns.
        .padding(.horizontal, Self.scriptRowInset + Self.scriptListInset + 4)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(height: 20)
    }

    private var scriptFontList: some View {
        List {
            ForEach(FontCascadeScript.allCases, id: \.self) { script in
                scriptRow(script)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 1, leading: Self.scriptRowInset,
                                              bottom: 1, trailing: Self.scriptRowInset))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, scriptRowHeight)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .frame(height: scriptRowHeight * 5)
    }

    /// One script's row, under the three column titles: a sample of the script
    /// drawn in its own face, and the ligature switch.
    ///
    /// The sample stands in for an English script name. "Chinese (Han)" told a
    /// reader nothing the glyphs do not, and the sample says the one thing the
    /// name could not: which face the script is actually being rendered in.
    ///
    /// The family and size are on the tooltip rather than in a column of their
    /// own. A row's font is worth being able to check, but it is not worth a
    /// third of the box's width on nine rows most people never set — and the
    /// sample already shows the size, drawn at it.
    ///
    /// One script: whether it takes the default, then its sample with the size
    /// it is drawn at, then its ligatures. Double-clicking the row opens the
    /// font panel.
    ///
    /// The Default switch is the row's own state made visible. With it on the
    /// rest of the row is disabled — there is no font to have ligatures, and
    /// the sample shows what the fallback will draw — and turning it off is
    /// what makes the row editable, seeding the font from that same fallback
    /// so nothing jumps.
    @ViewBuilder
    private func scriptRow(_ script: FontCascadeScript) -> some View {
        let isSet = fonts.cascadeFonts[script] != nil
        let preview = fonts.previewFont(for: script)
        let isSelected = selectedScript == script
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Toggle("", isOn: Binding(
                get: { !isSet },
                set: { useDefault in
                    fonts.setCascadeFont(script, family: useDefault ? nil : preview?.familyName)
                }))
                .accessibilityLabel("Use the standard font for \(script.label)")
                .labelsHidden()
                .controlSize(.small)
                .frame(width: Self.defaultColumnWidth, alignment: .leading)
                .help("Use the standard font for \(script.label)")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                AntialiasingText(script.sample)
                    .plain()
                    .antialiasDisabled(!fonts.antialias)
                    // The face at a list's size, not the body's; the size
                    // itself is the number beside it.
                    .font(nsFont: preview.map {
                        NSFont(descriptor: $0.fontDescriptor, size: 12) ?? $0
                    })
                    .alignment(.left)
                    .clickThrough()
                    .baselineAligned()
                    .fixedSize()
                Text("\(Int(fonts.cascadePointSize(for: script).rounded()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Dimmed with the ligature box, not the whole row: the Default
            // switch is live either way and must not look otherwise.
            .opacity(isSet ? 1 : 0.55)

            // Against the trailing edge, as Default is against the leading one:
            // each edge column belongs to its edge.
            Toggle("", isOn: cascadeLigaturesBinding(for: script))
                .accessibilityLabel("Ligatures for \(script.label)")
                .labelsHidden()
                .controlSize(.small)
                .frame(width: Self.ligatureColumnWidth, alignment: .trailing)
                .disabled(!isSet)
                .opacity(isSet ? 1 : 0.55)
        }
        .padding(.horizontal, 4)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        // A table row, the way NSTableView has always behaved: one click
        // selects, a double click acts — here, opens the font panel, as Font
        // Book does — and the menu is on the right button. No Button wrapping
        // the sample: single-click-to-open was not the convention, and a
        // Button is what was keeping the tooltip from showing.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard isSet else { return }
            fonts.selectCascadeFont(script)
        }
        .onTapGesture(count: 1) { selectedScript = script }
        .contextMenu {
            // The face and size the row is drawn in, as Mail's recipient menu
            // opens with the address: a disabled first item naming what the
            // commands below act on. Here for the reader the tooltip never
            // reached, and named even when unset — that is the fallback the
            // editor will really use.
            Text(fontDescription(preview))
            Divider()
            Button("Choose Font…") { fonts.selectCascadeFont(script) }
                .disabled(!isSet)
            Button("Reset to Default") { fonts.setCascadeFont(script, family: nil) }
                .disabled(!isSet)
        }
        .help(scriptTooltip(script, preview))
    }

    /// "Songti SC, 16 pt" — the face and size a row is really drawn in, which
    /// for an unset script is the fallback.
    private func fontDescription(_ font: NSFont?) -> String {
        guard let font else { return "System font" }
        let family = font.familyName ?? font.displayName ?? font.fontName
        return "\(family), \(Int(font.pointSize.rounded())) pt"
    }

    /// "Chinese (Han): Songti SC, 16 pt" — the script, then its font.
    private func scriptTooltip(_ script: FontCascadeScript, _ font: NSFont?) -> String {
        "\(script.label): \(fontDescription(font))"
    }

    private func cascadeLigaturesBinding(for script: FontCascadeScript) -> Binding<Bool> {
        Binding(
            get: { fonts.cascadeLigatures(for: script) },
            set: { fonts.setCascadeLigatures(script, on: $0) }
        )
    }

}
