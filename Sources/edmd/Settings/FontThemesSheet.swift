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
    /// Opened by "New Font Theme…" on a fresh copy: ask for its name at once,
    /// the one thing a copy cannot supply for itself.
    var asksForName = false
    @Environment(\.dismiss) private var dismiss

    @State private var renamingTheme = false
    @State private var newThemeName = ""
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
                        .keyboardShortcut(.defaultAction)
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
            if asksForName {
                newThemeName = ""
                renamingTheme = true
            }
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
        .alert("Rename Font Theme", isPresented: $renamingTheme) {
            TextField("Name", text: $newThemeName)
            Button("Cancel", role: .cancel) {}
            Button("Rename", action: commitRename)
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
                ForEach(fontThemes, id: \.name) { Text($0.displayName).tag($0.name) }
            }
        }
        .listStyle(.sidebar)
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

    private var deleteTitle: String {
        let name = fontThemes.first { $0.name == fontTheme }?.displayName
        return name.map { "Delete “\($0)”?" } ?? "Delete this font theme?"
    }

    /// Preview's sidebar footer: small bare glyphs under a rule, close to
    /// the edge — the list's controls, not a toolbar of their own.
    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: duplicateTheme) { Image(systemName: "plus") }
                .help("New font theme, copied from the selected one")
            Button { confirmingDelete = true } label: { Image(systemName: "minus") }
                .help("Delete the selected font theme")
                // A bundled theme lives inside the app: there is nothing to
                // delete, and removing the last one would leave the picker with
                // nothing to name.
                .disabled(!ThemeStore.shared.isUserTheme(fontTheme) || fontThemes.count < 2)
            Menu {
                Button("Rename…") {
                    newThemeName = fontThemes.first { $0.name == fontTheme }?.displayName ?? ""
                    renamingTheme = true
                }
                    // A built-in keeps the name it ships under; Duplicate is the
                    // way to one with your own name on it.
                    .disabled(ThemeStore.shared.isBuiltIn(fontTheme))
                Button("Duplicate", action: duplicateTheme)
            } label: {
                // Circled, as every other Settings list's footer has it.
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // Grey like + and −: a borderless menu button draws its label in
            // the control tint.
            .tint(.secondary)
            .fixedSize()
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func commitRename() {
        let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var theme = fontThemes.first(where: { $0.name == fontTheme }) else { return }
        // The display name only: `name` is the filename and the value stored in
        // settings, so moving it would orphan the selection.
        theme.displayName = trimmed
        try? ThemeStore.shared.save(theme)
        fontThemes = ThemeStore.shared.fontThemes()
    }

    private func duplicateTheme() {
        guard let copy = try? ThemeStore.shared.duplicate(fontTheme) else { return }
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
    }

    private func deleteTheme() {
        let going = fontTheme
        guard let next = fontThemes.first(where: { $0.name != going }) else { return }
        // The pane's onChange applies it; applying here too repainted twice.
        fontTheme = next.name
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
                             select: fonts.selectStandardFont)
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
                             select: fonts.selectMonospaceFont)
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
    private func fontWell(summary: String, font: NSFont,
                          select: @escaping () -> Void) -> some View {
        // The face at the control's size, as Xcode draws it: the size is in
        // the summary, and drawn at it a long name would not fit beside its
        // Ligatures switch.
        let shown = NSFont(descriptor: font.fontDescriptor, size: NSFont.systemFontSize) ?? font
        // The capitals centered in the field, whatever the face: a shared
        // baseline, which suits the script list's column of samples, put a
        // tall-capped face high and a short-capped one low. On the half point,
        // where a 2x display can draw it.
        let baseline = ((AntialiasingText.plainHeight + shown.capHeight) / 2 * 2).rounded() / 2
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
                    .help("Choose Font…")
                    .accessibilityLabel("Choose Font")
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background { FieldBezel() }
            // The script box's width, so the wells and the box share both edges.
            .frame(width: scriptBoxWidth)
        }
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
    /// Narrower than it was with a third column: two columns in a 380pt box
    /// left a stretch of nothing down the middle.
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

    /// One script's row, under the two column titles: a sample of the script
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
    /// it is drawn at, then its ligatures. The sample IS the font button.
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
