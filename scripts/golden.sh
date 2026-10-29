#!/usr/bin/env bash
# Project O — golden-image tests for anything that renders (CLAUDE.md, the loop).
#
# Usage: scripts/golden.sh            # compare renders against the stored goldens
#        scripts/golden.sh --update   # regenerate goldens after an intended render change
#
# Golden images are produced by the headless engine harness (software clock,
# capturing sink) on a Metal device and compared per pixel within a stated
# tolerance (Spec 4 §16). The goldens live under tests/goldens/; a mismatch
# writes <name>.golden-diff.png and <name>.actual.png beside the golden, both
# ignored by git.
set -euo pipefail

cd "$(dirname "$0")/.."

update=0
if [[ "${1:-}" == "--update" ]]; then
  update=1
fi

filter='OEngineTests.MetalChannelPassTests|OEngineTests.MetalStackPassTests|OEngineTests.MetalEncodeTests'

if [[ $update -eq 1 ]]; then
  echo "golden.sh: regenerating goldens under tests/goldens/"
  OENGINE_GOLDEN_UPDATE=1 swift test --filter "$filter"
  echo "golden.sh: goldens written; review them, then commit tests/goldens/"
else
  swift test --filter "$filter"
fi
