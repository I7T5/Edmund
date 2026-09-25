#!/usr/bin/env bash
# grep-trace.sh [YYYY-MM-DD] — surface the suspect patterns in today's (or a
# given day's) Edmund diagnostic log. Read-only.
#
# Requires the app to have run with:
#   -settings.general.diagnosticLogging YES -settings.advanced.verboseEditorDiagnostics YES
set -euo pipefail

day="${1:-$(date +%F)}"
# Log.defaultDirectory: the sandboxed app writes inside its container, a
# debug build (unsandboxed) writes the real folder. Take whichever has the day.
log=""
for dir in "$HOME/Library/Containers/com.i7t5.edmund/Data/Library/Application Support/Edmund/Logs" \
           "$HOME/Library/Application Support/Edmund/Logs"; do
  [[ -f "$dir/edmund-${day}.log" ]] && { log="$dir/edmund-${day}.log"; break; }
done

if [[ -z "$log" ]]; then
  echo "No log for ${day} in the container or ~/Library/Application Support/Edmund/Logs" >&2
  exit 1
fi

echo "== $log =="
echo "--- bypassed-didChangeText heals ---"
grep -n 'healing storage edit that bypassed didChangeText' "$log" || echo "(none)"
echo "--- content-above-origin repairs ---"
grep -n 'repairing content above origin' "$log" || echo "(none)"
echo "--- persistent length mismatches ---"
grep -n 'LEN-MISMATCH' "$log" || echo "(none)"
echo "--- repro asserts ---"
grep -n 'repro assertcaret' "$log" || echo "(none)"
echo "--- FAILs ---"
grep -n 'FAIL' "$log" || echo "(none)"
