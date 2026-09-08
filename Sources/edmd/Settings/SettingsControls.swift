// Shared Settings view helpers.

import SwiftUI

/// The shared surface color for Settings boxes — the Syntax list, the Key
/// Bindings nav/header/table, the Extensions panel.
///
/// `.controlBackgroundColor` is what the Key Bindings nav list already drew by
/// default, and it is the color the rest of Settings is matched to. Notably it
/// is *not* the editor's canvas color: Settings is chrome, not document
/// surface, and matching the document made the boxes read as editable content.
extension View {
    func settingsSurfaceBackground() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Draws the label and nothing else — no pressed-state dimming.
///
/// For buttons whose label *is* the whole control, like a section header: the
/// built-in `.plain` style fades the entire label while the mouse is down, which
/// on a header reads as the title flickering rather than as a press.
struct StaticButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

extension ButtonStyle where Self == StaticButtonStyle {
    static var `static`: StaticButtonStyle { StaticButtonStyle() }
}

extension AttributedString {
    /// Recolors link runs to the app's accent, so a markdown link in Settings
    /// body text matches the `.foregroundStyle(.tint)` link buttons beside it —
    /// the Extensions pane's Author and Repository rows, say.
    ///
    /// `.tint` on the surrounding `Text` does not do this: a link run carries
    /// its own platform-blue foreground, and only setting the run's
    /// `foregroundColor` outright replaces it.
    func settingsLinkTinted() -> AttributedString {
        var copy = self
        // Ranges are collected before mutating: writing to `copy` inside a loop
        // over `copy.runs` mutates the collection being iterated.
        for range in copy.runs.filter({ $0.link != nil }).map(\.range) {
            copy[range].foregroundColor = .accentColor
        }
        return copy
    }
}

// MARK: - Sidebar + Detail Panes

/// The metrics shared by every Settings pane built as a sidebar beside a detail
/// box — Extensions, Themes. They were tuned once, on Extensions, against
/// Safari's Extensions pane (misc/frontend-refs/settings-safari-extensions.png);
/// a second pane picking its own would read as a different app.
enum SettingsSidebar {
    /// Where names and section titles start. The dot gutter lives to the left of
    /// it, so a row's name sits at the same margin whether or not a dot is drawn.
    static let nameInset: CGFloat = 20
    /// The dot's column: `dotInset` from the box edge, `dotGutter` wide, with the
    /// 6pt dot at its leading edge. Tight — the dot belongs to the name beside
    /// it, and wider gaps read as its own column.
    static let dotInset: CGFloat = 8
    static let dotGutter: CGFloat = nameInset - dotInset
    /// Section titles sit at half the names' inset: outdented from the rows they
    /// head, so they read as a level above them rather than as another row.
    static let headerInset: CGFloat = nameInset / 2
    static let rowTrailing: CGFloat = 8
    static let rowHeight: CGFloat = 24
    static let width: CGFloat = 140
    /// The same curve and duration the Key Bindings pane animates its submenu
    /// disclosure with, so the panes open and close alike. `.snappy` — a spring —
    /// was here first and read as abrupt next to it.
    static let disclosureAnimation: Animation = .easeInOut(duration: 0.2)

    /// The row an arrow key should land on. Clamps at both ends rather than
    /// wrapping — a sidebar selection doesn't cycle — and enters from the near
    /// end when nothing is selected yet.
    ///
    /// `nonisolated` because it is a pure function of its arguments, and because
    /// SwiftUI's `View` is `@MainActor @preconcurrency`: on the toolchain CI uses
    /// that isolation is inferred for a static declared on a View, so the
    /// (synchronous, nonisolated) test suite couldn't call it — a build failure
    /// that does not reproduce under a newer local toolchain. Living on a plain
    /// enum sidesteps the inference entirely.
    nonisolated static func neighbor(of current: String?, in ids: [String], step: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return step > 0 ? ids.first : ids.last
        }
        return ids[min(max(index + step, 0), ids.count - 1)]
    }
}

