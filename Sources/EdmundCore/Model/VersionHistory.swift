import Foundation

// MARK: - Version history model
//
// Edmund keeps NO version history of its own. macOS's "Auto Save with Versions"
// (opted into via Document.autosavesInPlace) stores historical copies in a hidden,
// per-volume system store. The only sanctioned way to read or delete them is
// `NSFileVersion`, and it works one known file URL at a time — there is no API to
// enumerate "all versioned files". So the popup can only surface documents whose URL
// we already have (recent/open docs, or a folder the user asks us to scan).
//
// This file is split so the grouping/filtering logic is unit-testable without touching
// the disk; the `VersionHistoryStore` I/O layer does the NSFileVersion calls.

/// One historical (non-current) version of a document.
public struct VersionInfo: Identifiable, Hashable, Sendable {
    /// The version's own store URL — unique per version within a single query.
    public let id: URL
    /// The live document this version belongs to.
    public let sourceURL: URL
    public let date: Date
    /// Size on disk, in bytes.
    public let size: Int64

    public init(id: URL, sourceURL: URL, date: Date, size: Int64) {
        self.id = id
        self.sourceURL = sourceURL
        self.date = date
        self.size = size
    }
}

public struct VersionNode: Identifiable, Hashable, Sendable {
    public let info: VersionInfo
    public var id: URL { info.id }
    public var date: Date { info.date }
    public var size: Int64 { info.size }
    public init(_ info: VersionInfo) { self.info = info }
}

public struct FileNode: Identifiable, Hashable, Sendable {
    public let url: URL
    public let versions: [VersionNode]
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    public var versionCount: Int { versions.count }
    public var size: Int64 { versions.reduce(0) { $0 + $1.size } }
    public init(url: URL, versions: [VersionNode]) {
        self.url = url
        self.versions = versions
    }
}

public struct FolderNode: Identifiable, Hashable, Sendable {
    /// The directory containing the files.
    public let url: URL
    public let files: [FileNode]
    public var id: URL { url }
    public var name: String { url.lastPathComponent }
    /// Path with a leading `~` for the home directory, for display.
    public var displayPath: String { abbreviatingHome(url.path) }
    public var versionCount: Int { files.reduce(0) { $0 + $1.versionCount } }
    public var size: Int64 { files.reduce(0) { $0 + $1.size } }
    public init(url: URL, files: [FileNode]) {
        self.url = url
        self.files = files
    }
}

/// Group flat version infos into folder → file → version, newest version first,
/// folders and files sorted case-insensitively by path/name.
public func buildVersionTree(_ infos: [VersionInfo]) -> [FolderNode] {
    let byFile = Dictionary(grouping: infos, by: \.sourceURL)
    let files: [FileNode] = byFile.map { url, list in
        FileNode(url: url, versions: list.sorted { $0.date > $1.date }.map(VersionNode.init))
    }
    let byDir = Dictionary(grouping: files, by: { $0.url.deletingLastPathComponent() })
    return byDir.map { dir, fs in
        FolderNode(url: dir,
                   files: fs.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    }.sorted { $0.url.path.localizedCaseInsensitiveCompare($1.url.path) == .orderedAscending }
}

/// Filter the tree by a filename/filepath substring (case-insensitive). A folder
/// whose own path matches is kept whole; otherwise only its matching files survive.
/// Empty/whitespace query passes everything through unchanged.
public func filterVersionTree(_ folders: [FolderNode], query: String) -> [FolderNode] {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return folders }
    return folders.compactMap { folder in
        if folder.url.path.localizedCaseInsensitiveContains(q) { return folder }
        let matches = folder.files.filter {
            $0.name.localizedCaseInsensitiveContains(q) || $0.url.path.localizedCaseInsensitiveContains(q)
        }
        return matches.isEmpty ? nil : FolderNode(url: folder.url, files: matches)
    }
}

/// Versions strictly older than `date` — the targets for "clear before [date]".
public func versions(olderThan date: Date, in infos: [VersionInfo]) -> [VersionInfo] {
    infos.filter { $0.date < date }
}

private func abbreviatingHome(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path == home ? "~"
        : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count)
        : path
}

// MARK: - NSFileVersion I/O
//
// Disk I/O — call `gather`/`remove` off the main actor. `remove()` is irreversible.

public enum VersionHistoryStore {
    /// Recursively find Markdown files under a folder.
    public static func scanFolder(_ folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where ["md", "markdown"].contains(url.pathExtension.lowercased()) {
            out.append(url)
        }
        return out
    }

    /// Query macOS version history for each URL and flatten to `VersionInfo`.
    public static func gather(urls: [URL]) -> [VersionInfo] {
        var infos: [VersionInfo] = []
        for url in urls {
            guard let versions = NSFileVersion.otherVersionsOfItem(at: url) else { continue }
            for v in versions {
                let vurl = v.url
                let values = try? vurl.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                infos.append(VersionInfo(id: vurl, sourceURL: url,
                                         date: v.modificationDate ?? .distantPast, size: size))
            }
        }
        return infos
    }

    /// Permanently delete the given versions. Returns any errors encountered.
    public static func remove(_ targets: [VersionInfo]) -> [Error] {
        var errors: [Error] = []
        let bySource = Dictionary(grouping: targets, by: \.sourceURL)
        for (source, list) in bySource {
            guard let versions = NSFileVersion.otherVersionsOfItem(at: source) else { continue }
            let wanted = Set(list.map(\.id))
            for v in versions where wanted.contains(v.url) {
                do { try v.remove() } catch { errors.append(error) }
            }
        }
        return errors
    }
}
