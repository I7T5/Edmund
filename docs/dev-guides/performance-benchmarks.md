# Performance benchmark workflow

Edmund's performance work starts from a frozen, executable contract rather
than one-off stopwatch numbers. The open-document benchmark has two layers:

1. Normal `swift test` verifies the contract structure, generated Markdown
   fingerprints, statistics, process isolation, and gate behavior without
   running wall-clock measurements.
2. `scripts/benchmark-open.sh` builds and orchestrates the opt-in windowed
   benchmark, then writes a machine-readable JSON report.

This is a deterministic `EdmundCore` window benchmark, not a claim that the
test constructs every toolbar and overlay in `Document.makeWindowControllers`.
It uses the production editor geometry that affects TextKit 2 work: an
800×560 visible window, vertical scroller, 24×18 text inset, and 1,000-point
content-width cap.

## Commands

Record an authoritative baseline from a clean committed tree:

```bash
./scripts/benchmark-open.sh report \
  --output Benchmarks/Baselines/pre-optimization-2026-07-23.json
```

Run the test-first performance gate:

```bash
./scripts/benchmark-open.sh gate
```

Increase the odd sample count:

```bash
./scripts/benchmark-open.sh report --samples 7
```

`--skip-build` is for exploratory reports only. Such reports are explicitly
marked non-authoritative, and gate mode rejects the option. An authoritative
run requires a clean source tree and starts with `swift package clean` because
this repository has produced stale incremental release binaries. Workers match
a foreground AppKit app's user-interactive scheduling priority.

The report's benchmark-definition SHA-256 covers the contract, measurement and
aggregation code, test entry points, and shell orchestrator. Any change to
those semantics invalidates the reference baseline until it is deliberately
re-recorded. Gate comparisons also require the same OS build, hardware model,
processor architecture/count, Swift toolchain, and release configuration.

## Measurement model

Every measured sample runs in a fresh Swift test process. Its process ID is
recorded, and aggregation fails if any process is reused. Each worker validates
its fixture fingerprint, performs one same-scenario warmup, then records:

- `synchronousLoadMilliseconds`: blocking time inside `loadContent`.
- `firstPresentationMilliseconds`: time from load start through viewport
  layout and immediate window display.
- `activeDrainCPUMilliseconds`: main-thread CPU time spent inside lazy-styling
  drain slices, excluding scheduler delay and unrelated process preemption.

After the active drain, the worker yields to the real scheduled callbacks and
requires every block to be styled and all progressive-styling, promotion, and
full-layout-settle work to clear. The convergence cap is a failure, never a
truncated success. Scheduler latency is deliberately not reported as user
latency: Swift Testing's main-actor executor can delay queued drain callbacks
by orders of magnitude. Synchronous load and first presentation are the
user-facing open endpoints; active drain is an algorithmic-work metric.

The default is seven samples per workload. The shell runner counterbalances
scenario order on alternating iterations. Aggregation uses the median, pairs
the 100k and 200k samples by iteration for first-presentation and active-drain
scaling, reports relative median absolute deviation (MAD), and rejects unstable
runs above the contract limit.

## What the gate means

`Benchmarks/open-document.json` owns the workload fingerprints, thresholds,
and reference-baseline path. A gate passes only when all of these hold:

1. The run is authoritative: clean committed tree, clean release build, and
   recorded contract and test-binary SHA-256 fingerprints.
2. Every sample converges in a distinct process.
3. Relative MAD stays below the stability limit.
4. Median paired first-presentation and active-drain ratios stay below their
   scaling targets.
5. In the same recorded environment, neither scenario's synchronous load,
   first presentation, or active drain CPU time regresses beyond the baseline
   allowance.

The absolute checks prevent a fixed slowdown from making the ratio look
better. The initial contract remains deliberately red on pre-optimization
code; the performance work must turn it green without violating the baseline
checks. Wall-clock gates remain opt-in and do not run on shared CI hardware.

Reports preserve every raw sample, fixture structure and fingerprint,
dispersion, paired scaling, baseline comparisons, OS/hardware/toolchain
metadata, source-tree state, source revision, contract hash, release test
binary hash, and authority/pass/fail state.

The script writes to a temporary sibling of the requested output and only
replaces the prior report after aggregation produced a valid JSON file. A
worker or aggregation failure therefore cannot leave an old report presented
as fresh evidence.

## Changing the workload

Changing the generator, seed, size, parser behavior, endpoint, or gate is a
benchmark migration:

1. Explain why the old contract no longer represents the product question.
2. Update `Benchmarks/open-document.json` and its schema version if required.
3. Run the always-on contract tests and inspect the new fingerprints and
   structure.
4. Commit the harness change.
5. Record and commit a fresh authoritative pre-optimization baseline before
   changing production code.

Never use `test-files/` as benchmark input; it is the maintainer's manual test
corpus.