/// One sidebar row: a dot in its own leading gutter that acts on its own tap —
/// independent of selecting the row — then the name.
///
/// The dot occupies a real column rather than an offset overlay. An overlay
/// pushed outside the row's bounds still draws, but it stops reliably
/// hit-testing there, which would leave the control looking present and dead. A
/// fixed-width gutter every row reserves keeps the names aligned whether or not
/// a dot is drawn, which is what the overlay was for.
///
/// Presence — not hue — encodes the dot's state: a colored/gray pair would carry
/// it in hue alone, the distinction red-green color blindness loses, while
/// presence-vs-absence survives that, grayscale, and low contrast. `isDimmed`
/// carries the same state redundantly in the label, and the tap target keeps its
/// size either way so an "off" row is still actionable.
///
/// Extensions reads the dot as enabled/disabled; Themes reads it as the theme
/// active in its light or dark slot.
struct SettingsSidebarRow: View {
    let name: String
    let dotFilled: Bool
    let isDimmed: Bool
    let isEmphasized: Bool
    /// What the dot does and is called — "Enabled", "Active for Light", …
    let dotAccessibilityLabel: String
    let onDotTap: () -> Void

    /// Explicit colors, not `.primary`/`.secondary`: the selection fill is drawn
    /// by hand by the caller, so nothing else is going to adjust the label for
    /// it. A dimmed row goes two steps down — tertiary, not secondary — so the
    /// difference is visible at a glance next to a normal row rather than only in
    /// comparison.
    private var labelColor: Color {
        if isEmphasized { return Color(nsColor: .selectedMenuItemTextColor) }
        return Color(nsColor: isDimmed ? .tertiaryLabelColor : .labelColor)
    }

    /// Dimmer than the name it marks, so it reads as a quiet indicator rather
    /// than competing with the text — but the selected row's own text color while
    /// that row is emphasized, since a faint gray dot would sink into the accent
    /// fill entirely.
    private var dotColor: Color {
        isEmphasized ? Color(nsColor: .selectedMenuItemTextColor)
                     : Color(nsColor: .tertiaryLabelColor)
    }

    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .fill(dotFilled ? dotColor : .clear)
                .frame(width: 6, height: 6)
                // A tap target wider and taller than the visible dot, filling the
                // gutter — the dot itself is too small to hit comfortably.
                .frame(width: SettingsSidebar.dotGutter, height: Self.tapHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDotTap)
                .accessibilityLabel(dotAccessibilityLabel)
                .accessibilityAddTraits(.isButton)

            Text(name)
                // The size Xcode's Themes list uses, which is also the size of
                // the "Theme" caption above these rows and of the section
                // headers between them — one text size for the whole sidebar
                // (misc/frontend-refs/settings-xcode-themes.png). At body size
                // a row shouted next to its own header.
                .font(.subheadline)
                .foregroundStyle(labelColor)
                .lineLimit(1)
        }
        .padding(.leading, SettingsSidebar.dotInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let tapHeight: CGFloat = 18
}

/// A sidebar group's header: the title, and a chevron at the far trailing edge.
///
/// Hand-built, so the chevron can sit there at all — `DisclosureGroup` and a
/// sidebar list's outline groups both hang it at the *leading* edge and indent
/// their children under it, with no API to move it.
struct SettingsSectionHeader: View {
    let title: String
    @Binding var isExpanded: Bool
    /// Which header the pointer is over, shared across the sidebar's headers so
    /// only one chevron shows at a time.
    @Binding var hoveredSection: String?
    var body: some View {
        Button {
            withAnimation(SettingsSidebar.disclosureAnimation) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    // Shown on hover only, collapsed or not — the convention
                    // Finder and Mail follow, where a sidebar section reveals
                    // its Show/Hide affordance as the pointer arrives and is
                    // otherwise a bare title. Faded rather than removed, so the
                    // header's layout doesn't shift on the way in.
                    .opacity(hoveredSection == title ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            // Symmetric: the chevron sits as far off the trailing edge as the
            // title does off the leading one, so neither crowds the border.
            .padding(.horizontal, SettingsSidebar.headerInset)
            .frame(height: SettingsSidebar.rowHeight)
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
}

extension View {
    /// Consistent pane padding: CotEditor-style breathing room (scene padding at
    /// the top, a little more on the sides and bottom).
    func settingsPanePadding() -> some View {
        self.padding(EdgeInsets(top: 20, leading: 28, bottom: 28, trailing: 28))
            .frame(width: 600, alignment: .leading)
            // Don't auto-focus (and draw a focus ring around) the first control
            // when a pane opens — Settings has no use for keyboard-focus rings.
            .focusEffectDisabled()
    }
}
