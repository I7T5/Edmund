// The three theme detail panes for Settings ▸ Themes: the seven editor-chrome
// colors of a general theme, the ten code scopes of a syntax theme, and the two
// faces of a font theme. The color panes are laid out as CotEditor's Appearance
// pane does it — two columns of label + swatch
// (misc/frontend-refs/settings-coteditor-appearance.png).
//
// Built-in themes are read-only: their wells are disabled, and the way to
// change one is to duplicate it and edit the copy. A user theme's wells are
// live, and every change is written back through `onChange`, which the pane
// debounces before it touches the disk — a color well fires continuously while
// the pointer moves inside it.
//
// Neither pane names the theme it is showing. The selected sidebar row already
// does, and repeating it costs a title's worth of height on a pane whose colors
// have to fit a fixed box — the same reading Xcode's Themes pane and
// CotEditor's Appearance pane make. Extensions still titles its detail, where
// the name sits over a description, a version and links rather than a grid.

import SwiftUI
import AppKit
import EdmundCore

/// A color well and its label. `hex == nil` means the theme leaves the role to
/// the platform — the well still shows the resolved color, and for the two roles
/// where deferring is a choice rather than the only sensible default, a
/// checkbox under the well says so, as CotEditor's Appearance pane does it.
private struct ColorRow: View {
    let label: String
    @Binding var hex: String?
    let systemFallback: NSColor
    let appearance: ThemeAppearance
    let isEditable: Bool
    /// Whether this role offers "Use system color" at all. Only Selection and
    /// Cursor do: every other role has a definite color that a theme is
    /// expected to name, so a checkbox there would be a switch with one
    /// meaningful position.
    var offersSystemColor = false
    /// The label column's width. Fixed rather than intrinsic so the block's
    /// total width is a constant this file can hand to the row below it — see
    /// `GeneralThemeDetail.blockWidth`.
    var labelWidth: CGFloat

    /// The width of the drawn swatch, measured off the rendered pane.
    private static let wellWidth: CGFloat = 40

    /// Resolved against the *theme's* appearance rather than whatever the
    /// Settings window happens to be in, so a dark theme's swatches show the
    /// colors it actually paints when that theme is in use.
    private var resolved: NSColor {
        if let hex, let color = NSColor(hex: hex) { return color }
        var fallback = systemFallback
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)?
            .performAsCurrentDrawingAppearance {
                fallback = systemFallback.usingColorSpace(.deviceRGB) ?? systemFallback
            }
        return fallback
    }

    /// Picking a color always assigns one, including on a row that was showing
    /// a system color — that is what unchecking the box below amounts to.
    private var swatch: Binding<Color> {
        Binding(get: { Color(nsColor: resolved) },
                set: { hex = NSColor($0).hexString })
    }

    /// Checking it drops the theme's own color; unchecking seeds one from
    /// whatever was on screen, so the well does not jump when the box is
    /// cleared.
    private var usesSystemColor: Binding<Bool> {
        Binding(get: { hex == nil },
                set: { hex = $0 ? nil : resolved.hexString })
    }

    @ViewBuilder
    var body: some View {
        GridRow {
            Text("\(label):")
                .frame(width: labelWidth, alignment: .trailing)
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            // The stock color well, so these read as the same control the rest
            // of macOS edits a color with.
            ColorPicker("", selection: swatch, supportsOpacity: false)
                .labelsHidden()
                .disabled(!isEditable)
                // Pinned to the swatch it draws: left to itself a hidden-label
                // ColorPicker still lays out wider than the well, which put the
                // column's trailing edge — and so the checkbox right-aligned to
                // it below — well past the color it belongs to.
                .frame(width: Self.wellWidth)
        }
        if offersSystemColor {
            // A row of its own spanning both columns, as CotEditor has it: the
            // checkbox is wider than the well, so it runs back under the label
            // instead of widening the well's column, and its right edge lands
            // on the well's.
            GridRow {
                Toggle("Use system color", isOn: usesSystemColor)
                    .controlSize(.small)
                    .disabled(!isEditable)
                    .fixedSize()
                    // Pulled up against the well it belongs to. The grid's row
                    // spacing is the gap *between* colors, and leaving it here
                    // read as the checkbox floating between two of them rather
                    // than hanging off the one above — CotEditor keeps them
                    // nearly touching.
                    .padding(.top, -4)
                    .gridCellColumns(2)
                    // `gridCellAnchor`, not a trailing `frame(maxWidth:
                    // .infinity)`: that makes the cell greedy, which makes the
                    // whole grid greedy, and the checkbox then right-aligns to
                    // the stretched edge instead of to the well.
                    .gridCellAnchor(.trailing)
            }
        }
    }
}

