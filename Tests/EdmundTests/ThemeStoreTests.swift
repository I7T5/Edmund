import Testing
import AppKit
@testable import EdmundCore

/// Phase 1 of Settings ▸ Themes routed every editor color through `ThemeStore`
/// but must not have *changed* any of them. These are the parity goldens: the
/// expected values are transcribed from the code as it stood before the move,
/// not read back out of the new JSON — a test that compared the JSON to itself
/// would pass no matter how far the built-ins drifted.
/// Serialized: these tests share one on-disk store — `ThemeStore.shared` plus
/// the real user theme directory — and several of them write a shadow file for
/// the same bundled theme. Run concurrently, one test's shadow is visible to
/// another's assertions; `restoreAllBuiltIns` counts every shadowed built-in,
/// so it returned 2 where the test that created exactly one expected 1.
@Suite("Theme store — parity with the pre-theme palette", .serialized)
@MainActor
struct ThemeStoreTests {

    private let allTokens: [CodeHighlighter.TokenType?] = [
        nil, .keyword, .command, .type, .attribute,
        .variable, .value, .number, .string, .comment,
    ]

    // MARK: Bundled themes load at all

    @Test("Bundled themes are present")
    func bundledThemesLoad() {
        let store = ThemeStore.shared
        let generals = Set(store.generalThemes().map(\.name))
        let syntaxes = Set(store.syntaxThemes().map(\.name))
        #expect(generals.isSuperset(of: ["classic-light", "classic-dark"]))
        #expect(syntaxes.isSuperset(of: ["tomorrow", "one-dark"]))
    }

    @Test("Themes label with their appearance suffix only when it is needed")
    func labels() throws {
        let store = ThemeStore.shared
        // Classic ships in both, so the suffix separates them.
        #expect(store.label(for: store.general(dark: false)) == "Classic (Light)")
        // One Dark is the only theme of its name — One Light is a name of its
        // own — so it says what it is called and nothing more.
        #expect(store.label(for: try #require(store.syntax(dark: true))) == "One Dark")
    }

    // MARK: Syntax color parity

