import Foundation
import MetricKit

// MARK: - Crash reporting (CotEditor-style: the user files it, no server)
//
// MetricKit hands the app a diagnostic payload on the launch after a crash.
// Edmund never uploads it: the app layer asks the user and, on yes, opens a
// prefilled GitHub issue (summary in the body, full JSON on the clipboard).
// Sandbox-safe — the old `.ips` scan of ~/Library/Logs/DiagnosticReports
// can't run in a container — and the payload holds no home path, account
// name, file names or document text, only versions and stack addresses.
//
// Symbolicate a report's frames with the release's `edmd-<version>.dSYM.zip`
// (attached to every GitHub release), matching on the binary UUID:
//   atos -o edmd.dSYM -arch arm64 -l 0x100000000 <0x100000000 + offset>

/// The human-readable part of one crash, parsed from a MetricKit payload's
/// JSON. Pure, so it's testable without a real `MXCrashDiagnostic`.
public struct CrashReport: Equatable, Sendable {
    public var appVersion = "?"
    public var appBuild = "?"
    public var osVersion = "?"
    public var architecture = "?"
    public var exception = "?"
    public var terminationReason: String?
    /// Crashing thread, innermost first: "edmd +0x1a2b (UUID)".
    public var frames: [String] = []
    /// The whole payload, for the clipboard.
    public var json = ""

    /// Frames kept in the issue body — enough to group by, short enough for a URL.
    static let bodyFrameLimit = 12

    /// First crash in a `MXDiagnosticPayload.jsonRepresentation()` blob, or nil.
    public static func parse(payloadJSON data: Data) -> CrashReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let crash = (root["crashDiagnostics"] as? [[String: Any]])?.first else { return nil }
        var report = CrashReport(json: String(decoding: data, as: UTF8.self))
        let meta = crash["diagnosticMetaData"] as? [String: Any] ?? [:]
        report.appVersion = meta["appVersion"] as? String ?? "?"
        report.appBuild = meta["appBuildVersion"] as? String ?? "?"
        report.osVersion = meta["osVersion"] as? String ?? "?"
        report.architecture = meta["platformArchitecture"] as? String ?? "?"
        report.terminationReason = meta["terminationReason"] as? String
        report.exception = [
            (meta["exceptionType"] as? Int).map { exceptionNames[$0] ?? "exception \($0)" },
            (meta["signal"] as? Int).map { signalNames[$0] ?? "signal \($0)" },
        ].compactMap { $0 }.joined(separator: " / ")
        if report.exception.isEmpty { report.exception = "?" }

        // Frames nest caller-inside-callee via `subFrames`; follow the first
        // child from the root of the thread MetricKit attributes the crash to.
        let stacks = (crash["callStackTree"] as? [String: Any])?["callStacks"] as? [[String: Any]] ?? []
        let thread = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
        var frame = (thread?["callStackRootFrames"] as? [[String: Any]])?.first
        while let f = frame {
            let offset = f["offsetIntoBinaryTextSegment"] as? Int ?? 0
            report.frames.append("\(f["binaryName"] as? String ?? "?") +0x\(String(offset, radix: 16)) "
                                 + "(\(f["binaryUUID"] as? String ?? "?"))")
            frame = (f["subFrames"] as? [[String: Any]])?.first
        }
        return report
    }

    public var issueTitle: String { "Crash: \(exception) in \(appVersion)" }

    public var issueBody: String {
        var lines = [
            "**Description**",
            "<!-- What were you doing just before Edmund quit? -->",
            "",
            "**Crash**",
            "- Edmund \(appVersion) (\(appBuild))",
            "- \(osVersion), \(architecture)",
            "- \(exception)",
        ]
        if let terminationReason { lines.append("- \(terminationReason)") }
        lines += ["", "**Crashing thread**", "```"]
        lines += frames.prefix(Self.bodyFrameLimit).enumerated().map { "\($0.offset)  \($0.element)" }
        lines += ["```", "",
                  "<!-- The full crash report is on your clipboard. Paste it here if you're OK sharing it: "
                  + "it holds versions and code addresses, no documents or file names. -->"]
        return lines.joined(separator: "\n")
    }

    /// New-issue URL on `repo` with title, body and the bug label prefilled.
    public func issueURL(repo: String = "I7T5/Edmund") -> URL? {
        var c = URLComponents(string: "https://github.com/\(repo)/issues/new")
        c?.queryItems = [URLQueryItem(name: "labels", value: "bug"),
                         URLQueryItem(name: "title", value: issueTitle),
                         URLQueryItem(name: "body", value: issueBody)]
        return c?.url
    }

    static let exceptionNames = [1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
                                 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 10: "EXC_CRASH",
                                 11: "EXC_RESOURCE", 12: "EXC_GUARD"]
    static let signalNames = [4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE",
                              9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV"]
}

/// Subscribes to MetricKit and hands each crash to `onCrash` on the main
/// actor. Hold it for the app's lifetime; MetricKit delivers every payload
/// once, so there's nothing to de-duplicate.
public final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    private let onCrash: @MainActor (CrashReport) -> Void

    public init(onCrash: @escaping @MainActor (CrashReport) -> Void) {
        self.onCrash = onCrash
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit { MXMetricManager.shared.remove(self) }

    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Only the newest crash: after several, one report is plenty.
        guard let report = payloads.reversed().lazy
            .compactMap({ CrashReport.parse(payloadJSON: $0.jsonRepresentation()) }).first else { return }
        let onCrash = onCrash
        Task { @MainActor in onCrash(report) }
    }
}
