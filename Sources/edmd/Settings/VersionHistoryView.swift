// The Manage Version History popup: browse macOS Auto Save versions grouped by
// folder → file → version, and clear them (by selection or older than a date),
// with filename/path search. See EdmundCore/Model/VersionHistory.swift for the model.

import SwiftUI
import AppKit
import EdmundCore

/// Recent + currently-open document URLs, deduped, existing files only.
@MainActor
private func candidateDocumentURLs() -> [URL] {
    var urls = NSDocumentController.shared.recentDocumentURLs
    for doc in NSDocumentController.shared.documents {
        if let u = doc.fileURL { urls.append(u) }
    }
    var seen = Set<URL>()
    return urls.filter { FileManager.default.fileExists(atPath: $0.path) && seen.insert($0).inserted }
}

struct VersionHistoryView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [FolderNode] = []
    @State private var query = ""
    @State private var selection: Set<URL> = []      // selected version ids
    @State private var beforeDate = Date()
    @State private var scannedURLs: [URL] = []
    @State private var isLoading = false
    @State private var refreshToken = 0

    /// Outline rows, rebuilt only when the data or the search query changes —
    /// NSOutlineView keys off object identity, so rebuilding per body pass
    /// would collapse the tree on every checkbox click.
    @State private var roots: [VersionOutlineItem] = []

    @State private var pendingTargets: [VersionInfo] = []
    @State private var confirmClear = false
    @State private var errorMessage: String?

    private var allInfos: [VersionInfo] { folders.flatMap { $0.files.flatMap { $0.versions.map(\.info) } } }
    private var selectedInfos: [VersionInfo] { allInfos.filter { selection.contains($0.id) } }
    private var totalSize: Int64 { allInfos.reduce(0) { $0 + $1.size } }
    private var selectedSize: Int64 { selectedInfos.reduce(0) { $0 + $1.size } }
    /// Checked versions older than the cutoff — exactly what Delete removes.
    private var deleteTargets: [VersionInfo] { selectedInfos.filter { $0.date < beforeDate } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 560)
        .task(id: refreshToken) { await reload() }
        .onChange(of: query) { rebuildRoots() }
        .confirmationDialog(
            "Delete \(pendingTargets.count) version\(pendingTargets.count == 1 ? "" : "s")?",
            isPresented: $confirmClear, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { performRemove(pendingTargets) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently deletes the selected saved versions. It can't be undone.")
        }
        .alert("Couldn't delete some versions",
               isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Version History").font(.headline)
                Text("Auto Save keeps past versions of your documents. Review and delete them to reclaim disk space. Only documents Edmund knows about are shown — use Scan Folder to add more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search filename or path", text: $query)
                .textFieldStyle(.plain)
            Spacer()
            Button { scanFolder() } label: { Label("Scan Folder…", systemImage: "folder.badge.plus") }
            Button { refreshToken += 1 } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    @ViewBuilder private var content: some View {
        if isLoading {
            centered { ProgressView() }
        } else if roots.isEmpty {
            centered {
                Text(folders.isEmpty ? "No version history found for these documents."
                                     : "No matches.")
                    .foregroundStyle(.secondary)
            }
        } else {
            VersionOutline(roots: roots, selection: $selection)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                // Stock NSDatePicker field: mm/dd/yyyy in en_US, keyboard-editable,
                // localized elsewhere for free.
                DatePicker("Delete versions before", selection: $beforeDate,
                           displayedComponents: .date)
                    .fixedSize()
                Spacer()
            }
            HStack {
                Text("Selected: \(byteString(selectedSize))").foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Text("Total: \(byteString(totalSize))").foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                Button { confirm(deleteTargets) } label: {
                    Text("Delete").foregroundStyle(.red)
                }
                .disabled(deleteTargets.isEmpty)
            }
        }
        .padding(16)
    }

    private func centered<V: View>(@ViewBuilder _ v: () -> V) -> some View {
        VStack { Spacer(); v(); Spacer() }.frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func reload() async {
        isLoading = true
        let urls = Array(Set(candidateDocumentURLs() + scannedURLs))
        let infos = await Task.detached { VersionHistoryStore.gather(urls: urls) }.value
        folders = buildVersionTree(infos)
        selection.formIntersection(Set(infos.map(\.id)))   // drop ids that no longer exist
        rebuildRoots()
        isLoading = false
    }

    private func rebuildRoots() {
        roots = versionOutlineItems(filterVersionTree(folders, query: query))
    }

    private func confirm(_ targets: [VersionInfo]) {
        guard !targets.isEmpty else { return }
        pendingTargets = targets
        confirmClear = true
    }

    private func performRemove(_ targets: [VersionInfo]) {
        Task {
            let errors = await Task.detached { VersionHistoryStore.remove(targets) }.value
            selection.subtract(targets.map(\.id))
            if !errors.isEmpty { errorMessage = errors.first?.localizedDescription }
            refreshToken += 1
        }
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan for Markdown files with version history"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            let found = await Task.detached { VersionHistoryStore.scanFolder(dir) }.value
            scannedURLs = Array(Set(scannedURLs + found))
            refreshToken += 1
        }
    }
}

private func byteString(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
