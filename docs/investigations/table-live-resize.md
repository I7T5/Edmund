# Table live-resize check — PR #290

Measured on 2026-09-10 with the image-overlay follow-up to `5d7f007`,
using the original 60 Hz scheduling interval. The subsequent review follow-up
reduces scheduling to 30 Hz; the timings below have not been remeasured at that
cadence and do not demonstrate its performance.
Release build (`swift build -c release`), Swift 6.3.3, macOS 26.6.2,
M3 Max (14 CPU cores), 36 GB RAM. An isolated app bundle opened a generated
95,000 UTF-16-unit Markdown document in Edit mode, with eight two-column
tables (six body rows each) distributed among ordinary wrapping paragraphs.
The content-width cap was set above the window width. The viewport remained
near the first table. This exercises the <=8-dirty-block path below the
100,000-unit full-layout threshold; it does not characterize larger files.

The contributor manually dragged the right window edge narrower and then wider,
releasing between drags. AppKit's live-resize callbacks bracketed 3.90 s and
5.92 s respectively, with numerous intermediate widths and repeated scheduled
restyles. Final usable column widths were 282 pt and 746 pt. An earlier automated
drag yielded no intervening timer samples and is excluded from these results.

| Measurement (milliseconds) | Narrowing | Widening |
| --- | ---: | ---: |
| Width-update worker calls | 64 | 138 |
| Worker median | 15.28 | 15.12 |
| Worker p95 | 18.41 | 16.67 |
| Worker maximum | 22.70 | 22.49 |
| Main-run-loop work samples | 369 | 365 |
| Main-run-loop work p95 | 28.83 | 41.49 |
| Main-run-loop work maximum | 138.10 | 257.41 |

Temporary instrumentation timed `updateContentWidths()` with
`CFAbsoluteTimeGetCurrent`, including its early-return cases. A common-mode
`CFRunLoopObserver` measured elapsed main-thread work from `afterWaiting` to
`beforeWaiting` during live resizing, excluding time asleep. Samples were
buffered in memory and written after each drag; `setFrameSize` also recorded
intermediate widths and `inLiveResize`. Percentiles use sorted sample index
`floor(0.95 * (count - 1))`.

The run-loop measurement is a frame-cost proxy, **not GPU presentation timing or
an FPS measurement**. It includes work outside the width-update worker, but
cannot attribute the longest stalls to a particular function. Most turns do
little work, so their near-zero median is not representative of resize frames.
The p95 and maximum show that this document can exceed a 16.7 ms frame budget.
These results do not establish smooth 60 Hz resizing or an improvement over the
pre-PR version. The review's headless timings alone could not establish the
behavior during a sustained drag; this check confirms repeated work and stalls
in the live app. Profiling and reducing that cost remain follow-up work.

The narrow live window visibly rewrapped the table. A separate offscreen
800 -> 350 -> 800 pt check verified table and image rendering, proportional
image resizing, and text placement below them; the two wide PNGs were identical.
Temporary probes are excluded from production code. Raw timings, the exact
fixture, probe source, PNGs, and test logs are retained locally in the ignored
`build/pr290-review-evidence/` directory.

Validation: the full suite ran 1,471 tests including the temporary visual probe.
The table and image tests passed. The same two failures occurred before and
after the follow-up: `ScrollStabilityTests`' line-number viewport assertion and
nine tint assertions in `FormatToolbarTests.theIconRowIsMouseOnlyUntintedAndEvenlySized`.
The visual probe was removed after the run; the production suite has 1,470 tests.
