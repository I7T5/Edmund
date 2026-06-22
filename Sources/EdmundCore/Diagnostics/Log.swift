import Foundation

// MARK: - Diagnostic logging
//
// A small always-on (opt-out) file logger that writes human-readable lines to
// `~/.edmund/logs/edmund-YYYY-MM-DD.log` (one file per day) so problems can be
// diagnosed after the fact. Logs stay on the user's Mac and may contain document
// text — that's fine because they never leave the device.
//
// Design:
// - Three semantic levels (`debug`/`info`/`error`). A single compile-time
//   threshold decides what ships: release writes `info` and up; DEBUG builds also
//   write `debug`. The user never picks a level — only on/off (see Settings).
// - Writes happen on a private serial queue, so logging never blocks the caller;
//   timestamps are captured at the call site, so async writes stay in order.
// - `measure` times a closure and emits a single duration line — for operations
//   (load, full recompose) whose cost can't be read off a pair of events.

public enum Log {

    public enum Level: Int, Comparable, Sendable {
        case debug = 0, info = 1, error = 2
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
        var tag: String {
            switch self {
            case .debug: return "DEBUG"
            case .info:  return "INFO"
            case .error: return "ERROR"
            }
        }
    }

    /// Subsystem tag on each line — mirrors the architecture's areas so logs can
    /// be grepped by concern.
    public enum Category: String, Sendable {
        case app, document, io, render, compose, selection, lazy, callout
    }

    /// What gets written in this build. The user opts the whole facility out;
    /// they do not choose a level.
    #if DEBUG
    static let minLevel: Level = .debug
    #else
    static let minLevel: Level = .info
    #endif

    // MARK: Configuration (driven by the app from Settings)

    /// Point the logger at a directory, enable/disable it, and set a retention
    /// window (`nil` = keep forever). Enabling prunes anything past `retention`.
    public static func configure(enabled: Bool, directory: URL, retention: TimeInterval?) {
        LogStore.shared.configure(enabled: enabled, directory: directory, retention: retention)
    }

    public static func setEnabled(_ enabled: Bool) {
        LogStore.shared.setEnabled(enabled)
    }

    // MARK: Emit

    public static func debug(_ message: @autoclosure () -> String, category: Category = .app) {
        guard shouldLog(.debug) else { return }
        LogStore.shared.write(level: .debug, category: category, message: message(), date: Date())
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .app) {
        guard shouldLog(.info) else { return }
        LogStore.shared.write(level: .info, category: category, message: message(), date: Date())
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .app) {
        guard shouldLog(.error) else { return }
        LogStore.shared.write(level: .error, category: category, message: message(), date: Date())
    }

    /// Runs `body`, and if logging is active emits one line with how long it took.
    /// Zero overhead (just runs `body`) when the level is filtered out or logging
    /// is off.
    @discardableResult
    public static func measure<T>(_ label: @autoclosure () -> String,
                                  category: Category = .app,
                                  level: Level = .info,
                                  _ body: () throws -> T) rethrows -> T {
        guard shouldLog(level) else { return try body() }
        let start = DispatchTime.now()
        let result = try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        LogStore.shared.write(level: level, category: category,
                              message: "\(label()) — \(String(format: "%.1f", ms)) ms", date: Date())
        return result
    }

    /// Logs the structure of a block array at `debug` level: each block's kind
    /// and character count, with no document text. Example output:
    ///   Structure (4): heading(2)·18c, paragraph·234c, codeBlock(swift)·456c, callout·120c
    public static func blockStructure(_ blocks: [Block], category: Category = .compose) {
        guard shouldLog(.debug) else { return }
        let parts = blocks.map { b -> String in
            let c = b.range.length
            switch b.kind {
            case .paragraph:              return "paragraph·\(c)c"
            case .heading(let level):     return "heading(\(level))·\(c)c"
            case .quoteRun(let isCallout): return "\(isCallout ? "callout" : "quote")·\(c)c"
            case .fence:                  return "fence·\(c)c"
            case .mathDisplay:            return "math·\(c)c"
            case .table:                  return "table·\(c)c"
            case .listItem:               return "listItem·\(c)c"
            case .thematicBreak:          return "hr·\(c)c"
            case .blank:                  return "blank·\(c)c"
            }
        }
        LogStore.shared.write(level: .debug, category: category,
                              message: "Structure (\(blocks.count)): \(parts.joined(separator: ", "))",
                              date: Date())
    }

    /// Blocks until queued writes have hit disk. For tests.
    public static func flush() { LogStore.shared.flush() }

    private static func shouldLog(_ level: Level) -> Bool {
        level >= minLevel && LogStore.shared.isEnabled
    }
}

// MARK: - Backing store

/// Holds the logger's mutable state. Configuration is guarded by a lock; all file
/// I/O (and the non-`Sendable` `DateFormatter`s) is confined to one serial queue.
private final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.i7t5.edmund.log")

    // Lock-guarded configuration.
    private var _enabled = false
    private var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".edmund/logs", isDirectory: true)

    // Queue-confined state.
    private var handle: FileHandle?
    private var handleDay: String?
    private let dayFormatter = LogStore.makeFormatter("yyyy-MM-dd")
    private let timeFormatter = LogStore.makeFormatter("yyyy-MM-dd HH:mm:ss.SSS")

    var isEnabled: Bool { lock.withLock { _enabled } }

    func configure(enabled: Bool, directory: URL, retention: TimeInterval?) {
        lock.withLock {
            _enabled = enabled
            self.directory = directory
        }
        queue.async { [weak self] in
            self?.closeHandle()   // directory may have changed
            if enabled, let retention { self?.prune(retention: retention) }
        }
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { _enabled = enabled }
    }

    func write(level: Log.Level, category: Log.Category, message: String, date: Date) {
        let dir = lock.withLock { directory }
        queue.async { [weak self] in
            guard let self else { return }
            let line = "\(self.timeFormatter.string(from: date)) [\(level.tag)] [\(category.rawValue)] \(message)"
            self.append(line, in: dir, date: date)
        }
    }

    func flush() { queue.sync {} }

    // MARK: File I/O (queue only)

    private func append(_ line: String, in dir: URL, date: Date) {
        let day = dayFormatter.string(from: date)
        if handleDay != day { closeHandle() }
        if handle == nil {
            guard let h = openHandle(dir: dir, day: day) else { return }
            handle = h
            handleDay = day
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try handle?.write(contentsOf: data)
        } catch {
            // The file may have been moved or deleted out from under us; reopen once.
            closeHandle()
            if let h = openHandle(dir: dir, day: day) {
                handle = h
                handleDay = day
                try? h.write(contentsOf: data)
            }
        }
    }

    private func openHandle(dir: URL, day: String) -> FileHandle? {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("edmund-\(day).log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        try? h.seekToEnd()
        return h
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
        handleDay = nil
    }

    private func prune(retention: TimeInterval) {
        let fm = FileManager.default
        let dir = lock.withLock { directory }
        guard let urls = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        for url in urls where url.lastPathComponent.hasPrefix("edmund-") && url.pathExtension == "log" {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }
}
