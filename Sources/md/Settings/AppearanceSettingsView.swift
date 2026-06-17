// The Appearance settings pane: appearance mode, fonts, and line height.
// The app accent comes from the AccentColor asset (see Resources/Assets.xcassets),
// so there is no in-app accent picker — native controls follow the asset / system.

import SwiftUI
import AppKit
import MarkdownEditorCore

struct AppearanceSettingsView: View {
    @ObservedObject var fonts: FontSettings
    @AppStorage(AppSettings.Key.appearanceMode) private var appearanceMode = AppSettings.AppearanceMode.matchSystem
    @AppStorage(AppSettings.Key.standardAntialias) private var standardAntialias = true
    @AppStorage(AppSettings.Key.standardLigatures) private var standardLigatures = true
    @AppStorage(AppSettings.Key.monospaceAntialias) private var monospaceAntialias = true
    @AppStorage(AppSettings.Key.monospaceLigatures) private var monospaceLigatures = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 12) {
            GridRow {
                Text("Appearance:")
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $appearanceMode) {
                    ForEach(AppSettings.AppearanceMode.displayOrder) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
                .labelsHidden()
                .onChange(of: appearanceMode) { AppSettings.applyAppearance() }
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            GridRow {
                Text("Standard font:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    fontRow(summary: fonts.standardSummary,
                            font: fonts.standardFont,
                            antialias: standardAntialias,
                            size: Binding(get: { Double(fonts.standardFont.pointSize) },
                                          set: { fonts.setStandardSize(CGFloat($0)) }),
                            select: fonts.selectStandardFont)
                    HStack(spacing: 16) {
                        Toggle("Antialias", isOn: $standardAntialias)
                        Toggle("Ligatures", isOn: $standardLigatures)
                    }
                }
            }

            GridRow {
                Text("Monospaced font:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    fontRow(summary: fonts.monospaceSummary,
                            font: fonts.monospaceFont,
                            antialias: monospaceAntialias,
                            size: Binding(get: { Double(fonts.monospaceFont.pointSize) },
                                          set: { fonts.setMonospaceSize(CGFloat($0)) }),
                            select: fonts.selectMonospaceFont)
                    HStack(spacing: 16) {
                        Toggle("Antialias", isOn: $monospaceAntialias)
                        Toggle("Ligatures", isOn: $monospaceLigatures)
                    }
                }
            }

            GridRow {
                Text("Line height:")
                    .gridColumnAlignment(.trailing)
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
            }
        }
        .settingsPanePadding()
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
