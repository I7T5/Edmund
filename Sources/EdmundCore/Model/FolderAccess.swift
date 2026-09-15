import Foundation

/// Security-scoped folder grants for files *next to* a document — sibling
/// images and wiki-link targets.
///
/// Under the App Sandbox, opening `notes.md` grants `notes.md` only: a read of
/// `diagram.png` beside it is denied (the kernel logs `deny file-read-data`;
/// `fileExists` still answers true, so callers must ask `covers(_:)` rather
/// than stat the file). The user picks the folder once in an `NSOpenPanel`
/// (`EditorTextView.requestFolderAccess`); the app-scoped bookmark lives in
/// UserDefaults and covers every document in that folder, on every launch.
///
/// Stored grants are resolved lazily on the first query and their security
/// scope is started once for the life of the process — never stopped. A user
/// grants a handful of folders at most, and stopping would race with
/// documents still open in them.
///
/// Unsandboxed builds (`--variant adhoc`): `isSandboxed` is false, every
/// folder counts as covered, and `grant` is a no-op.
public enum FolderAccess {

    /// The sandbox sets this in the environment of every sandboxed process.
    public static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static let defaultsKey = "folderGrants"

    // ponytail: main-thread only (styling + panel completions), same as ThemeStore.
    /// Standardized folder path → URL whose security scope is active.
    nonisolated(unsafe) private static var active: [String: URL] = [:]
    nonisolated(unsafe) private static var loadedStored = false

    /// True when `url` sits in a granted folder (or the build isn't sandboxed).
    public static func covers(_ url: URL) -> Bool {
        guard isSandboxed else { return true }
        loadStored()
        return folder(covering: url.standardizedFileURL.path, in: Array(active.keys)) != nil
    }

    /// Stores an app-scoped bookmark for `folder` and starts access. `folder`
    /// must come from an open panel (that's what makes the bookmark creatable).
    public static func grant(_ folder: URL) {
        guard isSandboxed else { return }
        loadStored()
        guard let data = try? folder.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil) else { return }
        _ = folder.startAccessingSecurityScopedResource()
        active[folder.standardizedFileURL.path] = folder
        var stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        stored.append(data)
        UserDefaults.standard.set(stored, forKey: defaultsKey)
    }

    /// The granted folder that contains `path` (or is `path`), by path prefix
    /// on whole components — `/a/b` covers `/a/b/c.png`, not `/a/bc.png`.
    static func folder(covering path: String, in granted: [String]) -> String? {
        granted.first { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }

    /// Resolves every stored bookmark once, starting its scope. A bookmark that
    /// no longer resolves is dropped; a stale one is re-created from the
    /// resolved URL so it keeps working after the folder moved.
    private static func loadStored() {
        guard !loadedStored else { return }
        loadedStored = true
        let stored = UserDefaults.standard.array(forKey: defaultsKey) as? [Data] ?? []
        var kept: [Data] = []
        for data in stored {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  url.startAccessingSecurityScopedResource() else { continue }
            active[url.standardizedFileURL.path] = url
            let fresh = stale ? try? url.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) : nil
            kept.append(fresh ?? data)
        }
        if kept != stored { UserDefaults.standard.set(kept, forKey: defaultsKey) }
    }
}
