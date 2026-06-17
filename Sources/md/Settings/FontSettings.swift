// FontSettings — owns the editor fonts, line height, and accent hex, bridges the
// AppKit font panel, and applies changes to every open document.

import SwiftUI
import AppKit
import MarkdownEditorCore

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
        monospaceFont = theme.monospaceFont()
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
        applyMonospace()
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
            applyMonospace()
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

    private func applyMonospace() {
        var updated = theme
        updated.monospaceFontName = monospaceFont.fontName
        updated.monospaceFontSize = monospaceFont.pointSize
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyTheme() {
        var updated = theme
        updated.fontName = standardFont.fontName
        updated.fontSize = standardFont.pointSize
        updated.lineSpacing = max(0, (lineHeight - 1) * standardFont.pointSize)
        theme = updated
        updated.save()
        applyToDocuments(updated)
    }

    private func applyToDocuments(_ theme: EditorTheme) {
        for case let document as Document in NSDocumentController.shared.documents {
            document.editor?.applyTheme(theme)
        }
    }

    private static func summary(_ font: NSFont) -> String {
        let name = font.displayName ?? font.familyName ?? font.fontName
        return "\(name)  \(Int(round(font.pointSize)))"
    }
}
