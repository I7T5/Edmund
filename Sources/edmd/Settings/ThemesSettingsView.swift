// The Themes settings pane: a sidebar of named themes beside a detail box
// showing the selected one. Two boxes with the window background between them,
// as in the Extensions pane; the sidebar and detail content follow Xcode's
// Themes pane and CotEditor's Appearance pane
// (misc/frontend-refs/settings-xcode-themes.png,
// misc/frontend-refs/settings-coteditor-appearance.png).
//
// The sidebar leads with Defaults — not a theme, but the values a theme
// *inherits* when it assigns none of its own: fonts, line height, and the
// default syntax theme per appearance. Under it, three groups of themes:
//   - Editor — the editor chrome, one theme per appearance.
//   - Fonts — faces, sizes and line height; assigned by an editor theme.
//   - Code Syntax — code-block colors, one theme per appearance.
// The three are headers only, not destinations: once General holds what their
// members fall back to, a group as a whole has nothing left to show.
//
// Editor opens; the other two start closed. They hold themes an editor theme
// *assigns* rather than ones activated on their own, so they are reference
// material — consulted while authoring, not on the way to anything else.
//
// Selecting a theme puts it in use. It only ever replaces the theme for its own
// appearance, so choosing a light one cannot disturb which dark one is in use —
// which is why there is no enable/disable anywhere: an appearance always has
// exactly one theme, and picking another is the whole of the interaction.
//
// That leaves two themes in use at once while a list can highlight only the row
// you are looking at, so the dot in each row's leading gutter marks the pair.

import SwiftUI
import AppKit
import EdmundCore

struct ThemesSettingsView: View {

    /// Which sidebar row is showing in the detail box. `general` is a
    /// destination with no theme behind it, hence the enum rather than a bare
    /// theme name.
    enum Selection: Hashable {
        case editor(String)
        case syntax(String)
    }

    @State private var viewing: Selection = .editor(AppSettings.DefaultTheme.generalLight)
    @State private var editorExpanded = true
    /// Both collapsed, unlike Editor — see the note at the top of the file.
    /// Open, they push the list the pane exists for up the column.
    @State private var syntaxExpanded = false
    @State private var hoveredSection: String?
    @State private var confirmingRestore = false
    @State private var restoreScope: RestoreScope = .everything
    @State private var confirmingDelete = false
    @State private var renaming: String?
    @State private var renameText = ""
    @State private var edited: PendingEdit?
    @State private var saveTask: Task<Void, Never>?
    /// Starts at the Extensions sidebar's width, so the two panes open alike;
    /// theme names are longer than extension names, so this one is draggable
    /// from there. Never remembered — see `onAppear` on the body.
    @State private var sidebarWidth: CGFloat = SettingsSidebar.width
    @State private var dragStartWidth: CGFloat?
    @FocusState private var sidebarFocused: Bool

    /// Bumped to force the theme lists to re-read `ThemeStore` after an
    /// activation or a reload — the store is a plain class, not observable.
    @State private var storeVersion = 0

    @AppStorage(AppSettings.Key.themeGeneralLight) private var generalLight = AppSettings.DefaultTheme.generalLight
    @AppStorage(AppSettings.Key.themeGeneralDark) private var generalDark = AppSettings.DefaultTheme.generalDark
    @AppStorage(AppSettings.Key.themeSyntaxLight) private var syntaxLight = AppSettings.DefaultTheme.syntaxLight
    @AppStorage(AppSettings.Key.themeSyntaxDark) private var syntaxDark = AppSettings.DefaultTheme.syntaxDark

    private var editorThemes: [GeneralTheme] {
        _ = storeVersion
        return ThemeStore.shared.generalThemes()
    }

