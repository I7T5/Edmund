import Foundation

// MARK: - Crash report uploading
//
// Opt-in (default off), best-effort uploading of the crash reports macOS writes
// for Edmund. On launch — when the user has enabled it — we read the per-user
// `.ips` reports the OS dropped in ~/Library/Logs/DiagnosticReports/ and POST any
// we haven't sent before.
//
// Why read `.ips` files rather than MetricKit's `MXCrashDiagnostic`? It's the
// simplest path that yields the *full* report (not just a call-stack payload),
// is available immediately on the next launch, and needs no framework wiring.
// The tradeoff: it relies on direct filesystem access, which only works because
// Edmund is **not sandboxed** (no entitlements file). If App Sandbox is ever
// adopted, this directory becomes unreadable and we'd switch to MetricKit.
//
// PII note: `.ips` reports embed the user's home path (and so their account
// name), the device model, and the OS version. We send them as-is — acceptable
// for crash-fix use, which the Settings note states plainly. Revisit if scope
// changes.

public enum CrashReporter {

    /// Placeholder ingestion endpoint. Nothing is ever sent against this in the
    /// shipped build (the feature toggle is off and its UI is commented out);
    /// replace this with the real server before exposing the toggle.
    static let reportingEndpoint = URL(string: "https://REPLACE-ME.invalid/crash")!  // TODO: real server

    /// macOS crash reports are named `<executable>-<timestamp>.ips`. Our Mach-O
    /// executable is `edmd` (see `main.swift`), so that's the filename prefix.
    public static let processPrefix = "edmd"

    /// Where macOS writes this user's crash reports.
    public static var diagnosticReportsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Pure and testable: the `.ips` crash reports in `directory` that belong to
    /// our process and haven't been sent yet, sorted by name (oldest-ish first)
    /// for deterministic order.
    public static func pendingReports(in directory: URL,
                                      processPrefix: String = processPrefix,
                                      alreadySent: Set<String>) -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { url in
            url.pathExtension == "ips"
                && url.lastPathComponent.hasPrefix(processPrefix)
                && !alreadySent.contains(url.lastPathComponent)
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Scan the real DiagnosticReports directory and POST any crash reports not in
    /// `alreadySent`. Fire-and-forget — returns immediately and never blocks the
    /// caller. `onSent` is invoked on the main actor with each filename that
    /// uploaded successfully, so the caller can record it and avoid resending.
    public static func uploadPendingReports(alreadySent: Set<String>,
                                            onSent: @escaping @MainActor (String) -> Void) {
        let pending = pendingReports(in: diagnosticReportsDirectory, alreadySent: alreadySent)
        guard !pending.isEmpty else { return }
        for url in pending { upload(url, onSent: onSent) }
    }

    private static func upload(_ url: URL,
                               onSent: @escaping @MainActor (String) -> Void) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.lastPathComponent
        var request = URLRequest(url: reportingEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(name, forHTTPHeaderField: "X-Crash-Report-Name")
        let task = URLSession.shared.uploadTask(with: request, from: data) { _, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            Task { @MainActor in onSent(name) }
        }
        task.resume()
    }
}
