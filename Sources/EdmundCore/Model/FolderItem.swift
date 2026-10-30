import Foundation
import UniformTypeIdentifiers

/// One file or folder in a folder window's sidebar (`FolderDocument`).
///
/// A reference-type tree so `NSOutlineView` can hold nodes as items: identity
/// keeps rows (and their expansion) stable across reloads. Children are read
/// from disk on first access and re-read only by `reload()`.
public final class FolderItem {
    public let url: URL
    public let isDirectory: Bool
    public private(set) weak var parent: FolderItem?
    private var cachedChildren: [FolderItem]?

    /// Never listed, hidden files shown or not: Finder litter and the
    /// repository database, which nobody browses to edit.
    static let excludedNames: Set<String> = [".DS_Store", ".git"]

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    public init(url: URL, parent: FolderItem? = nil) {
        self.url = url
        self.parent = parent
        isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    public var name: String { url.lastPathComponent }

    public var isHidden: Bool {
        name.hasPrefix(".") || (try? url.resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
    }

    /// Whether the editor opens this file. `Document` reads any file as UTF-8
    /// text, so this is about what is worth opening: Markdown, plain text and
    /// extensionless files (README, LICENSE). Not source code, JSON or the
    /// like: the editor would render it as Markdown, `#` comments as headings.
    public var isEditable: Bool {
        guard !isDirectory else { return false }
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty || Self.markdownExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        // Source code is plain text to UTType (public.source-code conforms
        // to public.plain-text), so it has to be ruled out by name.
        return type.conforms(to: .plainText) && !type.conforms(to: .sourceCode)
    }

    /// Folders first, then names in Finder order ("2" before "10").
    public func children(showingHidden: Bool) -> [FolderItem] {
        guard isDirectory else { return [] }
        if cachedChildren == nil { cachedChildren = readChildren(reusing: []) }
        return showingHidden ? cachedChildren! : cachedChildren!.filter { !$0.isHidden }
    }

    /// Re-reads this folder's entries, keeping the nodes that are still there
    /// so the outline keeps their expansion and selection.
    public func reload() {
        guard isDirectory, let old = cachedChildren else { return }
        cachedChildren = readChildren(reusing: old)
    }

    /// The loaded item for `url`, if it sits in an already-read part of the tree.
    /// Symlinks are resolved on both sides: FSEvents reports real paths
    /// (/private/var/…) for a folder opened through a link (/var/…).
    public func item(at url: URL) -> FolderItem? {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let base = self.url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.starts(with: base) else { return nil }
        var item = self
        for name in target.dropFirst(base.count) {
            guard let next = item.cachedChildren?.first(where: { $0.name == name }) else { return nil }
            item = next
        }
        return item
    }

    /// The nodes to show for a filename filter: those whose name contains
    /// `query` (case-insensitive), and the folders on the way to them. A
    /// folder that matches by its own name brings all its contents.
    /// Returns nil for an empty query, meaning "no filter".
    ///
    /// ponytail: walks (and reads) the whole tree synchronously; move off the
    /// main thread if large folders make typing lag.
    public func filter(_ query: String, showingHidden: Bool) -> Set<ObjectIdentifier>? {
        guard !query.isEmpty else { return nil }
        var shown = Set<ObjectIdentifier>()
        func visit(_ node: FolderItem) -> Bool {
            if node.name.localizedCaseInsensitiveContains(query) {
                markAll(node)
                return true
            }
            var any = false
            for child in node.children(showingHidden: showingHidden) where visit(child) { any = true }
            if any { shown.insert(ObjectIdentifier(node)) }
            return any
        }
        func markAll(_ node: FolderItem) {
            shown.insert(ObjectIdentifier(node))
            guard node.isDirectory else { return }
            node.children(showingHidden: showingHidden).forEach(markAll)
        }
        for child in children(showingHidden: showingHidden) { _ = visit(child) }
        return shown
    }

    private func readChildren(reusing old: [FolderItem]) -> [FolderItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey])) ?? []
        let existing = Dictionary(old.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
        return urls
            .filter { !Self.excludedNames.contains($0.lastPathComponent) }
            .map { existing[$0.standardizedFileURL] ?? FolderItem(url: $0, parent: self) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
    }
}
