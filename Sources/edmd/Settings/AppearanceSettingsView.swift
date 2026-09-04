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
                        .multilineTextAlignment(.trailing)
                        .frame(width: 32)
                    Stepper("", value: displayValueBinding,
                            in: displayRange, step: stepSize)
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
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Standard font:")
                    .frame(width: Self.labelColumnWidth, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    fontRow(summary: fonts.standardSummary,
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
                    fontRow(summary: fonts.monospaceSummary,
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
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: lineHeight, in: 1...3, step: 0.1)
                        .labelsHidden()
                    Text("times")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            fontCascadeSection
        }
        .settingsPanePadding()
    }

    /// Pushes a content-width change to every open editor live, converting cm
    /// to points using each editor's window screen PPI (or main screen as fallback).
    private func applyContentWidthToOpenDocuments() {
        for case let document as Document in NSDocumentController.shared.documents {
            let screen = document.editor?.window?.screen ?? NSScreen.main
            guard let screen else { continue }
            document.editor?.maxContentWidthPoints = screen.cmToPoints(maxContentWidthCm)
            document.refreshReadView()
        }
    }

    @ViewBuilder
    private func fontRow(summary: String, font: NSFont, antialias: Bool,
                         size: Binding<Double>, select: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            AntialiasingText(summary)
                .antialiasDisabled(!antialias)
                .font(nsFont: font)
                .frame(width: 240)
            Stepper("", value: size, in: 8...72, step: 1)
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
            scriptFontList
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Unset scripts use the system fallback.")
        }
    }

    /// Box width, and one script row's height. Five rows are visible and the
    /// remaining four scroll — the same 5-row window the Syntax pane's box uses.
    private var scriptBoxWidth: CGFloat { 380 }
    private var scriptRowHeight: CGFloat { 28 }

    private var scriptFontList: some View {
        List {
            ForEach(FontCascadeScript.allCases, id: \.self) { script in
                scriptRow(script)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, scriptRowHeight)
        .contentMargins(.vertical, 0, for: .scrollContent)
        .frame(width: scriptBoxWidth, height: scriptRowHeight * 5)
        .settingsSurfaceBackground()
        .border(.separator)
    }

    /// One script's row: name, the preview field (its text stays centered), the
    /// font button, and the script's ligature switch.
    ///
    /// The font button replaces the old stepper + "Select…" pair: the panel
    /// carries the size as well as the family, so the stepper was a second way
    /// to say the same thing, and dropping both is what makes room for the
    /// ligature checkbox inside the box.
    @ViewBuilder
    private func scriptRow(_ script: FontCascadeScript) -> some View {
        HStack(spacing: 8) {
            Text(script.label)
                .frame(width: 108, alignment: .leading)
            AntialiasingText(fonts.cascadeSummary(for: script))
                .antialiasDisabled(!fonts.antialias)
                .font(nsFont: fonts.previewFont(for: script))
                .frame(maxWidth: .infinity)
            Button { fonts.selectCascadeFont(script) } label: {
                Image(systemName: "textformat")
            }
            .buttonStyle(.borderless)
            .help("Choose a font for this script")
            // Still the only way to un-set a script's font; the row has no
            // room for a permanent button.
            .contextMenu {
                Button("Reset") { fonts.setCascadeFont(script, family: nil) }
                    .disabled(fonts.cascadeFonts[script] == nil)
            }
            Toggle("", isOn: cascadeLigaturesBinding(for: script))
                .labelsHidden()
                .help("Ligatures")
                // A ligature switch with no family drives nothing.
                .disabled(fonts.cascadeFonts[script] == nil)
        }
    }

    private func cascadeLigaturesBinding(for script: FontCascadeScript) -> Binding<Bool> {
        Binding(
            get: { fonts.cascadeLigatures(for: script) },
            set: { fonts.setCascadeLigatures(script, on: $0) }
        )
    }

}
