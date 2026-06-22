import Testing
import Foundation
@testable import EdmundCore

/// The diagnostic logger: writes lines to a daily file, honors the on/off switch,
/// emits durations via `measure`, and prunes files past the retention window.
/// Serialized — these share the process-wide `Log` singleton and a temp directory.
@Suite("Diagnostic logging", .serialized)
struct LogTests {

    /// A fresh temp directory for one test's logs.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edmund-logtest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func todaysLog(in dir: URL) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        let url = dir.appendingPathComponent("edmund-\(f.string(from: Date())).log")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    @Test("Enabled: writes a line per level with tag and category")
    func writesLines() {
        let dir = tempDir()
        Log.configure(enabled: true, directory: dir, retention: nil)
        Log.info("hello world", category: .document)
        Log.error("boom", category: .io)
        Log.flush()

        let contents = todaysLog(in: dir) ?? ""
        #expect(contents.contains("[INFO] [document] hello world"))
        #expect(contents.contains("[ERROR] [io] boom"))
    }

    @Test("Disabled: writes nothing")
    func disabledWritesNothing() {
        let dir = tempDir()
        Log.configure(enabled: false, directory: dir, retention: nil)
        Log.info("should not appear", category: .app)
        Log.error("nor this", category: .app)
        Log.flush()

        #expect(todaysLog(in: dir) == nil)
    }

    @Test("measure: returns the body's value and logs a duration line")
    func measureLogsDuration() {
        let dir = tempDir()
        Log.configure(enabled: true, directory: dir, retention: nil)
        let result = Log.measure("did work", category: .compose) { 6 * 7 }
        Log.flush()

        #expect(result == 42)
        let contents = todaysLog(in: dir) ?? ""
        #expect(contents.contains("did work — "))
        #expect(contents.contains(" ms"))
    }

    @Test("Loading a document logs its duration and the full recompose")
    @MainActor func loadContentInstrumented() {
        let dir = tempDir()
        Log.configure(enabled: true, directory: dir, retention: nil)

        let editor = makeEditor()
        editor.loadContent("# Title\n\nSome body text.\n")
        Log.flush()

        let contents = todaysLog(in: dir) ?? ""
        // The load duration (info) and, in this DEBUG test build, the recompose
        // sub-duration (debug) both land.
        #expect(contents.contains("[document] Loaded document ("))
        #expect(contents.contains("[compose] Full recompose ("))
        #expect(contents.contains(" ms"))
    }

    @Test("Retention prunes files older than the window, keeps newer ones")
    func retentionPrunes() throws {
        let dir = tempDir()
        let fm = FileManager.default

        // An "old" log file, back-dated well past the window.
        let old = dir.appendingPathComponent("edmund-2000-01-01.log")
        fm.createFile(atPath: old.path, contents: Data("stale\n".utf8))
        let longAgo = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01
        try fm.setAttributes([.modificationDate: longAgo], ofItemAtPath: old.path)

        // A current file we expect to survive.
        let fresh = dir.appendingPathComponent("edmund-keep.log")
        fm.createFile(atPath: fresh.path, contents: Data("fresh\n".utf8))

        // Configure with a one-day retention; the prune runs on configure.
        Log.configure(enabled: true, directory: dir, retention: 24 * 60 * 60)
        Log.flush()

        #expect(!fm.fileExists(atPath: old.path))
        #expect(fm.fileExists(atPath: fresh.path))
    }
}
