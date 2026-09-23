#!/bin/bash
# Performance benchmark: runs the MD_PERF harness (Tests/EdmundTests/
# PerfHarnessTests.swift + PerfCorpus.swift) in a release build and prints
# median latency and retained memory per case (document feature x editor variant).
#
# Usage: scripts/bench.sh [base-ref]
#   no ref:    benchmark the working tree.
#   base-ref:  also benchmark <base-ref> (e.g. main, or a PR's merge base) in a
#              temporary worktree, running THIS tree's harness files against the
#              old code, then print both side by side with the change in %.
#              If the old code lacks an API the harness calls, its build fails
#              and the script says so.
#
# Knobs pass through to the harness (see PerfHarnessTests.swift):
#   MD_PERF_BYTES=50000,300000   sizes (matrix at the first; mixed at all)
#   MD_PERF_CASES='tables|math'  regex over case names (profile/variant@bytes)
#   MD_PERF_REPS=3               median of N fresh editors per case
#   MD_PERF_DRAIN=1              also time the full lazy-styling drain
#   MD_PERF_MERMAID_DIR=<dir>    unpacked beautiful-mermaid, to time real diagrams
# Results: build/bench/{head,base}.tsv  (case, metric, median, min).
#
# Numbers only compare on the same machine and power state with nothing heavy
# running; treat differences under ~10% as noise. Refs before the storage
# string-copy fix (EditorTextStorage length/attributedSubstring overrides) blow up
# on big documents — use MD_PERF_BYTES=50000 when comparing against them.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build/bench"
mkdir -p "$OUT"
HARNESS=(Tests/EdmundTests/PerfHarnessTests.swift Tests/EdmundTests/PerfCorpus.swift)

run() {  # <checkout dir> <label>
    rm -f "$OUT/$2.tsv"
    echo "== $2: release build + harness in $1"
    (cd "$1" && MD_PERF=1 MD_PERF_OUT="$OUT/$2.tsv" \
        swift test -c release -Xswiftc -enable-testing --filter PerfHarnessTests 2>&1 \
        | grep '^\[MD_PERF\] [^…]') \
        || { echo "!! $2: harness failed to build or run (killed for memory? see [MD_PERF] … markers)" >&2; return 1; }
}

run "$ROOT" head

if [ $# -ge 1 ]; then
    BASE_DIR="$(mktemp -d)/edmund-bench-base"
    trap 'git -C "$ROOT" worktree remove --force "$BASE_DIR" 2>/dev/null || true' EXIT
    git worktree add --detach -q "$BASE_DIR" "$1"
    for f in "${HARNESS[@]}"; do cp "$ROOT/$f" "$BASE_DIR/$f"; done
    run "$BASE_DIR" base || true

    echo ""
    echo "== $1 -> working tree (median; negative % = faster / smaller)"
    awk -F'\t' '
        NR == FNR { base[$1 FS $2] = $3; next }
        {
            k = $1 FS $2
            if (k in base && base[k] != 0)
                printf "%-26s %-14s %10.2f -> %10.2f  %+7.1f%%\n", $1, $2, base[k], $3, ($3 - base[k]) / base[k] * 100
            else
                printf "%-26s %-14s %10s -> %10.2f\n", $1, $2, "-", $3
        }' "$OUT/base.tsv" "$OUT/head.tsv" 2>/dev/null \
        || echo "(no base results to compare)"
fi
