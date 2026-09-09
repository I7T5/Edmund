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

/// One color as a well with its name beneath it.
///
/// The name goes under rather than beside because four of these have to fit
/// across the pane: label-beside-well needs about 550pt for a row of four, and
/// there are 376. That is the trade the two-row layout buys its compactness
/// with — the rest of Settings labels to the left.
private struct ColorCell: View {
    let label: String
    @Binding var hex: String?
    let systemFallback: NSColor
    let appearance: ThemeAppearance
    let isEditable: Bool

    private static let wellWidth: CGFloat = 40
    /// Sized to the longest name ("Background") at caption2.
    fileprivate static let cellWidth: CGFloat = 58

    private var resolved: NSColor {
        if let hex, let color = NSColor(hex: hex) { return color }
        var fallback = systemFallback
        NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)?
            .performAsCurrentDrawingAppearance {
                fallback = systemFallback.usingColorSpace(.deviceRGB) ?? systemFallback
            }
        return fallback
    }

    private var swatch: Binding<Color> {
        Binding(get: { Color(nsColor: resolved) },
                set: { hex = NSColor($0).hexString })
    }

    var body: some View {
        VStack(spacing: 3) {
            ColorPicker("", selection: swatch, supportsOpacity: false)
                .labelsHidden()
                .disabled(!isEditable)
                .frame(width: Self.wellWidth)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .frame(width: Self.cellWidth)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Two rows of four, labels under the wells, each closed by the
            // system-color box for its last well. The ink the editor lays down
            // on the first row, the surface and what marks it on the second.
            //
            // The box names its role — "Use system cursor", not "Use system
            // color" — because at the end of a row of four wells a generic
            // label reads as governing all of them. Under a single well the
            // owner was obvious; here it has to be said.
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: Self.cellGap) {
                    ColorCell(label: "Text", hex: color(\.text),
                              systemFallback: .textColor, appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Invisibles", hex: color(\.invisibles),
                              systemFallback: .tertiaryLabelColor, appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Background", hex: color(\.background),
                              systemFallback: .textBackgroundColor, appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Cursor", hex: color(\.cursor),
                              systemFallback: .controlAccentColor, appearance: theme.appearance,
                              isEditable: isEditable)
                    systemColorBox("System cursor", color(\.cursor),
                                   fallback: .controlAccentColor)
                }
                HStack(alignment: .center, spacing: Self.cellGap) {
                    ColorCell(label: "Checkbox", hex: color(\.checkbox),
                              systemFallback: .controlAccentColor, appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Link", hex: color(\.link),
                              systemFallback: .systemBlue, appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Highlight", hex: color(\.highlight),
                              systemFallback: .systemYellow.withAlphaComponent(0.3),
                              appearance: theme.appearance,
                              isEditable: isEditable)
                    ColorCell(label: "Selection", hex: color(\.selection),
                              systemFallback: .systemOrange.withAlphaComponent(0.3),
                              appearance: theme.appearance,
                              isEditable: isEditable)
                    systemColorBox("System selection", color(\.selection),
                                   fallback: .systemOrange.withAlphaComponent(0.3))
                }
            }

            // A rule, now that this is more than a row. Everything above edits
            // THIS theme's own colors; below it, the theme hands code off to a
            // different theme and shows what that one looks like — a real
            // boundary, and one the eye finds faster than the label does.
            //
            // Shown outright rather than behind an "Advanced" disclosure. One
            // popup is not worth hiding, and hiding it made a theme's most
            // consequential choice the one thing you had to go looking for.
            Divider()

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rowLabel("Code syntax")
                // Runs to the right margin, like the preview under it: the two
                // are one choice, and a popup stopping short of the sample it
                // controls left the row looking unfinished beside it.
                syntaxAssignment
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Full width, under both the label and the popup: a page of code is
            // what it is imitating, and a page runs to its margins. Boxed to
            // the popup's width it read as an attachment hanging off the
            // control rather than as the bottom of the pane.
            if let syntax = previewedSyntax {
                SyntaxSample(syntax: syntax,
                             background: theme.background,
                             appearance: theme.appearance)
            }
        }
    }

    fileprivate static let cellGap: CGFloat = 8

    /// The system-color box for one role, closing its row. Vertically centered
    /// on the cells beside it — well plus label — rather than pinned to the
    /// wells' line, which left it riding high above a two-line neighbour.
    private func systemColorBox(_ title: String, _ hex: Binding<String?>,
                                fallback: NSColor) -> some View {
        Toggle(title, isOn: Binding(
            get: { hex.wrappedValue == nil },
            set: { hex.wrappedValue = $0 ? nil : fallback.hexString }))
            .controlSize(.small)
            .disabled(!isEditable)
            .fixedSize()
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

    /// The syntax theme this one shows a palette of — the one it names, or the
    /// one it falls back to when it names none.
    private var previewedSyntax: SyntaxTheme? {
        let name = theme.syntaxTheme ?? resolvedSyntaxName
        return syntaxThemes.first { $0.name == name }
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

/// Two lines of code drawn in a syntax theme, on the editor theme's own page.
///
/// A preview rather than a set of swatches: it shows the colors doing the job
/// they are for, which is the only way to tell whether a theme is actually
/// legible — two colors that look distinct as rectangles can be hard to tell
/// apart as words. It previews the *pair*, too: syntax colors on this theme's
/// background, which is the combination the reader will really see.
///
/// The spans are fixed rather than run through `CodeHighlighter`: the scanner
/// is internal to EdmundCore, and this is a sample, not a claim about
/// tokenization. The lines are chosen to reach nine of the ten scopes.
private struct SyntaxSample: View {
    let syntax: SyntaxTheme
    let background: String?
    let appearance: ThemeAppearance

    private static let inset: CGFloat = 7

    /// Chosen for coverage: attribute, keyword, variable, type, number on the
    /// first line; command, string, comment on the second, with punctuation
    /// left plain. Short enough not to wrap at the popup's width.
    private var lines: [[(String, String)]] {
        [[("@State", syntax.attribute), (" ", syntax.plain),
          ("var", syntax.keyword), (" ", syntax.plain),
          ("count", syntax.variable), (": ", syntax.plain),
          ("Int", syntax.type), (" = ", syntax.plain),
          ("42", syntax.number)],
         [("print", syntax.command), ("(", syntax.plain),
          ("\"Hi\"", syntax.string), (", ", syntax.plain),
          ("count", syntax.variable), (")  ", syntax.plain),
          ("// ready", syntax.comment)]]
    }

    private var pageColor: NSColor {
        if let background, let color = NSColor(hex: background) { return color }
        return appearance == .dark
            ? NSColor(srgbRed: 0x29 / 255, green: 0x29 / 255, blue: 0x29 / 255, alpha: 1)
            : .textBackgroundColor
    }

    /// The pane's own surface, resolved for the appearance the Settings window
    /// is actually in — not the theme's, which may be the other one.
    private var paneColor: NSColor {
        var resolved = NSColor.controlBackgroundColor
        NSApplication.shared.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlBackgroundColor.usingColorSpace(.deviceRGB)
                ?? .controlBackgroundColor
        }
        return resolved
    }

    /// Only when the sample's page is close enough to the pane's to disappear
    /// into it. A theme of the other appearance draws its own edge — a rule
    /// around it there is a second line saying what the color already said.
    private var needsBorder: Bool {
        guard let page = pageColor.usingColorSpace(.deviceRGB),
              let pane = paneColor.usingColorSpace(.deviceRGB) else { return true }
        let distance = abs(page.redComponent - pane.redComponent)
            + abs(page.greenComponent - pane.greenComponent)
            + abs(page.blueComponent - pane.blueComponent)
        return distance < 0.3
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                line.reduce(Text("")) { text, span in
                    text + Text(span.0)
                        .foregroundColor(Color(nsColor: NSColor(hex: span.1) ?? .textColor))
                }
                .font(.system(size: 10, design: .monospaced))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
        .padding(.horizontal, Self.inset)
        .background(Color(nsColor: pageColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            if needsBorder {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
        }
        .accessibilityLabel("Sample code in \(syntax.displayName)")
    }
}
