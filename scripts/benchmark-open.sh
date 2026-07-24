#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: scripts/benchmark-open.sh [report|gate] [--samples N] [--output PATH] [--skip-build]"
    echo
    echo "  report       Measure and write JSON without enforcing the target (default)."
    echo "  gate         Measure and fail unless scaling, stability, and baseline checks pass."
    echo "  --samples N  Use N isolated samples per workload (minimum 5, odd only)."
    echo "  --output     Write the JSON report to PATH."
    echo "  --skip-build Reuse a release test bundle; report is non-authoritative."
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

mode=${1:-report}
if [[ "$mode" == "report" || "$mode" == "gate" ]]; then
    if [[ $# -gt 0 ]]; then shift; fi
else
    usage >&2
    exit 2
fi

samples=""
output=""
skip_build=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --samples)
            samples=${2:?--samples requires a value}
            shift 2
            ;;
        --output)
            output=${2:?--output requires a path}
            shift 2
            ;;
        --skip-build)
            skip_build=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -n "$samples" ]]; then
    if ! [[ "$samples" =~ ^[0-9]+$ ]] \
        || (( samples < 5 )) \
        || (( samples % 2 == 0 )); then
        echo "--samples must be an odd integer of at least 5" >&2
        exit 2
    fi
fi
if [[ "$mode" == "gate" && "$skip_build" == true ]]; then
    echo "gate mode requires a clean release rebuild; --skip-build is exploratory only" >&2
    exit 2
fi

