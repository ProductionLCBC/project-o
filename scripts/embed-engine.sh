#!/bin/sh
# Spec 10 §2 — "The app is `Project O.app`; the engine is `oengine`, inside it
# at `Contents/Helpers/oengine`, built from the same commit."
#
# Run by the app target's "Embed the engine" build phase
# (app/ProjectO.xcodeproj), after the app's own executable is in place and
# before Xcode signs the bundle. It builds the engine with the package's own
# build, the one `swift test` and `scripts/soak.sh` use, and never through
# Xcode: the engine's shaders come from the package's Metal plugin, and the
# engine that ships is then the engine that was tested.
#
#   Contents/Helpers/oengine                    the engine, signed ad hoc (ADR 0007)
#   Contents/Resources/ProjectO_OEngine.bundle  its shaders and fonts
#   Contents/Helpers/ProjectO_OEngine.bundle    a link to them: the engine looks
#                                               beside itself, and a folder with a
#                                               dot in its name can't live among
#                                               code, where signing takes it for
#                                               a bundle of code
#
# OENGINE_CONFIGURATION  release (the default) or debug
# OENGINE_SCRATCH        the package build folder (the default: .build at the root)
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${OENGINE_CONFIGURATION:-release}"
SCRATCH="${OENGINE_SCRATCH:-$ROOT/.build}"

if [ -z "${BUILT_PRODUCTS_DIR:-}" ] || [ -z "${CONTENTS_FOLDER_PATH:-}" ]; then
    echo "embed-engine.sh: run from the app target's build phase (BUILT_PRODUCTS_DIR and CONTENTS_FOLDER_PATH unset)" >&2
    exit 2
fi
CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"

# Xcode's environment (its SDK, toolchain and module-cache settings) is for
# the app's own build and breaks a package build started inside it, so the
# engine is built with the user's environment and nothing else.
DEVELOPER="${DEVELOPER_DIR:-$(xcode-select -p)}"
build() {
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="${TMPDIR:-/tmp}" DEVELOPER_DIR="$DEVELOPER" \
        swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIGURATION" --product oengine "$@"
}

echo "embed-engine.sh: building oengine ($CONFIGURATION) in $SCRATCH"
build
BIN="$(build --show-bin-path)"

if [ ! -x "$BIN/oengine" ]; then
    echo "embed-engine.sh: no oengine at $BIN" >&2
    exit 1
fi
if [ ! -d "$BIN/ProjectO_OEngine.bundle" ]; then
    echo "embed-engine.sh: no ProjectO_OEngine.bundle at $BIN (the engine's shaders and fonts)" >&2
    exit 1
fi

mkdir -p "$CONTENTS/Helpers" "$CONTENTS/Resources"
cp -f "$BIN/oengine" "$CONTENTS/Helpers/oengine"
rm -rf "$CONTENTS/Resources/ProjectO_OEngine.bundle"
cp -R "$BIN/ProjectO_OEngine.bundle" "$CONTENTS/Resources/ProjectO_OEngine.bundle"
rm -rf "$CONTENTS/Helpers/ProjectO_OEngine.bundle"
ln -s "../Resources/ProjectO_OEngine.bundle" "$CONTENTS/Helpers/ProjectO_OEngine.bundle"

# ADR 0007 — ad hoc signing. The helper is signed here, under a name of its
# own, so the app's signature, which Xcode makes last, finds it signed.
codesign --force --sign - --identifier org.lcbc.projecto.engine "$CONTENTS/Helpers/oengine"
echo "embed-engine.sh: embedded $(basename "$BIN")/oengine and its resources in $CONTENTS"