/// Drives the shared font panel for a theme's own font override.
///
/// `NSFontManager` is an app-wide singleton with a single target, the same
/// shape as `NSColorPanel` above — so the target is set on every open rather
/// than once, and whoever opened last owns it. That is also why the current
/// font is held here: `changeFont` is handed a manager to convert *from*
/// something, and the panel does not remember what.
@MainActor
private final class ThemeFontPanel: NSObject, ObservableObject {
    private var current: NSFont = .systemFont(ofSize: 16)
    private var onChange: ((NSFont) -> Void)?

    func open(_ font: NSFont, onChange: @escaping (NSFont) -> Void) {
        current = font
        self.onChange = onChange
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(font, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    @objc private func changeFont(_ sender: NSFontManager) {
        current = sender.convert(current)
        onChange?(current)
    }
}

// MARK: - General theme

struct GeneralThemeDetail: View {
    let theme: GeneralTheme
    let syntaxThemes: [SyntaxTheme]
    let isEditable: Bool
    let onChange: (GeneralTheme) -> Void
    /// Asked to make a syntax theme for this editor theme to name, when the
    /// picker's last item is chosen.
    let onNewSyntaxTheme: (GeneralTheme) -> Void


    /// One color of the theme, as something a well can write through. Edits go
    /// to a copy and straight back out via `onChange`; this view never owns the
    /// theme, so there is no second copy to fall out of step with the store.
    private func color(_ path: WritableKeyPath<GeneralTheme, String?>) -> Binding<String?> {
        Binding(get: { theme[keyPath: path] },
                set: { new in
                    var edited = theme
                    edited[keyPath: path] = new
                    onChange(edited)
                })
    }

    /// The two label columns, sized to their own longest label ("Background:"
    /// and "Highlight:"), and the gap between the pairs. Constants rather than
    /// intrinsic widths because the row beneath has to match the total, and a
    /// greedy child cannot ask for it without making the whole block greedy and
    /// undoing the trailing alignment.
    private static let inkLabelWidth: CGFloat = 88
    private static let markLabelWidth: CGFloat = 78
    private static let columnGap: CGFloat = 36
    private static let wellColumn: CGFloat = 10 + 40

    private static var blockWidth: CGFloat {
        inkLabelWidth + wellColumn + columnGap + markLabelWidth + wellColumn
    }

    var body: some View {
        // Set against the box's trailing edge, as CotEditor's Appearance pane
        // is. The wells are the thing being compared down the pane, so they
        // want one edge to line up on; left-aligned they sat in the middle of
        // the box with the slack all on the right.
        //
        // `fixedSize` horizontally is what makes the row below able to match
        // this block's width: it pins the stack to its ideal width — the width
        // of the two grids — so a greedy child fills that rather than making
        // the whole stack greedy and undoing the alignment.
        VStack(alignment: .leading, spacing: 12) {
            // Two columns, as CotEditor's Appearance pane has them: the ink the
            // editor lays down on the left, the surface and what marks it on
            // the right.
            HStack(alignment: .top, spacing: Self.columnGap) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ColorRow(label: "Text", hex: color(\.text),
                             systemFallback: .textColor, appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.inkLabelWidth)
                    ColorRow(label: "Invisibles", hex: color(\.invisibles),
                             systemFallback: .tertiaryLabelColor, appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.inkLabelWidth)
                    ColorRow(label: "Background", hex: color(\.background),
                             systemFallback: .textBackgroundColor, appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.inkLabelWidth)
                    ColorRow(label: "Cursor", hex: color(\.cursor),
                             systemFallback: .controlAccentColor, appearance: theme.appearance,
                             isEditable: isEditable, offersSystemColor: true,
                             labelWidth: Self.inkLabelWidth)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    ColorRow(label: "Checkbox", hex: color(\.checkbox),
                             systemFallback: .controlAccentColor, appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.markLabelWidth)
                    ColorRow(label: "Link", hex: color(\.link),
                             systemFallback: .systemBlue, appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.markLabelWidth)
                    ColorRow(label: "Highlight", hex: color(\.highlight),
                             systemFallback: .systemYellow.withAlphaComponent(0.3),
                             appearance: theme.appearance,
                             isEditable: isEditable, labelWidth: Self.markLabelWidth)
                    ColorRow(label: "Selection", hex: color(\.selection),
                             systemFallback: .systemOrange.withAlphaComponent(0.3),
                             appearance: theme.appearance,
                             isEditable: isEditable, offersSystemColor: true,
                             labelWidth: Self.markLabelWidth)
                }
            }

            // Labelled, and with no rule above it: one row under the wells
            // is not a second section, and the label is what says the popup
            // names code colors rather than anything else on the pane.
            //
            // Shown outright rather than behind an "Advanced" disclosure. One
            // popup is not worth hiding, and hiding it made a theme's most
            // consequential choice the one thing you had to go looking for.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rowLabel("Code syntax")
                // Runs out to the wells' own trailing edge, so the pane has one
                // right margin rather than two. Greedy inside a fixed-width
                // row, which is what keeps it from widening the block.
                syntaxAssignment
                    .frame(maxWidth: .infinity)
            }
            .frame(width: Self.blockWidth)
            // Set down from the wells by more than the gap between their own
            // rows. It is a row of the same pane, not a section of its own, but
            // at the grid's spacing it read as a ninth color.
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// What this theme's code colors resolve to when it names none — so the
    /// popup shows the theme actually in use rather than an empty selection.
    /// Choosing anything writes a name, so it stops being nil at the first
    /// touch.
    private var resolvedSyntaxName: String {
        let shipped = theme.appearance == .dark
            ? AppSettings.DefaultTheme.syntaxDark
            : AppSettings.DefaultTheme.syntaxLight
        if syntaxThemes.contains(where: { $0.name == shipped }) { return shipped }
        return syntaxThemes.first { $0.appearance == theme.appearance }?.name ?? ""
    }

    /// The tag for the trailing "New Theme…" item. A tag no theme can carry —
    /// theme names come from filenames — so picking it is unambiguous.
    private static let newThemeTag = "\u{0}new"

    /// Which syntax theme this one pins, if any. "Default" is a real choice,
    /// not a placeholder: it means the theme assigns none and takes whatever
    /// General holds for the current appearance.

    @ViewBuilder
    private var syntaxAssignment: some View {
        if isEditable {
            Picker("", selection: Binding(
                get: { theme.syntaxTheme ?? resolvedSyntaxName },
                set: { new in
                    // Not a value to store — a command. Making one is the
                    // pane's job: it has to create the theme, assign it here
                    // and select it in the sidebar, in that order.
                    guard new != Self.newThemeTag else { onNewSyntaxTheme(theme); return }
                    var edited = theme
                    edited.syntaxTheme = new.isEmpty ? nil : new
                    onChange(edited)
                })) {
                // Only themes of this theme's own appearance: pinning a light
                // syntax theme to a dark editor theme is never what was meant.
                ForEach(syntaxThemes.filter { $0.appearance == theme.appearance }, id: \.name) {
                    Text($0.displayName).tag($0.name)
                }
                // No rule above it: it belongs with the themes it is a way of
                // getting another of.
                //
                // "New Theme…", not "Custom…": the ellipsis promises something
                // opens, and what it makes is a theme like the ones above it,
                // not a nameless one-off. Title case, as every macOS menu item
                // is — the sentence case elsewhere in this pane is for form
                // labels, which follow the opposite rule.
                Text("New Theme…").tag(Self.newThemeTag)
            }
            .labelsHidden()
            // The height is load-bearing: at `.controlSize(.small)` the popup
            // reserves less than its bezel draws, so its bottom edge and the
            // shadow under it were clipped away while the side borders ran on —
            // a box open at the bottom. Sized to the bezel instead of to what
            // the layout thought it needed. The width is the row's to divide.
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        } else {
            Text(assignedSyntaxLabel ?? "Default")
                .foregroundStyle(assignedSyntaxLabel == nil ? .tertiary : .primary)
        }
    }

    /// "Default" is not a placeholder for an unknown value — it is the value:
    /// the theme assigns nothing here and takes whatever General holds.
    private func inheritedRow(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text("\(label):")
                .gridColumnAlignment(.trailing)
                .foregroundStyle(.secondary)
            Text(value ?? "Default")
                .foregroundStyle(value == nil ? .tertiary : .primary)
        }
    }

