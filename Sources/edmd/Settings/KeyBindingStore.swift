// KeyBindingStore — user overrides for menu-command shortcuts.
//
// Every rebindable command is a `MenuCommand` with a stable `id` and a default
// `Shortcut` (see FormatMenu.swift). `makeItem()` asks this store for an
// override before building the NSMenuItem, and registers the built item in
// `KeyBindingCatalog` so the Settings pane can list it and retune it live.
//
// Only Edmund's own commands are rebindable. The OS-standard items (New, Save,
// Cut/Copy/Paste, Undo/Redo, Quit, Minimize, …) keep their hardcoded key
// equivalents: they are muscle memory, and several are AppKit selectors that
// the system may re-decorate anyway.

import AppKit

// MARK: - Shortcut coding & display

extension Shortcut {
    /// The modifier flags a shortcut may carry. Anything else (Caps Lock, the
    /// `.function` bit AppKit sets for arrow/F-keys) is stripped before compare.
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// Canonical string form for UserDefaults, e.g. `"cmd+shift+b"`. Stable
    /// across launches and independent of modifier ordering.
    var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    init?(storageString: String) {
        // The key itself may be "+", so split off the last component by index
        // rather than taking the last split piece.
        guard let lastPlus = storageString.lastIndex(of: "+"),
              lastPlus != storageString.startIndex else {
            guard !storageString.isEmpty else { return nil }
            self.init(key: storageString, modifiers: [])
            return
        }
        // An empty tail means the final "+" *is* the key ("cmd++").
        let key = String(storageString[storageString.index(after: lastPlus)...])
        let modifierPart = String(storageString[storageString.startIndex..<lastPlus])
        var modifiers: NSEvent.ModifierFlags = []
        for token in modifierPart.split(separator: "+") {
            switch token {
            case "ctrl": modifiers.insert(.control)
            case "opt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            case "cmd": modifiers.insert(.command)
            default: return nil
            }
        }
        self.init(key: key.isEmpty ? "+" : key, modifiers: modifiers)
    }

    /// The shortcut as macOS writes it in a menu: ⌃⌥⇧⌘ in that order, then the key.
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Shortcut.displayKey(key)
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case " ": return "Space"
        case "\t": return "⇥"
        case "\r": return "↩"
        case "\u{8}", "\u{7f}": return "⌫"
        case "\u{1b}": return "⎋"
        default: return key.uppercased()
        }
    }

    /// Normalized for comparison: lowercased key with an uppercase letter folded
    /// into an explicit Shift, and only the four real modifier bits kept.
    /// AppKit treats `keyEquivalent: "B"` with no mask as ⇧⌘B, so the two spellings
    /// have to compare equal or the conflict check misses them.
    var normalized: Shortcut {
        var modifiers = self.modifiers.intersection(Shortcut.allowedModifiers)
        var key = self.key
        if key.count == 1, key.lowercased() != key {
            key = key.lowercased()
            modifiers.insert(.shift)
        }
        return Shortcut(key: key, modifiers: modifiers)
    }

    /// Whether this is safe to install as a menu key equivalent. A key with no
    /// ⌘ or ⌃ fires on ordinary typing — Shift-only or bare letters would make
    /// the editor unusable, so they are refused.
    var isValidKeyEquivalent: Bool {
        guard !key.isEmpty else { return false }
        return modifiers.contains(.command) || modifiers.contains(.control)
    }
}

// MARK: - Store

/// Persisted per-command shortcut overrides, keyed by `MenuCommand.id`.
///
/// An entry's value is a `Shortcut.storageString`; the empty string means "the
/// user deliberately removed this shortcut", which is distinct from having no
/// entry at all (fall back to the command's default).
@MainActor
enum KeyBindingStore {
    static let defaultsKey = "settings.keyBindings"

    /// Swapped for an isolated suite in tests; the app always uses `.standard`.
    static var defaults: UserDefaults = .standard

    private static var overrides: [String: String] {
        get { defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set {
            if newValue.isEmpty {
                defaults.removeObject(forKey: defaultsKey)
            } else {
                defaults.set(newValue, forKey: defaultsKey)
            }
        }
    }

    /// The shortcut a command should actually use: its override if one is set,
    /// otherwise its default.
    static func effective(id: String, default defaultShortcut: Shortcut?) -> Shortcut? {
        guard let raw = overrides[id] else { return defaultShortcut }
        return raw.isEmpty ? nil : Shortcut(storageString: raw)
    }

    static func hasOverride(id: String) -> Bool { overrides[id] != nil }

    static var hasAnyOverride: Bool { !overrides.isEmpty }

    /// Records an override. `nil` stores "no shortcut"; pass a shortcut equal to
    /// the command's default to drop the override instead of storing a no-op.
    static func setOverride(_ shortcut: Shortcut?, id: String, default defaultShortcut: Shortcut?) {
        var dict = overrides
        if shortcut?.normalized == defaultShortcut?.normalized {
            dict.removeValue(forKey: id)
        } else {
            dict[id] = shortcut?.storageString ?? ""
        }
        overrides = dict
    }

    /// Drops every override. The caller re-applies defaults to the live menu.
    static func removeAllOverrides() {
        overrides = [:]
    }

    /// Commands whose `id` has changed, old to new.
    ///
    /// An override is filed under the command's id, so renaming one strands the
    /// user's shortcut under a key nothing reads again — it does not revert to
    /// the default, it silently stops applying. Anything renamed belongs here.
    private static let renamedIDs = [
        "view.typewriterScroll": "edit.typewriterScroll",
        "view.focusMode": "edit.focusMode",
    ]

    /// Re-files overrides left under an old id. Runs once, before the menus are
    /// built, so `effective(id:default:)` finds them under the new name.
    static func migrateRenamedIDs() {
        var dict = overrides
        var changed = false
        for (old, new) in renamedIDs {
            guard let shortcut = dict.removeValue(forKey: old) else { continue }
            changed = true
            // A binding already set under the new id was chosen more recently
            // than one stranded under the old one; leave it alone.
            if dict[new] == nil { dict[new] = shortcut }
        }
        if changed { overrides = dict }
    }
}

// MARK: - Catalog

/// Every rebindable command that has been built into the menu bar, in menu
/// order, with a weak handle on the live `NSMenuItem` so the Settings pane can
/// retune a shortcut without rebuilding the menu bar.
@MainActor
final class KeyBindingCatalog {
    static let shared = KeyBindingCatalog()

