import AppKit
import CryptoKit
import Darwin
import Foundation
@testable import EdmundCore

let benchmarkPhase = ProcessInfo.processInfo.environment["EDMUND_BENCHMARK_PHASE"] ?? ""

enum OpenDocumentBenchmarkValidationError: Error, CustomStringConvertible {
    case invalid(String)

    var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}

struct OpenDocumentBenchmarkContract: Codable {
    struct Scenario: Codable, Hashable {
        let name: String
        let approximateBytes: Int
        let seed: UInt64
        let expectedSHA256: String
        let expectedUTF16Length: Int
        let expectedBlockCount: Int
    }

    struct Gate: Codable {
        let baselineScenario: String
        let scaledScenario: String
        let maxFirstPresentationScalingRatio: Double
        let maxActiveDrainScalingRatio: Double
        let maxBaselineRegressionRatio: Double
        let maxRelativeMAD: Double
        let baselineReportPath: String
    }

    let schemaVersion: Int
    let generatorVersion: Int
    let warmupIterations: Int
    let measuredIterations: Int
    let sampleTimeoutSeconds: Double
    let scenarios: [Scenario]
    let gate: Gate

    static var rootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // EdmundTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
    }

    static var url: URL {
        rootURL.appendingPathComponent("Benchmarks/open-document.json")
    }

    static func load() throws -> Self {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func validate() throws {
        guard schemaVersion == 3 else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Unsupported benchmark schema version \(schemaVersion)"
            )
        }
        guard generatorVersion > 0, warmupIterations >= 1,
              measuredIterations >= 5, measuredIterations % 2 == 1,
              sampleTimeoutSeconds > 0
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Iterations must include a warmup and at least five odd-count samples"
            )
        }
        guard scenarios.count >= 2,
              Set(scenarios.map(\.name)).count == scenarios.count,
              scenarios.allSatisfy({
                  $0.name.isEmpty == false
                      && $0.approximateBytes > 0
                      && $0.expectedSHA256.count == 64
                      && $0.expectedUTF16Length > 0
                      && $0.expectedBlockCount > 0
              })
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Scenarios must be unique, positive, and fingerprinted"
            )
        }
        guard gate.baselineScenario != gate.scaledScenario,
              let baseline = scenarios.first(where: { $0.name == gate.baselineScenario }),
              let scaled = scenarios.first(where: { $0.name == gate.scaledScenario }),
              scaled.approximateBytes > baseline.approximateBytes
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "The scaled gate scenario must exist, be distinct, and be larger"
            )
        }
        guard gate.maxFirstPresentationScalingRatio > 1,
              gate.maxActiveDrainScalingRatio > 1,
              gate.maxBaselineRegressionRatio >= 1,
              gate.maxRelativeMAD > 0,
              gate.maxRelativeMAD < 1,
              gate.baselineReportPath.isEmpty == false
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Gate thresholds and baseline report path are invalid"
            )
        }
    }

    func replacingGate(
        baselineScenario: String,
        scaledScenario: String
    ) -> Self {
        Self(
            schemaVersion: schemaVersion,
            generatorVersion: generatorVersion,
            warmupIterations: warmupIterations,
            measuredIterations: measuredIterations,
            sampleTimeoutSeconds: sampleTimeoutSeconds,
            scenarios: scenarios,
            gate: Gate(
                baselineScenario: baselineScenario,
                scaledScenario: scaledScenario,
                maxFirstPresentationScalingRatio:
                    gate.maxFirstPresentationScalingRatio,
                maxActiveDrainScalingRatio: gate.maxActiveDrainScalingRatio,
                maxBaselineRegressionRatio: gate.maxBaselineRegressionRatio,
                maxRelativeMAD: gate.maxRelativeMAD,
                baselineReportPath: gate.baselineReportPath
            )
        )
    }
}

struct OpenDocumentBenchmarkFixture {
    let source: String
    let sha256: String
    let utf16Length: Int
    let blockCount: Int

