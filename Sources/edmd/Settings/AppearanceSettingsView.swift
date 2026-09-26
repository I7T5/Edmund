// The Appearance settings pane: appearance mode, fonts, and line height.
// The app accent comes from the AccentColor asset (see Resources/Assets.xcassets),
// so there is no in-app accent picker — native controls follow the asset / system.

import SwiftUI
import AppKit
import EdmundCore

struct AppearanceSettingsView: View {
    @ObservedObject var fonts: FontSettings
    @AppStorage(AppSettings.Key.appearanceMode) private var appearanceMode = AppSettings.AppearanceMode.matchSystem
    @AppStorage(AppSettings.Key.maxContentWidthCm) private var maxContentWidthCm = AppSettings.defaultMaxContentWidthCm
    /// "" follows the locale; "cm"/"in" override it (toggled via the unit button).
    @AppStorage(AppSettings.Key.contentWidthUnit) private var unitOverride = ""
    /// The font preset in force. Always names one: everything below the divider
    /// is its contents, and a picker reading blank while the fonts are set
    /// would say nothing true. Choosing one here is choosing it — there is no
    /// separate "use this" step.
    @AppStorage(AppSettings.Key.themeFont) private var fontTheme = AppSettings.DefaultTheme.font

    @State private var fontThemes: [FontTheme] = []
    /// The tag for the popup's trailing "New Font Theme…" item. A tag no theme
    /// can carry — names come from filenames — so picking it is unambiguous.
    private static let newThemeTag = "\u{0}new"
    @State private var renamingTheme = false
    /// The script row the pointer last picked. Selection, not state: nothing
    /// reads it but the highlight, which is what tells a reader the box is a
    /// table and a double click will do something.
    @State private var selectedScript: FontCascadeScript?
    @State private var newThemeName = ""

    /// Every label in the pane gets this fixed width, so the "Fonts by script"
    /// rows can appear/disappear without re-sizing the Grid's label column
    /// (which would slide every row sideways as the section opens). Sized to
    /// fit the pane's widest label ("Max content width:").
    static let labelColumnWidth: CGFloat = 130

    // MARK: - Unit helpers

    /// Imperial when the user picked "in", metric when "cm", else the locale default.
    private var usesImperial: Bool {
        switch unitOverride {
        case "in": return true
        case "cm": return false
        default:   return Locale.current.measurementSystem == .us
        }
    }
    private func toggleUnit() { unitOverride = usesImperial ? "cm" : "in" }

    private var unitLabel: String { usesImperial ? "in" : "cm" }
    /// Stepper increment in display units (0.5 cm ≈ 0.25 in).
    private var stepSize: Double { usesImperial ? 0.25 : 0.5 }

    /// Lower bound ≈ 3 inches (7.62 cm); upper bound is the full physical width
    /// of the main display, so the column can be capped anywhere up to the
    /// screen edge.
    private var minCm: Double { 7.62 }
    private var maxCm: Double { NSScreen.main?.physicalWidthCm ?? 50 }
    private var displayRange: ClosedRange<Double> {
        usesImperial ? (minCm / 2.54)...(maxCm / 2.54) : minCm...maxCm
    }

    /// Magnetic snap target in display units: 5 in / 12 cm (the default width).
    private var snapDisplayValue: Double { usesImperial ? 5.0 : 12.0 }

    /// Two-way binding between stored cm and the display unit.
    private var displayValueBinding: Binding<Double> {
        Binding(
            get: { usesImperial ? maxContentWidthCm / 2.54 : maxContentWidthCm },
            set: { maxContentWidthCm = usesImperial ? $0 * 2.54 : $0 }
        )
    }

