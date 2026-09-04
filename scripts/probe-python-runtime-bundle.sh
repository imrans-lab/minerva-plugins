#!/usr/bin/env bash
#
# scripts/probe-python-runtime-bundle.sh
#
# Import-probe a runtime bundle STAGE built by build-python-runtime-bundle.sh:
# run the lock file's LAYER1_IMPORTS plus one import per worker package inside
# the staged interpreter, with the host environment wiped.
#
# Usage:
#   scripts/probe-python-runtime-bundle.sh <plugin-dir> <target-triple>
#
# Env:
#   RUNTIME_PROBE_PREFIX  command prefix used to launch the interpreter, e.g.
#                         "arch -x86_64" to run an x86_64 stage on an arm64
#                         mac under Rosetta. Empty for a native probe.
#
# WHY THIS IS ITS OWN SCRIPT. The build script can only probe a bundle whose
# interpreter the build machine can execute, so a CROSS-installed stage — the
# macos-amd64 half of the universal build being the one that ships — was never
# imported by anything before the release. A stage that resolved no wheel for
# the foreign platform, or resolved a wheel for the wrong architecture, packs
# and ships exactly like a good one. Pulling the probe out lets CI aim it at a
# cross stage through a translator, using the SAME import list the build used,
# so the two cannot drift.
#
# It is plugin-agnostic: everything it imports comes from the lock file.

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Usage: $0 <plugin-dir> <target-triple>" >&2
  exit 64
fi

PLUGIN_DIR_INPUT="$1"
TRIPLE="$2"

if [ ! -d "$PLUGIN_DIR_INPUT" ]; then
  echo "plugin dir not found: $PLUGIN_DIR_INPUT" >&2
  exit 65
fi
PLUGIN_DIR="$(cd "$PLUGIN_DIR_INPUT" && pwd)"

LOCK="$PLUGIN_DIR/scripts/runtime-bundle.lock"
if [ ! -f "$LOCK" ]; then
  echo "missing lock file: $LOCK" >&2
  exit 65
fi
# shellcheck disable=SC1090
. "$LOCK"
: "${LAYER1_IMPORTS:=}"
: "${WORKER_PACKAGES:=}"
: "${RUNTIME_PROBE_PREFIX:=}"

STAGE_DIR="$PLUGIN_DIR/runtime-build/runtime-stage/$TRIPLE"
if [ ! -d "$STAGE_DIR" ]; then
  echo "no runtime stage for $TRIPLE at $STAGE_DIR — build it first" >&2
  exit 66
fi

if [ "$TRIPLE" = "windows-x86_64" ]; then
  PYTHON_BIN="python.exe"
else
  PYTHON_BIN="bin/python3"
fi

# Start from LAYER1_IMPORTS only if the lock declared any — a stdlib-only
# worker (empty LAYER1_IMPORTS) must NOT produce a leading ';', a Python
# SyntaxError. The worker-package probe below is the real check there.
IMPORTS=""
if [ -n "$LAYER1_IMPORTS" ]; then
  IMPORTS="${LAYER1_IMPORTS};"
fi
# shellcheck disable=SC2086
for pkg in $WORKER_PACKAGES; do
  IMPORTS="${IMPORTS} import $pkg;"
done
IMPORTS="${IMPORTS} print('runtime bundle import probe OK')"
# Trim leading whitespace: with an empty LAYER1_IMPORTS the first append leaves
# a leading space, which Python rejects as an IndentationError.
IMPORTS="$(printf '%s' "$IMPORTS" | sed 's/^[[:space:]]*//')"

echo "[$TRIPLE] import probe${RUNTIME_PROBE_PREFIX:+ (via $RUNTIME_PROBE_PREFIX)}: $IMPORTS"

# env -i wipes the host env so the bundle's python sees only what we hand it —
# a probe that passed because the BUILD MACHINE had a package installed would
# certify nothing about the bundle.
if [ "$TRIPLE" = "windows-x86_64" ]; then
  # parso (transitive via build123d -> IPython -> jedi) reads LOCALAPPDATA and
  # USERPROFILE at import time to build its cache path; with either missing it
  # falls back to Path('~') and expanduser raises "Could not determine home
  # directory". So Windows needs the whole home-dir set passed through.
  if [ -z "${USERPROFILE:-}" ] && [ -n "${HOME:-}" ] && command -v cygpath >/dev/null 2>&1; then
    USERPROFILE="$(cygpath -w "$HOME")"
  fi
  : "${USERPROFILE:=C:\\Users\\runneradmin}"
  : "${LOCALAPPDATA:=${USERPROFILE}\\AppData\\Local}"
  : "${HOMEDRIVE:=${USERPROFILE%%:*}:}"
  : "${HOMEPATH:=${USERPROFILE#${HOMEDRIVE}}}"
  # shellcheck disable=SC2086
  env -i \
    HOME="${HOME:-}" \
    PATH="${PATH:-/usr/bin:/bin}" \
    USERPROFILE="$USERPROFILE" \
    LOCALAPPDATA="$LOCALAPPDATA" \
    HOMEDRIVE="$HOMEDRIVE" \
    HOMEPATH="$HOMEPATH" \
    APPDATA="${APPDATA:-}" \
    TEMP="${TEMP:-}" \
    TMP="${TMP:-}" \
    PYTHONHOME="$STAGE_DIR" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    $RUNTIME_PROBE_PREFIX "$STAGE_DIR/$PYTHON_BIN" -c "$IMPORTS"
else
  # shellcheck disable=SC2086
  env -i \
    HOME="${HOME:-}" \
    PATH="/usr/bin:/bin" \
    PYTHONHOME="$STAGE_DIR" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    $RUNTIME_PROBE_PREFIX "$STAGE_DIR/$PYTHON_BIN" -c "$IMPORTS"
fi