    /// The bundled Tomorrow / One Dark JSON must still agree with the palettes
    /// that used to be the only source. `builtinHex` is that original code,
    /// kept as the no-JSON fallback — so this also proves the fallback path
    /// stays interchangeable with the themed one.
    @Test("Bundled syntax themes match the compiled-in palettes")
    func syntaxThemeParity() {
        for dark in [false, true] {
            guard let theme = ThemeStore.shared.syntax(dark: dark) else {
                Issue.record("no syntax theme for dark=\(dark)")
                continue
            }
            for token in allTokens {
                #expect(theme.hex(token) == CodeSyntaxPalette.builtinHex(token, dark: dark),
                        "token \(String(describing: token)), dark=\(dark)")
            }
        }
    }

    /// The values every code block was colored with before this change, spelled
    /// out. If a bundled JSON is edited, this is what fails.
    @Test("Syntax colors are unchanged, literally")
    func syntaxColorLiterals() {
        let tomorrow = ["#4d4d4c", "#8959a8", "#4271ae", "#c18401", "#3e999f",
                        "#c82829", "#986801", "#f5871f", "#718c00", "#8e908c"]
        let oneDark = ["#abb2bf", "#c678dd", "#61afef", "#e5c07b", "#56b6c2",
                       "#e06c75", "#d19a66", "#d19a66", "#98c379", "#5c6370"]
        for (token, expected) in zip(allTokens, tomorrow) {
            #expect(CodeSyntaxPalette.hex(token, dark: false) == expected)
        }
        for (token, expected) in zip(allTokens, oneDark) {
            #expect(CodeSyntaxPalette.hex(token, dark: true) == expected)
        }
    }

    // MARK: General color parity

    /// Dark ink is the `#e6e6e6` Read mode has always used; light ink stays the
    /// *semantic* `textColor` rather than a hex, because it tracks Increase
    /// Contrast (see `EditorTheme.bodyTextColor`). So `classic-light` must leave
    /// `text` null — a hex there would silently drop that behavior.
    @Test("Body ink is unchanged")
    func bodyInkParity() {
        #expect(ThemeStore.shared.general(dark: false).text == nil)
        #expect(EditorTheme.bodyTextColor(dark: false) == .textColor)
        #expect(EditorTheme.bodyTextColor(dark: true)
                == NSColor(srgbRed: 230 / 255, green: 230 / 255, blue: 230 / 255, alpha: 1))
    }

    /// The appearance is pinned rather than inherited: an editor with no window
    /// resolves against `NSApp`, so these would otherwise assert light-mode
    /// values on a machine running dark and pass only in CI.
    @Test("Editor chrome colors are unchanged", arguments: [false, true])
    func chromeParity(dark: Bool) {
        let editor = makeEditor()
        editor.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        #expect(editor.selectionHighlightColor == .systemOrange.withAlphaComponent(0.3))
        #expect(editor.cursorColor == .controlAccentColor)
        #expect(editor.checkboxColor == .controlAccentColor)
        #expect(editor.linkColor == NSColor(hex: "#3366E6"))
        if dark {
            #expect(editor.editorBackgroundColor
                    == NSColor(srgbRed: 0x29 / 255.0, green: 0x29 / 255.0, blue: 0x29 / 255.0, alpha: 1.0))
        } else {
            #expect(editor.editorBackgroundColor == .textBackgroundColor)
        }
    }

    /// The dark page color moved from an `srgbRed:` literal in
    /// `editorBackgroundColor` into `classic-dark.json`. `NSColor(hex:)` decodes
    /// as sRGB, so the two are the same color — but only if the JSON says
    /// exactly `#292929`.
    @Test("Dark page color survives the move to JSON")
    func darkBackgroundParity() {
        let hex = ThemeStore.shared.general(dark: true).background
        #expect(hex == "#292929")
        #expect(NSColor(hex: hex ?? "") == NSColor(srgbRed: 0x29 / 255.0, green: 0x29 / 255.0,
                                                   blue: 0x29 / 255.0, alpha: 1.0))
    }

    // MARK: Read mode follows the same store

    @Test("Read mode CSS still emits the same colors")
    func readModeParity() {
        let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                codeHex: "#8A2425",
                                lineSpacing: 4, paragraphSpacingBefore: 2)
        let light = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
        let dark = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: true)
        #expect(light.contains("--accent: #3366E6;"))
        #expect(light.contains("--bg: #ffffff;"))
        #expect(dark.contains("--bg: #292929;"))
        #expect(light.contains("pre code .tok-keyword { color: #8959a8; }"))
        #expect(dark.contains("pre code .tok-keyword { color: #c678dd; }"))
    }

    /// The properties above being right is not the same as them being *applied*.
    /// `commonInit` and `viewDidChangeEffectiveAppearance` now share one
    /// `applyChromeColors()`; if that call were dropped from either, every color
    /// test would still pass while the editor drew AppKit's defaults.
    @Test("Chrome colors are pushed onto the view, not just computed")
    func chromeColorsAreApplied() {
        let editor = makeEditor()
        editor.appearance = NSAppearance(named: .aqua)
        editor.viewDidChangeEffectiveAppearance()

        #expect(editor.backgroundColor == editor.editorBackgroundColor)
        #expect(editor.insertionPointColor == editor.cursorColor)
        #expect(editor.selectedTextAttributes[.backgroundColor] as? NSColor
                == editor.selectionHighlightColor)
        #expect(editor.selectedTextAttributes[.foregroundColor] as? NSColor
                == editor.foregroundColor)
    }

    // MARK: Degradation

    /// A theme name that no longer exists on disk — a deleted user theme still
    /// named in settings — must fall back rather than leave the editor
    /// colorless.
    @Test("An unknown active theme name falls back to the built-in")
    func unknownThemeFallsBack() {
        let store = ThemeStore.shared
        let original = store.activeGeneralLight
        defer { store.activeGeneralLight = original }

        store.activeGeneralLight = "no-such-theme"
        #expect(store.general(dark: false).name == "classic-light")
    }

    // MARK: Deletion

    /// The one destructive operation the pane has. It must refuse a built-in
    /// rather than no-op: the Delete button reads a thrown error as "nothing
    /// happened", while silence would read as "deleted" and leave the row.
    @Test("Deleting a built-in theme is refused, and leaves it on disk")
    func deletingBuiltInIsRefused() {
        let store = ThemeStore.shared
        #expect(throws: ThemeStore.DeleteError.builtIn) {
            try store.deleteUserTheme(named: "classic-light")
        }
        #expect(store.generalThemes().contains { $0.name == "classic-light" })
    }

    /// "(Light)"/"(Dark)" earns its place only when it separates two themes of
    /// the same name. Solarized ships in both, so both say which; Tomorrow
    /// Night is the only theme called that, and a suffix there would tell the
    /// reader what the name already says.
    @Test("An appearance suffix appears only where it disambiguates")
    func labelsQualifyOnlyWhenAmbiguous() throws {
        let store = ThemeStore.shared
        let syntax = store.syntaxThemes()

        let solarized = syntax.filter { $0.displayName == "Solarized" }
        #expect(solarized.count == 2)
        for theme in solarized {
            #expect(store.label(for: theme) == theme.qualifiedLabel)
        }

        for name in ["Tomorrow", "Tomorrow Night", "One Light", "One Dark"] {
            let theme = try #require(syntax.first { $0.displayName == name })
            #expect(store.label(for: theme) == name)
        }

        // The editor themes shipped in pairs from the start.
        for theme in store.generalThemes() where theme.displayName == "Classic" {
            #expect(store.label(for: theme) == theme.qualifiedLabel)
        }
    }

    /// Every bundled theme is loadable and complete. A color that failed to
    /// parse would fall back silently at render time, so the check is here.
    @Test("Every bundled syntax theme parses to ten usable colors")
    func bundledSyntaxThemesAreComplete() throws {
        for theme in ThemeStore.shared.syntaxThemes() {
            for (scope, hex) in [("plain", theme.plain), ("keyword", theme.keyword),
                                 ("command", theme.command), ("type", theme.type),
                                 ("attribute", theme.attribute), ("variable", theme.variable),
                                 ("value", theme.value), ("number", theme.number),
                                 ("string", theme.string), ("comment", theme.comment)] {
                #expect(NSColor(hex: hex) != nil,
                        "\(theme.name).\(scope) is not a color: \(hex)")
            }
        }
    }

    /// The code block's page comes from the code theme now, and Edit mode and
    /// Read mode have to land on the same one — two renderers reading one
    /// value is exactly the pair that drifts when nobody is looking.
    ///
    /// Driven through the editor theme, because that is what decides: an editor
    /// theme's own assignment wins over the standalone active-syntax name.
    @Test("Edit and Read agree on the code block background")
    func codeBackgroundMatchesAcrossModes() throws {
        let store = ThemeStore.shared
        let saved = store.activeGeneralLight
        defer { store.activeGeneralLight = saved }
        // Start from what ships. A run killed mid-test leaves its shadow files
        // behind, and a stale shadow of either theme here would make this
        // assert against someone else's edit.
        try? store.restoreBuiltIn(named: "solarized-code-light")
        try? store.restoreBuiltIn(named: "solarized-light")
        store.reload()

        // Solarized names its own page; Classic's Tomorrow names none.
        for (editorTheme, expected) in [("solarized-light", "#eee8d5"),
                                        ("classic-light",
                                         SyntaxTheme.defaultBackgroundHex(dark: false))] {
            store.activeGeneralLight = editorTheme
            let resolved = store.syntax(dark: false)?.background
                ?? SyntaxTheme.defaultBackgroundHex(dark: false)
            #expect(resolved.lowercased() == expected.lowercased(),
                    "Edit mode resolved \(resolved) for \(editorTheme)")

            let theme = EditorTheme(fontName: "Iowan Old Style", fontSize: 16,
                                    codeHex: "#8A2425",
                                    lineSpacing: 4, paragraphSpacingBefore: 2)
            let css = HTMLTheme.css(theme, callouts: Callout.defaultStyles, dark: false)
            #expect(css.contains("--code-bg: \(expected);"),
                    "Read mode did not use \(expected) for \(editorTheme)")
        }
    }

    /// A copy that lost the original's page would be a copy of a different
    /// theme — the same trap `duplicate` has for every field it rebuilds.
    @Test("Duplicating a code theme carries its background")
    func duplicateKeepsSyntaxBackground() throws {
        let store = ThemeStore.shared
        var made: [String] = []
        defer {
            for name in made {
                try? FileManager.default.removeItem(
                    at: ThemeStore.userDirectory(.syntax).appendingPathComponent("\(name).json"))
            }
            store.reload()
        }

        // Same reason as above: the copy is of whatever is loaded, and a stale
        // shadow would make it a copy of the wrong thing.
        try? store.restoreBuiltIn(named: "solarized-code-light")
        store.reload()

        let copy = try store.duplicate("solarized-code-light")
        made.append(copy)
        let made_ = try #require(store.syntaxThemes().first { $0.name == copy })
        #expect(made_.background == "#eee8d5")
    }

    // MARK: Writing

    /// The inheritance model rides on this. A color a theme does not set is
    /// `nil`, meaning "use the platform default for this role", and a syntax
    /// theme it does not name is `nil` too; if a save/load round trip turned
    /// either into a concrete value, the theme would quietly stop following
    /// what it was following and nothing would look broken until someone
    /// noticed their setting had no effect.
    @Test("Unassigned values survive a save and load as nil, not as zeros")
    func nilsSurviveRoundTrip() throws {
        let store = ThemeStore.shared
        let name = "test-nil-\(UUID().uuidString.prefix(8))"
        let theme = GeneralTheme(name: name, displayName: "Test", appearance: .light,
                                 text: "#111111", invisibles: nil, checkbox: nil,
                                 link: nil, background: nil, selection: nil, cursor: nil,
                                 syntaxTheme: nil)
        defer {
            try? FileManager.default.removeItem(
                at: ThemeStore.userDirectory(.general).appendingPathComponent("\(name).json"))
            store.reload()
        }

        try store.save(theme)
        let loaded = try #require(store.generalThemes().first { $0.name == name })

        #expect(loaded.text == "#111111")
        #expect(loaded.invisibles == nil)
        #expect(loaded.selection == nil)
        #expect(loaded.cursor == nil)
        #expect(loaded.syntaxTheme == nil)
        // Equality covers the rest, and catches a field added later that the
        // expectations above forget about.
        #expect(loaded == theme)
    }

    @Test("Duplicating an editor theme carries every color across")
    func duplicateGeneralKeepsEveryColor() throws {
        let store = ThemeStore.shared
        let directory = ThemeStore.userDirectory(.general)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "test-dup-\(UUID().uuidString.prefix(8))"
        let url = directory.appendingPathComponent("\(name).json")
        var made: [String] = []
        defer {
            try? FileManager.default.removeItem(at: url)
            for copy in made {
                try? FileManager.default.removeItem(
                    at: directory.appendingPathComponent("\(copy).json"))
            }
            store.reload()
        }

        // Every color set to a distinct value, so a field the copy drops cannot
        // coincide with the one it should have had.
        let json = """
        {"name": "\(name)", "displayName": "Test", "appearance": "light",
         "text": "#111111", "invisibles": "#222222", "checkbox": "#333333",
         "link": "#444444", "highlight": "#555555", "background": "#666666",
         "selection": "#777777", "cursor": "#888888", "syntaxTheme": "tomorrow"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        store.reload()

        let copyName = try store.duplicate(name)
        made.append(copyName)
        let original = try #require(store.generalThemes().first { $0.name == name })
        let copy = try #require(store.generalThemes().first { $0.name == copyName })

        // Compared whole rather than color by color: `duplicate` rebuilds the
        // struct field by field, so a color added later and forgotten there is
        // caught here instead of by a user noticing it vanished on Duplicate.
        // Only the two fields a copy is meant to change may differ.
        let encoder = JSONEncoder()
        func fields(_ theme: GeneralTheme) throws -> [String: String] {
            let object = try JSONSerialization.jsonObject(with: encoder.encode(theme))
            var dictionary = try #require(object as? [String: Any])
            dictionary.removeValue(forKey: "name")
            dictionary.removeValue(forKey: "displayName")
            return dictionary.mapValues { String(describing: $0) }
        }
        #expect(try fields(copy) == fields(original))
        #expect(copy.displayName == original.displayName + " copy")
    }

    @Test("Duplicating a theme names the copy uniquely and keeps its colors")
    func duplicateNamesAndCopies() throws {
        let store = ThemeStore.shared
        var made: [String] = []
        defer {
            for name in made {
                try? FileManager.default.removeItem(
                    at: ThemeStore.userDirectory(.syntax).appendingPathComponent("\(name).json"))
            }
            store.reload()
        }

        let first = try store.duplicate("tomorrow")
        made.append(first)
        #expect(first == "tomorrow-copy")

        let second = try store.duplicate("tomorrow")
        made.append(second)
        #expect(second == "tomorrow-copy-2")

        let copy = try #require(store.syntaxThemes().first { $0.name == first })
        let original = try #require(store.syntaxThemes().first { $0.name == "tomorrow" })
        #expect(copy.keyword == original.keyword)
        #expect(copy.displayName == original.displayName + " copy")
        #expect(store.isUserTheme(first))
    }

    /// Editing a built-in writes a file that shadows the bundled one; the
    /// bundled copy inside the app is never touched, which is what lets Restore
    /// put the original back by simply dropping the shadow.
    @Test("A built-in can be edited, and restored by dropping the edit")
    func builtInEditsAreShadowsAndRestore() throws {
        let store = ThemeStore.shared
        let original = try #require(store.syntaxThemes().first { $0.name == "tomorrow" })
        defer {
            try? FileManager.default.removeItem(
                at: ThemeStore.userDirectory(.syntax).appendingPathComponent("tomorrow.json"))
            store.reload()
        }

        var edited = original
        edited.keyword = "#ABCDEF"
        try store.save(edited)

        #expect(store.syntaxThemes().first { $0.name == "tomorrow" }?.keyword == "#ABCDEF")
        #expect(store.isEditedBuiltIn("tomorrow"))
        // Still a built-in — an edit does not make it the user's to delete.
        #expect(store.isBuiltIn("tomorrow"))

        try store.restoreBuiltIn(named: "tomorrow")

        #expect(store.syntaxThemes().first { $0.name == "tomorrow" }?.keyword == original.keyword)
        #expect(!store.isEditedBuiltIn("tomorrow"))
    }

    /// Restore-all drops every edited built-in and leaves themes the user made
    /// alone: those shadow nothing, so removing them would be a deletion
    /// wearing a restore's name.
    @Test("Restoring all built-ins spares user-created themes")
    func restoreAllSparesUserThemes() throws {
        let store = ThemeStore.shared
        let mine = try store.duplicate("tomorrow")
        defer {
            try? FileManager.default.removeItem(
                at: ThemeStore.userDirectory(.syntax).appendingPathComponent("\(mine).json"))
            try? FileManager.default.removeItem(
                at: ThemeStore.userDirectory(.syntax).appendingPathComponent("tomorrow.json"))
            store.reload()
        }

        var edited = try #require(store.syntaxThemes().first { $0.name == "tomorrow" })
        let originalKeyword = edited.keyword
        edited.keyword = "#ABCDEF"
        try store.save(edited)

        let restored = store.restoreAllBuiltIns()

        #expect(restored == 1)
        #expect(store.syntaxThemes().first { $0.name == "tomorrow" }?.keyword == originalKeyword)
        #expect(store.syntaxThemes().contains { $0.name == mine })
        #expect(store.isUserTheme(mine))
    }

    /// A theme can name a syntax theme that is not there — deleted here, its
    /// file removed in the Finder, or an editor theme shared by someone whose
    /// syntax themes you do not have. Code has to keep its colors through that:
    /// a nil here would render a fenced block in no theme at all.
    @Test("An editor theme naming a missing syntax theme still resolves")
    func danglingSyntaxReferenceFallsBack() throws {
        let store = ThemeStore.shared
        let directory = ThemeStore.userDirectory(.general)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "test-dangling-\(UUID().uuidString.prefix(8))"
        let url = directory.appendingPathComponent("\(name).json")
        let savedLight = store.activeGeneralLight
        defer {
            try? FileManager.default.removeItem(at: url)
            store.activeGeneralLight = savedLight
            store.reload()
        }

        let json = """
        {"name": "\(name)", "displayName": "Test", "appearance": "light",
         "text": null, "invisibles": null, "checkbox": null, "link": null,
         "highlight": null, "background": null, "selection": null,
         "cursor": null, "syntaxTheme": "no-such-theme"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        store.reload()
        store.activeGeneralLight = name

        let resolved = try #require(store.syntax(dark: false))
        // Whichever theme it lands on, it must be a real one with real colors.
        #expect(resolved.name != "no-such-theme")
        #expect(!resolved.keyword.isEmpty)
    }

    // MARK: Overrides

    /// An editor theme that pins a syntax theme wins over the General row's
    /// choice; one that pins none — the default — leaves General's alone. This
    /// is the only override wired to the editor so far, so it is the only one
    /// that can be asserted end to end.
    @Test("An editor theme's own syntax theme overrides the General default")
    func assignedSyntaxThemeOverridesGeneral() throws {
        let store = ThemeStore.shared
        let name = "test-pin-\(UUID().uuidString.prefix(8))"
        let pinned = GeneralTheme(name: name, displayName: "Pinned", appearance: .light,
                                  syntaxTheme: "one-dark")
        let originalActive = store.activeGeneralLight
        let originalSyntax = store.activeSyntaxLight
        defer {
            store.activeGeneralLight = originalActive
            store.activeSyntaxLight = originalSyntax
            try? FileManager.default.removeItem(
                at: ThemeStore.userDirectory(.general).appendingPathComponent("\(name).json"))
            store.reload()
        }

        try store.save(pinned)
        store.activeSyntaxLight = "tomorrow"

        // With the stock editor theme, General's choice stands.
        store.activeGeneralLight = "classic-light"
        #expect(store.syntax(dark: false)?.name == "tomorrow")

        // With the pinning theme in use, its own choice does.
        store.activeGeneralLight = name
        #expect(store.syntax(dark: false)?.name == "one-dark")
    }

    @Test("Deleting an unknown theme reports it as missing")
    func deletingUnknownThrows() {
        #expect(throws: ThemeStore.DeleteError.notFound) {
            try ThemeStore.shared.deleteUserTheme(named: "no-such-theme")
        }
    }

    /// The real path, exercised against a genuine file in the user directory —
    /// the store only treats a theme as deletable when it loaded it from there.
    @Test("Deleting a user theme removes its file and drops it from the list")
    func deletingUserThemeRemovesIt() throws {
        let store = ThemeStore.shared
        let directory = ThemeStore.userDirectory(.syntax)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A name no bundled theme uses, so the test can't shadow a real one.
        let name = "test-delete-\(UUID().uuidString.prefix(8))"
        let url = directory.appendingPathComponent("\(name).json")
        let json = """
        {"name": "\(name)", "displayName": "Test", "appearance": "light",
         "plain": "#000000", "keyword": "#000000", "command": "#000000",
         "type": "#000000", "attribute": "#000000", "variable": "#000000",
         "value": "#000000", "number": "#000000", "string": "#000000",
         "comment": "#000000"}
        """
        try json.write(to: url, atomically: true, encoding: .utf8)
        // Leave nothing behind if an expectation below fails early.
        defer {
            try? FileManager.default.removeItem(at: url)
            store.reload()
        }

        store.reload()
        #expect(store.syntaxThemes().contains { $0.name == name })
        #expect(store.isUserTheme(name))

        try store.deleteUserTheme(named: name)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!store.syntaxThemes().contains { $0.name == name })
    }
}