    var body: some View {
        // Every column-2 cell is maxWidth: .infinity: the 544pt content box is
        // wider than the collapsed content, and the Grid hands the slack to
        // whichever column can grow. If that is the label column, opening
        // "Fonts by script" (whose rows out-width the rest) takes the slack
        // back and every column-2 control slides sideways.
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 12) {
            GridRow {
                Text("Appearance:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                Picker("", selection: $appearanceMode) {
                    ForEach(AppSettings.AppearanceMode.displayOrder) { Text($0.label).tag($0) }
                }
                .accessibilityLabel("Appearance")
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .onChange(of: appearanceMode) { AppSettings.applyAppearance() }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
                Text("Max content width:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                HStack(spacing: 8) {
                    ContentWidthSlider(
                        cmValue: $maxContentWidthCm,
                        usesImperial: usesImperial,
                        displayRange: displayRange,
                        snapDisplayValue: snapDisplayValue
                    )
                    .frame(width: 200, height: 20)

                    // Field width is sized so its stepper's chevrons line up
                    // vertically with the font rows' steppers (slider 200 + two
                    // 8-pt gaps + field == 240, the font rows' label width).
                    TextField("", value: displayValueBinding,
                              format: .number.precision(.fractionLength(1)))
                        .accessibilityLabel("Max content width")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 32)
                    Stepper("", value: displayValueBinding,
                            in: displayRange, step: stepSize)
                        .accessibilityLabel("Max content width")
                        .labelsHidden()
                    // Clickable unit toggle styled exactly like a plain label —
                    // .plain strips all button chrome so only the text shows.
                    Button(action: toggleUnit) { Text(unitLabel) }
                        .buttonStyle(.plain)
                        .help("Switch between centimetres and inches")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: maxContentWidthCm) { applyContentWidthToOpenDocuments() }
            }

