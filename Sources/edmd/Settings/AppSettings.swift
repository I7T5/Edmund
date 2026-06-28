// AppSettings — UserDefaults-backed model for every Settings value.
// The rest of the app reads these accessors; the SwiftUI panes bind to the
// same keys via @AppStorage.

import AppKit
import EdmundCore

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

    /// How long diagnostic logs are kept before being pruned on launch.
    enum LogRetention: String, CaseIterable, Identifiable {
        case oneDay, twoDays, oneWeek, twoWeeks, thirtyDays, never
        var id: Self { self }
        var label: String {
            switch self {
            case .oneDay: return "1 day"
            case .twoDays: return "2 days"
            case .oneWeek: return "1 week"
            case .twoWeeks: return "2 weeks"
            case .thirtyDays: return "30 days"
            case .never: return "Never"
            }
        }
        /// The retention window in seconds; `nil` means keep forever.
        var timeInterval: TimeInterval? {
            let day: TimeInterval = 24 * 60 * 60
            switch self {
            case .oneDay: return day
            case .twoDays: return 2 * day
            case .oneWeek: return 7 * day
            case .twoWeeks: return 14 * day
            case .thirtyDays: return 30 * day
            case .never: return nil
            }
        }
    }

    enum Key {
        static let reopenWindows = "settings.general.reopenWindows"
        // Must match Sparkle's own default key exactly — Sparkle reads/writes this string.
        static let automaticallyChecksForUpdates = "SUAutomaticallyChecksForUpdates"
        static let startupAction = "settings.general.startupAction"
        static let autoSaveWithVersions = "settings.general.autoSaveWithVersions"
        static let conflictResolution = "settings.general.conflictResolution"
        static let appearanceMode = "settings.appearance.mode"
        static let maxContentWidthCm = "settings.appearance.maxContentWidthCm"
        static let suppressInconsistentLineEndingWarning = "settings.general.suppressInconsistentLineEndingWarning"
        static let diagnosticLogging = "settings.general.diagnosticLogging"
        static let verboseEditorDiagnostics = "settings.advanced.verboseEditorDiagnostics"
        static let logRetention = "settings.general.logRetention"
        static let renderBlankLinesAsBreaks = "settings.reading.renderBlankLinesAsBreaks"
        static let sourceMode = "settings.view.sourceMode"
        static let sendCrashLogs = "settings.advanced.sendCrashLogs"
        static let sentCrashReports = "settings.advanced.sentCrashReports"
    }

    /// Maximum text-column width in centimetres. Wider windows center the
    /// column at this physical width; narrower windows fill edge-to-edge.
    /// Default: 43 % of the main screen's physical width at first launch.
    static var maxContentWidthCm: Double {
        get {
            guard UserDefaults.standard.object(forKey: Key.maxContentWidthCm) != nil else {
                return defaultMaxContentWidthCm
            }
            return UserDefaults.standard.double(forKey: Key.maxContentWidthCm)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.maxContentWidthCm) }
    }

    /// 43 % of the main screen's physical width in cm — a comfortable reading
    /// column out of the box that matches the previous fraction-based default.
    static var defaultMaxContentWidthCm: Double {
        guard let screen = NSScreen.main else { return 40.0 }
        let pts = screen.frame.width * 0.43
        return Double(pts / screen.physicalPPI) * 2.54
    }

    static var reopenWindows: Bool {
        get { UserDefaults.standard.bool(forKey: Key.reopenWindows) }
        set { UserDefaults.standard.set(newValue, forKey: Key.reopenWindows) }
    }

    /// Source mode: an alternate form of Edit mode that shows the raw markdown.
    /// When on, the editing half of the view-mode toggle is Source instead of
    /// Edit (so the toggle flips Source ↔ Read). Defaults off.
    static var sourceMode: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sourceMode) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sourceMode) }
    }

    /// Read mode: render runs of blank lines as proportional vertical space
    /// (preserving the author's spacing). Defaults on. The toggle UI lives in a
    /// future Reading-settings tab; the value is already honored here.
    static var renderBlankLinesAsBreaks: Bool {
        get {
            guard UserDefaults.standard.object(forKey: Key.renderBlankLinesAsBreaks) != nil else {
                return true
            }
            return UserDefaults.standard.bool(forKey: Key.renderBlankLinesAsBreaks)
        }
        set { UserDefaults.standard.set(newValue, forKey: Key.renderBlankLinesAsBreaks) }
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

    /// Whether diagnostic logging is on. Defaults to off; the user can opt in.
    static var diagnosticLogging: Bool {
        get { UserDefaults.standard.bool(forKey: Key.diagnosticLogging) }
        set { UserDefaults.standard.set(newValue, forKey: Key.diagnosticLogging) }
    }

    /// Verbose editor tracing: high-volume per-edit / per-caret-move trace lines
    /// for diagnosing live-NSTextView / TextKit 2 editor bugs (caret drift, sync
    /// desyncs) that can't be reproduced headlessly. Off by default — turned on
    /// only when capturing a reproduction. Requires diagnostic logging to be on.
    static var verboseEditorDiagnostics: Bool {
        get { UserDefaults.standard.bool(forKey: Key.verboseEditorDiagnostics) }
        set { UserDefaults.standard.set(newValue, forKey: Key.verboseEditorDiagnostics) }
    }

    /// Whether to auto-send crash reports on launch. Opt-in: defaults off, since
    /// it sends data off-device. (UI currently commented out — see
    /// AdvancedSettingsView — until the receiving server exists.)
    static var sendCrashLogs: Bool {
        get { UserDefaults.standard.bool(forKey: Key.sendCrashLogs) }
        set { UserDefaults.standard.set(newValue, forKey: Key.sendCrashLogs) }
    }

    /// Filenames of crash reports already uploaded, so we don't resend them.
    /// Bounded on write by dropping entries whose `.ips` file no longer exists.
    static var sentCrashReports: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: Key.sentCrashReports) ?? []) }
        set {
            let onDisk = (try? FileManager.default.contentsOfDirectory(
                atPath: CrashReporter.diagnosticReportsDirectory.path)).map(Set.init) ?? []
            let pruned = onDisk.isEmpty ? newValue : newValue.intersection(onDisk)
            UserDefaults.standard.set(Array(pruned), forKey: Key.sentCrashReports)
        }
    }

    static var logRetention: LogRetention {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Key.logRetention),
                  let value = LogRetention(rawValue: raw) else {
                return .twoWeeks
            }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Key.logRetention) }
    }

    /// Where diagnostic logs live: `~/.edmund/logs`.
    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".edmund/logs", isDirectory: true)
    }

    /// Pushes the current logging settings into the `Log` facility. Called at
    /// launch and whenever the toggle or retention changes.
    static func applyLogging() {
        Log.configure(enabled: diagnosticLogging,
                      directory: logDirectory,
                      retention: logRetention.timeInterval)
        Log.setVerbose(verboseEditorDiagnostics)
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

// MARK: - Screen physical-unit helpers

extension NSScreen {
    /// Physical pixels-per-inch from the display's actual diagonal/width size
    /// (via Core Graphics — not the nominal 72 pt/in). Falls back to 109 PPI
    /// (the typical value for a 27-inch 5K iMac) when the display ID can't be read.
    var physicalPPI: CGFloat {
        guard let n = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 109
        }
        let mm = CGDisplayScreenSize(CGDirectDisplayID(n.uint32Value))
        guard mm.width > 0 else { return 109 }
        // frame.width is in points (not pixels); mm.width is physical mm.
        return frame.width / (mm.width / 25.4)
    }

    /// Convert a physical centimetre value to AppKit points on this display.
    func cmToPoints(_ cm: Double) -> CGFloat {
        CGFloat(cm) / 2.54 * physicalPPI
    }
}
