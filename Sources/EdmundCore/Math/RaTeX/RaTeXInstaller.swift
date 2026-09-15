import Foundation
import CryptoKit

/// Install-state machine for the RaTeX extension's payload archive.
public enum MathExtensionState: Equatable, Sendable {
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case installed
    case failed(String)
}

public enum RaTeXInstallError: Error, Equatable {
    case notConfigured
    case downloadFailed(URL)
    case hashMismatch
    case unpackFailed
}

/// Downloads, SHA-256-verifies, and atomically installs the pinned RaTeX
/// payload (`.tar.gz` of wasm + glue + KaTeX fonts) into Application Support.
/// The download is verified before it is ever unpacked, so a corrupted or
/// tampered archive is never installed; a failure at any step leaves
/// `state == .failed` and throws — the caller (`RaTeXRenderer`) stays
/// not-ready and `MathRendering` falls back to SwiftMath, never crashing.
public actor RaTeXInstaller {
    public private(set) var state: MathExtensionState = .notInstalled

    public init() {}

    /// Directory the pinned version installs into:
    /// `~/Library/Application Support/Edmund/Math/ratex-<version>/`. A
    /// version-stamped path means a new pinned version installs fresh.
    public static var installDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Edmund/Math/ratex-\(RaTeXRelease.version)", isDirectory: true)
    }

    /// Name of the stamp file recording the verified archive hash of a
    /// completed install, so a relaunch can skip re-downloading.
    private static let stampName = ".verified-sha256"

    /// Removes the installed version directory, if any, and resets `state`.
    /// Best-effort — a missing/already-gone directory is not an error.
    public func uninstall() {
        try? FileManager.default.removeItem(at: Self.installDirectory)
        state = .notInstalled
    }

    /// Ensures the pinned release is installed (downloading + verifying +
    /// unpacking if needed) and returns the install directory.
    public func ensureInstalled() async throws -> URL {
        do {
            guard RaTeXRelease.isConfigured else { throw RaTeXInstallError.notConfigured }
            let dir = Self.installDirectory
            if isVerifiedInstall(dir) {
                state = .installed
                return dir
            }

            state = .downloading(progress: 0)
            let archive = try await download(RaTeXRelease.archiveURL)

            state = .verifying
            try verify(archive, sha256: RaTeXRelease.archiveSHA256)

            try installAtomically(archive: archive, sha256: RaTeXRelease.archiveSHA256, into: dir)
            state = .installed
            return dir
        } catch {
            state = .failed(String(describing: error))
            throw error
        }
    }

    /// A completed install is trusted on relaunch when its stamp records the
    /// pinned hash and the wasm file is present. The download was hash-verified
    /// before it was unpacked; the stamp just avoids re-downloading. (The
    /// unpacked dir lives in the user's Application Support; we don't re-hash
    /// every file on each launch — the trust boundary is the verified download.)
    private func isVerifiedInstall(_ dir: URL) -> Bool {
        let stamp = (try? String(contentsOf: dir.appendingPathComponent(Self.stampName), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stamp == RaTeXRelease.archiveSHA256
            && FileManager.default.fileExists(atPath: dir.appendingPathComponent("ratex_wasm_bg.wasm").path)
    }

    private func download(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RaTeXInstallError.downloadFailed(url)
        }
        return data
    }

    // Internal (not private) so tests can exercise the security-critical hash
    // check and the atomic-install/unpack path directly, without a live network
    // fixture.
    func verify(_ data: Data, sha256 expected: String) throws {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw RaTeXInstallError.hashMismatch }
    }

    /// Unpacks the verified `.tar.gz` into a temp dir, stamps it with the
    /// archive hash, then moves it into place — so a half-unpack is never seen
    /// as a valid install.
    func installAtomically(archive: Data, sha256: String, into dir: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let tarball = tmp.appendingPathComponent("payload.tar.gz")
        try archive.write(to: tarball)
        let unpacked = tmp.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try untar(tarball, into: unpacked)
        guard fm.fileExists(atPath: unpacked.appendingPathComponent("ratex_wasm_bg.wasm").path) else {
            throw RaTeXInstallError.unpackFailed
        }
        try sha256.write(to: unpacked.appendingPathComponent(Self.stampName), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: unpacked, to: dir)
    }

    /// Extracts a gzip tarball with the system `tar`. The archive stores its
    /// files at the root (`ratex_wasm_bg.wasm`, `ratex_wasm.js`, `fonts/…`),
    /// so they land directly in `dir`.
    private func untar(_ tarball: URL, into dir: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        proc.arguments = ["-xzf", tarball.path, "-C", dir.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw RaTeXInstallError.unpackFailed }
    }
}
