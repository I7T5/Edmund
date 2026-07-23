import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EdmundCore

/// The "Syntax" pane: a master switch for non-GFM syntax with the individual
/// extension toggles in a 2-column grid beneath it. The master is centered over
/// the grid; clearing it disables (and grays) every toggle at once. GFM callout
/// alerts (NOTE/TIP/…) and ordinary image dimensions have no toggle — the former
/// is always on (core GFM), the latter rides the master switch directly.
struct SyntaxSettingsView: View {
    @AppStorage(AppSettings.Key.enableNonGFM)       private var enableNonGFM = true
    @AppStorage(AppSettings.Key.synFrontMatter)     private var frontMatter = true
    @AppStorage(AppSettings.Key.synMath)            private var math = true
    @AppStorage(AppSettings.Key.synMermaid)         private var mermaid = true
    @AppStorage(AppSettings.Key.synHighlight)       private var highlight = true
    @AppStorage(AppSettings.Key.synComment)         private var comment = true
    @AppStorage(AppSettings.Key.synWikilink)        private var wikilink = true
    @AppStorage(AppSettings.Key.synTag)             private var tag = true
    @AppStorage(AppSettings.Key.synBlockRef)        private var blockRef = true
    @AppStorage(AppSettings.Key.synFootnote)        private var footnote = true
    @AppStorage(AppSettings.Key.synObsidianCallout) private var obsidianCallout = true
    @AppStorage(AppSettings.Key.defaultCodeSyntax)  private var defaultCodeSyntax = "plain"

    /// The selected row in the "Available syntax" list (a language id).
    @State private var selectedSyntax: String?
    /// Bumped after an import/removal so the popup + list re-read the store.
    @State private var defsVersion = 0

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow(alignment: .firstTextBaseline) {
                Text("Markdown syntax:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Enable extended Markdown syntax (non-GFM)", isOn: $enableNonGFM)
                        .onChange(of: enableNonGFM) { applyFeatures() }
                        .padding(.top, -8)
                    // Parsed rather than left to `Text`'s own literal markdown
                    // handling, so `settingsLinkTinted()` can bring the link in
                    // line with every other link in Settings.
                    Text(AttributedString(
                        inlineMarkdown: "Opt-in support for [Obsidian-flavored Markdown](https://obsidian.md/help/obsidian-flavored-markdown)."
                    ).settingsLinkTinted())
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 340, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            GridRow {
                Color.clear.frame(width: 0, height: 0)   // empty leading cell
                // The feature grid sits below the master switch and indented
                // further in, so the toggles read as its children.
                featureGrid
                    .padding(.leading, 20)
                    .padding(.top, -4)   // tighten the gap under the compat note
                    .disabled(!enableNonGFM)
            }

            GridRow { Divider().gridCellColumns(2) }

            // Code-block highlighting: the default language for untagged fences,
            // and the list of installed language definitions (bundled + user).
            GridRow {
                Text("Default code syntax:").gridColumnAlignment(.trailing)
                Picker("", selection: $defaultCodeSyntax) {
                    ForEach(languages, id: \.id) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                .frame(width: boxWidth)   // match the list box below
                .onChange(of: defaultCodeSyntax) {
                    AppSettings.applyCodeSyntax()
                    refreshCodeBlocks()
                }
            }
            // Pull the box up toward its popup (the outer 18-pt row spacing is
            // too wide a gap here — see the CotEditor Format ref).
            GridRow(alignment: .top) {
                Text("Available syntaxes:").gridColumnAlignment(.trailing)
                    .padding(.top, -10)
                availableSyntaxList
                    .padding(.top, -10)
            }
        }
        .settingsPanePadding()
    }

    /// The installed languages, "Plain Text" first. `defsVersion` is read so an
    /// import/removal re-evaluates this list.
    private var languages: [(id: String, label: String)] {
        _ = defsVersion
        return SyntaxDefinitionStore.shared.availableLanguages()
    }

    /// Fixed width shared by the list box and the "Default code syntax" popup,
    /// matching CotEditor's 260-pt syntax box.
    private let boxWidth: CGFloat = 260
    /// One list row's height; the box shows exactly 5 (`rowHeight * 5`).
    private let rowHeight: CGFloat = 20

