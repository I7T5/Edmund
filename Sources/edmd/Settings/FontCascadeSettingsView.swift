// The Fonts settings pane: a dedicated font per script (the multi-font
// cascade). Rows mirror the Appearance pane's font rows — trailing-aligned
// label, 240pt preview field, control at the right — and unset scripts fall
// back to the system font cascade, exactly as before.

import SwiftUI
import AppKit
import EdmundCore

struct FontCascadeSettingsView: View {
    @ObservedObject var fonts: FontSettings

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 12) {
            GridRow {
                Text("Fonts:")
                    .gridColumnAlignment(.trailing)
                Text("A dedicated font for each script. Unset scripts use the system fallback.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 380, alignment: .leading)
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            ForEach(FontCascadeScript.allCases, id: \.self) { script in
                GridRow {
                    Text("\(script.label):")
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 8) {
                        // Preview mirrors the Appearance pane's font field
                        // (same 240pt width, same bezeled control).
                        AntialiasingText(script.sample)
                            .antialiasDisabled(!fonts.antialias)
                            .font(nsFont: fonts.previewFont(for: script))
                            .frame(width: 240)
                        Picker("", selection: cascadeBinding(for: script)) {
                            Text("Default (system fallback)").tag("")
                            Divider()
                            ForEach(fonts.availableFontFamilies, id: \.self) { family in
                                Text(displayName(for: family)).tag(family)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
        }
        .settingsPanePadding()
    }

    /// "" means unset (system fallback); anything else is a family name.
    private func cascadeBinding(for script: FontCascadeScript) -> Binding<String> {
        Binding(
            get: { fonts.cascadeFonts[script] ?? "" },
            set: { fonts.setCascadeFont(script, family: $0.isEmpty ? nil : $0) }
        )
    }

    /// Family names are postscript-ish ("Hiragino Sans" is fine, but some
    /// families report better display names via an instantiated font).
    private func displayName(for family: String) -> String {
        NSFont(name: family, size: 12)?.displayName ?? family
    }
}
