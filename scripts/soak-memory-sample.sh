#!/usr/bin/env bash
# Project O — memory attribution run (Spec 4 §13: "memory in use (heaps, decoder
# pools, caches)" per minute; "memory flat to within 5% after the first ten minutes").
#
# Usage: scripts/soak-memory-sample.sh [--minutes N] [--at "5 10 20 30"] [--out <folder>]
#                                      [--leaks] [--scenario <file>] [soak.sh args…]
#        scripts/soak-memory-sample.sh --report <folder>
#
# Runs one soak through scripts/soak.sh and, at each listed minute, samples the
# engine process with Apple's `footprint` (dirty memory by category: IOSurface,
# Metal, MALLOC, CoreGraphics image data, …) and `vmmap -summary` (regions by
# type and the malloc zones) into <folder>. When the run ends it writes
# report.txt: every footprint category at every sample, largest growth first,
# the malloc zones' live bytes against their dirty bytes, and the black box's
# own minute totals, so the growth after minute ten has a name before anything
# in the engine is touched. `--report` rebuilds that report from a finished folder.
#
# Like any soak this takes the machine's displays and default audio device for
# the whole run: run it only in a window set aside for it. Each sample suspends
# the process for some milliseconds, which may show as a watchdog event or a
# re-present in that minute; `--leaks` runs `leaks` at the last sample too,
# which suspends it for seconds. The run is for attribution, not the §13 verdict.
#
# Defaults: 35 minutes, samples at minutes 5, 10, 20 and 30, output under
# tests/soak-output/memory-<timestamp>/ (footprint-<minute>.txt,
# vmmap-<minute>.txt, soak.log, blackbox/, report.txt).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
minutes=35
at="5 10 20 30"
out=""
leaks=0
report_only=""
scenario="$root/tests/soak/spike.json"
extra=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --minutes) minutes="$2"; shift 2 ;;
    --at) at="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --leaks) leaks=1; shift ;;
    --scenario) scenario="$2"; shift 2 ;;
    --report) report_only="$2"; shift 2 ;;
    *) extra+=("$1"); shift ;;
  esac
done

# The sample minutes a folder holds, in order.
sampled_minutes() {
  ls "$1" | sed -n 's/^footprint-\([0-9]*\)\.txt$/\1/p' | sort -n
}

