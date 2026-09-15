// The Edit settings pane: one page, in three sections separated by rules —
// the window chrome, what typing does, and what you see.

import SwiftUI
import AppKit
import EdmundCore

struct EditSettingsView: View {
    @AppStorage(AppSettings.Key.showInvisibles) private var showInvisibles = false
    // Parked with the rest of the Always mode — see the "Characters:" row.
    // @AppStorage(AppSettings.Key.invisiblesMode)
    // private var invisiblesMode = AppSettings.InvisibleCharacterMode.uponSelection
    @AppStorage(AppSettings.Key.invisibleLineEnding) private var lineEnding = true
    @AppStorage(AppSettings.Key.invisibleTab)        private var tab = true
    @AppStorage(AppSettings.Key.invisibleSpace)      private var space = true
    @AppStorage(AppSettings.Key.invisibleWhitespace) private var otherWhitespace = true
    @AppStorage(AppSettings.Key.invisibleControl)    private var otherControl = true
    @AppStorage(AppSettings.Key.showListIndentGuides) private var showListIndentGuides = false
    @AppStorage(AppSettings.Key.showLineNumbers)      private var showLineNumbers = false
    @AppStorage(AppSettings.Key.indentStyle)
    private var indentStyle = AppSettings.IndentStyle.spaces
    @AppStorage(AppSettings.Key.indentWidth)       private var indentWidth = 2
    @AppStorage(AppSettings.Key.detectIndent)      private var detectIndent = true
    @AppStorage(AppSettings.Key.strictLineBreaks)  private var strictLineBreaks = true
    @AppStorage(AppSettings.Key.hardWrapLongLines) private var hardWrapLongLines = false
    @AppStorage(AppSettings.Key.autoCloseBrackets) private var autoCloseBrackets = true
    @AppStorage(AppSettings.Key.continueLists)     private var continueLists = true
    @AppStorage(AppSettings.Key.spellCheck)        private var spellCheck = false
    @AppStorage(AppSettings.Key.grammarCheck)      private var grammarCheck = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            // Window- and view-level state isn't configured here: toolbar
            // visibility and its full-screen auto-hide, typewriter scroll,
            // focus mode and source mode are all things you flip while working
            // and see immediately, so they live in the View menu. This pane is
            // for the defaults you set once — how text is indented, checked and
            // displayed.

            // TODO: Move Max Content Width here, after Settings ▸ Themes

            // MARK: - Content-level editing settings
            GridRow {
                Text("Indentation:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Prefer using")
                        Picker("", selection: $indentStyle) {
                            ForEach(AppSettings.IndentStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    HStack(spacing: 6) {
                        Text("Indent width:")
                        TextField("", value: $indentWidth,
                                  format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing)
                            .frame(width: 24)
                        Stepper("", value: $indentWidth, in: 1...8)
                            .labelsHidden()
                        Text("spaces")
                    }
                    Toggle("Detect indent style on document opening", isOn: $detectIndent)
                }
                .onChange(of: indentStyle) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: indentWidth) { AppSettings.applyEditSettingsToOpenDocuments() }
            }
            