    private var assignedSyntaxLabel: String? {
        guard let assigned = theme.syntaxTheme else { return nil }
        return syntaxThemes.first { $0.name == assigned }?.label ?? assigned
    }
}

// MARK: - Shared row pieces

/// The name column. Trailing-aligned against the controls, and fixed so every
/// row of a table shares one column edge.
private func rowLabel(_ title: String) -> some View {
    Text("\(title):")
        .gridColumnAlignment(.trailing)
        .foregroundStyle(.secondary)
        // Outside a Grid there is no column to hold this open, and a squeezed
        // HStack will happily wrap it to one character per line.
        .fixedSize()
}

/// The face, drawn at the label's size rather than the theme's. The row is
/// where you read *which* font this is; the size is in the text beside it, and
/// previewing at 32pt would shove every row under this one down the pane as
/// soon as someone picked a large body font.
private func preview(_ font: NSFont) -> NSFont {
    NSFont(descriptor: font.fontDescriptor, size: NSFont.systemFontSize) ?? font
}

/// The *family*, not the styled face: "Iowan Old Style", never "Iowan Old
/// Style Roman". A theme names a family and the editor synthesizes the weights,
/// which is also what the per-script rows store — and the style word was long
/// enough to truncate the well it has to share with a ligature checkbox.
private func summary(_ font: NSFont) -> String {
    let name = font.familyName ?? font.displayName ?? font.fontName
    return "\(name)  \(Int(font.pointSize.rounded()))"
}

