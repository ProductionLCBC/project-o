#!/usr/bin/env bash
# Project O — test-bench soak run (Spec 4 §13 and §15).
#
# Usage: scripts/soak.sh <scenario.json> [--minutes N] [--library <root>] [--machine <root>] [--blackbox <folder>] [--no-audio]
#
# Builds the engine in release, writes the synthetic spike media if it is not
# there yet, then runs `oengine soak`: the engine on the machine's outputs with
# the scenario sent over OSC, and the Spec 4 §13 thresholds judged at the end
# from the black box (zero dropped or late SDI frames, display re-presents at
# or below the drift rate, GPU p99 under half the tick, zero text-late after the
# first minute, zero audio underruns, zero watchdog recoveries, memory flat
# within 5% after minute ten). Exit 1 on any failure. The default run is the
# three hours of Spec 4 §15; --minutes 1 is the smoke run.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/soak.sh <scenario.json> [--minutes N] [--library <root>] [--machine <root>] [--blackbox <folder>] [--no-audio]" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="$1"
shift
library="$root/tests/fixtures/spike/library"
machine="$root/tests/fixtures/spike/machine"
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --library) library="$2"; shift 2 ;;
    --machine) machine="$2"; shift 2 ;;
    *) extra+=("$1"); shift ;;
  esac
done

cd "$root"
swift build -c release --product oengine
oengine="$(swift build -c release --show-bin-path)/oengine"

if [[ ! -f "$library/media/clapper/clapper.mov" ]]; then
  echo "soak.sh: writing the spike media into $library/media" >&2
  "$oengine" make-fixtures "$library/media"
fi

exec "$oengine" soak --library "$library" --machine "$machine" --scenario "$scenario" "${extra[@]}"
