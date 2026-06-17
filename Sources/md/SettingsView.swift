import SwiftUI
import AppKit
import MarkdownEditorCore

// MARK: - General

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Key.reopenWindows) private var reopenWindows = false
    @AppStorage(AppSettings.Key.startupAction) private var startupAction = AppSettings.StartupAction.createNewDocument
    @AppStorage(AppSettings.Key.autoSaveWithVersions) private var autoSave = true
    @AppStorage(AppSettings.Key.conflictResolution) private var conflict = AppSettings.ConflictResolution.ask
    @State private var showingWarnings = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 18) {
            GridRow {
                Text("On startup:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Reopen windows from last session", isOn: $reopenWindows)
                    Text("When nothing else is open:")
                    Picker("", selection: $startupAction) {
                        ForEach(AppSettings.StartupAction.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .padding(.leading, 20)
                }
            }

            GridRow {
                Text("Document save:")
                    .gridColumnAlignment(.trailing)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Enable Auto Save with Versions", isOn: $autoSave)
                    Text("A system feature that automatically overwrites your files while editing. Even if turned off, md creates a backup in case it unexpectedly quits.")
                        .foregroundStyle(.secondary)
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360, alignment: .leading)
                        .padding(.leading, 20)
                }
            }

            GridRow {
                Text("When document is changed by another application:")
                    .gridCellColumns(2)
            }
            .padding(.bottom, -8)

            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Picker("", selection: $conflict) {
                    ForEach(AppSettings.ConflictResolution.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            GridRow {
                Text("Dialog warnings:")
                    .gridColumnAlignment(.trailing)
                Button("Manage Warnings…") { showingWarnings = true }
            }
        }
        .accentTinted()
        .scenePadding()
        .padding(8)
        .frame(width: 560, alignment: .leading)
        .alert("No Dialog Warnings", isPresented: $showingWarnings) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("There are no suppressed warnings to manage.")
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject var fonts: FontSettings
    @AppStorage(AppSettings.Key.appearanceMode) private var appearanceMode = AppSettings.AppearanceMode.matchSystem
    @AppStorage(AppSettings.Key.accentColor) private var accentColor = AppSettings.AccentColor.brown
    @AppStorage(AppSettings.Key.customAccentHex) private var customAccentHex = AppSettings.defaultCustomHex
    @AppStorage(AppSettings.Key.highlightColor) private var highlightColor = AppSettings.HighlightColor.accent
    @AppStorage(AppSettings.Key.standardAntialias) private var standardAntialias = true
    @AppStorage(AppSettings.Key.standardLigatures) private var standardLigatures = true
    @AppStorage(AppSettings.Key.monospaceAntialias) private var monospaceAntialias = true
    @AppStorage(AppSettings.Key.monospaceLigatures) private var monospaceLigatures = false

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, verticalSpacing: 12) {
            // System-level appearance
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
                Text("Accent color:")
                    .gridColumnAlignment(.trailing)
                AccentColorPicker(selection: $accentColor, customHex: $customAccentHex)
            }

            GridRow {
                Text("Highlight color:")
                    .gridColumnAlignment(.trailing)
                Picker("", selection: $highlightColor) {
                    ForEach(AppSettings.HighlightColor.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            GridRow {
                Divider().gridCellColumns(2)
            }

            // Fonts
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
        .accentTinted()
        .scenePadding()
        .padding(8)
        .frame(width: 560, alignment: .leading)
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

// MARK: - Accent color

/// A Reminders-style accent picker: two rows of swatches, the selected one shown
/// with a white center ring, and a trailing custom-color well.
private struct AccentColorPicker: View {
    @Binding var selection: AppSettings.AccentColor
    @Binding var customHex: String

    private static let perRow = 6

    var body: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(rows, id: \.first) { row in
                GridRow {
                    ForEach(row) { swatch($0) }
                }
            }
        }
    }

    private var rows: [[AppSettings.AccentColor]] {
        let all = AppSettings.AccentColor.allCases
        return stride(from: 0, to: all.count, by: Self.perRow).map {
            Array(all[$0..<min($0 + Self.perRow, all.count)])
        }
    }

    @ViewBuilder
    private func swatch(_ accent: AppSettings.AccentColor) -> some View {
        if accent == .custom {
            ColorPicker("", selection: Binding(
                get: { Color(hexString: customHex) },
                set: { customHex = $0.hexString; selection = .custom }
            ), supportsOpacity: false)
            .labelsHidden()
        } else {
            Button {
                selection = accent
            } label: {
                Circle()
                    .fill(accent.color)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                    .overlay {
                        if selection == accent {
                            Circle().inset(by: 3).strokeBorder(.white, lineWidth: 2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(accent.rawValue.capitalized)
        }
    }
}

extension AppSettings.AccentColor {
    /// The swatch / tint color. `brown` is our signature #895129; `custom` is a
    /// fallback (the live custom color is resolved from its stored hex).
    var color: Color {
        switch self {
        case .red: return Color(nsColor: .systemRed)
        case .orange: return Color(nsColor: .systemOrange)
        case .yellow: return Color(nsColor: .systemYellow)
        case .green: return Color(nsColor: .systemGreen)
        case .mint: return Color(nsColor: .systemMint)
        case .blue: return Color(nsColor: .systemBlue)
        case .indigo: return Color(nsColor: .systemIndigo)
        case .purple: return Color(nsColor: .systemPurple)
        case .pink: return Color(nsColor: .systemPink)
        case .lightGray: return Color(hexString: "C4C4C4")
        case .brown, .custom: return Color(hexString: AppSettings.defaultCustomHex)
        }
    }
}

extension Color {
    /// Creates an opaque sRGB color from an "RRGGBB" (or "#RRGGBB") string.
    init(hexString: String) {
        var string = hexString
        if string.hasPrefix("#") { string.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: string).scanHexInt64(&value)
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The color as an uppercase "RRGGBB" hex string.
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(format: "%02X%02X%02X",
                      Int((ns.redComponent * 255).rounded()),
                      Int((ns.greenComponent * 255).rounded()),
                      Int((ns.blueComponent * 255).rounded()))
    }
}

/// Applies the user's accent color as the SwiftUI `tint`, so checkboxes, radio
/// pickers, and pop-up selections in Settings all follow it.
private struct AccentTint: ViewModifier {
    @AppStorage(AppSettings.Key.accentColor) private var accent = AppSettings.AccentColor.brown
    @AppStorage(AppSettings.Key.customAccentHex) private var customHex = AppSettings.defaultCustomHex

    func body(content: Content) -> some View {
        content.tint(accent == .custom ? Color(hexString: customHex) : accent.color)
    }
}

extension View {
    func accentTinted() -> some View { modifier(AccentTint()) }
}

// MARK: - Font / theme state

/// Owns the editor's standard/monospace fonts and line height, bridges the
/// AppKit font panel, and applies font/line-height changes to open documents
/// (the genuinely AppKit-bound part of the Appearance pane).
@MainActor
final class FontSettings: NSObject, ObservableObject {
    @Published var standardFont: NSFont
    @Published var monospaceFont: NSFont
    @Published var lineHeight: CGFloat

    private var theme: EditorTheme
    private enum Target { case standard, monospace }
    private var target: Target = .standard

    override init() {
        let theme = EditorTheme.load()
        self.theme = theme
        standardFont = theme.bodyFont
        monospaceFont = NSFont(name: AppSettings.monospaceFontName, size: AppSettings.monospaceFontSize)
            ?? .monospacedSystemFont(ofSize: AppSettings.monospaceFontSize, weight: .regular)
        let size = theme.bodyFont.pointSize
        lineHeight = size > 0 ? max(1, min(3, (size + theme.lineSpacing) / size)) : 1
        super.init()
    }

    var standardSummary: String { Self.summary(standardFont) }
    var monospaceSummary: String { Self.summary(monospaceFont) }

    func selectStandardFont() { beginFontPanel(.standard, current: standardFont) }
    func selectMonospaceFont() { beginFontPanel(.monospace, current: monospaceFont) }

    func setStandardSize(_ size: CGFloat) {
        standardFont = NSFont(descriptor: standardFont.fontDescriptor, size: size) ?? standardFont
        applyTheme()
    }

    func setMonospaceSize(_ size: CGFloat) {
        monospaceFont = NSFont(descriptor: monospaceFont.fontDescriptor, size: size) ?? monospaceFont
        persistMonospace()
    }

    func setLineHeight(_ value: CGFloat) {
        lineHeight = max(1, min(3, value))
        applyTheme()
    }

    @objc func changeFont(_ sender: NSFontManager) {
        switch target {
        case .standard:
            standardFont = sender.convert(standardFont)
            applyTheme()
        case .monospace:
            monospaceFont = sender.convert(monospaceFont)
            persistMonospace()
        }
    }

    private func beginFontPanel(_ target: Target, current: NSFont) {
        self.target = target
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(nil)
    }

    private func persistMonospace() {
        AppSettings.monospaceFontName = monospaceFont.fontName
        AppSettings.monospaceFontSize = monospaceFont.pointSize
    }

    private func applyTheme() {
        var updated = theme
        updated.fontName = standardFont.fontName
        updated.fontSize = standardFont.pointSize
        updated.lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        theme = updated
        updated.save()
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyTheme(updated)
        }
    }

    private static func summary(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return "\(name)  \(Int(round(font.pointSize)))"
    }
}
