import Foundation

// MARK: - Theme Store
//
// Loads themes from two sources — the bundled JSON under Resources/Themes and
// the user's Application Support dir — and resolves the active theme for an
// appearance. A user theme overrides a bundled one of the same name, which is
// what makes a built-in customizable: drop a same-named JSON and it wins.
//
// Which theme is active is NOT read from UserDefaults here. EdmundCore has no
// settings dependency; `edmd` pushes the four active names in, exactly as
// `AppSettings.applyCodeSyntax()` pushes `SyntaxDefinitionStore.defaultLanguage`.
//
// ponytail: not thread-safe, same reasoning as SyntaxDefinitionStore — reads
// happen during rendering (main thread) and the app pushes config on the main
// thread. Add a lock only if a background consumer ever appears.

public final class ThemeStore {
    // ponytail: single-thread (main) use — see the type note above.
    nonisolated(unsafe) public static let shared = ThemeStore()

    /// The active theme name per kind per appearance. Set by the app from
    /// `settings.themes.*`; the defaults are the bundled built-ins.
    public var activeGeneralLight = "classic-light"
    public var activeGeneralDark = "classic-dark"
    public var activeSyntaxLight = "tomorrow"
    public var activeSyntaxDark = "one-dark"

    private var generalByName: [String: GeneralTheme] = [:]
    private var syntaxByName: [String: SyntaxTheme] = [:]
    private var generalOrdered: [GeneralTheme] = []
    private var syntaxOrdered: [SyntaxTheme] = []
    private var userNames: Set<String> = []
    /// Every name the app ships with, whether or not a user file is currently
    /// shadowing it. This is what makes "restore" possible: without it, an
    /// edited built-in is indistinguishable from a theme the user created.
    private var bundledNames: Set<String> = []
    private var sourceURLs: [String: URL] = [:]

    init() { reload() }

    // MARK: Loading

    /// Rebuild the tables from bundled + user themes. Call after import/removal.
    public func reload() {
        var generals: [String: GeneralTheme] = [:]
        var syntaxes: [String: SyntaxTheme] = [:]
        var generalList: [GeneralTheme] = []
        var syntaxList: [SyntaxTheme] = []
        var users: Set<String> = []
        var bundled: Set<String> = []
        var sources: [String: URL] = [:]

        func addGeneral(_ theme: GeneralTheme, url: URL, user: Bool) {
            if let i = generalList.firstIndex(where: { $0.name == theme.name }) { generalList[i] = theme }
            else { generalList.append(theme) }
            generals[theme.name] = theme
            sources[theme.name] = url
            if user { users.insert(theme.name) } else { bundled.insert(theme.name) }
        }

        func addSyntax(_ theme: SyntaxTheme, url: URL, user: Bool) {
            if let i = syntaxList.firstIndex(where: { $0.name == theme.name }) { syntaxList[i] = theme }
            else { syntaxList.append(theme) }
            syntaxes[theme.name] = theme
            sources[theme.name] = url
            if user { users.insert(theme.name) } else { bundled.insert(theme.name) }
        }

        for (t, url) in Self.load(GeneralTheme.self, bundled: "Themes/General") { addGeneral(t, url: url, user: false) }
        for (t, url) in Self.load(GeneralTheme.self, user: Self.userDirectory(.general)) { addGeneral(t, url: url, user: true) }
        for (t, url) in Self.load(SyntaxTheme.self, bundled: "Themes/Syntax") { addSyntax(t, url: url, user: false) }
        for (t, url) in Self.load(SyntaxTheme.self, user: Self.userDirectory(.syntax)) { addSyntax(t, url: url, user: true) }

        generalByName = generals
        syntaxByName = syntaxes
        generalOrdered = generalList.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        syntaxOrdered = syntaxList.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        userNames = users
        bundledNames = bundled
        sourceURLs = sources
    }

    // MARK: Resolution

