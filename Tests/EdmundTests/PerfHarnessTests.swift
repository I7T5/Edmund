import AppKit
import Testing
@testable import EdmundCore

@Suite("Performance benchmark contract")
struct PerformanceBenchmarkContractTests {
    @Test("Committed contract is structurally valid")
    func configurationIsValid() throws {
        try OpenDocumentBenchmarkContract.load().validate()
    }

    @Test("Degenerate self-comparison gate is rejected")
    func selfComparisonIsRejected() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        let invalid = contract.replacingGate(
            baselineScenario: contract.gate.baselineScenario,
            scaledScenario: contract.gate.baselineScenario
        )

        #expect(throws: OpenDocumentBenchmarkValidationError.self) {
            try invalid.validate()
        }
    }

    @Test("Generated workloads match their committed fingerprints")
    func workloadFingerprintsAreStable() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        for scenario in contract.scenarios {
            try OpenDocumentBenchmarkFixture(scenario: scenario).validate(against: scenario)
        }
    }

    @Test(
        "Median is deterministic for odd and even sample counts",
        arguments: [
            ([9.0, 1.0, 5.0], 5.0),
            ([8.0, 2.0, 4.0, 6.0], 5.0),
        ]
    )
    func median(samples: [Double], expected: Double) {
        #expect(PerformanceBenchmarkStatistics.median(samples) == expected)
    }

    @Test("Relative median absolute deviation exposes unstable samples")
    func relativeMedianAbsoluteDeviation() {
        let stable = PerformanceBenchmarkStatistics.relativeMedianAbsoluteDeviation(
            [100, 101, 99, 100, 102]
        )
        let unstable = PerformanceBenchmarkStatistics.relativeMedianAbsoluteDeviation(
            [669, 1_124, 2_957]
        )

        #expect(stable < 0.02)
        #expect(unstable > 0.40)
    }

    @Test("Absolute regression cannot be hidden by a better scaling ratio")
    func ratioOnlyImprovementDoesNotPass() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        let metrics = OpenDocumentBenchmarkGateMetrics(
            firstPresentationScalingRatio: 1.92,
            activeDrainScalingRatio: 1.92,
            maximumRelativeMAD: 0.05,
            regressionRatios: [
                .init(scenario: "lazy-100k", metric: "firstPresentation", ratio: 4.0),
                .init(scenario: "lazy-200k", metric: "activeDrainCPU", ratio: 1.61),
            ]
        )

        let evaluation = OpenDocumentBenchmarkGateEvaluator.evaluate(
            metrics: metrics,
            gate: contract.gate,
            authoritative: true
        )

        #expect(evaluation.passed == false)
        #expect(evaluation.failures.contains { $0.contains("regressed") })
    }

    @Test("Active-drain regression is derived for every scenario")
    func activeDrainRegressionCoversBaselineAndScaledScenarios() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        let reference = contract.scenarios.map {
            benchmarkScenarioResult(name: $0.name, activeDrainCPU: 100)
        }
        let current = contract.scenarios.map {
            benchmarkScenarioResult(
                name: $0.name,
                activeDrainCPU: $0.name == contract.gate.baselineScenario ? 400 : 100
            )
        }

        let ratios = try OpenDocumentBenchmarkAggregator.makeRegressionRatios(
            current: current,
            reference: reference,
            contract: contract
        )
        let activeDrainRatios = ratios.filter { $0.metric == "activeDrainCPU" }

        #expect(activeDrainRatios.count == contract.scenarios.count)
        #expect(activeDrainRatios.contains {
            $0.scenario == contract.gate.baselineScenario && $0.ratio == 4
        })
    }

    @Test("Reference evidence must match implementation and environment")
    func referenceCompatibilityIsStrict() throws {
        let contractHash = String(repeating: "a", count: 64)
        let definitionHash = String(repeating: "b", count: 64)
        let provenance = OpenDocumentBenchmarkProvenance(
            sourceRevision: "revision",
            sourceTreeDirty: false,
            contractSHA256: contractHash,
            benchmarkDefinitionSHA256: definitionHash,
            testBinarySHA256: String(repeating: "c", count: 64),
            usedSkipBuild: false,
            authoritative: true
        )
        let environment = OpenDocumentBenchmarkEnvironment(
            operatingSystem: "macOS build",
            hardwareModel: "Mac17,3",
            processorArchitecture: "arm64",
            processorCount: 10,
            swiftVersion: "Swift 6",
            buildConfiguration: "release"
        )

        try OpenDocumentBenchmarkAggregator.validateReferenceCompatibility(
            referenceSchemaVersion: 2,
            referenceProvenance: provenance,
            referenceEnvironment: environment,
            expectedSchemaVersion: 2,
            expectedContractSHA256: contractHash,
            expectedBenchmarkDefinitionSHA256: definitionHash,
            currentEnvironment: environment
        )
        #expect(throws: OpenDocumentBenchmarkValidationError.self) {
            try OpenDocumentBenchmarkAggregator.validateReferenceCompatibility(
                referenceSchemaVersion: 2,
                referenceProvenance: provenance,
                referenceEnvironment: environment,
                expectedSchemaVersion: 2,
                expectedContractSHA256: contractHash,
                expectedBenchmarkDefinitionSHA256: String(repeating: "d", count: 64),
                currentEnvironment: environment
            )
        }
        let differentOS = OpenDocumentBenchmarkEnvironment(
            operatingSystem: "different macOS build",
            hardwareModel: environment.hardwareModel,
            processorArchitecture: environment.processorArchitecture,
            processorCount: environment.processorCount,
            swiftVersion: environment.swiftVersion,
            buildConfiguration: environment.buildConfiguration
        )
        #expect(throws: OpenDocumentBenchmarkValidationError.self) {
            try OpenDocumentBenchmarkAggregator.validateReferenceCompatibility(
                referenceSchemaVersion: 2,
                referenceProvenance: provenance,
                referenceEnvironment: environment,
                expectedSchemaVersion: 2,
                expectedContractSHA256: contractHash,
                expectedBenchmarkDefinitionSHA256: definitionHash,
                currentEnvironment: differentOS
            )
        }
    }

    @Test("Every measured sample must come from a distinct process")
    func duplicateWorkerProcessesAreRejected() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        let sample = OpenDocumentBenchmarkSample.stub()
        let envelopes = [
            OpenDocumentBenchmarkSampleEnvelope(
                scenarioName: contract.gate.baselineScenario,
                iteration: 1,
                processIdentifier: 42,
                sample: sample
            ),
            OpenDocumentBenchmarkSampleEnvelope(
                scenarioName: contract.gate.scaledScenario,
                iteration: 1,
                processIdentifier: 42,
                sample: sample
            ),
        ]

        #expect(throws: OpenDocumentBenchmarkValidationError.self) {
            try OpenDocumentBenchmarkAggregator.validateSampleSet(
                envelopes,
                contract: contract,
                measuredIterations: 1
            )
        }
    }
}