if [[ -z "$output" ]]; then
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    output="benchmark-results/open-document-${timestamp}.json"
fi
if [[ "$output" != /* ]]; then
    output="$repo_root/$output"
fi
output_dir=$(dirname "$output")
output_name=$(basename "$output")
mkdir -p "$output_dir"

scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/edmund-benchmark.XXXXXX")
temporary_report="$output_dir/.${output_name}.tmp.$$"
cleanup() {
    rm -rf "$scratch_dir"
    rm -f "$temporary_report"
}
trap cleanup EXIT

source_tree_dirty=false
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
    source_tree_dirty=true
fi
if [[ "$mode" == "gate" && "$source_tree_dirty" == true ]]; then
    echo "gate mode requires a clean committed source tree" >&2
    exit 2
fi
source_revision=$(git rev-parse HEAD)
swift_version=$(swift --version | head -n 1)
contract_sha256=$(shasum -a 256 Benchmarks/open-document.json | awk '{print $1}')
benchmark_definition_sha256=$(
    shasum -a 256 \
        Benchmarks/open-document.json \
        Tests/EdmundTests/PerfHarnessTests.swift \
        Tests/EdmundTests/PerformanceBenchmarkSupport.swift \
        scripts/benchmark-open.sh \
        | shasum -a 256 \
        | awk '{print $1}'
)
manifest_path="$scratch_dir/manifest.txt"
sample_dir="$scratch_dir/samples"
mkdir -p "$sample_dir"

if [[ "$skip_build" == false ]]; then
    # Authoritative evidence pays the cost of a clean build. Edmund's release
    # artifacts have previously remained stale after incremental SwiftPM builds.
    swift package clean
    EDMUND_BENCHMARK_PHASE=manifest \
    EDMUND_BENCHMARK_MANIFEST="$manifest_path" \
        swift test -c release \
        --filter PerformanceBenchmarkManifestTests.writeManifest
else
    EDMUND_BENCHMARK_PHASE=manifest \
    EDMUND_BENCHMARK_MANIFEST="$manifest_path" \
        swift test --skip-build -c release \
        --filter PerformanceBenchmarkManifestTests.writeManifest
fi

if [[ ! -s "$manifest_path" ]]; then
    echo "Benchmark manifest was not generated" >&2
    exit 1
fi

default_samples=$(sed -n 's/^iterations=//p' "$manifest_path")
if [[ -z "$samples" ]]; then
    samples="$default_samples"
fi
scenarios=()
while IFS= read -r line; do
    case "$line" in
        scenario=*)
            scenarios[${#scenarios[@]}]=${line#scenario=}
            ;;
    esac
done < "$manifest_path"
if (( ${#scenarios[@]} < 2 )); then
    echo "Benchmark manifest must contain at least two scenarios" >&2
    exit 1
fi

release_bin_path=$(swift build -c release --show-bin-path)
test_binary="$release_bin_path/EdmundPackageTests.xctest/Contents/MacOS/EdmundPackageTests"
if [[ ! -x "$test_binary" ]]; then
    echo "Release test binary not found at $test_binary" >&2
    exit 1
fi
binary_sha256=$(shasum -a 256 "$test_binary" | awk '{print $1}')

authoritative=false
if [[ "$source_tree_dirty" == false && "$skip_build" == false ]]; then
    authoritative=true
fi

run_worker() {
    worker_scenario=$1
    worker_iteration=$2
    worker_output=$(printf "%s/%03d-%s.json" \
        "$sample_dir" "$worker_iteration" "$worker_scenario")
    echo "[EDMUND_BENCHMARK] $worker_scenario sample $worker_iteration/$samples"
    EDMUND_BENCHMARK_PHASE=worker \
    EDMUND_BENCHMARK_SCENARIO="$worker_scenario" \
    EDMUND_BENCHMARK_ITERATION="$worker_iteration" \
    EDMUND_BENCHMARK_SAMPLE_OUTPUT="$worker_output" \
        swift test --skip-build -c release \
        --filter PerformanceBenchmarkWorkerTests.measureScenario
    if [[ ! -s "$worker_output" ]]; then
        echo "Worker did not produce $worker_output" >&2
        exit 1
    fi
}

for (( iteration = 1; iteration <= samples; iteration++ )); do
    if (( iteration % 2 == 1 )); then
        for (( index = 0; index < ${#scenarios[@]}; index++ )); do
            run_worker "${scenarios[$index]}" "$iteration"
        done
    else
        for (( index = ${#scenarios[@]} - 1; index >= 0; index-- )); do
            run_worker "${scenarios[$index]}" "$iteration"
        done
    fi
done

dirty_flag=0
skip_flag=0
authoritative_flag=0
if [[ "$source_tree_dirty" == true ]]; then dirty_flag=1; fi
if [[ "$skip_build" == true ]]; then skip_flag=1; fi
if [[ "$authoritative" == true ]]; then authoritative_flag=1; fi

set +e
EDMUND_BENCHMARK_PHASE=aggregate \
EDMUND_BENCHMARK_MODE="$mode" \
EDMUND_BENCHMARK_SAMPLES="$samples" \
EDMUND_BENCHMARK_SAMPLE_DIR="$sample_dir" \
EDMUND_BENCHMARK_OUTPUT="$temporary_report" \
EDMUND_BENCHMARK_REVISION="$source_revision" \
EDMUND_BENCHMARK_DIRTY="$dirty_flag" \
EDMUND_BENCHMARK_SKIP_BUILD="$skip_flag" \
EDMUND_BENCHMARK_AUTHORITATIVE="$authoritative_flag" \
EDMUND_BENCHMARK_CONTRACT_SHA256="$contract_sha256" \
EDMUND_BENCHMARK_DEFINITION_SHA256="$benchmark_definition_sha256" \
EDMUND_BENCHMARK_BINARY_SHA256="$binary_sha256" \
EDMUND_BENCHMARK_SWIFT_VERSION="$swift_version" \
    swift test --skip-build -c release \
    --filter PerformanceBenchmarkReportTests.aggregate
aggregate_status=$?
set -e

if [[ -s "$temporary_report" ]]; then
    mv -f "$temporary_report" "$output"
    echo "Benchmark report written: $output"
elif (( aggregate_status == 0 )); then
    echo "Benchmark aggregation succeeded without producing a report" >&2
    exit 1
else
    echo "Benchmark aggregation failed; previous report was left untouched" >&2
fi

exit "$aggregate_status"
