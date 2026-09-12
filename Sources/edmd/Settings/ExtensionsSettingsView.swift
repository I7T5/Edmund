// The Extensions settings pane: a master-detail list of the app's optional
// extensions (today: "Advanced Math", the RaTeX engine option). Sidebar in
// the CotEditor/Safari style; detail pane modeled on Obsidian's plugin
// browser (misc/frontend-refs/obsidian-plugin-installed.png).

import SwiftUI
import AppKit
import EdmundCore

struct ExtensionsSettingsView: View {
    @State private var selectedID: String? = ExtensionRegistry.all.first?.id
    @State private var enabledIDs: Set<String> = AppSettings.enabledExtensionIDs
    @State private var installedExpanded = true
    @State private var recommendedExpanded = true
    /// Whether the sidebar holds keyboard focus. Drives both the arrow keys and
    /// the selection's emphasis, the way a list dims its selection when focus
    /// leaves it.
    @FocusState private var sidebarFocused: Bool
    /// Which section's header the pointer is over — its chevron is drawn only
    /// then. `nil` when the pointer is elsewhere.
    @State private var hoveredSection: String?

    private var selected: EdmundExtension? {
        ExtensionRegistry.all.first { $0.id == selectedID }
    }

    private var installed: [EdmundExtension] { ExtensionRegistry.all.filter(\.isInstalled) }
    private var recommended: [EdmundExtension] { ExtensionRegistry.all.filter { !$0.isInstalled } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Two separate boxes with the window background between and around
            // them, as in Safari's Extensions pane
            // (misc/frontend-refs/settings-safari-extensions.png), rather than
            // one panel filling the pane.
            HStack(spacing: 12) {
                sidebar
                detail
            }
            .frame(height: 300)

            HStack {
                Spacer()
                Button("More extensions…") {
                    // STUB: link to GitHub extensions repo for now.
                    // Extensions marketplace comes later.
                }
            }
        }
        // Even margins all round, as the pane originally had them: the
        // sidebar/detail boxes are the content, and a box wants the same air
        // under it as beside it.
        .padding(20)
        // Every settings pane is 600 wide, so switching tabs only ever resizes
        // the window vertically.
        .frame(width: 600)
        .focusEffectDisabled()
    }

    /// A `ScrollView` + `LazyVStack`, not a `List`, for one reason: pinned
    /// section headers. Safari's Extensions sidebar keeps the current group's
    /// header at the top while its rows scroll under it
    /// (misc/frontend-refs/settings-safari-extensions.png), and `pinnedViews` is
    /// the only way to get that — a macOS `List` floats group rows only in the
    /// `.sidebar` style, which also insets and rounds the selection into a pill
    /// instead of the full-width bar this pane wants.
    ///
    /// The cost is that selection and arrow keys are ours to draw and handle,
    /// which is what `row(_:)` and `onMoveCommand` below are for.
    private var sidebar: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    sidebarSection("Installed", items: installed, isExpanded: $installedExpanded)
                    sidebarSection("Recommended", items: recommended, isExpanded: $recommendedExpanded)
                }
            }
            // Keyboard movement has to bring its target into view itself; only a
            // List does that on its own.
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.snappy(duration: 0.18)) { proxy.scrollTo(id) }
            }
        }
        .frame(width: SettingsSidebar.width)
        .settingsSurfaceBackground()
        .border(.separator)
        // Focusable so the arrow keys arrive at all, and focused on appear
        // rather than left to the Tab order — Tab reaches the detail pane's
        // buttons first, so waiting for it would mean the arrows do nothing
        // until the user happened to Tab back around. The pane disables focus
        // rings, so this claims the keys without drawing a ring on the box.
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

    /// The rows the arrow keys can reach: a collapsed section's rows are not on
    /// screen, so they are not steppable either.
    private var visibleIDs: [String] {
        (installedExpanded ? installed.map(\.id) : [])
            + (recommendedExpanded ? recommended.map(\.id) : [])
    }

    private func selectNeighbor(step: Int) {
        selectedID = SettingsSidebar.neighbor(of: selectedID, in: visibleIDs, step: step) ?? selectedID
    }

    private var detail: some View {
        Group {
            if let selected {
                ExtensionDetailView(
                    ext: selected,
                    isEnabled: Binding(
                        get: { enabledIDs.contains(selected.id) },
                        set: { setEnabled($0, for: selected.id) }
                    )
                )
                .id(selected.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                Text("No extensions installed.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .settingsSurfaceBackground()
        .border(.separator)
    }

    /// One collapsible sidebar group. Omitted entirely when empty — an
    /// "Installed" header with nothing under it reads as a broken list.
    ///
    /// A real `Section` here, unlike the flat rows this used to emit: inside a
    /// `LazyVStack` a Section is only layout, so `pinnedViews` can pin its
    /// header and nothing owns a second collapsed state to disagree with
    /// `isExpanded`. (That disagreement is exactly what ruled Section out while
    /// this was a `.sidebar`-styled List, where a Section becomes an outline
    /// group with its own disclosure state.)
    @ViewBuilder
    private func sidebarSection(_ title: String, items: [EdmundExtension],
                                isExpanded: Binding<Bool>) -> some View {
        if !items.isEmpty {
            Section {
                // The rows are always built, and collapsing clips them to zero
                // height, so they slide out from under the header. Inserting and
                // removing them instead — the obvious spelling — fades them in
                // over the rows they push down, which is the same reason the
                // Key Bindings pane animates a height rather than a list's
                // contents.
                VStack(spacing: 0) {
                    ForEach(items, id: \.id) { row($0) }
                }
                .frame(height: isExpanded.wrappedValue
                       ? SettingsSidebar.rowHeight * CGFloat(items.count)
                       : 0,
                       alignment: .top)
                .clipped()
            } header: {
                SettingsSectionHeader(title: title, isExpanded: isExpanded, hoveredSection: $hoveredSection)
            }
        }
    }

    /// One selectable row, with the selection fill drawn here rather than by a
    /// List: full-width and square, like the Key Bindings menu list, emphasized
    /// only while the sidebar holds focus.
    private func row(_ ext: EdmundExtension) -> some View {
        let isSelected = selectedID == ext.id
        let isEmphasized = isSelected && sidebarFocused
        let isEnabled = enabledIDs.contains(ext.id)
        return SettingsSidebarRow(
            name: ext.name,
            dotFilled: isEnabled,
            isDimmed: !isEnabled,
            isEmphasized: isEmphasized,
            dotAccessibilityLabel: isEnabled ? "Enabled" : "Disabled",
            onDotTap: { setEnabled(!isEnabled, for: ext.id) }
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
        .onTapGesture {
            selectedID = ext.id
            sidebarFocused = true
        }
        .id(ext.id)
    }

    private func setEnabled(_ enabled: Bool, for id: String) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        AppSettings.setExtensionEnabled(id, enabled)
    }
}

/// One extension's detail pane, top to bottom: name, version line, short
/// description + "Learn more…", action buttons, then a specs block
/// (author/repository/size/last updated).
private struct ExtensionDetailView: View {
    let ext: EdmundExtension
    @Binding var isEnabled: Bool

    @State private var isInstalled: Bool
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var showingLongDescription = false

    init(ext: EdmundExtension, isEnabled: Binding<Bool>) {
        self.ext = ext
        self._isEnabled = isEnabled
        self._isInstalled = State(initialValue: ext.isInstalled)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ext.name)
                .font(.title2.bold())

            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle")
                if let downloadCount = ext.downloadCount {
                    Text("\(downloadCount)")
                    Text("·")
                }
                Text("v\(ext.version)")
                if isInstalled {
                    Text("(installed v\(ext.version))")
                }
            }
            .foregroundStyle(.secondary)
            .controlSize(.small)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(ext.summary.settingsLinkTinted())
                    .fixedSize(horizontal: false, vertical: true)
                if ext.longDescriptionURL != nil {
                    Button("Learn more…") { showingLongDescription = true }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .controlSize(.small)
                }
            }

            buttonRow

            Spacer().frame(height: 4)

            specs

            Spacer()
        }
        .sheet(isPresented: $showingLongDescription) {
            if let url = ext.longDescriptionURL {
                LongDescriptionSheet(title: ext.name, markdownURL: url)
            }
        }
        // `isInstalled` is a local snapshot so the button group doesn't
        // flicker on every SwiftUI re-evaluation; that snapshot only refreshes
        // on our own download()/uninstall() calls. An install can also finish
        // in the background outside this view (AppSettings.applyExtensionStates
        // re-installing a previously-enabled extension at launch) — catch that
        // by refreshing on the same notification that signals a real change.
        .onReceive(NotificationCenter.default.publisher(for: .mathEngineChanged)) { _ in
            isInstalled = ext.isInstalled
        }
    }

    @ViewBuilder
    private var buttonRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isInstalled {
                    if ext.hasUpdate {
                        Button("Update") { download() }
                    }
                    Button(isEnabled ? "Disable" : "Enable") { isEnabled.toggle() }
                    Button("Uninstall") { uninstall() }
                } else {
                    Button(isDownloading ? "Downloading…" : "Download") { download() }
                        .disabled(isDownloading)
                }
                if let donateURL = ext.donateURL {
                    Button("Donate") { NSWorkspace.shared.open(donateURL) }
                }
            }
            if let downloadError {
                Text(downloadError)
                    .foregroundStyle(.secondary)
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 300, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var specs: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let developer = ext.developer {
                specRow("Author") {
                    if let url = developer.profileURL {
                        Button(developer.name) { NSWorkspace.shared.open(url) }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    } else {
                        Text(developer.name)
                    }
                }
            }
            if let repo = ext.repositoryURL {
                specRow("Repository") {
                    Button(repo.absoluteString) { NSWorkspace.shared.open(repo) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
            if let size = ext.installedSizeDescription {
                specRow("Size") { Text(size) }
            }
            if let lastUpdated = ext.lastUpdated {
                specRow("Last updated") {
                    Text(lastUpdated, format: .relative(presentation: .named))
                }
            }
        }
        .foregroundStyle(.secondary)
        .controlSize(.small)
    }

    @ViewBuilder
    private func specRow(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack(spacing: 4) {
            Text("\(label):")
            value()
        }
    }

    private func download() {
        isDownloading = true
        downloadError = nil
        Task {
            await ext.download()
            isDownloading = false
            if ext.isInstalled {
                isInstalled = true
            } else {
                // Only real extension today; a generic "download failed"
                // would be technically true but less useful here — say why.
                downloadError = RaTeXRelease.isConfigured
                    ? "Download failed. Try again."
                    : "RaTeX isn't available in this build yet."
            }
        }
    }

    private func uninstall() {
        // Disable first: MathRendering would fall back to SwiftMath on its
        // own once the renderer stops reporting ready, but leaving the
        // persisted "enabled" flag set would make a fresh install of the
        // same extension silently come back on.
        if isEnabled { isEnabled = false }
        Task {
            await ext.uninstall()
            isInstalled = ext.isInstalled
        }
    }
}

/// A markdown README fetched from `markdownURL` and rendered in a themed
/// popup webview — reuses Edmund's own Read-mode markdown→HTML pipeline
/// (`ReadModeWebView`) rather than a second, weaker renderer.
private struct LongDescriptionSheet: View {
    let title: String
    let markdownURL: URL
    @State private var markdown: String?
    @State private var loadError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Group {
                if let markdown {
                    ReadModeWebViewRepresentable(markdown: markdown)
                } else if let loadError {
                    Text(loadError)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 640, height: 480)
        .task {
            do {
                let (data, _) = try await URLSession.shared.data(from: markdownURL)
                markdown = String(data: data, encoding: .utf8) ?? ""
            } catch {
                loadError = "Couldn't load the description."
            }
        }
    }
}

/// Wraps `ReadModeWebView` (Edmund's own themed, JS-disabled markdown→HTML
/// renderer — already public) for SwiftUI. Mirrors `ContentWidthSlider`'s
/// `NSViewRepresentable` pattern in AppearanceSettingsView.swift.
private struct ReadModeWebViewRepresentable: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> ReadModeWebView {
        let view = ReadModeWebView()
        view.render(markdown: markdown, theme: .default, callouts: Callout.defaultStyles)
        return view
    }

    func updateNSView(_ view: ReadModeWebView, context: Context) {
        view.render(markdown: markdown, theme: .default, callouts: Callout.defaultStyles)
    }
}