    init(scenario: OpenDocumentBenchmarkContract.Scenario) {
        source = makeLargeMarkdown(
            approximateBytes: scenario.approximateBytes,
            seed: scenario.seed
        )
        sha256 = benchmarkSHA256(Data(source.utf8))
        utf16Length = (source as NSString).length
        blockCount = BlockParser.parse(source).count
    }

    func validate(against scenario: OpenDocumentBenchmarkContract.Scenario) throws {
        guard sha256 == scenario.expectedSHA256 else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "\(scenario.name) SHA-256 changed to \(sha256)"
            )
        }
        guard utf16Length == scenario.expectedUTF16Length else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "\(scenario.name) UTF-16 length changed to \(utf16Length)"
            )
        }
        guard blockCount == scenario.expectedBlockCount else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "\(scenario.name) block count changed to \(blockCount)"
            )
        }
    }
}

struct OpenDocumentBenchmarkSample: Codable {
    let synchronousLoadMilliseconds: Double
    let firstPresentationMilliseconds: Double
    let activeDrainCPUMilliseconds: Double
    let styledAtFirstPresentation: Int
    let finalStyledBlockCount: Int
    let totalBlockCount: Int
    let drainSlices: Int
    let schedulerYields: Int
    let converged: Bool

    static func stub() -> Self {
        Self(
            synchronousLoadMilliseconds: 1,
            firstPresentationMilliseconds: 2,
            activeDrainCPUMilliseconds: 3,
            styledAtFirstPresentation: 1,
            finalStyledBlockCount: 2,
            totalBlockCount: 2,
            drainSlices: 1,
            schedulerYields: 1,
            converged: true
        )
    }
}

struct OpenDocumentBenchmarkSampleEnvelope: Codable {
    let scenarioName: String
    let iteration: Int
    let processIdentifier: Int32
    let sample: OpenDocumentBenchmarkSample
}

struct OpenDocumentBenchmarkScenarioResult: Codable {
    let name: String
    let approximateBytes: Int
    let seed: UInt64
    let sha256: String
    let utf16Length: Int
    let blockCount: Int
    let samples: [OpenDocumentBenchmarkSampleEnvelope]
    let medianSynchronousLoadMilliseconds: Double
    let medianFirstPresentationMilliseconds: Double
    let medianActiveDrainCPUMilliseconds: Double
    let relativeMADSynchronousLoad: Double
    let relativeMADFirstPresentation: Double
    let relativeMADActiveDrainCPU: Double
}

struct OpenDocumentBenchmarkEnvironment: Codable {
    let operatingSystem: String
    let hardwareModel: String
    let processorArchitecture: String
    let processorCount: Int
    let swiftVersion: String
    let buildConfiguration: String
}

struct OpenDocumentBenchmarkProvenance: Codable {
    let sourceRevision: String
    let sourceTreeDirty: Bool
    let contractSHA256: String
    let benchmarkDefinitionSHA256: String
    let testBinarySHA256: String
    let usedSkipBuild: Bool
    let authoritative: Bool
}

struct OpenDocumentBenchmarkRegressionRatio: Codable {
    let scenario: String
    let metric: String
    let ratio: Double
}

struct OpenDocumentBenchmarkGateMetrics {
    let firstPresentationScalingRatio: Double
    let activeDrainScalingRatio: Double
    let maximumRelativeMAD: Double
    let regressionRatios: [OpenDocumentBenchmarkRegressionRatio]
    let preconditionFailures: [String]

    init(
        firstPresentationScalingRatio: Double,
        activeDrainScalingRatio: Double,
        maximumRelativeMAD: Double,
        regressionRatios: [OpenDocumentBenchmarkRegressionRatio],
        preconditionFailures: [String] = []
    ) {
        self.firstPresentationScalingRatio = firstPresentationScalingRatio
        self.activeDrainScalingRatio = activeDrainScalingRatio
        self.maximumRelativeMAD = maximumRelativeMAD
        self.regressionRatios = regressionRatios
        self.preconditionFailures = preconditionFailures
    }
}