            GridRow {
                Text("Words:")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Automatically close parentheses and quotes", isOn: $autoCloseBrackets)
                    Toggle("Check spelling while typing", isOn: $spellCheck)
                    // AppKit checks grammar as part of the continuous
                    // spell-checking pass (hence the menu's "Check Grammar With
                    // Spelling"), so it has nothing to do on its own.
                    Toggle("Check grammar while typing", isOn: $grammarCheck)
                        .padding(.leading, 20)
                        .disabled(!spellCheck)
                }
                .onChange(of: autoCloseBrackets) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: spellCheck) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: grammarCheck) { AppSettings.applyEditSettingsToOpenDocuments() }
            }
            
            GridRow {
                Text("Lists:")
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show list indent guides", isOn: $showListIndentGuides)
                        .onChange(of: showListIndentGuides) { AppSettings.applyEditSettingsToOpenDocuments() }
                    Toggle("Automatically continue lists", isOn: $continueLists)
                        .onChange(of: continueLists) { AppSettings.applyEditSettingsToOpenDocuments() }
                }
            }
            
            GridRow { Divider().gridCellColumns(2) }
                        
            // MARK: - Content-level display settings
            GridRow {
                Text("Characters:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Show invisible characters upon selection", isOn: $showInvisibles)
                    // The mode picker this toggle replaced (commit 6652972),
                    // parked in case Always comes back. Restoring it also needs
                    // AppSettings.InvisibleCharacterMode, its key/accessor, and
                    // InvisiblesConfig.Mode — all commented at their sites.
                    //
                    // HStack {
                    //     // fixedSize, or the picker's flexible width squeezes the
                    //     // label down to "Invisible charac…".
                    //     Toggle("Show invisible characters", isOn: $showInvisibles)
                    //         .fixedSize()
                    //     // When to draw them, once they're on at all.
                    //     Picker("", selection: $invisiblesMode) {
                    //         ForEach(AppSettings.InvisibleCharacterMode.allCases) {
                    //             Text($0.label).tag($0)
                    //         }
                    //     }
                    //     .labelsHidden()
                    //     .fixedSize()
                    //     .disabled(!showInvisibles)
                    // }
                    invisibleCharacterGrid
                        .padding(.leading, 20)
                        .padding(.bottom, -15)  // hardcoded
                        .disabled(!showInvisibles)
                }
                .onChange(of: showInvisibles) { AppSettings.applyEditSettingsToOpenDocuments() }
                // .onChange(of: invisiblesMode) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: lineEnding) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: tab) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: space) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: otherWhitespace) { AppSettings.applyEditSettingsToOpenDocuments() }
                .onChange(of: otherControl) { AppSettings.applyEditSettingsToOpenDocuments() }
            }
            
            GridRow {
                Text("Lines:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    // Not in print / PDF, for now.
                    Toggle("Show line numbers", isOn: $showLineNumbers)
                        .onChange(of: showLineNumbers) { AppSettings.applyEditSettingsToOpenDocuments() }
                    Toggle("Strict line breaks", isOn: $strictLineBreaks)
                        .onChange(of: strictLineBreaks) { refreshReadViews() }
                    Text("Turn off to make single line breaks / soft-wraps visible.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
            }
            
            GridRow {
                Text("Document:").gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    // Joining lines only makes sense while a single newline is
                    // formatting rather than content — see the note below the
                    // strict line breaks toggle.
                    // One switch for the whole feature: a file that opens
                    // hard-wrapped is joined for editing and written back at the
                    // width it already uses, detected from its own line breaks.
                    Toggle("Detect hard wrap pattern for lines on document opening", isOn: $hardWrapLongLines)
                        .disabled(!strictLineBreaks)
                    Text("Requires strict line breaks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380, alignment: .leading)
                        .padding(.leading, 20)
                }
            }
        }
        .settingsPanePadding()
    }

    private var invisibleCharacterGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                cell("Line ending", $lineEnding)
                cell("Tab", $tab)
                cell("Space", $space)
            }
            GridRow {
                cell("Other whitespace", $otherWhitespace)
                cell("Other control characters", $otherControl)
                    .gridCellColumns(2)
            }
        }
    }

    /// One grid toggle, sized to its own text — without `fixedSize` the grid
    /// hands each column an equal share and the longer labels wrap.
    private func cell(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(label, isOn: binding)
            .fixedSize()
            .gridColumnAlignment(.leading)
    }

    /// Strict line breaks changes Read-mode output, so re-render every open
    /// document (Read mode reads `AppSettings.strictLineBreaks` on render).
    private func refreshReadViews() {
        for case let document as Document in NSDocumentController.shared.documents {
            document.refreshReadView()
        }
    }
}
