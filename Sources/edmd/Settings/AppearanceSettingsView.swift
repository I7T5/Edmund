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
                Text("Max content width:")
                    .gridColumnAlignment(.trailing)
                HStack(spacing: 8) {
                    TextField("", value: $maxContentWidthCm,
                              format: .number.precision(.fractionLength(1)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("", value: $maxContentWidthCm, in: 5.0...200.0, step: 0.5)
                        .labelsHidden()
                    Text("cm")
                    Text("(wider windows cap the column at this physical width)")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                }
                .onChange(of: maxContentWidthCm) { applyContentWidthToOpenDocuments() }
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
                            antialias: fonts.antialias,
                            size: Binding(get: { Double(fonts.standardFont.pointSize) },
                                          set: { fonts.setStandardSize(CGFloat($0)) }),
                            select: fonts.selectStandardFont)
                    HStack(spacing: 16) {
                        Toggle("Antialias", isOn: $fonts.antialias)
                        Toggle("Ligatures", isOn: $fonts.standardLigatures)
                    }
                }
            }

            GridRow {
                Text("Monospaced font:")
                    .gridColumnAlignment(.trailing)
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

    /// Pushes a content-width change to every open editor live, converting cm
    /// to points using each editor's window screen PPI (or main screen as fallback).
    private func applyContentWidthToOpenDocuments() {
        for case let document as Document in NSDocumentController.shared.documents {
            let screen = document.editor?.window?.screen ?? NSScreen.main
            guard let screen else { continue }
            document.editor?.applyContentWidth(screen.cmToPoints(maxContentWidthCm))
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