    /// The active general theme for an appearance. Falls back to the built-in
    /// of that appearance, then to `GeneralTheme.fallback` — the editor must
    /// always have colors to draw with, even with no readable theme on disk.
    public func general(dark: Bool) -> GeneralTheme {
        let active = dark ? activeGeneralDark : activeGeneralLight
        return generalByName[active]
            ?? generalByName[dark ? "classic-dark" : "classic-light"]
            ?? .fallback(dark ? .dark : .light)
    }

    /// The syntax theme in force for an appearance, or `nil` if none can be
    /// loaded — `CodeSyntaxPalette` then falls back to its compiled-in palettes.
    ///
    /// An editor theme may pin a syntax theme of its own; that wins over the
    /// General row's choice, which is what makes the assignment an *override*
    /// rather than a second setting. A theme that assigns none — `nil`, the
    /// default — takes General's, so switching editor themes normally leaves
    /// code colors alone.
    func syntax(dark: Bool) -> SyntaxTheme? {
        let assigned = general(dark: dark).syntaxTheme
        let active = assigned ?? (dark ? activeSyntaxDark : activeSyntaxLight)
        return syntaxByName[active]
            ?? syntaxByName[dark ? activeSyntaxDark : activeSyntaxLight]
            ?? syntaxByName[dark ? "one-dark" : "tomorrow"]
    }

    // MARK: UI queries

    public func generalThemes() -> [GeneralTheme] { generalOrdered }
    public func syntaxThemes() -> [SyntaxTheme] { syntaxOrdered }


    public func isUserTheme(_ name: String) -> Bool { userNames.contains(name) }

    /// A name the app ships with, whether or not the user has edited it. Such a
    /// theme can be changed but never removed: deleting only drops the edit.
    public func isBuiltIn(_ name: String) -> Bool { bundledNames.contains(name) }

    /// A built-in the user has edited — the only case `restoreBuiltIn` has
    /// anything to do.
    public func isEditedBuiltIn(_ name: String) -> Bool {
        isBuiltIn(name) && isUserTheme(name)
    }

    /// Puts a built-in back to what ships, by dropping the file shadowing it.
    /// Silent when there is no edit to drop — restoring an untouched theme is
    /// a no-op, not a failure.
    public func restoreBuiltIn(named name: String) throws {
        guard isEditedBuiltIn(name), let url = sourceURLs[name] else { return }
        try FileManager.default.removeItem(at: url)
        reload()
    }