// MARK: - Syntax theme

/// Owns the shared `NSColorPanel` while a code scope is being edited.
///
/// One panel exists per app, so the row that opened it last is the one it
/// edits — rebinding target and action on each open is how AppKit expects this
/// to work. The binding is dropped when the pane goes away, so a panel left
/// open afterwards cannot fire into a stale closure.
@MainActor
private final class ScopeColorPanel: NSObject, ObservableObject {
    /// Which scope is open, so the list can mark the row whose color the panel
    /// is currently showing.
    @Published var editing: String?
    private var onChange: ((NSColor) -> Void)?
    /// `NSColorPanel` exposes `setTarget` but not `target`, so whether we are
    /// still the one it calls has to be remembered rather than asked.
    private var isBound = false

    func open(_ scope: String, color: NSColor, onChange: @escaping (NSColor) -> Void) {
        editing = scope
        self.onChange = onChange
        isBound = true
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    func release() {
        editing = nil
        onChange = nil
        guard isBound else { return }
        isBound = false
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        onChange?(sender.color)
    }
}

/// The code scopes, one per row, each drawn in its own color on the page the
/// theme will actually be read against — Xcode's Themes pane, which previews
/// itself rather than carrying a preview alongside.
///
/// Clicking a row opens the color panel on that scope. There are ten of them,
/// so ten wells would be ten controls competing with the colors they set; the
/// row *is* the control, and the color it shows is the value.
struct SyntaxThemeDetail: View {
    let theme: SyntaxTheme
    let isEditable: Bool
    let onChange: (SyntaxTheme) -> Void