    /// The CotEditor-style list of definitions with a `+ − ✎` toolbar, closely
    /// following FormatSettingsView: a plain `List` with a `.border`, the toolbar
    /// pinned by a bottom safe-area bar with a full-width `Divider` above it.
    private var availableSyntaxList: some View {
        let defs = languages.filter { $0.id != "plain" }
        let selectionIsUser = selectedSyntax.map {
            SyntaxDefinitionStore.shared.isUserDefinition($0)
        } ?? false
        // CotEditor's FormatSettingsView box: a plain `List` over a white
        // background, a full-width `Divider`, then the +/−/✎ toolbar — the whole
        // stack wrapped by one `.border`. (CotEditor pins the toolbar with
        // `.safeAreaBar`, macOS 15+; this container reproduces the same look on
        // the macOS 14 target.)
        return VStack(spacing: 0) {
            List(selection: $selectedSyntax) {
                ForEach(defs, id: \.id) { lang in
                    // A tight dot + label (rather than `Label`, whose icon column
                    // reserves ~20pt and over-indents the text). The dot marks a
                    // user-customized syntax.
                    HStack(spacing: 5) {
                        Circle()
                            .frame(width: 4)
                            .foregroundStyle(.secondary)
                            .opacity(SyntaxDefinitionStore.shared.isUserDefinition(lang.id) ? 1 : 0)
                        Text(lang.label)
                    }
                    .listRowSeparator(.hidden)
                    // Tighten each row's vertical padding (default plain-list
                    // rows centre the text in a taller cell).
                    .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 8))
                    .tag(lang.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, rowHeight)
            .contentMargins(.vertical, 0, for: .scrollContent)  // no top inset → 5 full rows
            .frame(height: rowHeight * 5)

            Divider()
            HStack(spacing: 10) {
                Button(action: importDefinition) { Image(systemName: "plus") }
                    .help("Import a language definition (.json)")
                Button(action: removeDefinition) { Image(systemName: "minus") }
                    .help("Remove the selected user definition")
                    .disabled(!selectionIsUser)
                Button(action: revealDefinition) { Image(systemName: "pencil") }
                    .help("Show the definition's JSON file in the Finder")
                    // Built-ins are read-only inside the app bundle.
                    .disabled(!selectionIsUser)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: boxWidth)
        .settingsSurfaceBackground()
        .border(.separator)
    }

    private var featureGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                cell("Front matter (YAML)", $frontMatter)
                cell("==Highlight==", $highlight)
            }
            GridRow {
                cell("Math ($ & $$)", $math)
                cell("%%Comment%%", $comment)
            }
            GridRow {
                cell("[[Wikilink]]", $wikilink)
                cell("#tag", $tag)
            }
            GridRow {
                cell("Footnote [^1]", $footnote)
                cell("Block ^1", $blockRef)
            }
            GridRow {
                cell("Mermaid diagrams", $mermaid)
                cell("Obsidian callout > [!note]", $obsidianCallout)
            }
        }
    }

    /// One grid toggle. Left-aligned within its column (Grid aligns the columns);
    /// intrinsic width so the whole grid stays compact and centers under the
    /// master switch. Broadcasts on change.
    private func cell(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding)
            .onChange(of: binding.wrappedValue) { applyFeatures() }
            .gridColumnAlignment(.leading)
    }

    /// Pushes the assembled feature set into every open document's editor and
    /// Read view so the change takes effect immediately.
    private func applyFeatures() {
        let features = AppSettings.markdownFeatures
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.markdownFeatures = features
            document.refreshFormatBar()
            document.refreshReadView()
        }
    }

    /// Re-styles every open document's code blocks (Edit + Read) after the
    /// default language or the installed definitions changed.
    private func refreshCodeBlocks() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.rerenderStyles()
            document.refreshReadView()
        }
    }

    /// Reload the store from disk, refresh the UI, and re-highlight open docs.
    private func reloadDefinitions() {
        AppSettings.applyCodeSyntax()
        defsVersion += 1
        refreshCodeBlocks()
    }

    /// `+` — copy a chosen `.json` into the user syntaxes dir (overwriting a
    /// same-named file), then reload.
    private func importDefinition() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let src = panel.url else { return }

        let dir = SyntaxDefinitionStore.userDirectory
        let dest = dir.appendingPathComponent(src.lastPathComponent.lowercased())
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
        } catch {
            NSSound.beep()
            return
        }
        reloadDefinitions()
    }

    /// `−` — delete the selected user definition (built-ins have no file to remove).
    private func removeDefinition() {
        guard let id = selectedSyntax,
              SyntaxDefinitionStore.shared.isUserDefinition(id),
              let url = SyntaxDefinitionStore.shared.fileURL(forName: id) else { return }
        try? FileManager.default.removeItem(at: url)
        selectedSyntax = nil
        reloadDefinitions()
    }

    /// `✎` — reveal the selected user definition's JSON in the Finder. Enabled
    /// only for user defs (built-ins are read-only inside the app bundle).
    private func revealDefinition() {
        guard let id = selectedSyntax,
              SyntaxDefinitionStore.shared.isUserDefinition(id),
              let url = SyntaxDefinitionStore.shared.fileURL(forName: id) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