            GridRow {
                Text("Font theme:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                HStack(spacing: 8) {
                    // 240 to match the font rows' preview field below, so the
                    // three boxes share one edge.
                    Picker("", selection: $fontTheme) {
                        ForEach(fontThemes, id: \.name) { Text($0.displayName).tag($0.name) }
                        Divider()
                        // The same trailing item the code-syntax popup has:
                        // making one belongs with choosing one. It starts from
                        // what is on screen — the selected preset always is —
                        // and asks for a name straight away, which is the one
                        // thing a copy cannot supply for itself.
                        Text("New Font Theme…").tag(Self.newThemeTag)
                    }
                    .accessibilityLabel("Font theme")
                    .labelsHidden()
                    .frame(width: 240)
                    .onChange(of: fontTheme) { previous, name in
                        if name == Self.newThemeTag {
                            newTheme(from: previous)
                            return
                        }
                        guard let chosen = fontThemes.first(where: { $0.name == name }) else { return }
                        fonts.apply(preset: chosen)
                    }
                    // One size for the whole preset, the way iA Writer and
                    // Obsidian offer one: the standard size is the anchor, and
                    // the monospaced and per-script sizes scale with it. No
                    // field of its own — it sits where the font rows' steppers
                    // sit, and the numbers in the fields below are its readout,
                    // which is what makes a nudge here legible. The rows below
                    // still change each on its own.
                    Stepper("", value: Binding(
                        get: { Double(fonts.standardFont.pointSize) },
                        set: { fonts.scaleAllSizes(toStandard: CGFloat($0)) }),
                        in: 8...72, step: 1)
                        .accessibilityLabel("Font size")
                        .labelsHidden()
                        .help("Scale every font size together")
                    fontThemeMenu
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Standard font:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    fontRow(summary: fonts.standardSummary, sizeLabel: "Standard font size",
                            font: fonts.standardFont,
                            antialias: fonts.antialias,
                            size: Binding(get: { Double(fonts.standardFont.pointSize) },
                                          set: { fonts.setStandardSize(CGFloat($0)) }),
                            select: fonts.selectStandardFont)
                    HStack(spacing: 16) {
                        Toggle("Antialias", isOn: $fonts.antialias)
                        Toggle("Ligatures", isOn: $fonts.standardLigatures)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
                Text("Monospaced font:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    fontRow(summary: fonts.monospaceSummary, sizeLabel: "Monospaced font size",
                            font: fonts.monospaceFont,
                            antialias: fonts.antialias,
                            size: Binding(get: { Double(fonts.monospaceFont.pointSize) },
                                          set: { fonts.setMonospaceSize(CGFloat($0)) }),
                            select: fonts.selectMonospaceFont)
                    HStack(spacing: 16) {
                        Toggle("Antialias", isOn: $fonts.antialias)
                        Toggle("Ligatures", isOn: $fonts.monospaceLigatures)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GridRow {
                Text("Line height:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                HStack(spacing: 6) {
                    let lineHeight = Binding(get: { Double(fonts.lineHeight) },
                                             set: { fonts.setLineHeight(CGFloat($0)) })
                    TextField("", value: lineHeight, format: .number.precision(.fractionLength(1)))
                        .accessibilityLabel("Line height")
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: lineHeight, in: 1...3, step: 0.1)
                        .accessibilityLabel("Line height")
                        .labelsHidden()
                    Text("times")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            fontCascadeSection
        }
        // The tab is wider than this grid, and all of the slack was landing on
        // the right. Nudged so the block sits nearer the middle of it.
        .padding(.leading, 20)
        .settingsPanePadding()
        .onAppear {
            fontThemes = ThemeStore.shared.fontThemes()
            // Told, not applied: the values are already live, and re-applying
            // on every visit would overwrite an edit made since.
            fonts.editingPreset = fontTheme
        }
        .alert("Rename Font Theme", isPresented: $renamingTheme) {
            TextField("Name", text: $newThemeName)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { commitThemeRename() }
        }
    }

    /// Duplicate / Rename / Delete — what the Themes pane's footer gives its
    /// own lists. A menu rather than a row of buttons: these are rare beside
    /// the picker they act on.
    private var fontThemeMenu: some View {
        Menu {
            Button("Duplicate") { duplicateTheme() }
            Button("Rename…") {
                newThemeName = fontThemes.first { $0.name == fontTheme }?.displayName ?? ""
                renamingTheme = true
            }
                // A built-in keeps the name it ships under; Duplicate is the
                // way to one with your own name on it.
                .disabled(ThemeStore.shared.isBuiltIn(fontTheme))
            Divider()
            Button("Delete", role: .destructive) { deleteTheme() }
                // A bundled theme lives inside the app: there is nothing to
                // delete, and removing the last one would leave the picker with
                // nothing to name.
                .disabled(!ThemeStore.shared.isUserTheme(fontTheme) || fontThemes.count < 2)
        } label: {
            // System Settings' own "more" button: the circled ellipsis in the
            // secondary tint, with no chevron — it is a button that opens a
            // menu, not a popup showing a value.
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        // `tint`, not `foregroundStyle`: the borderless menu button draws its
        // label in the control tint and ignores the label's own style.
        .tint(.secondary)
        .fixedSize()
        .help("Manage font themes")
    }

    private func duplicateTheme() {
        guard let copy = try? ThemeStore.shared.duplicate(fontTheme) else { return }
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
    }

    /// A copy of `source` — the preset that was selected when "New Font
    /// Theme…" was picked, and so exactly the typography on screen — selected
    /// and put up for naming. Selecting it is what moves the popup off the
    /// sentinel; `onChange` then applies it, a no-op, since it already is what
    /// is live.
    private func newTheme(from source: String) {
        guard let copy = try? ThemeStore.shared.duplicate(source) else {
            fontTheme = source
            return
        }
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
        newThemeName = ""
        renamingTheme = true
    }

    private func commitThemeRename() {
        let trimmed = newThemeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var theme = fontThemes.first(where: { $0.name == fontTheme }) else { return }
        // The display name only: `name` is the filename and the value stored in
        // settings, so moving it would orphan the selection.
        theme.displayName = trimmed
        try? ThemeStore.shared.save(theme)
        fontThemes = ThemeStore.shared.fontThemes()
    }

    private func deleteTheme() {
        let going = fontTheme
        guard let next = fontThemes.first(where: { $0.name != going }) else { return }
        fontTheme = next.name
        fonts.apply(preset: next)
        try? ThemeStore.shared.deleteUserTheme(named: going)
        fontThemes = ThemeStore.shared.fontThemes()
    }

    /// Pushes a content-width change to every open editor live, converting cm
    /// to points using each editor's window screen PPI (or main screen as fallback).
    private func applyContentWidthToOpenDocuments() {
        for case let document as Document in NSDocumentController.shared.documents {
            let screen = document.editor?.window?.screen ?? NSScreen.main
            guard let screen else { continue }
            document.editor?.maxContentWidthPoints = screen.cmToPoints(maxContentWidthCm)
            document.refreshReadView(immediately: true)
        }
    }

    @ViewBuilder
    private func fontRow(summary: String, sizeLabel: String, font: NSFont, antialias: Bool,
                         size: Binding<Double>, select: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            AntialiasingText(summary)
                .antialiasDisabled(!antialias)
                .font(nsFont: font)
                .frame(width: 240)
            Stepper("", value: size, in: 8...72, step: 1)
                .accessibilityLabel(sizeLabel)
                .labelsHidden()
            Button("Select…", action: select)
                .fixedSize()
        }
    }
}

// MARK: - Continuous NSSlider

/// Wraps NSSlider so the content-width control can use cm/in units and a
/// magnetic snap onto the default value.
private struct ContentWidthSlider: NSViewRepresentable {
    @Binding var cmValue: Double
    let usesImperial: Bool
    let displayRange: ClosedRange<Double>
    /// Magnetic snap target in display units (the default width); dragging
    /// within `snapTolerance` of it locks onto it exactly.
    let snapDisplayValue: Double
    private var snapTolerance: Double { usesImperial ? 0.15 : 0.4 }

    func cmToDisplay(_ cm: Double) -> Double { usesImperial ? cm / 2.54 : cm }
    func displayToCm(_ d: Double) -> Double  { usesImperial ? d * 2.54 : d }

    /// Snap `display` onto the default value when it lands close enough.
    func snapped(_ display: Double) -> Double {
        abs(display - snapDisplayValue) < snapTolerance ? snapDisplayValue : display
    }

    private func clamp(_ v: Double) -> Double {
        max(displayRange.lowerBound, min(displayRange.upperBound, v))
    }

    func makeNSView(context: Context) -> NSSlider {
        NSSlider(value: clamp(cmToDisplay(cmValue)),
                 minValue: displayRange.lowerBound,
                 maxValue: displayRange.upperBound,
                 target: context.coordinator,
                 action: #selector(Coordinator.sliderChanged(_:)))
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        // Range changes when the unit is toggled (cm ↔ in).
        slider.minValue = displayRange.lowerBound
        slider.maxValue = displayRange.upperBound
        let display = clamp(cmToDisplay(cmValue))
        if abs(slider.doubleValue - display) > 0.001 {
            slider.doubleValue = display
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ContentWidthSlider
        init(parent: ContentWidthSlider) { self.parent = parent }

        @objc func sliderChanged(_ sender: NSSlider) {
            let snapped = parent.snapped(sender.doubleValue)
            if snapped != sender.doubleValue { sender.doubleValue = snapped }
            parent.cmValue = parent.displayToCm(snapped)
        }
    }
}

// MARK: - Fonts by script (per-script cascade)

extension AppearanceSettingsView {

    /// The "Fonts by script" group: a bordered, scrolling list of one row per
    /// script, in the shape of the Syntax pane's "Available syntaxes" box.
    ///
    /// A list rather than nine more form rows. Per-script fonts are overrides
    /// to the Standard/Monospaced fonts above, not nine more top-level
    /// settings, and nine right-aligned form labels made them read as the
    /// latter — while making this pane far taller than the other six. Inside
    /// the box the script name is the row's first column, so the group reads as
    /// one object beside a single label.
    ///
    /// The box still lives in the pane's OWN Grid cell, and every column-2 cell
    /// in the pane stays `maxWidth: .infinity` (see `body`) so the label column
    /// can never absorb the pane's slack and slide every row sideways.
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
    /// The font rows' preview fields are 240, and this sits under them; one
    /// edge for all three.
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