private func benchmarkScenarioResult(
    name: String,
    activeDrainCPU: Double
) -> OpenDocumentBenchmarkScenarioResult {
    OpenDocumentBenchmarkScenarioResult(
        name: name,
        approximateBytes: 1,
        seed: 1,
        sha256: String(repeating: "a", count: 64),
        utf16Length: 1,
        blockCount: 1,
        samples: [],
        medianSynchronousLoadMilliseconds: 1,
        medianFirstPresentationMilliseconds: 1,
        medianActiveDrainCPUMilliseconds: activeDrainCPU,
        relativeMADSynchronousLoad: 0,
        relativeMADFirstPresentation: 0,
        relativeMADActiveDrainCPU: 0
    )
}

@Suite(
    "Performance benchmark manifest",
    .enabled(if: benchmarkPhase == "manifest")
)
struct PerformanceBenchmarkManifestTests {
    @Test("Validate contract and write worker manifest")
    func writeManifest() throws {
        let contract = try OpenDocumentBenchmarkContract.load()
        try contract.validate()
        for scenario in contract.scenarios {
            try OpenDocumentBenchmarkFixture(scenario: scenario).validate(against: scenario)
        }

        let outputURL = try benchmarkEnvironmentURL("EDMUND_BENCHMARK_MANIFEST")
        let lines = ["iterations=\(contract.measuredIterations)"]
            + contract.scenarios.map { "scenario=\($0.name)" }
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: outputURL, options: .atomic)
    }
}