    struct Entry: Identifiable {
        let id: String
        let group: String
        /// The submenu the command lives in, if any (see `MenuCommand.submenu`).
        let submenu: String?
        let title: String
        let defaultShortcut: Shortcut?
        weak var item: NSMenuItem?
    }

    /// One line of the Settings command list: either a command, or the title of
    /// the submenu whose (indented) commands follow it.
    struct Row: Identifiable {
        let id: String
        let title: String
        /// The submenu this row belongs to — a submenu's own title row included,
        /// which is what the disclosure triangle collapses.
        let submenu: String?
        let entry: Entry?

        /// A command inside a submenu, i.e. a row that hides when collapsed.
        var indented: Bool { entry != nil && submenu != nil }
    }

    private(set) var entries: [Entry] = []

    /// The menu names, in the order their commands were registered.
    var groups: [String] {
        var seen: Set<String> = []
        return entries.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    func entries(inGroup group: String) -> [Entry] {
        entries.filter { $0.group == group }
    }

    /// The group's commands in menu order, with each submenu's title inserted
    /// above its commands — the nesting the menu bar itself shows. Commands of
    /// one submenu are registered contiguously (the submenu is built in one go),
    /// so a title is emitted whenever the submenu changes.
    func rows(inGroup group: String) -> [Row] {
        var rows: [Row] = []
        var currentSubmenu: String?
        for entry in entries where entry.group == group {
            if entry.submenu != currentSubmenu {
                currentSubmenu = entry.submenu
                if let submenu = currentSubmenu {
                    rows.append(Row(id: "\(group)/\(submenu)", title: submenu,
                                    submenu: submenu, entry: nil))
                }
            }
            rows.append(Row(id: entry.id, title: entry.title,
                            submenu: entry.submenu, entry: entry))
        }
        return rows
    }

    /// Called by `MenuCommand.makeItem()`. The Font submenu is rebuilt for every
    /// editor right-click, so an id can be registered many times — keep the first
    /// live item (the menu-bar one, built at launch) rather than repointing the
    /// catalog at a throwaway context menu that is gone by the time the user
    /// edits its shortcut.
    func register(id: String, group: String, submenu: String? = nil, title: String,
                  defaultShortcut: Shortcut?, item: NSMenuItem) {
        if let index = entries.firstIndex(where: { $0.id == id }) {
            guard entries[index].item == nil else { return }
            entries[index].item = item
            return
        }
        entries.append(Entry(id: id, group: group, submenu: submenu, title: title,
                             defaultShortcut: defaultShortcut, item: item))
    }

    /// Pushes a shortcut onto the live menu item.
    func apply(_ shortcut: Shortcut?, toItemWithID id: String) {
        guard let item = entries.first(where: { $0.id == id })?.item else { return }
        item.keyEquivalent = shortcut?.key ?? ""
        item.keyEquivalentModifierMask = shortcut?.modifiers ?? []
    }

    /// Re-reads every registered command's effective shortcut onto its menu item.
    /// Used by Restore Defaults.
    func reapplyAll() {
        for entry in entries {
            let shortcut = KeyBindingStore.effective(id: entry.id, default: entry.defaultShortcut)
            entry.item?.keyEquivalent = shortcut?.key ?? ""
            entry.item?.keyEquivalentModifierMask = shortcut?.modifiers ?? []
        }
    }
}

// MARK: - Conflict detection

@MainActor
enum KeyBindingConflict {
    /// The menu item already using `shortcut`, if any — searched across the whole
    /// live menu bar, not just the rebindable catalog, so system items (⌘S, ⌘C)
    /// and AppKit's injected ones are caught too.
    ///
    /// `excluding` is the item being edited: re-typing an item's current shortcut
    /// must not report the item conflicting with itself.
    static func conflictingItem(with shortcut: Shortcut,
                                excluding editedItem: NSMenuItem?,
                                in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        guard let menu else { return nil }
        let target = shortcut.normalized
        for item in menu.items {
            if let submenu = item.submenu,
               let hit = conflictingItem(with: shortcut, excluding: editedItem, in: submenu) {
                return hit
            }
            guard item !== editedItem, !item.keyEquivalent.isEmpty else { continue }
            let existing = Shortcut(key: item.keyEquivalent,
                                    modifiers: item.keyEquivalentModifierMask).normalized
            if existing == target { return item }
        }
        return nil
    }

    /// Why a shortcut can't be assigned, or nil if it can.
    static func rejectionReason(for shortcut: Shortcut, excluding editedItem: NSMenuItem?) -> String? {
        guard shortcut.isValidKeyEquivalent else {
            return "A shortcut must include ⌘ or ⌃."
        }
        guard let clash = conflictingItem(with: shortcut, excluding: editedItem) else { return nil }
        return "\(shortcut.displayString) is already used by “\(clash.title)”."
    }
}
