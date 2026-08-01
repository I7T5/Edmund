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

    /// Where names and section titles start. The dot gutter lives to the left of
    /// it, so a row's name sits at the same margin whether or not a dot is drawn.
    private static let nameInset: CGFloat = 20
    /// The dot's column: `dotInset` from the box edge, `dotGutter` wide, with the
    /// 6pt dot at its leading edge. Tight — the dot belongs to the name beside
    /// it, and wider gaps read as its own column.
    private static let dotInset: CGFloat = 8
    private static let dotGutter: CGFloat = nameInset - dotInset
    /// Section titles sit at half the names' inset: outdented from the rows they
    /// head, so they read as a level above them rather than as another row.
    private static let headerInset: CGFloat = nameInset / 2
    private static let rowTrailing: CGFloat = 8
    private static let rowHeight: CGFloat = 24
    /// Sized to the longest extension name in prospect: "Advanced Tables"
    /// measures 103pt at the 13pt system font, and with `nameInset` and
    /// `rowTrailing` needs 135. The rest is slack — a longer name truncates
    /// rather than widening the pane, whose 600pt total is fixed.
    private static let sidebarWidth: CGFloat = 140
    /// The same curve and duration the Key Bindings pane animates its submenu
    /// disclosure with, so the two panes open and close alike. `.snappy` — a
    /// spring — was here first and read as abrupt next to it.
    private static let disclosureAnimation: Animation = .easeInOut(duration: 0.2)

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
        // Less at the bottom than the other edges: the footer button sits 10pt
        // under the boxes (the stack's spacing), so a full 20pt beneath it left
        // the row looking pushed up rather than centred in its own margin.
        .padding(EdgeInsets(top: 20, leading: 20, bottom: 12, trailing: 20))
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
        .frame(width: Self.sidebarWidth)
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
        selectedID = Self.neighbor(of: selectedID, in: visibleIDs, step: step) ?? selectedID
    }

    /// The row an arrow key should land on. Clamps at both ends rather than
    /// wrapping — a sidebar selection doesn't cycle — and enters from the near
    /// end when nothing is selected yet.
    ///
    /// `nonisolated` because it is a pure function of its arguments, and because
    /// SwiftUI's `View` is `@MainActor @preconcurrency`: on the toolchain CI uses
    /// that isolation is inferred for this static too, so the (synchronous,
    /// nonisolated) test suite couldn't call it — a build failure that does not
    /// reproduce under a newer local toolchain.
    nonisolated static func neighbor(of current: String?, in ids: [String], step: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return step > 0 ? ids.first : ids.last
        }
        return ids[min(max(index + step, 0), ids.count - 1)]
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
                       ? Self.rowHeight * CGFloat(items.count)
                       : 0,
                       alignment: .top)
                .clipped()
            } header: {
                sectionHeader(title, isExpanded: isExpanded)
            }
        }
    }

    /// A group's header: the title, and a chevron at the far trailing edge.
    ///
    /// Hand-built, so the chevron can sit there at all — `DisclosureGroup` and a
    /// sidebar list's outline groups both hang it at the *leading* edge and
    /// indent their children under it, with no API to move it.
    private func sectionHeader(_ title: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(Self.disclosureAnimation) { isExpanded.wrappedValue.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                    // Shown on hover only. Faded rather than removed, so the
                    // header's layout doesn't shift as the pointer arrives.
                    .opacity(hoveredSection == title ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            // Symmetric: the chevron sits as far off the trailing edge as the
            // title does off the leading one, so neither crowds the border.
            .padding(.horizontal, Self.headerInset)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // Not `.plain`: that style dims its whole label while the mouse is down,
        // and this label is the entire header row — so every toggle flashed the
        // title a lighter gray on the way down.
        .buttonStyle(.static)
        // A pinned header scrolls *over* the rows, so it needs its own backing or
        // they read through it. Opaque, not the frosted `.bar` Safari uses: a
        // translucent header takes its tint from whatever is behind it, so it
        // visibly changed color as the rows left from under it on collapse.
        .settingsSurfaceBackground()
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredSection = inside ? title : (hoveredSection == title ? nil : hoveredSection)
            }
        }
    }

    /// One selectable row, with the selection fill drawn here rather than by a
    /// List: full-width and square, like the Key Bindings menu list, emphasized
    /// only while the sidebar holds focus.
    private func row(_ ext: EdmundExtension) -> some View {
        let isSelected = selectedID == ext.id
        let isEmphasized = isSelected && sidebarFocused
        return ExtensionRow(
            name: ext.name,
            isEnabled: enabledIDs.contains(ext.id),
            isInstalled: ext.isInstalled,
            isEmphasized: isEmphasized,
            dotInset: Self.dotInset,
            dotGutter: Self.dotGutter,
            onToggle: { setEnabled($0, for: ext.id) }
        )
        .padding(.trailing, Self.rowTrailing)
        .frame(height: Self.rowHeight)
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

/// One sidebar row: a dot in its own leading gutter that toggles the extension
/// on its own tap — independent of selecting the row — then the name.
///
/// The dot occupies a real column rather than an offset overlay. An overlay
/// pushed outside the row's bounds still draws, but it stops reliably
/// hit-testing there, which would leave the toggle looking present and dead. A
/// fixed-width gutter every row reserves keeps the names aligned whether or not
/// a dot is drawn, which is what the overlay was for.
///
/// The dot is drawn only when the extension is enabled, and presence — not hue —
/// is what encodes that: a colored/gray pair would carry the state in hue alone,
/// the distinction red-green color blindness loses, while presence-vs-absence
/// survives that, grayscale, and low contrast. The name stays dimmed while
/// disabled so the row carries the state redundantly, and the tap target keeps
/// its size either way, so a disabled extension is still togglable here.
private struct ExtensionRow: View {
    let name: String
    let isEnabled: Bool
    let isInstalled: Bool
    let isEmphasized: Bool
    let dotInset: CGFloat
    let dotGutter: CGFloat
    let onToggle: (Bool) -> Void

    /// Explicit colors, not `.primary`/`.secondary`: the selection fill is drawn
    /// by hand here, so nothing else is going to adjust the label for it.
    /// A disabled extension is dimmed two steps down from an enabled one —
    /// tertiary, not secondary — so the difference is visible at a glance next to
    /// an enabled row rather than only in comparison. Dimming means *disabled*,
    /// so it applies only under "Installed": a recommended row has nothing to
    /// enable yet, and dimming it would read as a state it can't be in.
    private var labelColor: Color {
        if isEmphasized { return Color(nsColor: .selectedMenuItemTextColor) }
        return Color(nsColor: isEnabled || !isInstalled ? .labelColor : .tertiaryLabelColor)
    }

    /// Dimmer than the name it marks, so it reads as a quiet indicator rather
    /// than competing with the text — but the selected row's own text color
    /// while that row is emphasized, since a faint gray dot would sink into the
    /// accent fill entirely.
    private var dotColor: Color {
        isEmphasized ? Color(nsColor: .selectedMenuItemTextColor)
                     : Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(isEnabled ? dotColor : .clear)
                .frame(width: 6, height: 6)
                // A tap target wider and taller than the visible dot, filling
                // the gutter — the dot itself is too small to hit comfortably.
                .frame(width: dotGutter, height: Self.tapHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { onToggle(!isEnabled) }
                .accessibilityLabel(isEnabled ? "Enabled" : "Disabled")
                .accessibilityAddTraits(.isButton)

            Text(name)
                .foregroundStyle(labelColor)
                .lineLimit(1)
        }
        .padding(.leading, dotInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let tapHeight: CGFloat = 18
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
        .onReceive(NotificationCenter.default.publisher(for: .renderEngineChanged)) { _ in
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
                // A generic "download failed" would be technically true but
                // less useful when the payload was never published for this
                // build — that download can never succeed, so say so.
                downloadError = ext.payloadIsConfigured
                    ? "Download failed. Try again."
                    : "\(ext.name) isn't available in this build yet."
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
