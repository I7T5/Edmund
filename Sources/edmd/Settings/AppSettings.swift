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
            case .keepCurrent: return "Keep Edmund’s edition"
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

    /// Content-width slider bounds. The stored value is a fraction of the
    /// available width (see `EditorTextView+ContentWidth`): the slider runs
    /// continuously from the Mobile minimum to full width, with a magnetic snap
    /// only at the default (≈ Obsidian) reading width.
    enum ContentWidth {
        /// Slider floor — the "Mobile" width (narrowest readable column).
        static let minFraction = 0.0
        /// Out-of-the-box default — ≈ Obsidian's default reading width.
        static let defaultFraction = 0.25
        /// How close to the default the marker must get to snap onto it.
        static let snapTolerance = 0.02
    }

    enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        static let startupAction = "settings.general.startupAction"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let conflictResolution = "settings.general.conflictResolution"
        static let appearanceMode = "settings.appearance.mode"
        static let contentWidthFraction = "settings.appearance.contentWidthFraction"
        static let suppressInconsistentLineEndingWarning = "settings.general.suppressInconsistentLineEndingWarning"
    }

    /// Text-column width as a fraction of the available width (`0...1`). `1`
    /// fills the width; lower narrows toward a mobile-ish minimum, centered.
    /// Defaults to the Narrower (≈ Obsidian) width so full-screen windows get
    /// readable margins out of the box.
    static var contentWidthFraction: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.contentWidthFraction) != nil else {
                return ContentWidth.defaultFraction
            }
            return UserDefaults.standard.double(forKey: Key.contentWidthFraction)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.contentWidthFraction) }
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

    static var suppressInconsistentLineEndingWarning: Bool {
        get { UserDefaults.standard.bool(forKey: Key.suppressInconsistentLineEndingWarning) }
        set { UserDefaults.standard.set(newValue, forKey: Key.suppressInconsistentLineEndingWarning) }
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