    /// Every edited built-in at once. Themes the user *created* are untouched —
    /// they shadow nothing, so there is no original to go back to and dropping
    /// them would be a deletion wearing a restore's name.
    @discardableResult
    public func restoreAllBuiltIns() -> Int {
        let edited = bundledNames.filter(isUserTheme)
        for name in edited {
            guard let url = sourceURLs[name] else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        if !edited.isEmpty { reload() }
        return edited.count
    }

    /// The JSON file backing a theme (user copy if it overrides, else bundled).
    public func fileURL(forName name: String) -> URL? { sourceURLs[name] }

    public enum DeleteError: Error, Equatable {
        /// A bundled theme lives inside the app; there is nothing to delete and
        /// removing it would mean modifying the app itself.
        case builtIn
        case notFound
    }

    /// Deletes a user theme's JSON and reloads.
    ///
    /// Refuses built-ins rather than silently doing nothing: the caller decides
    /// what a failed delete looks like, and a no-op would read as success. A
    /// user theme that shadows a bundled one of the same name reverts to the
    /// bundled version on reload rather than disappearing.
    public func deleteUserTheme(named name: String) throws {
        guard isUserTheme(name) else {
            throw sourceURLs[name] == nil ? DeleteError.notFound : DeleteError.builtIn
        }
        guard let url = sourceURLs[name] else { throw DeleteError.notFound }
        try FileManager.default.removeItem(at: url)
        reload()
    }

    // MARK: Writing

    /// Which theme a name belongs to, or `nil` if nothing has that name.
    public func kind(ofThemeNamed name: String) -> Kind? {
        if generalByName[name] != nil { return .general }
        if syntaxByName[name] != nil { return .syntax }
        return nil
    }

    public func save(_ theme: GeneralTheme) throws {
        try write(theme, kind: .general, name: theme.name)
    }

    public func save(_ theme: SyntaxTheme) throws {
        try write(theme, kind: .syntax, name: theme.name)
    }

    /// Writes a theme into the user directory and reloads.
    ///
    /// Always the user directory, including for a name the app ships with: a
    /// user file *shadows* the bundled one (see `reload`), which is how a
    /// built-in is edited without touching the app bundle. Nothing is
    /// overwritten inside the app, so `restoreBuiltIn` can put the original
    /// back at any time by deleting the shadow.
    ///
    /// The write is atomic. A theme half-written by a crash would fail to
    /// decode, and `reload` skips anything it cannot decode — so the theme
    /// would silently vanish from the list rather than reporting an error.
    private func write<T: Encodable>(_ theme: T, kind: Kind, name: String) throws {
        let directory = Self.userDirectory(kind)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted and indented because these files are meant to be opened and
        // hand-edited — they are the documented way to author a theme.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(theme)
        try data.write(to: directory.appendingPathComponent("\(name).json"), options: .atomic)
        reload()
    }

    public enum DuplicateError: Error, Equatable {
        case notFound
    }

    /// Copies a theme under a fresh name and returns that name, so the caller
    /// can select the copy it just made.
    public func duplicate(_ name: String) throws -> String {
        if var theme = generalByName[name] {
            let copy = uniqueName(basedOn: name)
            theme = GeneralTheme(name: copy, displayName: theme.displayName + " copy",
                                 appearance: theme.appearance,
                                 text: theme.text, invisibles: theme.invisibles,
                                 checkbox: theme.checkbox, link: theme.link,
                                 highlight: theme.highlight,
                                 background: theme.background, selection: theme.selection,
                                 cursor: theme.cursor,
                                 syntaxTheme: theme.syntaxTheme)
            try save(theme)
            return copy
        }
        if var theme = syntaxByName[name] {
            let copy = uniqueName(basedOn: name)
            theme = SyntaxTheme(name: copy, displayName: theme.displayName + " copy",
                                appearance: theme.appearance,
                                plain: theme.plain, keyword: theme.keyword,
                                command: theme.command, type: theme.type,
                                attribute: theme.attribute, variable: theme.variable,
                                value: theme.value, number: theme.number,
                                string: theme.string, comment: theme.comment)
            try save(theme)
            return copy
        }
        throw DuplicateError.notFound
    }

    /// "anura" → "anura-copy", then "anura-copy-2". Checked against every known
    /// name of either kind: the two share one namespace because a theme's name
    /// is also the key stored in settings.
    private func uniqueName(basedOn name: String) -> String {
        let base = name + "-copy"
        if kind(ofThemeNamed: base) == nil { return base }
        var suffix = 2
        while kind(ofThemeNamed: "\(base)-\(suffix)") != nil { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    // MARK: Filesystem

    /// The rawValue is the directory name, under both `Resources/Themes` and
    /// the user's Application Support dir.
    public enum Kind: String {
        case general = "General"
        case syntax = "Syntax"
    }

    /// The canonical, update-proof home for user themes:
    /// ~/Library/Application Support/Edmund/Themes/{General,Syntax}.
    public static func userDirectory(_ kind: Kind) -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Edmund/Themes/\(kind.rawValue)", isDirectory: true)
    }

    private static func load<T: Decodable>(_ type: T.Type, bundled subdirectory: String) -> [(T, URL)] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) ?? []
        return urls.compactMap { decode(type, $0) }
    }

    private static func load<T: Decodable>(_ type: T.Type, user directory: URL) -> [(T, URL)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap { decode(type, $0) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ url: URL) -> (T, URL)? {
        guard let data = try? Data(contentsOf: url),
              let theme = try? JSONDecoder().decode(T.self, from: data)
        else { return nil }
        return (theme, url)
    }
}
