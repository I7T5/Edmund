import Foundation
import EdmundCore

/// Points `ThemeStore` at a scratch directory for the life of the test process,
/// so no suite reads the user's real themes or writes into them.
///
/// Touched from the `init` of every suite that reaches the store, which makes
/// the redirect happen before that suite's first test whatever order the
/// runner picks. One directory per process: a run killed mid-test leaves its
/// files in a directory no later run will look at, and earlier ones are swept
/// here so they do not pile up.
enum ThemeScratch {
    static let root: URL = {
        let tmp = FileManager.default.temporaryDirectory
        let prefix = "edmund-tests-themes-"
        if let old = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil) {
            for url in old where url.lastPathComponent.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let url = tmp.appendingPathComponent(
            prefix + String(ProcessInfo.processInfo.processIdentifier), isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        ThemeStore.userThemesRoot = url
        ThemeStore.shared.reload()
        return url
    }()

    /// Call from a suite's `init`.
    static func activate() { _ = root }
}
