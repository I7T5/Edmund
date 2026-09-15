import Foundation

/// Pinned RaTeX (KaTeX-compatible, MIT) release coordinates. Never "latest" —
/// a specific version is baked in so an update requires a new app build (and a
/// fresh SHA-256 pin), never a moving target.
///
/// The runtime payload is a single `.tar.gz` bundling the `ratex-wasm` module
/// (`ratex_wasm_bg.wasm` + `ratex_wasm.js` glue) and the KaTeX `.ttf` fonts
/// RaTeX's display list references, unpacked to:
///   `ratex_wasm_bg.wasm`, `ratex_wasm.js`, `fonts/KaTeX_*.ttf`, `licenses/*`
/// Built by `scripts/build-ratex-payload.sh` in `I7T5/edmund-extensions` —
/// that repo owns payload building, and hosts the result as a release asset
/// rather than depending on npm/upstream uptime. An untracked copy of the
/// script may sit at this repo's `scripts/` for convenience; it is gitignored,
/// so the version over there is the one of record. A separate repo, not just a non-`v*` tag here, so a
/// 1 MB binary never enters this repo's history and so publishing a payload
/// cannot touch the app's `v*` tag-driven `release.yml` at all.
public enum RaTeXRelease {
    /// Tracks the upstream RaTeX release the payload was built from.
    ///
    /// 0.1.14 is the first release the Advanced Math extension can ship on: it
    /// closes both of the layout gaps that blocked it. `renderLatex` gained a
    /// `displayMode` argument (upstream PR #134), so inline math finally
    /// typesets inline; and `aligned` now expands row spacing to fit tall rows
    /// — measured on the repro from
    /// `docs/investigations/math-ratex-multirow-investigation.md`, a 3-row
    /// `\lim`/`\frac`/`\exp` derivation went from height 1.6 / depth 1.1 em
    /// with its rows collapsed into a 1.57em band (0.1.12) to height 4.15 /
    /// depth 3.65 em with three cleanly separated rows at a ~2.7em pitch.
    public static let version = "0.1.14"
    public static let archiveURL = URL(string: "https://github.com/I7T5/edmund-extensions/releases/download/ratex-wasm-assets-0.1.14/ratex-wasm-0.1.14.tar.gz")!
    /// Lowercase hex SHA-256 of the pinned `.tar.gz`, verified by downloading
    /// the hosted asset and hashing that — not the local build. The two can
    /// differ: the build script is byte-stable on one machine but not across
    /// `tar`/`gzip` implementations, so the local artifact is evidence about
    /// this machine, not about what users will actually fetch.
    public static let archiveSHA256 = "90b845f89a825763d31631f95d052b38f52c221e71ca8da3f4dc8c59e9ab766a"

    /// Whether a real artifact hash has been pinned.
    public static var isConfigured: Bool { !archiveSHA256.isEmpty }
}