struct OpenDocumentBenchmarkGateEvaluation {
    let passed: Bool
    let failures: [String]
}

enum OpenDocumentBenchmarkGateEvaluator {
    static func evaluate(
        metrics: OpenDocumentBenchmarkGateMetrics,
        gate: OpenDocumentBenchmarkContract.Gate,
        authoritative: Bool
    ) -> OpenDocumentBenchmarkGateEvaluation {
        var failures = metrics.preconditionFailures
        if authoritative == false {
            failures.append(
                "Run is non-authoritative: require a clean tree and clean release build"
            )
        }
        if metrics.firstPresentationScalingRatio
            > gate.maxFirstPresentationScalingRatio {
            failures.append(
                "First-presentation scaling "
                    + "\(format(metrics.firstPresentationScalingRatio))× exceeds "
                    + "\(format(gate.maxFirstPresentationScalingRatio))×"
            )
        }
        if metrics.activeDrainScalingRatio > gate.maxActiveDrainScalingRatio {
            failures.append(
                "Active-drain scaling \(format(metrics.activeDrainScalingRatio))× exceeds "
                    + "\(format(gate.maxActiveDrainScalingRatio))×"
            )
        }
        if metrics.maximumRelativeMAD > gate.maxRelativeMAD {
            failures.append(
                "Sample relative MAD \(format(metrics.maximumRelativeMAD)) exceeds "
                    + "\(format(gate.maxRelativeMAD))"
            )
        }
        for regression in metrics.regressionRatios
        where regression.ratio > gate.maxBaselineRegressionRatio {
            failures.append(
                "\(regression.scenario) \(regression.metric) regressed "
                    + "\(format(regression.ratio))× versus baseline"
            )
        }
        return OpenDocumentBenchmarkGateEvaluation(
            passed: failures.isEmpty,
            failures: failures
        )
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

struct OpenDocumentBenchmarkReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let mode: String
    let measuredIterations: Int
    let provenance: OpenDocumentBenchmarkProvenance
    let environment: OpenDocumentBenchmarkEnvironment
    let freshProcessCount: Int
    let scenarios: [OpenDocumentBenchmarkScenarioResult]
    let pairedFirstPresentationScalingRatio: Double
    let maximumFirstPresentationScalingRatio: Double
    let pairedActiveDrainScalingRatio: Double
    let maximumActiveDrainScalingRatio: Double
    let maximumRelativeMAD: Double
    let allowedRelativeMAD: Double
    let regressionRatios: [OpenDocumentBenchmarkRegressionRatio]
    let maximumBaselineRegressionRatio: Double
    let evidenceFailures: [String]
    let evidenceValid: Bool
    let gateFailures: [String]
    let gatePassed: Bool
}

enum PerformanceBenchmarkStatistics {
    static func median(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return .nan }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    static func relativeMedianAbsoluteDeviation(_ values: [Double]) -> Double {
        let center = median(values)
        guard center.isFinite, center != 0 else { return .infinity }
        return median(values.map { abs($0 - center) }) / abs(center)
    }
}

@MainActor
enum OpenDocumentBenchmarkRunner {
    static func measure(
        _ fixture: OpenDocumentBenchmarkFixture,
        timeoutSeconds: Double
    ) async -> OpenDocumentBenchmarkSample {
        // XCTest does not inherit the interactive scheduling priority of a
        // foreground AppKit app. Match the shipped editor so unrelated host
        // work cannot turn a UI-latency sample into a scheduler benchmark.
        var previousQoS = QOS_CLASS_DEFAULT
        var previousRelativePriority: Int32 = 0
        pthread_get_qos_class_np(
            pthread_self(),
            &previousQoS,
            &previousRelativePriority
        )
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        defer {
            pthread_set_qos_class_self_np(
                previousQoS,
                previousRelativePriority
            )
        }

        _ = NSApplication.shared
        let width: CGFloat = 800
        let height: CGFloat = 560
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(x: 0, y: 0, width: width, height: height),
            containerSize: NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        let defaultsName = "EdmundBenchmark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        editor.themeDefaults = defaults
        editor.theme = .load(from: defaults)
        editor.minSize = .zero
        editor.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 24, height: 18)
        editor.maxContentWidthPoints = 1_000
        editor.updateContentInset()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Programmatically-created windows otherwise self-release on close,
        // then ARC releases the local owner again during test teardown.
        window.isReleasedWhenClosed = false
        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = editor
        window.contentView = scrollView
        window.makeFirstResponder(editor)
        window.orderFrontRegardless()
        window.displayIfNeeded()