# The report. footprint prints "<dirty> <unit> <clean> <unit> <reclaimable>
# <unit> <regions> <category…>" per line, units B, KB, MB, GB; vmmap -summary
# prints a MALLOC ZONE table whose columns are virtual, resident, dirty,
# swapped, allocation count, bytes allocated, fragmentation and region count.
write_report() {
  local folder="$1" m files=() header
  local -a samples=()
  for m in $(sampled_minutes "$folder"); do
    [[ -s "$folder/footprint-$m.txt" ]] || continue
    samples+=("$m")
    files+=("$folder/footprint-$m.txt")
  done
  {
    echo "memory attribution: $folder"
    grep -h -E '^(PASS|FAIL)' "$folder/soak.log" 2>/dev/null || true
    echo
    echo "black box, resident MB per minute record:"
    if ls "$folder"/blackbox/blackbox-*.jsonl >/dev/null 2>&1; then
      cat "$folder"/blackbox/blackbox-*.jsonl | grep '"kind":"minute"' \
        | sed -E 's/.*"memoryBytes":([0-9]+),.*"minute":([0-9]+),.*/\2 \1/' \
        | awk '{ printf "  minute %3d: %5.0f MB\n", $1, $2 / 1048576 }' || true
    else
      echo "  (no minute records in $folder/blackbox)"
    fi
    echo
    echo "footprint samples:"
    for m in ${samples[@]+"${samples[@]}"}; do
      echo "  minute $m: $(sed -n 's/.*Footprint: //p' "$folder/footprint-$m.txt" | head -1)"
    done
    echo
    if (( ${#samples[@]} >= 2 )); then
      echo "footprint, dirty MB by category at each sample, largest growth first:"
      header="$(printf '  %9s' growth)"
      for m in "${samples[@]}"; do header="$header$(printf ' %9s' "min $m")"; done
      echo "$header  category"
      awk '
        function bytes(v, u) { if (u == "KB") return v * 1024; if (u == "MB") return v * 1048576; if (u == "GB") return v * 1073741824; return v }
        FNR == 1 { n++ }
        $2 ~ /^(B|KB|MB|GB)$/ && $4 ~ /^(B|KB|MB|GB)$/ && $6 ~ /^(B|KB|MB|GB)$/ && $7 ~ /^[0-9]+$/ {
          cat = $8; for (i = 9; i <= NF; i++) cat = cat " " $i
          seen[cat] = 1
          v[n, cat] = bytes($1, $2)
        }
        END {
          for (cat in seen) {
            line = sprintf("%.1f", (v[n, cat] - v[1, cat]) / 1048576)
            for (i = 1; i <= n; i++) line = line "\t" sprintf("%.1f", v[i, cat] / 1048576)
            print line "\t" cat
          }
        }' "${files[@]}" \
        | sort -t $'\t' -k1,1 -g -r \
        | awk -F '\t' '{ printf "  %+9.1f", $1; for (i = 2; i < NF; i++) printf " %9.1f", $i; printf "  %s\n", $NF }'
      echo
    else
      echo "(fewer than two footprint samples; nothing to compare)"
      echo
    fi
    echo "malloc zones (vmmap): dirty against bytes allocated; dirty rising with allocated flat is fragmentation, not growth:"
    for m in ${samples[@]+"${samples[@]}"}; do
      [[ -s "$folder/vmmap-$m.txt" ]] || continue
      awk -v m="$m" '
        /^MALLOC ZONE/ { inzone = 1; next }
        inzone && /^=/ { next }
        inzone && NF == 0 { inzone = 0 }
        inzone && NF >= 9 { printf "  minute %3s  %-36s dirty %8s  allocated %8s  fragmentation %5s\n", m, $1, $4, $7, $9 }' "$folder/vmmap-$m.txt"
    done
    echo
    echo "reading: IOSurface is decoder pools and drawables; Metal (IOAccelerator) is textures and heaps;"
    echo "MALLOC_* is the process heap, where CoreText, CoreGraphics and AVFoundation caches also live;"
    echo "CoreGraphics image data and ColorSync are the system's image caches. A category that keeps"
    echo "growing sample to sample at a steady rate is a leak; one that flattens is a cache filling."
  } > "$folder/report.txt"
  cat "$folder/report.txt"
}

if [[ -n "$report_only" ]]; then
  write_report "$report_only"
  exit 0
fi

for tool in footprint vmmap; do
  command -v "$tool" >/dev/null 2>&1 || { echo "soak-memory-sample.sh: $tool not found; it ships with Xcode's command line tools" >&2; exit 2; }
done

stamp="$(date +%Y-%m-%d-%H%M%S)"
out="${out:-$root/tests/soak-output/memory-$stamp}"
mkdir -p "$out"

# Build before the clock starts, so minute 5 is five minutes of engine, not of compiler.
(cd "$root" && swift build -c release --product oengine)

echo "soak-memory-sample.sh: $minutes minutes, samples at minute(s) $at; files in $out" >&2
"$root/scripts/soak.sh" "$scenario" --minutes "$minutes" --blackbox "$out/blackbox" ${extra[@]+"${extra[@]}"} > "$out/soak.log" 2>&1 &
soak=$!
started="$(date +%s)"

# soak.sh execs oengine, so the job's pid becomes the engine's once its build step is over.
sample() {
  local tag="$1" comm
  kill -0 "$soak" 2>/dev/null || return 1
  comm="$(ps -o comm= -p "$soak" 2>/dev/null || true)"
  if [[ "$comm" != *oengine* ]]; then
    echo "soak-memory-sample.sh: minute $tag: process $soak is '$comm', not oengine; sample skipped" >&2
    return 0
  fi
  footprint "$soak" > "$out/footprint-$tag.txt" 2>&1 || true
  vmmap -summary "$soak" > "$out/vmmap-$tag.txt" 2>&1 || true
  echo "soak-memory-sample.sh: minute $tag: footprint $(sed -n 's/.*Footprint: //p' "$out/footprint-$tag.txt" | head -1)" >&2
}

last=""
for m in $at; do
  target=$(( started + m * 60 ))
  while (( $(date +%s) < target )); do
    kill -0 "$soak" 2>/dev/null || break 2
    sleep 5
  done
  sample "$m" || break
  last="$m"
done
if (( leaks )) && [[ -n "$last" ]] && kill -0 "$soak" 2>/dev/null; then
  leaks "$soak" > "$out/leaks-$last.txt" 2>&1 || true
  echo "soak-memory-sample.sh: minute $last: $(grep -m1 'leaks for' "$out/leaks-$last.txt" || echo 'leaks wrote no summary')" >&2
fi
wait "$soak" || true
tail -3 "$out/soak.log" >&2 || true
write_report "$out"
