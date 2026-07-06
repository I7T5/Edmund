#!/usr/bin/env bash
# check-live-instance.sh — report any running `edmd` processes, refuse to kill.
#
# The user's daily-driver Edmund shares the binary name `edmd`. NEVER blanket
# `pkill -x edmd`. Run this first; if it finds an instance you did not start,
# leave it alone and launch your own debug bundle instead (launch-debug.sh
# uses EdmundDbg so `pkill -f EdmundDbg` only ever hits yours).
#
# Exit: 0 = no edmd running; 2 = at least one edmd running (inspect, don't kill).
set -euo pipefail

pids=$(pgrep -x edmd || true)
if [[ -z "$pids" ]]; then
  echo "No running edmd instance."
  exit 0
fi

echo "Found running edmd instance(s) — DO NOT pkill -x edmd:"
for pid in $pids; do
  ps -o pid=,lstart=,command= -p "$pid"
done
exit 2
