import Testing
import Foundation
@testable import EdmundCore

/// Parsing a MetricKit diagnostic payload into the GitHub issue the crash
/// prompt opens. The fixture follows `MXDiagnosticPayload.jsonRepresentation()`
/// (macOS 14): frames nest caller-inside-callee through `subFrames`.
@Suite("Crash report")
struct CrashReportTests {

    static let payload = Data("""
    {
      "timeStampBegin": "2026-09-22 10:00:00",
      "crashDiagnostics": [{
        "diagnosticMetaData": {
          "appVersion": "0.7.1", "appBuildVersion": "16",
          "osVersion": "macOS 15.7.9 (24G830)", "platformArchitecture": "arm64",
          "exceptionType": 1, "exceptionCode": 0, "signal": 11,
          "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"
        },
        "callStackTree": {
          "callStackPerThread": true,
          "callStacks": [
            { "threadAttributed": false, "callStackRootFrames": [
                { "binaryName": "libsystem_kernel.dylib", "binaryUUID": "K-UUID",
                  "offsetIntoBinaryTextSegment": 4096, "sampleCount": 1 } ] },
            { "threadAttributed": true, "callStackRootFrames": [
                { "binaryName": "edmd", "binaryUUID": "E-UUID",
                  "offsetIntoBinaryTextSegment": 6699, "sampleCount": 1,
                  "subFrames": [
                    { "binaryName": "AppKit", "binaryUUID": "A-UUID",
                      "offsetIntoBinaryTextSegment": 255, "sampleCount": 1 } ] } ] }
          ]
        }
      }]
    }
    """.utf8)

    @Test("Reads versions, exception and the attributed thread's frames, innermost first")
    func parses() throws {
        let r = try #require(CrashReport.parse(payloadJSON: Self.payload))
        #expect(r.appVersion == "0.7.1")
        #expect(r.appBuild == "16")
        #expect(r.osVersion == "macOS 15.7.9 (24G830)")
        #expect(r.exception == "EXC_BAD_ACCESS / SIGSEGV")
        #expect(r.frames == ["edmd +0x1a2b (E-UUID)", "AppKit +0xff (A-UUID)"])
        #expect(r.json.contains("crashDiagnostics"))
    }

    @Test("A payload with no crash (only hangs, say) yields nothing to report")
    func noCrash() {
        #expect(CrashReport.parse(payloadJSON: Data(#"{"hangDiagnostics":[]}"#.utf8)) == nil)
        #expect(CrashReport.parse(payloadJSON: Data("not json".utf8)) == nil)
    }

    @Test("Issue URL prefills title, body and the bug label on the repo")
    func issueURL() throws {
        let r = try #require(CrashReport.parse(payloadJSON: Self.payload))
        let url = try #require(r.issueURL())
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(url.absoluteString.hasPrefix("https://github.com/I7T5/Edmund/issues/new?"))
        #expect(q["labels"] == "bug")
        #expect(q["title"] == "Crash: EXC_BAD_ACCESS / SIGSEGV in 0.7.1")
        #expect(q["body"]?.contains("0  edmd +0x1a2b (E-UUID)") == true)
        #expect(q["body"]?.contains("Edmund 0.7.1 (16)") == true)
    }

    @Test("The body keeps a bounded number of frames so the URL stays short")
    func frameCap() {
        var r = CrashReport()
        r.frames = (0..<50).map { "f\($0)" }
        #expect(r.issueBody.contains("\(CrashReport.bodyFrameLimit - 1)  f\(CrashReport.bodyFrameLimit - 1)"))
        #expect(!r.issueBody.contains("  f\(CrashReport.bodyFrameLimit)\n"))
    }
}