        let clock = ContinuousClock()
        let overallStart = clock.now
        let synchronousLoadMilliseconds = milliseconds {
            editor.loadContent(fixture.source)
        }
        editor.textLayoutManager?.textViewportLayoutController.layoutViewport()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let firstPresentationMilliseconds = milliseconds(since: overallStart)
        let styledAtFirstPresentation = editor.blocks.lazy.filter(\.isStyled).count

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var activeDrainCPUMilliseconds = 0.0
        var drainSlices = 0
        while editor.blocks.contains(where: { $0.isStyled == false }),
              Date() < deadline {
            activeDrainCPUMilliseconds += threadCPUMilliseconds {
                editor.drainStylingSlice()
            }
            drainSlices += 1
        }
        let stylingConverged = editor.blocks.allSatisfy(\.isStyled)
        var schedulerYields = 0
        var settled = benchmarkHasSettled(editor)
        while settled == false, Date() < deadline, schedulerYields < 1_000 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
            schedulerYields += 1
            settled = benchmarkHasSettled(editor)
        }
        let finalStyledBlockCount = editor.blocks.lazy.filter(\.isStyled).count

        window.orderOut(nil)
        window.close()
        defaults.removePersistentDomain(forName: defaultsName)

        return OpenDocumentBenchmarkSample(
            synchronousLoadMilliseconds: synchronousLoadMilliseconds,
            firstPresentationMilliseconds: firstPresentationMilliseconds,
            activeDrainCPUMilliseconds: activeDrainCPUMilliseconds,
            styledAtFirstPresentation: styledAtFirstPresentation,
            finalStyledBlockCount: finalStyledBlockCount,
            totalBlockCount: editor.blocks.count,
            drainSlices: drainSlices,
            schedulerYields: schedulerYields,
            converged: stylingConverged && settled
        )
    }

    private static func benchmarkHasSettled(_ editor: EditorTextView) -> Bool {
        editor.progressiveStylingScheduled == false
            && editor.fullLayoutSettleScheduled == false
            && editor.pendingPromotion == false
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let duration = ContinuousClock().measure(body)
        return milliseconds(duration)
    }

    private static func threadCPUMilliseconds(_ body: () -> Void) -> Double {
        var start = timespec()
        var end = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &start)
        body()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &end)
        let seconds = Double(end.tv_sec - start.tv_sec)
        let nanoseconds = Double(end.tv_nsec - start.tv_nsec)
        return seconds * 1_000 + nanoseconds / 1e6
    }

    private static func milliseconds(
        since start: ContinuousClock.Instant
    ) -> Double {
        milliseconds(ContinuousClock.now - start)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }
}

