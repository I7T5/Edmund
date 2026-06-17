import AppKit
import SwiftUI
import MarkdownEditorCore

enum AppSettings {
    enum StartupAction: String, CaseIterable, Identifiable {
        case createNewDocument
        case doNothing
        var id: Self { self }
        var label: String {
            switch self {
            case .createNewDocument: return "Create New Document"
            case .doNothing: return "Do Nothing"
            }
        }
    }

    enum ConflictResolution: String, CaseIterable, Identifiable {
        case keepCurrent
        case ask
        case updateToModified
        var id: Self { self }
        var label: String {
            switch self {
            case .keepCurrent: return "Keep md’s edition"
            case .ask: return "Ask how to resolve"
            case .updateToModified: return "Update to modified edition"
            }
        }
    }

    enum AppearanceMode: String, CaseIterable, Identifiable {
        case matchSystem
        case light
        case dark
        var id: Self { self }
        var label: String {
            switch self {
            case .matchSystem: return "Match System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        static let startupAction = "settings.general.startupAction"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let conflictResolution = "settings.general.conflictResolution"
        static let standardAntialias = "settings.appearance.standardAntialias"
        static let standardLigatures = "settings.appearance.standardLigatures"
        static let monospaceFontName = "settings.appearance.monospaceFontName"
        static let monospaceFontSize = "settings.appearance.monospaceFontSize"
        static let monospaceAntialias = "settings.appearance.monospaceAntialias"
        static let monospaceLigatures = "settings.appearance.monospaceLigatures"
        static let appearanceMode = "settings.appearance.mode"
    }

    static var reopenWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reopenWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reopenWindows) }
    }

    static var startupAction: StartupAction {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.startupAction),
                  let action = StartupAction(rawValue: raw) else {
                return .createNewDocument
            }
            return action
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.startupAction) }
    }

    static var autoSaveWithVersions: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.autoSaveWithVersions) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.autoSaveWithVersions)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.autoSaveWithVersions) }
    }

    static var conflictResolution: ConflictResolution {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.conflictResolution),
                  let resolution = ConflictResolution(rawValue: raw) else {
                return .ask
            }
            return resolution
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.conflictResolution) }
    }

    static var standardAntialias: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.standardAntialias) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.standardAntialias)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.standardAntialias) }
    }

    static var standardLigatures: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.standardLigatures) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.standardLigatures)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.standardLigatures) }
    }

    static var monospaceFontName: String {
        get {
            UserDefaults.standard.string(forKey: Key.monospaceFontName)
                ?? NSFont.monospacedSystemFont(ofSize: 14, weight: .regular).fontName
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceFontName) }
    }

    static var monospaceFontSize: CGFloat {
        get {
            let size = CGFloat(UserDefaults.standard.float(forKey: Key.monospaceFontSize))
            return size > 0 ? size : 14
        }
        set { UserDefaults.standard.set(Float(newValue), forKey: Key.monospaceFontSize) }
    }

    static var monospaceAntialias: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.monospaceAntialias) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.monospaceAntialias)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceAntialias) }
    }

    static var monospaceLigatures: Bool {
        get { UserDefaults.standard.bool(forKey: Key.monospaceLigatures) }
        set { UserDefaults.standard.set(newValue, forKey: Key.monospaceLigatures) }
    }

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.appearanceMode),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .matchSystem
            }
            return mode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.appearanceMode) }
    }

    @MainActor static func applyAppearance() {
        switch appearanceMode {
        case .matchSystem:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A CotEditor-style Settings window. The window chrome and the pane-switching
/// preference toolbar stay AppKit; each pane's content is a SwiftUI view hosted
/// in an `NSHostingController`, which owns all of the layout.
final class SettingsWindowController: NSWindowController, NSToolbarDelegate {
    private enum Pane {
        case general
        case appearance

        var title: String {
            switch self {
            case .general: return "General"
            case .appearance: return "Appearance"
            }
        }

        var identifier: NSToolbarItem.Identifier {
            switch self {
            case .general: return Self.generalID
            case .appearance: return Self.appearanceID
            }
        }

        static let generalID = NSToolbarItem.Identifier("settings.general")
        static let appearanceID = NSToolbarItem.Identifier("settings.appearance")
    }

    /// Owns the editor font / line-height state and the font-panel plumbing.
    /// Shared across pane rebuilds so the font panel keeps targeting it.
    private let fonts = FontSettings()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.isReleasedWhenClosed = false

        self.init(window: window)
        setupWindow()
        showPane(.general)
    }

    private func setupWindow() {
        guard let window else { return }
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .line

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.selectedItemIdentifier = Pane.generalID
        window.toolbar = toolbar
        window.toolbarStyle = .preference
    }

    // MARK: - Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Pane.generalID, Pane.appearanceID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.action = #selector(selectPane(_:))

        switch itemIdentifier {
        case Pane.generalID:
            item.label = "General"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "General")
        case Pane.appearanceID:
            item.label = "Appearance"
            item.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "Appearance")
        default:
            return nil
        }
        item.paletteLabel = item.label
        return item
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        switch sender.itemIdentifier {
        case Pane.generalID: showPane(.general)
        case Pane.appearanceID: showPane(.appearance)
        default: break
        }
    }

    // MARK: - Panes

    private func showPane(_ pane: Pane) {
        window?.title = pane.title
        window?.toolbar?.selectedItemIdentifier = pane.identifier

        let root: AnyView = switch pane {
        case .general: AnyView(GeneralSettingsView())
        case .appearance: AnyView(AppearanceSettingsView(fonts: fonts))
        }
        let hosting = NSHostingController(rootView: root)
        hosting.sizingOptions = [.preferredContentSize]
        window?.contentViewController = hosting
    }
}
