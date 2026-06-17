// AppSettings — UserDefaults-backed model for every Settings value.
// The rest of the app reads these accessors; the SwiftUI panes bind to the
// same keys via @AppStorage.

import AppKit

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
        /// Display order in the Appearance pane (left to right).
        static let displayOrder: [AppearanceMode] = [.light, .dark, .matchSystem]
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
        static let suppressInconsistentLineEndingWarning = "settings.general.suppressInconsistentLineEndingWarning"
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
