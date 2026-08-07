import Testing
import AppKit
@testable import edmd

/// Settings ▸ Key Bindings: shortcut encoding, the override store, and the
/// conflict check that guards an assignment.
@MainActor
@Suite("Key bindings")
struct KeyBindingTests {

    /// A fresh, isolated UserDefaults domain so tests don't touch the real one.
    private func useFreshDefaults() {
        let suite = "KeyBindingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        KeyBindingStore.defaults = defaults
    }

    // MARK: - Renamed ids

    /// An override is filed under the command's id, so a rename has to carry it
    /// across — otherwise the shortcut silently stops applying, which does not
    /// even look like data loss to the user.
    @Test("A renamed command keeps the shortcut set under its old id")
    func migrationCarriesOverridesAcross() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdShift("t"), id: "view.typewriterScroll", default: nil)
        KeyBindingStore.migrateRenamedIDs()

        #expect(KeyBindingStore.effective(id: "edit.typewriterScroll", default: nil)
                == .cmdShift("t"))
        #expect(!KeyBindingStore.hasOverride(id: "view.typewriterScroll"))
    }

    /// A binding already set under the new id was chosen more recently than one
    /// stranded under the old one.
    @Test("Migration does not clobber a binding already set under the new id")
    func migrationPrefersTheNewID() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdShift("t"), id: "view.focusMode", default: nil)
        KeyBindingStore.setOverride(.cmdOpt("f"), id: "edit.focusMode", default: nil)
        KeyBindingStore.migrateRenamedIDs()

        #expect(KeyBindingStore.effective(id: "edit.focusMode", default: nil) == .cmdOpt("f"))
        #expect(!KeyBindingStore.hasOverride(id: "view.focusMode"))
    }

    @Test("Migration is a no-op when nothing was rebound")
    func migrationLeavesAnUntouchedStoreAlone() {
        useFreshDefaults()
        KeyBindingStore.migrateRenamedIDs()
        #expect(!KeyBindingStore.hasAnyOverride)
    }

    // MARK: - Shortcut coding

    @Test("Storage string round-trips every modifier combination")
    func storageRoundTrip() {
        let cases: [Shortcut] = [
            .cmd("b"),
            .cmdShift("b"),
            .cmdOpt("i"),
            Shortcut(key: "e", modifiers: [.command, .option, .control, .shift]),
            Shortcut(key: "-", modifiers: [.command]),
            // The key itself can be "+", which the decoder has to tell apart
            // from the separator.
            Shortcut(key: "+", modifiers: [.command, .shift]),
        ]
        for shortcut in cases {
            let decoded = Shortcut(storageString: shortcut.storageString)
            #expect(decoded == shortcut, "round-trip failed for \(shortcut.storageString)")
        }
    }

    @Test("Storage string is modifier-order independent")
    func storageCanonicalOrder() {
        let a = Shortcut(key: "b", modifiers: [.shift, .command])
        let b = Shortcut(key: "b", modifiers: [.command, .shift])
        #expect(a.storageString == b.storageString)
        #expect(a.storageString == "shift+cmd+b")
    }

    @Test("Garbage storage strings decode to nil")
    func storageRejectsGarbage() {
        #expect(Shortcut(storageString: "meta+b") == nil)
        #expect(Shortcut(storageString: "") == nil)
    }

    @Test("Display string uses ⌃⌥⇧⌘ order")
    func displayOrder() {
        #expect(Shortcut(key: "e", modifiers: [.command, .option, .control, .shift]).displayString == "⌃⌥⇧⌘E")
        #expect(Shortcut.cmd("b").displayString == "⌘B")
        #expect(Shortcut(key: " ", modifiers: [.command]).displayString == "⌘Space")
    }

    @Test("An uppercase key equivalent normalizes to lowercase plus Shift")
    func normalizeFoldsShift() {
        // AppKit spells ⇧⌘B as keyEquivalent "B" with only .command set; both
        // spellings have to compare equal or the conflict check misses them.
        let appKitStyle = Shortcut(key: "B", modifiers: [.command]).normalized
        #expect(appKitStyle == Shortcut.cmdShift("b"))
    }

    @Test("Normalize drops modifier bits that aren't ⌘⌥⌃⇧")
    func normalizeStripsStrayFlags() {
        let withFunctionBit = Shortcut(key: "0", modifiers: [.command, .function, .capsLock])
        #expect(withFunctionBit.normalized == Shortcut.cmd("0"))
    }

    @Test("A shortcut without ⌘ or ⌃ is not a usable key equivalent")
    func modifierGuard() {
        // A bare or Shift-only key equivalent fires while typing ordinary text.
        #expect(Shortcut(key: "b", modifiers: []).isValidKeyEquivalent == false)
        #expect(Shortcut(key: "b", modifiers: [.shift]).isValidKeyEquivalent == false)
        #expect(Shortcut(key: "b", modifiers: [.option]).isValidKeyEquivalent == false)
        #expect(Shortcut.cmd("b").isValidKeyEquivalent)
        #expect(Shortcut(key: "b", modifiers: [.control]).isValidKeyEquivalent)
    }

    // MARK: - Store

    @Test("With no override, a command keeps its default")
    func fallsBackToDefault() {
        useFreshDefaults()
        #expect(KeyBindingStore.effective(id: "format.bold", default: .cmd("b")) == .cmd("b"))
        #expect(KeyBindingStore.effective(id: "format.table", default: nil) == nil)
    }

    @Test("An override wins over the default and survives a re-read")
    func overrideWins() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdOpt("t"), id: "format.table", default: nil)
        #expect(KeyBindingStore.effective(id: "format.table", default: nil) == .cmdOpt("t"))
        #expect(KeyBindingStore.hasOverride(id: "format.table"))
        #expect(KeyBindingStore.hasAnyOverride)
    }

    @Test("Clearing a shortcut is stored, and is distinct from having no override")
    func clearedShortcutIsSticky() {
        useFreshDefaults()
        KeyBindingStore.setOverride(nil, id: "format.bold", default: .cmd("b"))
        // Not "fall back to ⌘B" — the user removed it on purpose.
        #expect(KeyBindingStore.effective(id: "format.bold", default: .cmd("b")) == nil)
        #expect(KeyBindingStore.hasOverride(id: "format.bold"))
    }

    @Test("Re-assigning the default drops the override instead of storing a no-op")
    func assigningDefaultClearsOverride() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdOpt("b"), id: "format.bold", default: .cmd("b"))
        KeyBindingStore.setOverride(.cmd("b"), id: "format.bold", default: .cmd("b"))
        #expect(KeyBindingStore.hasOverride(id: "format.bold") == false)
        #expect(KeyBindingStore.hasAnyOverride == false)
    }

    @Test("Restore Defaults removes every override")
    func restoreDefaults() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdOpt("t"), id: "format.table", default: nil)
        KeyBindingStore.setOverride(nil, id: "format.bold", default: .cmd("b"))
        KeyBindingStore.removeAllOverrides()
        #expect(KeyBindingStore.hasAnyOverride == false)
        #expect(KeyBindingStore.effective(id: "format.bold", default: .cmd("b")) == .cmd("b"))
    }

    // MARK: - Conflict detection

    /// A stand-in menu bar: a Format submenu with ⌘B, and a File submenu with the
    /// system ⌘S, so the search has to recurse and has to see non-Edmund items.
    private func sampleMenuBar() -> (menu: NSMenu, bold: NSMenuItem) {
        let root = NSMenu()

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let save = NSMenuItem(title: "Save", action: nil, keyEquivalent: "s")
        save.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(save)
        fileItem.submenu = fileMenu
        root.addItem(fileItem)

        let formatItem = NSMenuItem()
        let formatMenu = NSMenu(title: "Format")
        let bold = NSMenuItem(title: "Bold", action: nil, keyEquivalent: "b")
        bold.keyEquivalentModifierMask = [.command]
        formatMenu.addItem(bold)
        formatItem.submenu = formatMenu
        root.addItem(formatItem)

        return (root, bold)
    }

    @Test("A shortcut already used elsewhere in the menu bar is found")
    func findsConflict() {
        let (menu, _) = sampleMenuBar()
        let hit = KeyBindingConflict.conflictingItem(with: .cmd("b"), excluding: nil, in: menu)
        #expect(hit?.title == "Bold")
    }

    @Test("System shortcuts in other menus are found too")
    func findsSystemConflict() {
        let (menu, _) = sampleMenuBar()
        let hit = KeyBindingConflict.conflictingItem(with: .cmd("s"), excluding: nil, in: menu)
        #expect(hit?.title == "Save")
    }

    @Test("An item does not conflict with itself")
    func excludesEditedItem() {
        let (menu, bold) = sampleMenuBar()
        #expect(KeyBindingConflict.conflictingItem(with: .cmd("b"), excluding: bold, in: menu) == nil)
    }

    @Test("A free shortcut has no conflict")
    func noFalsePositive() {
        let (menu, _) = sampleMenuBar()
        #expect(KeyBindingConflict.conflictingItem(with: .cmdOpt("j"), excluding: nil, in: menu) == nil)
    }

    @Test("Conflicts match across ⇧-in-the-key and ⇧-in-the-mask spellings")
    func conflictMatchesNormalizedForms() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let submenu = NSMenu(title: "Edit")
        // AppKit's spelling of ⇧⌘Z: uppercase key, no explicit Shift in the mask.
        let redo = NSMenuItem(title: "Redo", action: nil, keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command]
        submenu.addItem(redo)
        item.submenu = submenu
        menu.addItem(item)

        let hit = KeyBindingConflict.conflictingItem(with: .cmdShift("z"), excluding: nil, in: menu)
        #expect(hit?.title == "Redo")
    }

    // MARK: - Catalog

    @Test("Building a command registers it and applies the user's override")
    func catalogRegistersAndAppliesOverride() {
        useFreshDefaults()
        KeyBindingStore.setOverride(.cmdOpt("q"), id: "test.command", default: .cmd("b"))

        let item = MenuCommand(id: "test.command", group: "Test", title: "Test Command",
                               action: #selector(NSApplication.terminate(_:)),
                               shortcut: .cmd("b")).makeItem()

        #expect(item.keyEquivalent == "q")
        #expect(item.keyEquivalentModifierMask == [.command, .option])

        let entry = KeyBindingCatalog.shared.entries.first { $0.id == "test.command" }
        #expect(entry?.group == "Test")
        #expect(entry?.defaultShortcut == .cmd("b"))
        #expect(entry?.item === item)

        // Restore Defaults path: drop the override, re-apply, item is back to ⌘B.
        KeyBindingStore.removeAllOverrides()
        KeyBindingCatalog.shared.reapplyAll()
        #expect(item.keyEquivalent == "b")
        #expect(item.keyEquivalentModifierMask == [.command])
    }

    @Test("Submenu commands are listed under a row for the submenu")
    func rowsNestSubmenuCommands() {
        useFreshDefaults()
        let group = "RowsTest"
        for command in [
            MenuCommand(id: "rows.top", group: group, title: "Top Level",
                        action: #selector(NSApplication.terminate(_:))),
            MenuCommand(id: "rows.sub1", group: group, submenu: "Sub", title: "First",
                        action: #selector(NSApplication.terminate(_:))),
            MenuCommand(id: "rows.sub2", group: group, submenu: "Sub", title: "Second",
                        action: #selector(NSApplication.terminate(_:))),
        ] { _ = command.makeItem() }

        let rows = KeyBindingCatalog.shared.rows(inGroup: group)
        #expect(rows.map(\.title) == ["Top Level", "Sub", "First", "Second"])
        #expect(rows.map(\.indented) == [false, false, true, true])
        // The submenu's own row is a heading, not an editable command.
        #expect(rows[1].entry == nil)
        #expect(rows[2].entry?.id == "rows.sub1")
    }
}
