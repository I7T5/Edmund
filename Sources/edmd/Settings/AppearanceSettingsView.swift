// The Appearance settings pane: appearance mode, fonts, and line height.
// The app accent comes from the AccentColor asset (see Resources/Assets.xcassets),
// so there is no in-app accent picker — native controls follow the asset / system.

import SwiftUI
import AppKit
import EdmundCore

struct AppearanceSettingsView: View {
    @ObservedObject var fonts: FontSettings
    @AppStorage(AppSettings.Key.appearanceMode) private var appearanceMode = AppSettings.AppearanceMode.matchSystem
    @AppStorage(AppSettings.Key.contentWidthFraction) private var contentWidth = AppSettings.ContentWidth.defaultFraction

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
                    // Continuous from the Mobile minimum to full width, with a
                    // magnetic snap onto the default (≈ Obsidian) width.
                    let value = Binding(
                        get: { contentWidth },
                        set: { newValue in
                            let d = AppSettings.ContentWidth.defaultFraction
                            contentWidth = abs(newValue - d) < AppSettings.ContentWidth.snapTolerance
                                ? d : newValue
                        }
                    )
                    Slider(value: value, in: AppSettings.ContentWidth.minFraction...1.0)
                        .frame(width: 200)
                    let percent = contentWidthPercentBinding
                    TextField("", value: percent, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 32)
                    Stepper("", value: percent, in: contentWidthPercentRange, step: 1)
                        .labelsHidden()
                    Text("%")
                }
                .onChange(of: contentWidth) { applyContentWidthToOpenDocuments() }
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

    /// The standard screen the coverage percentage is measured against.
    private var contentWidthScreen: CGFloat { NSScreen.main?.frame.width ?? 1440 }

    /// The percentage shown/edited is how much of the screen the column covers
    /// (≈25%…97%), not the raw fraction — so the narrowest setting reads as a
    /// sensible share of the screen, never 0%. The binding maps that percentage
    /// back to the stored fraction so the slider and stepper share one value.
    private var contentWidthPercentBinding: Binding<Double> {
        Binding(
            get: {
                (EditorTextView.contentCoverage(viewWidth: contentWidthScreen,
                                                fraction: CGFloat(contentWidth)) * 100).rounded()
            },
            set: { pct in
                contentWidth = Double(EditorTextView.fraction(forCoverage: CGFloat(pct / 100),
                                                              viewWidth: contentWidthScreen))
            }
        )
    }

    /// The coverage-percent range the stepper clamps to (Mobile minimum … full).
    private var contentWidthPercentRange: ClosedRange<Double> {
        let lo = (EditorTextView.contentCoverage(viewWidth: contentWidthScreen, fraction: 0) * 100).rounded()
        let hi = (EditorTextView.contentCoverage(viewWidth: contentWidthScreen, fraction: 1) * 100).rounded()
        return lo...hi
    }

    /// Pushes a content-width change to every open editor live (mirrors the
    /// font/line-height broadcast in FontSettings).
    private func applyContentWidthToOpenDocuments() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyContentWidth(CGFloat(contentWidth))
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
