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
    /// The font preset last chosen. Always names one, even while the popup
    /// reads Custom: it is what Custom was edited from, and what the Manage
    /// sheet opens on. Choosing one here is choosing it — there is no
    /// separate "use this" step.
    @AppStorage(AppSettings.Key.themeFont) private var fontTheme = AppSettings.DefaultTheme.font

    @State private var fontThemes: [FontTheme] = []
    /// The tag for the popup's trailing "New Font Theme…" item. A tag no theme
    /// can carry — names come from filenames — so picking it is unambiguous.
    private static let newThemeTag = "\u{0}new"
    private static let customTag = "\u{0}custom"
    @State private var managingThemes = false
    /// Set when "New Font Theme…" opens the sheet, so it asks for the new
    /// theme's name as it appears.
    @State private var namingNewTheme = false

    /// Every label in the pane gets this fixed width, so the label column
    /// never takes a share of the pane's slack. Sized to fit the pane's
    /// widest label ("Max content width:").
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
        // wider than the content, and the Grid hands the slack to whichever
        // column can grow — which must not be the label column.
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
                    // The popup and the size buttons span the width row's
                    // slider, field and stepper: the buttons at their own
                    // size against the stepper's trailing edge, the popup
                    // taking the rest. An invisible copy of that row sets the
                    // span, so Manage… then starts where the font rows'
                    // Select… buttons do.
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 200, height: 0)
                        Color.clear.frame(width: 32, height: 0)
                        Stepper("", value: .constant(0)).labelsHidden()
                    }
                    .hidden()
                    .accessibilityHidden(true)
                    .overlay { HStack(spacing: 8) { fontThemePicker; fontSizeButtons.fixedSize() } }
                    Button("Manage…") { managingThemes = true }
                        .fixedSize()
                        .help("Manage font themes")
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
                    Self.fontRow(summary: fonts.standardSummary, sizeLabel: "Standard font size",
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
                    Self.fontRow(summary: fonts.monospaceSummary, sizeLabel: "Monospaced font size",
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
                Self.lineHeightField(fonts)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The tab is wider than this grid, and all of the slack was landing on
        // the right. Nudged so the block sits nearer the middle of it.
        .padding(.leading, 20)
        .settingsPanePadding(help: HelpAnchor.appearance)
        .onAppear {
            fontThemes = ThemeStore.shared.fontThemes()
            // Told, not applied: the values are already live, and re-applying
            // on every visit would overwrite an edit made since.
            fonts.editingPreset = fontTheme
        }
        // Selecting a theme in the sheet writes `fontTheme`, and the picker's
        // onChange above applies it: one path for both, since this pane stays
        // alive beneath the sheet.
        .sheet(isPresented: $managingThemes, onDismiss: { namingNewTheme = false }) {
            FontThemesSheet(fonts: fonts, fontTheme: $fontTheme, fontThemes: $fontThemes,
                            asksForName: namingNewTheme)
        }
    }

    /// A copy of the selected theme holding the typography on screen — Custom
    /// edits included — selected, and opened in the Manage sheet to be named:
    /// a new theme is made to be edited, and the sheet is where that happens.
    /// `onChange` applies it, a no-op, since it already is what is live.
    private func newTheme() {
        guard let copy = try? ThemeStore.shared.duplicate(fontTheme),
              let made = ThemeStore.shared.fontThemes().first(where: { $0.name == copy })
        else { return }
        fonts.save(asPreset: copy, displayName: made.displayName)
        fontThemes = ThemeStore.shared.fontThemes()
        fontTheme = copy
        namingNewTheme = true
        managingThemes = true
    }

    private var selectedPreset: FontTheme? { fontThemes.first { $0.name == fontTheme } }

    /// The fonts on screen differ from the selected theme's: an edit in this
    /// pane changes only what is on screen (see `FontSettings.writesPreset`).
    private var isCustom: Bool { selectedPreset.map { !fonts.matches($0) } ?? false }

    /// The popup's selection: Custom while the fonts have diverged, else the
    /// theme. Choosing the theme already selected puts it back, which is the
    /// one way out of Custom to it — `fontTheme` does not change, so its
    /// onChange would not fire.
    private var themeSelection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : fontTheme },
            set: { name in
                switch name {
                case Self.customTag: break
                case Self.newThemeTag: newTheme()
                case fontTheme: selectedPreset.map(fonts.apply(preset:))
                default: fontTheme = name
                }
            })
    }

    private var fontThemePicker: some View {
        Picker("", selection: themeSelection) {
            // Only while it is true: an item for "none of these", shown when
            // the fonts on screen are no longer the selected theme's.
            if isCustom {
                Text("Custom").tag(Self.customTag)
                Divider()
            }
            ForEach(fontThemes, id: \.name) { Text($0.displayName).tag($0.name) }
            Divider()
            // The same trailing item the code-syntax popup has: making one
            // belongs with choosing one. It starts from what is on screen and
            // asks for a name straight away, which is the one thing a copy
            // cannot supply for itself.
            Text("New Font Theme…").tag(Self.newThemeTag)
        }
        .accessibilityLabel("Font theme")
        .labelsHidden()
        .onChange(of: fontTheme) {
            guard let chosen = selectedPreset else { return }
            fonts.apply(preset: chosen)
        }
    }

    /// One size for the whole preset, the way iA Writer and Obsidian offer
    /// one: the standard size is the anchor, and the monospaced and per-script
    /// sizes scale with it. Small A / big A rather than a stepper, as Safari
    /// and Books offer it: the glyphs say what the buttons change. The numbers
    /// in the fields below are the readout, and the rows there still change
    /// each on its own.
    private var fontSizeButtons: some View {
        let size = fonts.standardFont.pointSize
        return ControlGroup {
            Button { fonts.scaleAllSizes(toStandard: size - 1) } label: {
                Image(systemName: "textformat.size.smaller")
            }
            .accessibilityLabel("Smaller")
            .help("Make every font smaller")
            .disabled(size <= 8)
            Button { fonts.scaleAllSizes(toStandard: size + 1) } label: {
                Image(systemName: "textformat.size.larger")
            }
            .accessibilityLabel("Larger")
            .help("Make every font larger")
            .disabled(size >= 72)
        }
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

    /// The line-height field, stepper and unit; the pane and the Manage sheet
    /// both show it.
    static func lineHeightField(_ fonts: FontSettings) -> some View {
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
    }

    /// A font's preview, size stepper and Select… button; the pane and the
    /// Manage sheet both show it.
    @ViewBuilder
    static func fontRow(summary: String, sizeLabel: String, font: NSFont, antialias: Bool,
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