@MainActor
@Suite(
    "Open-document performance worker",
    .enabled(if: benchmarkPhase == "worker")
)
struct PerformanceBenchmarkWorkerTests {
    @Test("Measure one isolated windowed sample", .timeLimit(.minutes(5)))
    func measureScenario() async throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try OpenDocumentBenchmarkContract.load()
        try contract.validate()
        let scenarioName = try benchmarkEnvironment("EDMUND_BENCHMARK_SCENARIO")
        let iteration = try #require(
            environment["EDMUND_BENCHMARK_ITERATION"].flatMap(Int.init)
        )
        let scenario = try #require(
            contract.scenarios.first { $0.name == scenarioName }
        )
        let fixture = OpenDocumentBenchmarkFixture(scenario: scenario)
        try fixture.validate(against: scenario)

        for _ in 0..<contract.warmupIterations {
            let warmup = await OpenDocumentBenchmarkRunner.measure(
                fixture,
                timeoutSeconds: contract.sampleTimeoutSeconds
            )
            try #require(warmup.converged, "Benchmark warmup did not converge")
        }

        let sample = await OpenDocumentBenchmarkRunner.measure(
            fixture,
            timeoutSeconds: contract.sampleTimeoutSeconds
        )
        try #require(sample.converged, "Benchmark sample did not converge")
        try #require(sample.finalStyledBlockCount == sample.totalBlockCount)

        let envelope = OpenDocumentBenchmarkSampleEnvelope(
            scenarioName: scenario.name,
            iteration: iteration,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            sample: sample
        )
        try benchmarkWriteJSON(
            envelope,
            to: benchmarkEnvironmentURL("EDMUND_BENCHMARK_SAMPLE_OUTPUT")
        )
    }
}

@Suite(
    "Open-document performance report",
    .enabled(if: benchmarkPhase == "aggregate")
)
struct PerformanceBenchmarkReportTests {
    @Test("Aggregate isolated samples and enforce the requested gate")
    func aggregate() throws {
        let environment = ProcessInfo.processInfo.environment
        let contract = try OpenDocumentBenchmarkContract.load()
        try contract.validate()
        let measuredIterations = try #require(
            environment["EDMUND_BENCHMARK_SAMPLES"].flatMap(Int.init)
        )
        let sampleDirectory = try benchmarkEnvironmentURL("EDMUND_BENCHMARK_SAMPLE_DIR")
        let envelopes = try OpenDocumentBenchmarkAggregator.loadSamples(
            from: sampleDirectory
        )
        let report = try OpenDocumentBenchmarkAggregator.makeReport(
            contract: contract,
            envelopes: envelopes,
            measuredIterations: measuredIterations,
            environment: environment
        )
        if report.mode == "report",
           report.provenance.authoritative,
           report.evidenceValid == false {
            throw OpenDocumentBenchmarkValidationError.invalid(
                "Authoritative report rejected: "
                    + report.evidenceFailures.joined(separator: "; ")
            )
        }

        try benchmarkWriteJSON(
            report,
            to: benchmarkEnvironmentURL("EDMUND_BENCHMARK_OUTPUT")
        )
        OpenDocumentBenchmarkAggregator.printSummary(report)

        if report.mode == "gate" {
            #expect(
                report.gatePassed,
                Comment(rawValue: report.gateFailures.joined(separator: "; "))
            )
        }
    }
}
