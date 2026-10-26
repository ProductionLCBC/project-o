#!/usr/bin/env bash
# Project O — golden-image tests for anything that renders (CLAUDE.md, the loop).
#
# Usage: scripts/golden.sh            # compare renders against the stored goldens
#        scripts/golden.sh --update   # regenerate goldens after an intended render change
#
# Golden images are produced by the headless engine harness (software clock,
# capturing sink) and compared per pixel within a stated tolerance. Not
# implemented until the engine spike exists.
set -euo pipefail

echo "golden.sh: not implemented yet. The headless harness arrives with the engine spike (docs/specs/4-render-pipeline.md §15)." >&2
exit 1
