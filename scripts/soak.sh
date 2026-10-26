#!/usr/bin/env bash
# Project O — test-bench soak run (Spec 4 §13 and §15).
#
# Usage: scripts/soak.sh <scenario>
#
# Runs a soak scenario on the bench Mac against real outputs, captures both
# outputs, and fails the build on any dropped or late frame, text-late event,
# audio underrun, watchdog recovery, or memory growth beyond 5% after the
# first ten minutes. Not implemented until the engine spike exists.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: scripts/soak.sh <scenario>" >&2
  exit 2
fi

echo "soak.sh: not implemented yet. The soak rig arrives with the engine spike (docs/specs/4-render-pipeline.md §15)." >&2
exit 1
