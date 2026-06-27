import Testing
import Foundation
@testable import EdmundCore

/// Crash-report discovery: picks up our process's `.ips` files, ignores everything
/// else, and skips ones already uploaded. (The upload path itself is network I/O
/// and isn't exercised here.)
@Suite("Crash report discovery")
struct CrashReporterTests {

    /// A fresh temp directory seeded with the given filenames (empty files).
    private func tempDir(files: [String]) -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("edmund-crashtest-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in files {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
        return dir
    }

    @Test("Selects edmd .ips reports, ignores other processes and non-.ips files")
    func selectsOurReports() {
        let dir = tempDir(files: [
            "edmd-2026-06-27-120000.ips",     // ours
            "edmd-2026-06-26-090000.ips",     // ours
            "Safari-2026-06-27-120000.ips",   // other process
            "edmd-2026-06-27.log",            // not a crash report
            "edmd-notes.txt",                 // not .ips
        ])

        let names = CrashReporter.pendingReports(in: dir, alreadySent: [])
            .map(\.lastPathComponent)

        #expect(names == ["edmd-2026-06-26-090000.ips", "edmd-2026-06-27-120000.ips"])
    }

    @Test("Skips reports already sent")
    func skipsAlreadySent() {
        let dir = tempDir(files: [
            "edmd-2026-06-27-120000.ips",
            "edmd-2026-06-26-090000.ips",
        ])

        let names = CrashReporter.pendingReports(
            in: dir, alreadySent: ["edmd-2026-06-26-090000.ips"]
        ).map(\.lastPathComponent)

        #expect(names == ["edmd-2026-06-27-120000.ips"])
    }

    @Test("Missing directory yields no reports")
    func missingDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-crashtest-missing-\(UUID().uuidString)")
        #expect(CrashReporter.pendingReports(in: dir, alreadySent: []).isEmpty)
    }
}
