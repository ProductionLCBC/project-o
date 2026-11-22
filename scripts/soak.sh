#!/usr/bin/env bash
# Project O — test-bench soak run (Spec 4 §13 and §15).
#
# Usage: scripts/soak.sh <scenario.json> [--minutes N] [--library <root>] [--machine <root>] [--blackbox <folder>] [--no-audio]
#                         [--no-lan] [--screens display:<uuid>,display:<uuid>] [--capture]
#
# --capture (Spec 4 §15, Area 7): the machine root has an SDI output on the
# bench's card, whose SDI output is cabled to its own input (make one with
# `python3 -I scripts/bench-machine.py make <dest>`); `oengine capture` judges
# every frame the engine stamps, the weave and the clapper's A/V, and its
# failures fail the run.
#
# Builds the engine in release, writes the synthetic spike media if it is not
# there yet, then runs `oengine soak`: the engine on the machine's outputs with
# the scenario sent over OSC, and the Spec 4 §13 thresholds judged at the end
# from the black box (zero dropped or late SDI frames, display re-presents at
# or below the drift rate, GPU p99 under half the tick, zero text-late after the
# first minute, zero audio underruns, zero watchdog recoveries, memory flat
# within 5% after minute ten). Exit 1 on any failure. The default run is the
# three hours of Spec 4 §15; --minutes 1 is the smoke run.
#
# Since Area 19 a display output opens only on the screen its device names
# (Spec 10 §2), and the spike's outputs name none a Mac has, so `oengine soak`
# gives its display outputs this Mac's screens, left to right, or the ones
# --screens names (`oengine devices` lists them). It also holds the engine's
# Mach channel with a client of its own for the whole run, so the previews and
# the channel pictures are in the GPU time it judges (Spec 10 §18), and it
# opens the LAN listener and reads the login keychain unless --no-lan is given.
#
# The engine runs on temporary clones of both roots, never on them in place
# (Spec 8 §9: a launch walks the media and can write the indexes and the
# cache), with libraryMode set to writable in the clone: the spike's index
# names its generated media by fixed ids, and on a writable machine the launch
# walk lands each generated file on its fixed id as a re-export (Spec 8 §4,
# choice M-2), so the cues play it with their defaults. The clones are APFS
# clones, which take no time or space, and are removed when the run ends.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/soak.sh <scenario.json> [--minutes N] [--library <root>] [--machine <root>] [--blackbox <folder>] [--no-audio] [--no-lan] [--screens display:<uuid>,...] [--capture]" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scenario="$1"
shift
library="$root/tests/fixtures/spike/library"
machine="$root/tests/fixtures/spike/machine"
extra=()
capture=0
blackbox=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --library) library="$2"; shift 2 ;;
    --machine) machine="$2"; shift 2 ;;
    --capture) capture=1; shift ;;
    --blackbox) blackbox="$2"; extra+=("$1" "$2"); shift 2 ;;
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

# Spec 8 §9 — the run's own copies of the roots, side by side as library/ and
# machine/, so a relative mediaRoot (the spike's ../library/media) finds the
# clone's media.
work="$(mktemp -d "${TMPDIR:-/tmp}/oengine-soak.XXXXXX")"
cp -cR "$library" "$work/library"
cp -cR "$machine" "$work/machine"
sed -i '' 's/"libraryMode": "readOnlyMasters"/"libraryMode": "writable"/' "$work/machine/machine.json"
echo "soak.sh: running on clones of the roots in $work, libraryMode writable" >&2

# Spec 4 §15 — with --capture, `oengine capture` reads the card's input (its SDI
# output cabled to it) for the whole run and the engine stamps every SDI frame;
# the capture starts first, is stopped with Ctrl-C once the soak has ended, and
# its verdict joins the soak's. Its record goes into the black box folder.
capture_pid=""
if [[ $capture == 1 ]]; then
  if [[ -z "$blackbox" ]]; then
    blackbox="$root/tests/soak-output/$(date +%Y-%m-%d-%H%M%S)"
    extra+=(--blackbox "$blackbox")
  fi
  mkdir -p "$blackbox"
  read -r sdi_device sdi_format < <(python3 -I "$root/scripts/bench-machine.py" sdi "$work/machine")
  echo "soak.sh: capturing $sdi_device in $sdi_format into $blackbox/capture" >&2
  "$oengine" capture --device "$sdi_device" --format "$sdi_format" --out "$blackbox/capture" > "$blackbox/capture.log" 2>&1 &
  capture_pid=$!
  extra+=(--stamp-sdi)
  sleep 3
fi

set +e
"$oengine" soak --library "$work/library" --machine "$work/machine" --scenario "$scenario" "${extra[@]+"${extra[@]}"}"
status=$?
if [[ -n "$capture_pid" ]]; then
  sleep 2
  kill -INT "$capture_pid"
  wait "$capture_pid"
  capture_status=$?
  cat "$blackbox/capture.log"
  if [[ $capture_status != 0 ]]; then status=1; fi
fi
set -e
rm -rf "$work"
exit "$status"