enum OpenDocumentBenchmarkAggregator {
    static func loadSamples(
        from directory: URL
    ) throws -> [OpenDocumentBenchmarkSampleEnvelope] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map {
                try JSONDecoder().decode(
                    OpenDocumentBenchmarkSampleEnvelope.self,
                    from: Data(contentsOf: $0)
                )
            }
    }

    static func validateSampleSet(
        _ envelopes: [OpenDocumentBenchmarkSampleEnvelope],
        contract: OpenDocumentBenchmarkContract,
        measuredIterations: Int
    ) throws {
        let expectedCount = contract.scenarios.count * measuredIterations
        guard envelopes.count == expectedCount else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Expected \(expectedCount) samples, found \(envelopes.count)"
            )
        }
        guard Set(envelopes.map(\.processIdentifier)).count == expectedCount else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Every measured sample must come from a distinct worker process"
            )
        }
        for scenario in contract.scenarios {
            let samples = envelopes.filter { $0.scenarioName == scenario.name }
            guard samples.count == measuredIterations,
                  Set(samples.map(\.iteration)) == Set(1...measuredIterations)
            else {
                throw OpenDocumentBenchmarkValidationError.invalid(
                    "\(scenario.name) does not have one sample per iteration"
                )
            }
        }
        guard envelopes.allSatisfy({
            $0.sample.converged
                && $0.sample.finalStyledBlockCount == $0.sample.totalBlockCount
                && $0.sample.synchronousLoadMilliseconds > 0
                && $0.sample.firstPresentationMilliseconds
                    >= $0.sample.synchronousLoadMilliseconds
                && $0.sample.activeDrainCPUMilliseconds > 0
                && $0.sample.drainSlices > 0
        }) else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "A sample did not converge or reported impossible timing"
            )
        }
    }

    static func makeReport(
        contract: OpenDocumentBenchmarkContract,
        envelopes: [OpenDocumentBenchmarkSampleEnvelope],
        measuredIterations: Int,
        environment: [String: String]
    ) throws -> OpenDocumentBenchmarkReport {
        try validateSampleSet(
            envelopes,
            contract: contract,
            measuredIterations: measuredIterations
        )
        for scenario in contract.scenarios {
            try OpenDocumentBenchmarkFixture(scenario: scenario).validate(against: scenario)
        }

        let results = contract.scenarios.map { scenario in
            makeScenarioResult(
                scenario: scenario,
                samples: envelopes
                    .filter { $0.scenarioName == scenario.name }
                    .sorted { $0.iteration < $1.iteration }
            )
        }
        let baselineResult = try requireResult(
            contract.gate.baselineScenario,
            from: results
        )
        let scaledResult = try requireResult(
            contract.gate.scaledScenario,
            from: results
        )
        let pairedFirstPresentationRatios = (1...measuredIterations).map {
            iteration -> Double in
            let baseline = baselineResult.samples.first {
                $0.iteration == iteration
            }!.sample.firstPresentationMilliseconds
            let scaled = scaledResult.samples.first {
                $0.iteration == iteration
            }!.sample.firstPresentationMilliseconds
            return scaled / baseline
        }
        let pairedActiveDrainRatios = (1...measuredIterations).map {
            iteration -> Double in
            let baseline = baselineResult.samples.first {
                $0.iteration == iteration
            }!.sample.activeDrainCPUMilliseconds
            let scaled = scaledResult.samples.first {
                $0.iteration == iteration
            }!.sample.activeDrainCPUMilliseconds
            return scaled / baseline
        }
        let firstPresentationScalingRatio = PerformanceBenchmarkStatistics.median(
            pairedFirstPresentationRatios
        )
        let activeDrainScalingRatio = PerformanceBenchmarkStatistics.median(
            pairedActiveDrainRatios
        )
        let maximumRelativeMAD = results.flatMap {
            [
                $0.relativeMADSynchronousLoad,
                $0.relativeMADFirstPresentation,
                $0.relativeMADActiveDrainCPU,
            ]
        }.max() ?? .infinity

        let mode = environment["EDMUND_BENCHMARK_MODE"] ?? "report"
        let buildConfiguration = benchmarkBuildConfiguration
        let sourceTreeDirty = environment["EDMUND_BENCHMARK_DIRTY"] == "1"
        let usedSkipBuild = environment["EDMUND_BENCHMARK_SKIP_BUILD"] == "1"
        let authoritative = environment["EDMUND_BENCHMARK_AUTHORITATIVE"] == "1"
        var preconditionFailures = [String]()
        if authoritative != (
            sourceTreeDirty == false
                && usedSkipBuild == false
                && buildConfiguration == "release"
        ) {
            preconditionFailures.append("Authoritative provenance flags are inconsistent")
        }
        let contractSHA256 = environment["EDMUND_BENCHMARK_CONTRACT_SHA256"]
            ?? "unknown"
        let benchmarkDefinitionSHA256 =
            environment["EDMUND_BENCHMARK_DEFINITION_SHA256"] ?? "unknown"
        let testBinarySHA256 = environment["EDMUND_BENCHMARK_BINARY_SHA256"]
            ?? "unknown"
        if authoritative
            && (
                contractSHA256.count != 64
                    || benchmarkDefinitionSHA256.count != 64
                    || testBinarySHA256.count != 64
            ) {
            preconditionFailures.append(
                "Authoritative reports require contract, benchmark-definition, "
                    + "and test-binary SHA-256 values"
            )
        }

        let currentEnvironment = OpenDocumentBenchmarkEnvironment(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: benchmarkHardwareModel(),
            processorArchitecture: benchmarkProcessorArchitecture,
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            swiftVersion: environment["EDMUND_BENCHMARK_SWIFT_VERSION"] ?? "unknown",
            buildConfiguration: buildConfiguration
        )
        var regressionRatios = [OpenDocumentBenchmarkRegressionRatio]()
        if mode == "gate" {
            let baselineURL = OpenDocumentBenchmarkContract.rootURL
                .appendingPathComponent(contract.gate.baselineReportPath)
            do {
                let reference = try JSONDecoder().decode(
                    OpenDocumentBenchmarkReport.self,
                    from: Data(contentsOf: baselineURL)
                )
                guard reference.evidenceValid else {
                    throw OpenDocumentBenchmarkValidationError.invalid(
                        "Reference baseline is not valid evidence"
                    )
                }
                try validateReferenceCompatibility(
                    referenceSchemaVersion: reference.schemaVersion,
                    referenceProvenance: reference.provenance,
                    referenceEnvironment: reference.environment,
                    expectedSchemaVersion: contract.schemaVersion,
                    expectedContractSHA256: contractSHA256,
                    expectedBenchmarkDefinitionSHA256:
                        benchmarkDefinitionSHA256,
                    currentEnvironment: currentEnvironment
                )
                regressionRatios = try makeRegressionRatios(
                    current: results,
                    reference: reference.scenarios,
                    contract: contract
                )
            } catch {
                preconditionFailures.append("Cannot use reference baseline: \(error)")
            }
        }

        let metrics = OpenDocumentBenchmarkGateMetrics(
            firstPresentationScalingRatio: firstPresentationScalingRatio,
            activeDrainScalingRatio: activeDrainScalingRatio,
            maximumRelativeMAD: maximumRelativeMAD,
            regressionRatios: regressionRatios,
            preconditionFailures: preconditionFailures
        )
        let evaluation = OpenDocumentBenchmarkGateEvaluator.evaluate(
            metrics: metrics,
            gate: contract.gate,
            authoritative: authoritative
        )
        var evidenceFailures = preconditionFailures
        if authoritative == false {
            evidenceFailures.append(
                "Run is non-authoritative: require a clean tree and clean release build"
            )
        }
        if maximumRelativeMAD > contract.gate.maxRelativeMAD {
            evidenceFailures.append(
                "Sample relative MAD \(format(maximumRelativeMAD)) exceeds "
                    + "\(format(contract.gate.maxRelativeMAD))"
            )
        }
        return OpenDocumentBenchmarkReport(
            schemaVersion: contract.schemaVersion,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            mode: mode,
            measuredIterations: measuredIterations,
            provenance: OpenDocumentBenchmarkProvenance(
                sourceRevision: environment["EDMUND_BENCHMARK_REVISION"] ?? "unknown",
                sourceTreeDirty: sourceTreeDirty,
                contractSHA256: contractSHA256,
                benchmarkDefinitionSHA256: benchmarkDefinitionSHA256,
                testBinarySHA256: testBinarySHA256,
                usedSkipBuild: usedSkipBuild,
                authoritative: authoritative
            ),
            environment: currentEnvironment,
            freshProcessCount: Set(envelopes.map(\.processIdentifier)).count,
            scenarios: results,
            pairedFirstPresentationScalingRatio: firstPresentationScalingRatio,
            maximumFirstPresentationScalingRatio:
                contract.gate.maxFirstPresentationScalingRatio,
            pairedActiveDrainScalingRatio: activeDrainScalingRatio,
            maximumActiveDrainScalingRatio:
                contract.gate.maxActiveDrainScalingRatio,
            maximumRelativeMAD: maximumRelativeMAD,
            allowedRelativeMAD: contract.gate.maxRelativeMAD,
            regressionRatios: regressionRatios,
            maximumBaselineRegressionRatio: contract.gate.maxBaselineRegressionRatio,
            evidenceFailures: evidenceFailures,
            evidenceValid: authoritative && evidenceFailures.isEmpty,
            gateFailures: evaluation.failures,
            gatePassed: evaluation.passed
        )
    }

    static func printSummary(_ report: OpenDocumentBenchmarkReport) {
        for result in report.scenarios {
            print(
                "[EDMUND_BENCHMARK] \(result.name): "
                    + "load=\(format(result.medianSynchronousLoadMilliseconds))ms "
                    + "first=\(format(result.medianFirstPresentationMilliseconds))ms "
                    + "drainCPU=\(format(result.medianActiveDrainCPUMilliseconds))ms "
                    + "MAD=\(format(result.relativeMADActiveDrainCPU))"
            )
        }
        print(
            "[EDMUND_BENCHMARK] paired first-presentation scaling: "
                + "\(format(report.pairedFirstPresentationScalingRatio))× "
                + "(target ≤ \(format(report.maximumFirstPresentationScalingRatio))×)"
        )
        print(
            "[EDMUND_BENCHMARK] paired active-drain scaling: "
                + "\(format(report.pairedActiveDrainScalingRatio))× "
                + "(target ≤ \(format(report.maximumActiveDrainScalingRatio))×)"
        )
        print(
            "[EDMUND_BENCHMARK] authoritative=\(report.provenance.authoritative) "
                + "gatePassed=\(report.gatePassed)"
        )
    }

    private static func makeScenarioResult(
        scenario: OpenDocumentBenchmarkContract.Scenario,
        samples: [OpenDocumentBenchmarkSampleEnvelope]
    ) -> OpenDocumentBenchmarkScenarioResult {
        let loads = samples.map(\.sample.synchronousLoadMilliseconds)
        let presentations = samples.map(\.sample.firstPresentationMilliseconds)
        let drainCPU = samples.map(\.sample.activeDrainCPUMilliseconds)
        return OpenDocumentBenchmarkScenarioResult(
            name: scenario.name,
            approximateBytes: scenario.approximateBytes,
            seed: scenario.seed,
            sha256: scenario.expectedSHA256,
            utf16Length: scenario.expectedUTF16Length,
            blockCount: scenario.expectedBlockCount,
            samples: samples,
            medianSynchronousLoadMilliseconds:
                PerformanceBenchmarkStatistics.median(loads),
            medianFirstPresentationMilliseconds:
                PerformanceBenchmarkStatistics.median(presentations),
            medianActiveDrainCPUMilliseconds:
                PerformanceBenchmarkStatistics.median(drainCPU),
            relativeMADSynchronousLoad:
                PerformanceBenchmarkStatistics.relativeMedianAbsoluteDeviation(loads),
            relativeMADFirstPresentation:
                PerformanceBenchmarkStatistics.relativeMedianAbsoluteDeviation(presentations),
            relativeMADActiveDrainCPU:
                PerformanceBenchmarkStatistics.relativeMedianAbsoluteDeviation(drainCPU)
        )
    }

    static func makeRegressionRatios(
        current: [OpenDocumentBenchmarkScenarioResult],
        reference: [OpenDocumentBenchmarkScenarioResult],
        contract: OpenDocumentBenchmarkContract
    ) throws -> [OpenDocumentBenchmarkRegressionRatio] {
        var ratios = [OpenDocumentBenchmarkRegressionRatio]()
        for scenario in contract.scenarios {
            let now = try requireResult(scenario.name, from: current)
            let before = try requireResult(scenario.name, from: reference)
            ratios.append(.init(
                scenario: scenario.name,
                metric: "synchronousLoad",
                ratio: now.medianSynchronousLoadMilliseconds
                    / before.medianSynchronousLoadMilliseconds
            ))
            ratios.append(.init(
                scenario: scenario.name,
                metric: "firstPresentation",
                ratio: now.medianFirstPresentationMilliseconds
                    / before.medianFirstPresentationMilliseconds
            ))
            ratios.append(.init(
                scenario: scenario.name,
                metric: "activeDrainCPU",
                ratio: now.medianActiveDrainCPUMilliseconds
                    / before.medianActiveDrainCPUMilliseconds
            ))
        }
        return ratios
    }

    static func validateReferenceCompatibility(
        referenceSchemaVersion: Int,
        referenceProvenance: OpenDocumentBenchmarkProvenance,
        referenceEnvironment: OpenDocumentBenchmarkEnvironment,
        expectedSchemaVersion: Int,
        expectedContractSHA256: String,
        expectedBenchmarkDefinitionSHA256: String,
        currentEnvironment: OpenDocumentBenchmarkEnvironment
    ) throws {
        guard referenceSchemaVersion == expectedSchemaVersion,
              referenceProvenance.contractSHA256 == expectedContractSHA256
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Reference baseline uses a different benchmark contract"
            )
        }
        guard referenceProvenance.benchmarkDefinitionSHA256
            == expectedBenchmarkDefinitionSHA256
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Reference baseline uses a different benchmark implementation"
            )
        }
        guard referenceEnvironment.operatingSystem
                == currentEnvironment.operatingSystem,
              referenceEnvironment.hardwareModel
                == currentEnvironment.hardwareModel,
              referenceEnvironment.processorArchitecture
                == currentEnvironment.processorArchitecture,
              referenceEnvironment.processorCount
                == currentEnvironment.processorCount,
              referenceEnvironment.swiftVersion
                == currentEnvironment.swiftVersion,
              referenceEnvironment.buildConfiguration
                == currentEnvironment.buildConfiguration
        else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Reference baseline was recorded in a different environment"
            )
        }
    }

    private static func requireResult(
        _ name: String,
        from results: [OpenDocumentBenchmarkScenarioResult]
    ) throws -> OpenDocumentBenchmarkScenarioResult {
        guard let result = results.first(where: { $0.name == name }) else {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Missing result for \(name)"
            )
        }
        return result
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

var benchmarkBuildConfiguration: String {
    #if DEBUG
    "debug"
    #else
    "release"
    #endif
}

func benchmarkEnvironment(_ name: String) throws -> String {
    guard let value = ProcessInfo.processInfo.environment[name],
          value.isEmpty == false
    else {
        throw OpenDocumentBenchmarkValidationError.invalid(
            "Missing environment variable \(name)"
        )
    }
    return value
}

func benchmarkEnvironmentURL(_ name: String) throws -> URL {
    URL(fileURLWithPath: try benchmarkEnvironment(name))
}

func benchmarkWriteJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func benchmarkSHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

func benchmarkHardwareModel() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var bytes = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else {
        return "unknown"
    }
    return String(decoding: bytes.prefix { $0 != 0 }.map(UInt8.init), as: UTF8.self)
}

var benchmarkProcessorArchitecture: String {
    #if arch(arm64)
    "arm64"
    #elseif arch(x86_64)
    "x86_64"
    #else
    "unknown"
    #endif
}
