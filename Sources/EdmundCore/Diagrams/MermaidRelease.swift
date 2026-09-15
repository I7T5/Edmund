import Foundation

/// Pinned `beautiful-mermaid` (MIT) release coordinates. Never "latest" — a
/// specific version is baked in so an update requires a new app build (and a
/// fresh SHA-256 pin), never a moving target.
///
/// The runtime payload is a single `.tar.gz` holding one self-contained
/// JavaScript file plus the licenses of everything bundled into it:
///   `beautiful-mermaid.js`, `licenses/*`
/// Built by `scripts/build-mermaid-payload.sh` in `I7T5/edmund-extensions` —
/// that repo owns payload building, and hosts the result as a release asset
/// rather than depending on npm/upstream uptime. An untracked copy of the
/// script may sit at this repo's `scripts/` for convenience; it is gitignored,
/// so the version over there is the one of record. A separate repo, not just a
/// non-`v*` tag here, so a ~500 KB binary never enters this repo's history and
/// so publishing a payload cannot touch the app's `v*` tag-driven
/// `release.yml` at all.
///
/// The bundle carries `elkjs` (EPL-2.0) and `entities` (BSD-2-Clause) along
/// with beautiful-mermaid itself; EPL-2.0 redistribution is why `licenses/`
/// is part of the archive rather than an afterthought.
public enum MermaidRelease {
    /// Tracks the upstream beautiful-mermaid release the payload was built
    /// from. 1.1.3 is the current release; it renders flowchart, state,
    /// sequence, class, ER, and XY-chart diagrams, and its `renderMermaidSVG`
    /// is synchronous (a direct ELK FakeWorker bypass), which is what lets it
    /// run inside the synchronous `DocumentHTML.full` assembly.
    public static let version = "1.1.3"
    public static let archiveURL = URL(string: "https://github.com/I7T5/edmund-extensions/releases/download/mermaid-assets-1.1.3/beautiful-mermaid-1.1.3.tar.gz")!
    /// Lowercase hex SHA-256 of the pinned `.tar.gz`, verified by downloading
    /// the hosted asset and hashing that — not the local build. The two can
    /// differ: the build script is byte-stable on one machine but not across
    /// `tar`/`gzip` implementations, so the local artifact is evidence about
    /// this machine, not about what users will actually fetch.
    ///
    /// Empty leaves `isConfigured` false — the extension then shows in Settings
    /// but reports the payload as unavailable rather than attempting a download
    /// that cannot be verified. That was the state until the asset went up.
    public static let archiveSHA256 =
        "6c7dfaeff7fbf7ef9c88eb9531ab332b929db819d75200d333e483001eef1ab7"

    /// Whether a real artifact hash has been pinned.
    public static var isConfigured: Bool { payload.isConfigured }

    /// Coordinates for the shared installer. A version-stamped directory means
    /// a new pinned version installs fresh.
    public static let payload = ExtensionPayload(
        directoryName: "Diagrams/beautiful-mermaid-\(version)",
        archiveURL: archiveURL,
        archiveSHA256: archiveSHA256,
        sentinelFile: "beautiful-mermaid.js")
}