    private var syntaxThemes: [SyntaxTheme] {
        _ = storeVersion
        return ThemeStore.shared.syntaxThemes()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            boxes
            // Outside both boxes, like the Key Bindings pane's: it acts on the
            // whole pane — the General row and any built-in that has been
            // edited — not on whichever box has focus.
            Button("Restore Defaults…") { confirmingRestore = true }
                .disabled(!hasAnythingToRestore)
        }
        .padding(20)
        // Every settings pane is 600 wide, so switching tabs only ever resizes
        // the window vertically.
        .frame(width: 600)
        .focusEffectDisabled()
        .sheet(isPresented: $confirmingRestore) { restoreSheet }
    }

    private var boxes: some View {
        HStack(spacing: 0) {
            sidebar
            resizeHandle
            detail
        }
        // Sized to the tallest pane that has a natural end — the syntax theme's
        // ten color rows, measured at 268pt. The font theme's pane is half
        // again as tall once its nine per-script rows are counted, and it
        // scrolls: a settings pane that is simply long is ordinary on macOS,
        // and sizing every pane to the longest one left the others mostly
        // empty. Every settings pane is 600 *wide*; height is each pane's own,
        // and the window animates between them.
        .frame(height: 290)
        // The drag is a look-at-this-for-a-moment affordance, not a preference:
        // every visit starts at the width the pane was designed around, so a
        // one-off drag can't leave the sidebar permanently odd.
        .onAppear { sidebarWidth = SettingsSidebar.width }
        // The file goes, and nothing here can bring it back.
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: deleteSelected)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the theme's file. You can't undo this.")
        }
        .sheet(isPresented: Binding(get: { renaming != nil },
                                    set: { if !$0 { renaming = nil } })) {
            renameSheet
        }
    }

    // MARK: Restore

    /// What a restore puts back. Two scopes rather than one button because
    /// they answer different questions — "undo what I did to this theme" and
    /// "put the whole pane back" — and the second is much the larger hammer.
    enum RestoreScope: Hashable {
        case selectedTheme
        case everything
    }

    /// Any built-in, edited or not. Restoring an untouched one is a no-op
    /// rather than an error, and gating on "has been edited" would mean the
    /// option flickered in and out as the selection moved — the rule the user
    /// needs to learn is the simpler one: built-ins have an original to go
    /// back to, and themes you made do not.
    private var restorableSelection: String? {
        guard let name = selectedThemeName else { return nil }
        return ThemeStore.shared.isBuiltIn(name) ? name : nil
    }

    private var hasAnythingToRestore: Bool {
        restorableSelection != nil || hasEditedBuiltIns
    }

    private var hasEditedBuiltIns: Bool {
        _ = storeVersion
        let store = ThemeStore.shared
        return (store.generalThemes().map(\.name)
                + store.syntaxThemes().map(\.name))
            .contains { store.isEditedBuiltIn($0) }
    }

    private var restoreSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore Defaults").font(.headline)
            // Hand-built rather than a `.radioGroup` Picker: only one of the two
            // is ever unavailable, and a Picker disables all of its options or
            // none.
            VStack(alignment: .leading, spacing: 8) {
                radio(selectedRestoreLabel, .selectedTheme, enabled: restorableSelection != nil)
                radio("All built-in themes", .everything, enabled: true)
            }
            // Land on the one that can actually run.
            .onAppear { if restorableSelection == nil { restoreScope = .everything } }

            Text(restoreExplanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 340, alignment: .leading)

            HStack {
                Spacer()
                Button("Cancel") { confirmingRestore = false }
                    .keyboardShortcut(.cancelAction)
                Button("Restore", action: performRestore)
                    .keyboardShortcut(.defaultAction)
                    .disabled(restoreScope == .selectedTheme && restorableSelection == nil)
            }
        }
        .padding(20)
    }

    private func radio(_ title: String, _ scope: RestoreScope, enabled: Bool) -> some View {
        Button {
            restoreScope = scope
        } label: {
            HStack(spacing: 6) {
                Image(systemName: restoreScope == scope
                      ? "smallcircle.filled.circle.fill" : "circle")
                    .foregroundStyle(restoreScope == scope && enabled ? Color.accentColor
                                                                      : Color.secondary)
                Text(title)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var selectedRestoreLabel: String {
        guard let name = restorableSelection, let display = displayName(of: name) else {
            return "Selected theme only"
        }
        return "“\(display)” only"
    }

    /// Only what the radio's own label doesn't already say. "All built-in
    /// themes" is its own explanation; the one thing it leaves open is what
    /// happens to everything else.
    private var restoreExplanation: String {
        switch restoreScope {
        case .selectedTheme:
            return "Applies to built-in themes only."
        case .everything:
            return "Themes you created yourself are left alone."
        }
    }

    private func performRestore() {
        confirmingRestore = false
        switch restoreScope {
        case .selectedTheme:
            guard let name = restorableSelection else { return }
            try? ThemeStore.shared.restoreBuiltIn(named: name)
        case .everything:
            ThemeStore.shared.restoreAllBuiltIns()
        }
        storeVersion += 1
        AppSettings.applyThemesToOpenDocuments()
    }

    private var deleteTitle: String {
        guard let name = selectedThemeName, let display = displayName(of: name) else {
            return "Delete this theme?"
        }
        return "Delete “\(display)”?"
    }

    private var renameSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Theme").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(commitRename)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commitRename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    // MARK: Sidebar

    /// A `ScrollView` + `LazyVStack` with pinned section headers and a
    /// full-width square selection bar — the same construction as the Extensions
    /// sidebar, for the reasons documented there. A `.sidebar`-styled `List`
    /// would inset and round the selection into a pill, which at this width
    /// costs enough room to start truncating a theme's name plus its
    /// "(Light)"/"(Dark)" suffix.
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Xcode and CotEditor both caption this column (singular — it names
            // what a row is, not what the list holds).
            Text("Theme")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: Self.headerHeight)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    section("Editor", isExpanded: $editorExpanded, count: editorThemes.count) {
                        ForEach(editorThemes, id: \.name) { theme in
                            row(theme.label, selection: .editor(theme.name),
                                dot: isActive(theme), appearance: theme.appearance)
                        }
                    }
                    // No dots on these. An editor theme is the only thing
                    // activated directly; it names the syntax theme that goes
                    // with it, and the Defaults row holds what it falls back
                    // to — so a dot here would offer to turn on something
                    // already decided a level up. The gutter is still
                    // reserved, so these rows line up with the dotted ones.
                    section("Code Syntax", isExpanded: $syntaxExpanded, count: syntaxThemes.count) {
                        ForEach(syntaxThemes, id: \.name) { theme in
                            row(theme.label, selection: .syntax(theme.name),
                                dot: nil, appearance: theme.appearance)
                        }
                    }
                }
            }

            // No rule above the footer: Xcode's Themes list runs straight down
            // into its +/− (misc/frontend-refs/settings-xcode-themes.png). The
            // buttons are part of the list, not a separate bar under it.
            footer
        }
        .frame(width: sidebarWidth)
        .settingsSurfaceBackground()
        .border(.separator)
        .focusable()
        .focused($sidebarFocused)
        .onAppear { sidebarFocused = true }
        .onMoveCommand { direction in
            switch direction {
            case .up: selectNeighbor(step: -1)
            case .down: selectNeighbor(step: 1)
            default: break
            }
        }
    }

    /// Add, remove, and the rest — the same row of borderless glyphs the Syntax
    /// pane keeps under its definition list.
    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: duplicateSelected) { Image(systemName: "plus") }
                .help("New theme, copied from the selected one")
                .disabled(selectedThemeName == nil)
            Button { confirmingDelete = true } label: { Image(systemName: "minus") }
                .help("Delete the selected theme")
                .disabled(!selectionIsRemovable)
            Menu {
                Button("Rename…", action: beginRename)
                    .disabled(selectedThemeName == nil || selectionIsBuiltIn)
                Button("Duplicate", action: duplicateSelected)
                    .disabled(selectedThemeName == nil)
                Button("Show in Finder", action: revealSelected)
                    .disabled(!selectionHasFile)
                Divider()
                Button("Import…", action: importTheme)
                Button("Export…", action: exportSelected)
                    .disabled(selectedThemeName == nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(6)
        // Finder's bindings, since that is where the muscle memory for a list
        // of name-able things comes from. They live on the footer rather than
        // the list because a button is what carries a `keyboardShortcut`; the
        // sidebar has focus, and the window routes the key to them either way.
        .background {
            // Zero-sized and hidden: these exist only to own the shortcuts.
            // `.hidden()` alone would still let them take part in layout.
            Group {
                Button("", action: beginRename)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selectedThemeName == nil || selectionIsBuiltIn)
                Button("", action: duplicateSelected)
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(selectedThemeName == nil)
                Button("") { confirmingDelete = true }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!selectionIsRemovable)
                Button("", action: revealSelected)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!selectionHasFile)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    /// The gap between the two boxes, doubling as the drag target that resizes
    /// them. Nothing is drawn in it — the boxes' own borders already read as the
    /// edges being moved — but the pointer changes over it, which is what says
    /// it can be dragged at all.
    private var resizeHandle: some View {
        Color.clear
            .frame(width: Self.boxGap)
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        // Latched on the first change: `translation` is measured
                        // from where the drag began, so adding it to the current
                        // width every time would compound.
                        let base = dragStartWidth ?? sidebarWidth
                        dragStartWidth = base
                        sidebarWidth = min(max(base + drag.translation.width,
                                               Self.minSidebarWidth),
                                           Self.maxSidebarWidth)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .accessibilityHidden(true)
    }

    private static let boxGap: CGFloat = 12
    /// Narrow enough to be worth doing, wide enough that the detail box still
    /// holds its widest row — the font preview and its buttons.
    private static let minSidebarWidth: CGFloat = 120
    private static let maxSidebarWidth: CGFloat = 240

    /// One collapsible group. Collapsing clips the rows to zero height rather
    /// than removing them, so they slide out from under the header instead of
    /// fading over the rows they push down.
    @ViewBuilder
    private func section(_ title: String, isExpanded: Binding<Bool>, count: Int,
                         @ViewBuilder rows: () -> some View) -> some View {
        Section {
            VStack(spacing: 0) { rows() }
                .frame(height: isExpanded.wrappedValue
                       ? SettingsSidebar.rowHeight * CGFloat(count)
                       : 0,
                       alignment: .top)
                .clipped()
        } header: {
            SettingsSectionHeader(title: title, isExpanded: isExpanded, hoveredSection: $hoveredSection)
        }
    }

    /// One sidebar row. `dot == nil` is a row with nothing to activate; the
    /// gutter is still reserved, so every name starts on the same margin.
    private func row(_ label: String, selection: Selection,
                     dot: Bool?, appearance: ThemeAppearance = .light) -> some View {
        let isSelected = viewing == selection
        let isEmphasized = isSelected && sidebarFocused
        return SettingsSidebarRow(
            name: label,
            dotFilled: dot ?? false,
            isDimmed: false,
            isEmphasized: isEmphasized,
            dotAccessibilityLabel: appearance == .dark ? "In use for Dark" : "In use for Light",
            onDotTap: { if dot != nil { activate(selection) } }
        )
        .padding(.trailing, SettingsSidebar.rowTrailing)
        .frame(height: SettingsSidebar.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected
                    ? Color(nsColor: isEmphasized
                            ? .selectedContentBackgroundColor
                            : .unemphasizedSelectedContentBackgroundColor)
                    : .clear)
        .contentShape(Rectangle())
        .onTapGesture { select(selection) }
        .contextMenu {
            // Selecting a row already does this. The item is here for the same
            // reason Finder keeps "Open" in its menu with double-click bound:
            // it names the gesture's effect for anyone who does not know it,
            // and it is where the rest of theme management will hang.
            // Gated on being a theme, not on having a dot: a font theme has
            // no slot to be activated in but is renamed, duplicated and deleted
            // like any other. Only General, which is no theme at all, gets no
            // menu.
            if let name = themeName(of: selection) {
                if let dot {
                    Button("Make Active Theme") { activate(selection) }
                        .disabled(dot)
                    Divider()
                }
                Button("Rename…") { select(selection); beginRename() }
                    .disabled(ThemeStore.shared.isBuiltIn(name))
                Button("Duplicate") { select(selection); duplicateSelected() }
                Button("Delete…") { select(selection); confirmingDelete = true }
                    .disabled(ThemeStore.shared.isBuiltIn(name))
            }
        }
    }

    /// Selecting a theme shows it *and* puts it in use. There is no "off"
    /// state to reach: every appearance always has exactly one theme, and a
    /// theme only ever replaces the one for its own appearance, so choosing a
    /// light theme cannot disturb the dark one.
    private func select(_ new: Selection) {
        viewing = new
        sidebarFocused = true
        activate(new)
    }

    private func isActive(_ theme: GeneralTheme) -> Bool {
        theme.name == (theme.appearance == .dark ? generalDark : generalLight)
    }

    private func isActive(_ theme: SyntaxTheme) -> Bool {
        theme.name == (theme.appearance == .dark ? syntaxDark : syntaxLight)
    }

    /// Activation only ever replaces the slot matching the theme's own
    /// appearance, and only an editor theme has one. Everything else is chosen
    /// a level up — a font or syntax theme by the editor theme that names it,
    /// or by the General row — so for those this only changes what the detail
    /// box shows.
    private func activate(_ selection: Selection) {
        switch selection {
        case .syntax:
            return
        case .editor(let name):
            guard let theme = editorThemes.first(where: { $0.name == name }) else { return }
            if theme.appearance == .dark { generalDark = name } else { generalLight = name }
        }
        storeVersion += 1
        AppSettings.applyThemesToOpenDocuments()
    }

    // MARK: Editing

    /// The theme to draw, preferring an edit that has not reached disk yet over
    /// the store's copy — otherwise a dragged color would snap back to the last
    /// saved value between debounce ticks.
    private func editorTheme(named name: String) -> GeneralTheme? {
        if case .editor(let pending) = edited, pending.name == name { return pending }
        return editorThemes.first { $0.name == name }
    }

    private func syntaxTheme(named name: String) -> SyntaxTheme? {
        if case .syntax(let pending) = edited, pending.name == name { return pending }
        return syntaxThemes.first { $0.name == name }
    }

    /// Edits land here from the detail panes and are written after a pause.
    ///
    /// A color well fires on every pointer move inside it, and each write is a
    /// file write plus a full store reload plus a restyle of every open
    /// document — doing that per frame stutters the drag and thrashes the disk.
    /// The dragged color still shows immediately: `edited` is what the pane
    /// draws from, so only the *persisting* waits.
    private func scheduleSave(_ theme: GeneralTheme) {
        edited = .editor(theme)
        debounceSave { try ThemeStore.shared.save(theme) }
    }

    private func scheduleSave(_ theme: SyntaxTheme) {
        edited = .syntax(theme)
        debounceSave { try ThemeStore.shared.save(theme) }
    }

    private func debounceSave(_ write: @escaping () throws -> Void) {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                try write()
            } catch {
                Log.error("Saving theme failed: \(error)", category: .app)
                return
            }
            edited = nil
            storeVersion += 1
            AppSettings.applyThemesToOpenDocuments()
        }
    }

    /// The in-flight edit, so the pane draws what the well is showing rather
    /// than the last version that reached disk.
    enum PendingEdit {
        case editor(GeneralTheme)
        case syntax(SyntaxTheme)
    }

    // MARK: Theme management

    /// The theme the footer acts on, or nil when General is selected — it is
    /// not a theme and has no file.
    private var selectedThemeName: String? { themeName(of: viewing) }

    private func themeName(of selection: Selection) -> String? {
        switch selection {
        case .editor(let name), .syntax(let name): return name
        }
    }

    /// Only a theme the user created can be removed. A built-in the user has
    /// edited is *restored* instead — the bundled original is still there, so
    /// there is nothing to delete, only an edit to drop.
    private var selectionIsRemovable: Bool {
        guard let name = selectedThemeName else { return false }
        return ThemeStore.shared.isUserTheme(name) && !ThemeStore.shared.isBuiltIn(name)
    }

    /// Whether the selection is one of the app's own themes. A built-in keeps
    /// the name it ships under: it is what every release note and screenshot
    /// calls it, and a theme the user did not author is not theirs to retitle.
    /// Duplicate is the way to a theme with your own name on it.
    private var selectionIsBuiltIn: Bool {
        guard let name = selectedThemeName else { return false }
        return ThemeStore.shared.isBuiltIn(name)
    }

    /// Whether the selection has a file on disk for the Finder to show. A
    /// bundled theme lives inside the app, where nobody can be sent — but a
    /// built-in the user has *edited* has a real file shadowing it, and that one
    /// reveals fine. So the question is not "is it built in" but "is there a
    /// file", which is exactly what `isUserTheme` answers.
    private var selectionHasFile: Bool {
        guard let name = selectedThemeName else { return false }
        return ThemeStore.shared.isUserTheme(name)
    }

    private func duplicateSelected() {
        guard let name = selectedThemeName else { return }
        do {
            let copy = try ThemeStore.shared.duplicate(name)
            storeVersion += 1
            // Show the copy, and put it in use: duplicating is how you start
            // editing, and editing something you cannot see the effect of is
            // the wrong default.
            let selection: Selection
            switch ThemeStore.shared.kind(ofThemeNamed: copy) {
            case .syntax: selection = .syntax(copy)
            default: selection = .editor(copy)
            }
            select(selection)
        } catch {
            Log.error("Duplicating theme \(name) failed: \(error)", category: .app)
        }
    }

    /// Makes a syntax theme for an editor theme to pin, from the picker's
    /// "New Theme…" item.
    ///
    /// Copied from whatever that editor theme resolves to right now rather than
    /// from a blank: the point of pinning is usually to change a color or two,
    /// and starting from the colors already on screen is the shorter path to
    /// that. Selection follows the new theme, since making one is only ever a
    /// prelude to editing it.
    private func newSyntaxTheme(for editorTheme: GeneralTheme) {
        let dark = editorTheme.appearance == .dark
        let seed = editorTheme.syntaxTheme
            ?? (dark ? syntaxDark : syntaxLight)
        do {
            let created = try ThemeStore.shared.duplicate(seed)
            var edited = editorTheme
            edited.syntaxTheme = created
            try ThemeStore.shared.save(edited)
            storeVersion += 1
            select(.syntax(created))
            AppSettings.applyThemesToOpenDocuments()
        } catch {
            Log.error("Creating a syntax theme for \(editorTheme.name) failed: \(error)",
                      category: .app)
        }
    }

    private func deleteSelected() {
        guard let name = selectedThemeName else { return }
        let wasActive = [generalLight, generalDark, syntaxLight, syntaxDark].contains(name)
        do {
            try ThemeStore.shared.deleteUserTheme(named: name)
        } catch {
            Log.error("Deleting theme \(name) failed: \(error)", category: .app)
            return
        }
        // Hand any slot this theme held back to the built-in before the row
        // goes, or the appearance is left pointing at a theme that is gone.
        if wasActive {
            if generalLight == name { generalLight = AppSettings.DefaultTheme.generalLight }
            if generalDark == name { generalDark = AppSettings.DefaultTheme.generalDark }
            if syntaxLight == name { syntaxLight = AppSettings.DefaultTheme.syntaxLight }
            if syntaxDark == name { syntaxDark = AppSettings.DefaultTheme.syntaxDark }
        }
        viewing = .editor(generalLight)
        storeVersion += 1
        AppSettings.applyThemesToOpenDocuments()
    }

    private func beginRename() {
        guard let name = selectedThemeName else { return }
        renameText = displayName(of: name) ?? ""
        renaming = name
    }

    private func displayName(of name: String) -> String? {
        editorThemes.first { $0.name == name }?.displayName
            ?? syntaxThemes.first { $0.name == name }?.displayName
    }

    /// Renames the *display* name only. `name` is the filename and the value
    /// stored in settings, so moving it would orphan every reference.
    private func commitRename() {
        guard let name = renaming else { return }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !trimmed.isEmpty else { return }
        do {
            if var theme = editorThemes.first(where: { $0.name == name }) {
                theme.displayName = trimmed
                try ThemeStore.shared.save(theme)
            } else if var theme = syntaxThemes.first(where: { $0.name == name }) {
                theme.displayName = trimmed
                try ThemeStore.shared.save(theme)
            }
        } catch {
            Log.error("Renaming theme \(name) failed: \(error)", category: .app)
            return
        }
        storeVersion += 1
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.message = "Choose theme files to import."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { importTheme(from: url) }
        storeVersion += 1
    }

    /// Decoded before it is copied, so a malformed file is reported here rather
    /// than silently skipped by the loader at the next launch.
    private func importTheme(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        let kind: ThemeStore.Kind
        let name: String
        if let theme = try? decoder.decode(GeneralTheme.self, from: data) {
            kind = .general
            name = theme.name
        } else if let theme = try? decoder.decode(SyntaxTheme.self, from: data) {
            kind = .syntax
            name = theme.name
        } else {
            presentError("“\(url.lastPathComponent)” isn’t a theme file Edmund can read.")
            return
        }
        let destination = ThemeStore.userDirectory(kind).appendingPathComponent("\(name).json")
        do {
            try FileManager.default.createDirectory(at: ThemeStore.userDirectory(kind),
                                                    withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            ThemeStore.shared.reload()
        } catch {
            presentError("Couldn’t import “\(url.lastPathComponent)”: \(error.localizedDescription)")
        }
    }

    private func exportSelected() {
        guard let name = selectedThemeName,
              let source = ThemeStore.shared.fileURL(forName: name) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(name).json"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            presentError("Couldn’t export “\(name)”: \(error.localizedDescription)")
        }
    }

    private func revealSelected() {
        guard let name = selectedThemeName,
              let url = ThemeStore.shared.fileURL(forName: name) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Import Failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: Keyboard movement

    /// Every row the arrow keys can reach, in visual order. A collapsed group's
    /// themes are off screen, so they are not steppable either.
    private var visibleRows: [Selection] {
        var rows: [Selection] = []
        if editorExpanded { rows += editorThemes.map { Selection.editor($0.name) } }
        if syntaxExpanded { rows += syntaxThemes.map { Selection.syntax($0.name) } }
        return rows
    }

    private func selectNeighbor(step: Int) {
        let rows = visibleRows
        guard let index = rows.firstIndex(of: viewing) else { return }
        let next = rows[min(max(index + step, 0), rows.count - 1)]
        guard next != viewing else { return }
        select(next)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        Group {
            switch viewing {
            case .editor(let name):
                if let theme = editorTheme(named: name) {
                    // Scrolls rather than growing: the two boxes are pinned to
                    // one height, and without this a theme whose colors run
                    // long pushes the detail box past the sidebar's edges.
                    ScrollView {
                        GeneralThemeDetail(theme: theme,
                                           syntaxThemes: syntaxThemes,
                                           isEditable: true,
                                           onChange: scheduleSave,
                                           onNewSyntaxTheme: newSyntaxTheme)
                            .padding(16)
                    }
                } else {
                    missing
                }
            case .syntax(let name):
                if let theme = syntaxTheme(named: name) {
                    // Unpadded, unlike the other panes: this one paints the
                    // theme's own page and wants the box's full area.
                    SyntaxThemeDetail(theme: theme,
                                      isEditable: true,
                                      onChange: scheduleSave)
                } else {
                    missing
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .settingsSurfaceBackground()
        .border(.separator)
    }

    private var missing: some View {
        Text("This theme is no longer available.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The sidebar caption's height. It titled the detail box's columns too
    /// until that header came out; kept as its own constant because the
    /// caption's own height is still a deliberate number rather than whatever
    /// the text happens to measure.
    private static let headerHeight: CGFloat = 28
    private static let tableInset: CGFloat = 10
    private static let columnGap: CGFloat = 10
    /// Sized to "Code syntax (Light)", the longest label, so nothing truncates
    /// and the value column keeps everything that is left.
    private static let labelColumnWidth: CGFloat = 132

    /// Trailing-aligned, as the macOS settings grid has it: labels end against
    /// the gutter and values start after it. The read-out rows below match this
    /// edge and differ only in size, so the whole pane reads as one column.
    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .gridColumnAlignment(.trailing)
            .frame(width: Self.labelColumnWidth, alignment: .trailing)
    }


}


/// The T-in-a-window that Xcode's theme font row uses to open the font panel.
///
/// Drawn rather than loaded: `NSImage.fontPanelName` is the named AppKit image
/// for this, but on macOS 15 it vends an italic serif "A" instead, and no SF
/// Symbol pairs window chrome with a letter.
///
/// Every number below is measured off Xcode's own glyph
/// (misc/frontend-refs/settings-xcode-themes.png, the font row under the theme
/// list): a 28x26 px mask at 2x, so a 14x13 pt grid where one grid unit is one
/// point and the smallest feature — a title-bar dot, the border — is exactly
/// one of them.
struct FontPanelGlyph: View {
    var body: some View {
        GlyphShape()
            .fill(style: FillStyle(eoFill: true))
            .frame(width: 14, height: 13)
    }

    /// One even-odd path: the window is the outer rounded rect with its
    /// interior punched out, the dots punch back out of the title bar, and the
    /// T's strokes — being inside the punched interior — fill again.
    private struct GlyphShape: Shape {
        func path(in rect: CGRect) -> Path {
            let s = rect.width / 14
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: rect.minX + x * s, y: rect.minY + y * s,
                       width: w * s, height: h * s)
            }
            var path = Path()
            // The window: a 1pt border, corners cut by a single pixel at 2x.
            path.addRoundedRect(in: r(0, 0, 14, 13),
                                cornerSize: CGSize(width: 0.75 * s, height: 0.75 * s))
            path.addRect(r(1, 3, 12, 9))
            // Three dots, 1pt square, on a 2pt pitch.
            for i in 0..<3 { path.addRect(r(1 + CGFloat(i) * 2, 1, 1, 1)) }
            // A serif T: thin crossbar, a stub hanging off each of its ends,
            // the stem, and the foot. The pieces are butted, never overlapped —
            // an even-odd fill cancels where two of its own rects cross, which
            // punches holes in the letter rather than welding it.
            path.addRect(r(4, 4, 6, 0.5))
            path.addRect(r(4, 4.5, 1, 1.25))
            path.addRect(r(9, 4.5, 1, 1.25))
            path.addRect(r(6, 4.5, 2, 6))
            path.addRect(r(5, 10.5, 4, 0.5))
            return path
        }
    }
}
