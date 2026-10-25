import Foundation

extension Bundle {
    /// EdmundCore's resource bundle (bundled themes and syntax definitions).
    ///
    /// Use this, not `Bundle.module`. The accessor `swift build` generates looks
    /// only at `Bundle.main.bundleURL/<name>.bundle` — the bundle *root* — and
    /// otherwise at an absolute `.build` path, then calls `fatalError`. A file
    /// at the bundle root is outside the code signature, which notarization
    /// rejects ("The signature of the binary is invalid"), and the sandbox
    /// blocks the `.build` path. `scripts/build-app.sh` therefore puts this
    /// bundle in `Contents/Resources` of the app and the Quick Look appex, where
    /// it is sealed. `Bundle.module` stays as the fallback for `swift test` and
    /// `swift run`, which have no app bundle.
    static let edmundCore: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Edmund_EdmundCore.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
