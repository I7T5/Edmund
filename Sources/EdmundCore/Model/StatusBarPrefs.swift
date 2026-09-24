import Foundation

/// Persisted user preferences for the status bar: whether it is shown at all,
/// whether it auto-hides (the default — reveal on hover) or stays visible, and
/// which fields are shown.
/// Backed by `UserDefaults` so the choice survives relaunches.
public struct StatusBarPrefs: Equatable, Sendable {
    /// When true (the default), the bar is hidden and revealed on hover.
    /// When false, it stays visible.
    public var autoHide: Bool
    public var showWords: Bool
    public var showCharacters: Bool
    public var showLocation: Bool
    public var showLine: Bool
    public var showLineEnding: Bool
    /// False hides the bar outright — not even hover reveals it.
    public var isShown: Bool

    public init(autoHide: Bool = true,
                showWords: Bool = true,
                showCharacters: Bool = true,
                showLocation: Bool = true,
                showLine: Bool = true,
                showLineEnding: Bool = true,
                isShown: Bool = true) {
        self.autoHide = autoHide
        self.showWords = showWords
        self.showCharacters = showCharacters
        self.showLocation = showLocation
        self.showLine = showLine
        self.showLineEnding = showLineEnding
        self.isShown = isShown
    }

    private enum Key {
        static let configured = "statusBar.configured"
        static let autoHide = "statusBar.autoHide"
        static let showWords = "statusBar.showWords"
        static let showCharacters = "statusBar.showCharacters"
        static let showLocation = "statusBar.showLocation"
        static let showLine = "statusBar.showLine"
        static let showLineEnding = "statusBar.showLineEnding"
        static let isShown = "statusBar.isShown"
    }

    /// Loads saved preferences, or the defaults if nothing was ever saved.
    public static func load(from defaults: UserDefaults = .standard) -> StatusBarPrefs {
        guard defaults.bool(forKey: Key.configured) else { return StatusBarPrefs() }
        return StatusBarPrefs(
            autoHide: defaults.bool(forKey: Key.autoHide),
            showWords: defaults.bool(forKey: Key.showWords),
            showCharacters: defaults.bool(forKey: Key.showCharacters),
            showLocation: defaults.bool(forKey: Key.showLocation),
            showLine: defaults.bool(forKey: Key.showLine),
            showLineEnding: defaults.bool(forKey: Key.showLineEnding),
            // Added after the others: a config saved before it existed has no
            // value, and that user's bar was showing.
            isShown: defaults.object(forKey: Key.isShown) as? Bool ?? true
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: Key.configured)
        defaults.set(autoHide, forKey: Key.autoHide)
        defaults.set(showWords, forKey: Key.showWords)
        defaults.set(showCharacters, forKey: Key.showCharacters)
        defaults.set(showLocation, forKey: Key.showLocation)
        defaults.set(showLine, forKey: Key.showLine)
        defaults.set(showLineEnding, forKey: Key.showLineEnding)
        defaults.set(isShown, forKey: Key.isShown)
        NotificationCenter.default.post(name: StatusBarPrefs.didChangeNotification, object: nil)
    }

    /// Posted by `save`, so every window's status bar picks up a change made
    /// from any one of them (or from the View menu).
    public static let didChangeNotification = Notification.Name("StatusBarPrefsDidChange")
}
