#!/usr/bin/env bash
# Project O — first-run check for a development Mac.
# Verifies the toolchain, then builds and tests the package. Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")/.."

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=1; }
FAILED=0

echo "Toolchain"
if [[ "$(uname)" != "Darwin" ]]; then
  warn "not macOS: only OCore will build here (that is fine for CI and for the projection work)"
fi

if command -v xcode-select >/dev/null 2>&1 && xcode-select -p >/dev/null 2>&1; then
  dev_dir="$(xcode-select -p)"
  if [[ "$dev_dir" == *"/Xcode"*".app/"* ]]; then
    ok "Xcode at $dev_dir"
  else
    warn "command-line tools only ($dev_dir). Enough for OCore; install Xcode from the App Store before OEngine (Metal shaders need it), then: sudo xcode-select -s /Applications/Xcode.app"
  fi
elif [[ "$(uname)" == "Darwin" ]]; then
  fail "no Xcode or command-line tools. Install Xcode from the App Store, open it once, then re-run."
fi

if command -v swift >/dev/null 2>&1; then
  ok "$(swift --version 2>&1 | head -n 1)"
else
  fail "swift not found on PATH"
fi

if command -v git >/dev/null 2>&1; then
  ok "$(git --version)"
else
  fail "git not found"
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "GitHub CLI signed in"
  else
    warn "GitHub CLI installed but not signed in: gh auth login"
  fi
else
  warn "GitHub CLI not installed (brew install gh). Needed only to create the remote and open PRs from the terminal."
fi

if [[ -d .git ]]; then
  ok "git repository ($(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no commits yet'))"
else
  warn "not a git repository yet: git init -b main && git add -A && git commit -m 'Initial commit'"
fi

if [[ -d vendor/DeckLinkSDK ]]; then
  ok "DeckLink SDK present in vendor/DeckLinkSDK"
else
  warn "DeckLink SDK not present (vendor/README.md). Not needed until the engine spike."
fi

if [[ $FAILED -ne 0 ]]; then
  echo
  echo "Fix the items marked ✗ and re-run."
  exit 1
fi

echo
echo "Build"
swift build
echo
echo "Test"
swift test
echo
ok "ready. Next: read CLAUDE.md, then open this folder in a Claude Code session."
