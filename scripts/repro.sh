#!/bin/bash
# Live-app scenario suite: runs every Tests/Repro/*.repro (or those matching a
# pattern) in a real debug build of Edmund and aggregates PASS/FAIL.
#
# Usage: scripts/repro.sh [pattern]      e.g. scripts/repro.sh ime
#
# Unit tests drive a headless editor; these drive the running app — real
# window, real NSDocument, autosave, typewriter scrolling, the IME client — for
# the bug classes headless tests have historically missed (see the
# edmund-live-repro-and-diagnostics skill). Not run in CI: it needs a window
# server. Run it before merging anything that touches editing, undo, IME,
# selection or the storage/layout pipeline.
#
# Scenario format (Tests/Repro/<name>.repro): ReproScript commands, one per
# line (reference: the header of Sources/edmd/App/ReproScript.swift), plus
# header comments read by this runner:
#   # fixture: <file>.md   document to open, from Tests/Repro/fixtures/
#   # timeout: <seconds>   default 60
#   # expect-failures: <n> the scenario passes only if exactly n assertions
#                          FAIL (for self-checks that prove assertions can fail)
# End every scenario with `done` so the app exits with its verdict.
#
# Each scenario runs against a temp copy of the whole Tests/Repro tree (the
# document autosaves in place; fixtures and goldens must never change). The
# runner kills only the processes it started, never another edmd.
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
PATTERN="${1:-}"

echo "== building debug bundle"
swift build 2>&1 | grep -E "error:|Compiling|Build complete" | tail -3
BIN_DIR="$(swift build --show-bin-path)"
APP="build/EdmundDbg.app"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/edmd" "$APP/Contents/MacOS/edmd"
if [ -d "$BIN_DIR/Sparkle.framework" ]; then
    rm -rf "$APP/Contents/MacOS/Sparkle.framework"
    cp -R "$BIN_DIR/Sparkle.framework" "$APP/Contents/MacOS/"
fi
for bundle in "$BIN_DIR"/*.bundle; do [ -e "$bundle" ] && cp -R "$bundle" "$APP/"; done

RUN="$(mktemp -d)/repro"
cp -R Tests/Repro "$RUN"
pass=0; fail=0; failed=()

for script in "$RUN"/*.repro; do
    name="$(basename "$script" .repro)"
    [[ -n "$PATTERN" && "$name" != *$PATTERN* ]] && continue
    fixture="$(sed -n 's/^# fixture: *//p' "$script" | head -1)"
    timeout="$(sed -n 's/^# timeout: *//p' "$script" | head -1)"; timeout="${timeout:-60}"
    doc="$RUN/fixtures/$fixture"
    if [ -z "$fixture" ] || [ ! -f "$doc" ]; then
        echo "FAIL  $name  (fixture '$fixture' missing)"; fail=$((fail + 1)); failed+=("$name"); continue
    fi
    rm -f "$script.log"
    # The document must be the first argument (main.swift opens argv[1]).
    # The debug bundle shares the app's bundle id, so it would read the user's
    # own preferences; argument-domain values pin the editing settings the
    # scenarios' goldens depend on.
    "$ROOT/$APP/Contents/MacOS/edmd" "$doc" \
        -debug.reproScript "$script" -debug.disableUpdater YES \
        -ApplePersistenceIgnoreState YES \
        -settings.general.diagnosticLogging YES \
        -settings.edit.indentStyle spaces -settings.edit.indentWidth 2 \
        -settings.edit.continueLists YES -settings.edit.autoCloseBrackets YES \
        >/dev/null 2>&1 &
    pid=$!
    status=""
    for _ in $(seq 1 $((timeout * 4))); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; status="timeout after ${timeout}s (missing 'done'?)"
    else
        wait "$pid"; code=$?
        case $code in
            0) ;;
            1) status="assertion failed" ;;
            *) status="exit $code (crash? DEBUG invariant assertions abort the app)" ;;
        esac
    fi
    expect="$(sed -n 's/^# expect-failures: *//p' "$script" | head -1)"
    if [ -n "$expect" ] && [ "$status" = "assertion failed" ] \
       && grep -q "repro DONE .* fail=$expect\$" "$script.log"; then
        status=""   # a self-check that failed exactly as designed
    elif [ -n "$expect" ] && [ -z "$status" ]; then
        status="expected $expect failures, got none"
    fi
    if [ -z "$status" ] && grep -q "repro DONE" "$script.log" 2>/dev/null; then
        echo "PASS  $name  ($(grep -c ' PASS ' "$script.log") checks)"
        pass=$((pass + 1))
    else
        echo "FAIL  $name  (${status:-no DONE line})"
        grep -E " FAIL |repro DONE|repro source" "$script.log" 2>/dev/null | sed 's/^/        /'
        fail=$((fail + 1)); failed+=("$name")
    fi
done

echo ""
echo "== $pass passed, $fail failed  (logs: $RUN/*.repro.log)"
[ "$fail" -eq 0 ]
