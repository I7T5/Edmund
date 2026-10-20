import Foundation

// MARK: - Syntax Definition Store
//
// Loads language definitions from two sources — the bundled JSON under
// Resources/Syntaxes and the user's Application Support dir — and resolves a
// fence's info string (or its alias) to a definition. A user def overrides a
// bundled one of the same name, which is what makes a bundled language
// customizable: drop a same-named JSON and it wins.
//
// ponytail: not thread-safe. Tokenization runs during rendering (main thread) and
// the app pushes config / reloads on the main thread, so a plain shared instance
// is enough. Add a lock only if a background tokenizer ever appears.

public final class SyntaxDefinitionStore {
    // ponytail: single-thread (main) use — see the type note above. Matches the
    // codebase's `nonisolated(unsafe)` singleton idiom (Log, image caches).
    nonisolated(unsafe) public static let shared = SyntaxDefinitionStore()

    /// The outcome of resolving a fence's language against the loaded defs.
    enum Resolution: Equatable {
        case plain                              // explicitly no highlighting
        case definition(LanguageDefinition)     // a known language
        case unknown                            // tagged, but no def → C-family fallback
    }

    /// The language a fence with no info string is highlighted as. "plain" = none.
    public var defaultLanguage: String = "plain"

    private var byName: [String: LanguageDefinition] = [:]   // name + aliases → def
    private var ordered: [LanguageDefinition] = []           // dedup by name, for the UI list
    private var userNames: Set<String> = []                  // names sourced from the user dir
    private var sourceURLs: [String: URL] = [:]              // canonical name → backing JSON file

    /// Info-string spellings that mean "no highlighting".
    private static let plainAliases: Set<String> =
        ["", "plain", "plaintext", "text", "none", "txt"]

    init() { reload() }

    // MARK: Loading

    /// Rebuild the tables from bundled + user defs. Call after an import/removal.
    public func reload() {
        var map: [String: LanguageDefinition] = [:]
        var list: [LanguageDefinition] = []
        var users: Set<String> = []
        var sources: [String: URL] = [:]

        func add(_ def: LanguageDefinition, url: URL, user: Bool) {
            if let i = list.firstIndex(where: { $0.name == def.name }) { list[i] = def }
            else { list.append(def) }
            map[def.name] = def
            for a in def.aliases { map[a] = def }
            sources[def.name] = url
            if user { users.insert(def.name) } else { users.remove(def.name) }
        }

        for (def, url) in Self.loadBundled() { add(def, url: url, user: false) }
        for (def, url) in Self.loadUser()    { add(def, url: url, user: true) }  // user overrides bundled

        byName = map
        ordered = list.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        userNames = users
        sourceURLs = sources
    }

    // MARK: Resolution

    func resolve(_ language: String?) -> Resolution {
        let key = (language ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if Self.plainAliases.contains(key) { return .plain }
        if let def = byName[key] { return .definition(def) }
        return .unknown
    }

    // MARK: UI queries

    /// `(id, label)` rows for the settings popup / list, "Plain Text" first.
    public func availableLanguages() -> [(id: String, label: String)] {
        [("plain", "Plain Text")] + ordered.map { (id: $0.name, label: $0.label) }
    }

    public func isUserDefinition(_ name: String) -> Bool { userNames.contains(name.lowercased()) }

    /// The JSON file backing a def (user copy if it overrides, else bundled).
    public func fileURL(forName name: String) -> URL? { sourceURLs[name.lowercased()] }

    // MARK: Filesystem

    /// The canonical, update-proof home for user-editable defs:
    /// ~/Library/Application Support/Edmund/Syntaxes. Survives app and macOS
    /// updates (unlike an in-bundle path).
    public static var userDirectory: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Edmund/Syntaxes", isDirectory: true)
    }

    private static func loadBundled() -> [(LanguageDefinition, URL)] {
        let urls = Bundle.edmundCore.urls(forResourcesWithExtension: "json", subdirectory: "Syntaxes") ?? []
        return urls.compactMap(decode)
    }

    private static func loadUser() -> [(LanguageDefinition, URL)] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: userDirectory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension.lowercased() == "json" }.compactMap(decode)
    }

    private static func decode(_ url: URL) -> (LanguageDefinition, URL)? {
        guard let data = try? Data(contentsOf: url),
              let def = try? JSONDecoder().decode(LanguageDefinition.self, from: data)
        else { return nil }
        return (def, url)
    }
}