    @StateObject private var panel = ScopeColorPanel()
    @State private var hovered: String?

    /// One column, in reading order rather than alphabetical: plain text
    /// first, since it is what everything the scanner produced no token for
    /// falls back to.
    private static let scopes: [(String, WritableKeyPath<SyntaxTheme, String>)] = [
        ("Plain Text", \.plain), ("Keywords", \.keyword), ("Commands", \.command),
        ("Types", \.type), ("Attributes", \.attribute), ("Variables", \.variable),
        ("Values", \.value), ("Numbers", \.number), ("Strings", \.string),
        ("Comments", \.comment),
    ]

    /// The page this theme's code sits on: the editor theme's background for
    /// the same appearance, so the contrast shown here is the contrast you get.
    private var page: Color {
        let general = ThemeStore.shared.general(dark: theme.appearance == .dark)
        if let hex = general.background, let color = NSColor(hex: hex) {
            return Color(nsColor: color)
        }
        var resolved = NSColor.textBackgroundColor
        NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)?
            .performAsCurrentDrawingAppearance {
                resolved = NSColor.textBackgroundColor.usingColorSpace(.deviceRGB)
                    ?? .textBackgroundColor
            }
        return Color(nsColor: resolved)
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Self.scopes, id: \.0) { label, path in
                row(label, path)
            }
        }
        .padding(.vertical, 8)
        // No border, no rounded corners, no inset: the page fills the detail
        // box the way the editor fills its window. A framed slab would read as
        // a preview *of* the theme sitting inside the pane; this reads as the
        // pane being the theme.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(page)
        .onDisappear { panel.release() }
        // Another theme in the same pane is another set of colors; the panel
        // would otherwise keep writing into the one that opened it.
        .onChange(of: theme.name) { _, _ in panel.release() }
    }

    private func row(_ label: String,
                     _ path: WritableKeyPath<SyntaxTheme, String>) -> some View {
        let isOpen = panel.editing == label
        return Text(label)
            // Monospaced: every one of these names stands for something that
            // only ever appears inside a code block.
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(nsColor: NSColor(hex: theme[keyPath: path]) ?? .textColor))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .background(rowFill(isOpen: isOpen, isHovered: hovered == label))
            .contentShape(Rectangle())
            .onHover { inside in hovered = inside ? label : (hovered == label ? nil : hovered) }
            .onTapGesture { open(label, path) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens the color panel for \(label)")
    }

    /// Drawn over the theme's own page, so the cue is translucent rather than a
    /// system fill: an opaque selection color would hide the contrast the row
    /// exists to show.
    private func rowFill(isOpen: Bool, isHovered: Bool) -> Color {
        if isOpen { return Color.accentColor.opacity(0.30) }
        if isHovered && isEditable { return Color.primary.opacity(0.08) }
        return .clear
    }

    private func open(_ label: String, _ path: WritableKeyPath<SyntaxTheme, String>) {
        guard isEditable else { return }
        let current = NSColor(hex: theme[keyPath: path]) ?? .textColor
        panel.open(label, color: current) { picked in
            var edited = theme
            edited[keyPath: path] = picked.hexString
            onChange(edited)
        }
    }
}
