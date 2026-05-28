#!/usr/bin/env bash
#
# scripts/build-python-runtime-bundle.sh
#
# Build a portable Python runtime bundle (tar.zst) for a Minerva plugin.
#
# Usage:
#   scripts/build-python-runtime-bundle.sh <plugin-dir> <target-triple>
#
# Targets: linux-x86_64, linux-arm64, macos-arm64, macos-amd64, windows-x86_64
#
# Reads <plugin-dir>/scripts/runtime-bundle.lock for pinned versions and the
# plugin-specific worker package list. This script is PLUGIN-AGNOSTIC — it
# does not know about "cad", "build123d", "cadquery-ocp", or any other
# plugin/library name. Plugin-specific pins live entirely in the lock file.
#
# Filed under DCR 019e6a4bcb0c71019723011d8f8c8cf1 (Plan A: embedded PBS python).
# Scope-amended 2026-05-27 to 5-target matrix (no sentinel pattern).

set -euo pipefail

# --------------------------------------------------------------------------
# arg parse
# --------------------------------------------------------------------------

if [ $# -ne 2 ]; then
  cat <<EOF >&2
Usage: $0 <plugin-dir> <target-triple>

Plugin dir must contain scripts/runtime-bundle.lock and the worker source tree
declared by WORKER_SOURCE_DIR in the lock file.

Targets:
  linux-x86_64   linux-arm64
  macos-arm64    macos-amd64
  windows-x86_64
EOF
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

# Source the lock file (shell-sourceable KEY=VALUE format)
# shellcheck disable=SC1090
. "$LOCK"

# Sanity-check the lock provided the required vars
for v in PBS_TAG CPYTHON PIP_PKGS WORKER_SOURCE_DIR WORKER_PACKAGES BUNDLE_OUT_DIR; do
  if [ -z "${!v:-}" ]; then
    echo "lock file missing required var: $v" >&2
    exit 65
  fi
done

# --------------------------------------------------------------------------
# triple → PBS asset + wheel platform tag + python launcher path
# --------------------------------------------------------------------------

# WHEEL_PLATS is a space-separated list. pip accepts repeated --platform args,
# each adding to the accepted set. We enumerate compatible manylinux/macosx
# variants so wheels tagged with older manylinux baselines (e.g. numpy uses
# manylinux_2_17 / manylinux2014) match alongside the strictest target.
case "$TRIPLE" in
  linux-x86_64)
    PBS_ASSET="x86_64-unknown-linux-gnu"
    WHEEL_PLATS="manylinux_2_31_x86_64 manylinux_2_28_x86_64 manylinux_2_24_x86_64 manylinux_2_17_x86_64 manylinux2014_x86_64 manylinux2010_x86_64 manylinux1_x86_64 linux_x86_64"
    PYTHON_BIN="bin/python3"
    ;;
  linux-arm64)
    PBS_ASSET="aarch64-unknown-linux-gnu"
    WHEEL_PLATS="manylinux_2_31_aarch64 manylinux_2_28_aarch64 manylinux_2_24_aarch64 manylinux_2_17_aarch64 manylinux2014_aarch64 linux_aarch64"
    PYTHON_BIN="bin/python3"
    ;;
  macos-arm64)
    PBS_ASSET="aarch64-apple-darwin"
    WHEEL_PLATS="macosx_15_0_arm64 macosx_14_0_arm64 macosx_13_0_arm64 macosx_12_0_arm64 macosx_11_0_arm64"
    PYTHON_BIN="bin/python3"
    ;;
  macos-amd64)
    PBS_ASSET="x86_64-apple-darwin"
    WHEEL_PLATS="macosx_15_0_x86_64 macosx_14_0_x86_64 macosx_13_0_x86_64 macosx_12_0_x86_64 macosx_11_0_x86_64 macosx_10_15_x86_64 macosx_10_13_x86_64 macosx_10_9_x86_64"
    PYTHON_BIN="bin/python3"
    ;;
  windows-x86_64)
    PBS_ASSET="x86_64-pc-windows-msvc"
    WHEEL_PLATS="win_amd64"
    PYTHON_BIN="python.exe"
    ;;
  *)
    echo "unknown target triple: $TRIPLE" >&2
    exit 64
    ;;
esac

# Detect host triple so we can run Layer 1 self-test only on native bundles.
host_os="$(uname -s | tr '[:upper:]' '[:lower:]')"
host_arch="$(uname -m)"
case "$host_os-$host_arch" in
  darwin-arm64)         HOST_TRIPLE="macos-arm64";;
  darwin-x86_64)        HOST_TRIPLE="macos-amd64";;
  linux-x86_64)         HOST_TRIPLE="linux-x86_64";;
  linux-aarch64)        HOST_TRIPLE="linux-arm64";;
  linux-arm64)          HOST_TRIPLE="linux-arm64";;
  msys*|cygwin*|mingw*) HOST_TRIPLE="windows-x86_64";;
  *)                    HOST_TRIPLE="unknown";;
esac

# --------------------------------------------------------------------------
# paths
# --------------------------------------------------------------------------

BUILD_DIR="$PLUGIN_DIR/runtime-build"          # scratch: PBS cache + extraction stage
CACHE_DIR="$BUILD_DIR/cache/pbs"
STAGE_DIR="$BUILD_DIR/runtime-stage/$TRIPLE"
OUT_DIR="$PLUGIN_DIR/$BUNDLE_OUT_DIR"          # final: must be go:embed-reachable
OUT_TARBALL="$OUT_DIR/runtime-bundle-$TRIPLE.tar.zst"
OUT_TARBALL_SHA="$OUT_DIR/runtime-bundle-$TRIPLE.sha256"

mkdir -p "$CACHE_DIR" "$BUILD_DIR" "$OUT_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

# --------------------------------------------------------------------------
# download PBS (cached)
# --------------------------------------------------------------------------

PBS_FILE="cpython-${CPYTHON}+${PBS_TAG}-${PBS_ASSET}-install_only.tar.gz"
PBS_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${PBS_FILE}"
PBS_CACHED="$CACHE_DIR/$PBS_FILE"

if [ ! -f "$PBS_CACHED" ]; then
  echo "[$TRIPLE] downloading PBS: $PBS_URL"
  curl -fL --retry 3 -o "$PBS_CACHED.tmp" "$PBS_URL"
  mv "$PBS_CACHED.tmp" "$PBS_CACHED"
else
  echo "[$TRIPLE] PBS cached: $PBS_CACHED"
fi

# --------------------------------------------------------------------------
# extract PBS (strip 'python/' prefix so bundle layout matches design §6)
# --------------------------------------------------------------------------

echo "[$TRIPLE] extracting PBS to $STAGE_DIR"
tar -xzf "$PBS_CACHED" -C "$STAGE_DIR" --strip-components=1

# --------------------------------------------------------------------------
# determine the site-packages location inside the bundle
# --------------------------------------------------------------------------

PY_MAJOR_MINOR="$(echo "$CPYTHON" | cut -d. -f1,2)"
if [ "$TRIPLE" = "windows-x86_64" ]; then
  SITE_PACKAGES="$STAGE_DIR/Lib/site-packages"
else
  SITE_PACKAGES="$STAGE_DIR/lib/python${PY_MAJOR_MINOR}/site-packages"
fi
mkdir -p "$SITE_PACKAGES"

# --------------------------------------------------------------------------
# build dep list from lock var (plugin-agnostic: PIP_PKGS is the only source)
# --------------------------------------------------------------------------

# shellcheck disable=SC2206
DEPS=( $PIP_PKGS )

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "[$TRIPLE] WARNING: PIP_PKGS empty in lock file (only worker source will be bundled)" >&2
fi

# --------------------------------------------------------------------------
# pip install — native uses bundle's python; cross uses host python + --platform
# --------------------------------------------------------------------------

if [ "$TRIPLE" = "$HOST_TRIPLE" ]; then
  echo "[$TRIPLE] native build: pip install via bundled python"
  # Windows pip needs USERPROFILE (native Windows python checks it first)
  # for pathlib.Path.expanduser() during metadata bookkeeping. Git Bash may
  # provide HOME but not USERPROFILE in the form the native Windows binary
  # recognizes. Set defensively from cygpath(HOME) if needed.
  if [ "$TRIPLE" = "windows-x86_64" ]; then
    if [ -z "${USERPROFILE:-}" ] && [ -n "${HOME:-}" ]; then
      if command -v cygpath >/dev/null 2>&1; then
        export USERPROFILE="$(cygpath -w "$HOME")"
      fi
    fi
    if [ -z "${USERPROFILE:-}" ] && [ -n "${LOCALAPPDATA:-}" ]; then
      # LOCALAPPDATA is typically C:\Users\<user>\AppData\Local; user profile is one dir up.
      export USERPROFILE="$(dirname "$(dirname "$LOCALAPPDATA")")"
    fi
    echo "  USERPROFILE=${USERPROFILE:-<unset>} HOME=${HOME:-<unset>}"
  fi
  if [ ${#DEPS[@]} -gt 0 ]; then
    "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input "${DEPS[@]}"
  fi
else
  echo "[$TRIPLE] cross build: pip install via host python with --platform=$WHEEL_PLATS"
  # Find a host python3 (prefer 3.12 to match cpython version pin)
  HOST_PY="$(command -v "python${PY_MAJOR_MINOR}" || command -v python3 || true)"
  if [ -z "$HOST_PY" ]; then
    echo "no host python3 available for cross-build" >&2
    exit 70
  fi
  ABI="cp$(echo "$PY_MAJOR_MINOR" | tr -d '.')"
  # Build repeated --platform args from WHEEL_PLATS
  PLAT_ARGS=()
  for plat in $WHEEL_PLATS; do
    PLAT_ARGS+=( --platform "$plat" )
  done
  if [ ${#DEPS[@]} -gt 0 ]; then
    "$HOST_PY" -m pip install --no-cache-dir --no-input \
      --target "$SITE_PACKAGES" \
      "${PLAT_ARGS[@]}" \
      --python-version "$PY_MAJOR_MINOR" \
      --abi "$ABI" \
      --only-binary=:all: \
      "${DEPS[@]}"
  fi
fi

# --------------------------------------------------------------------------
# copy plugin's worker packages into site-packages
# --------------------------------------------------------------------------

WORKER_DIR="$PLUGIN_DIR/${WORKER_SOURCE_DIR}"
if [ ! -d "$WORKER_DIR" ]; then
  echo "missing worker source dir: $WORKER_DIR" >&2
  exit 71
fi

# shellcheck disable=SC2086
for pkg in $WORKER_PACKAGES; do
  src="$WORKER_DIR/$pkg"
  if [ ! -d "$src" ]; then
    echo "missing worker package: $src" >&2
    exit 71
  fi
  echo "[$TRIPLE] copying worker package: $pkg"
  rm -rf "${SITE_PACKAGES:?}/$pkg"
  cp -r "$src" "$SITE_PACKAGES/$pkg"
done

# --------------------------------------------------------------------------
# strip __pycache__ (regenerates on first import; saves space + cleans paths)
# --------------------------------------------------------------------------

find "$STAGE_DIR" -type d -name __pycache__ -prune -exec rm -rf {} +
find "$STAGE_DIR" -type f -name '*.pyc' -delete

# --------------------------------------------------------------------------
# Layer 1 self-test — only on native target (cross can't run foreign binary)
# --------------------------------------------------------------------------

if [ "$TRIPLE" = "$HOST_TRIPLE" ]; then
  echo "[$TRIPLE] Layer 1 self-test: bundle imports under isolated env"
  # Plugin-agnostic: lock file declares LAYER1_IMPORTS (semicolon-separated
  # python statements). Each WORKER_PACKAGES entry is also import-probed so
  # missing worker source is caught here, not at first MCP call.
  IMPORTS="${LAYER1_IMPORTS:-};"
  # shellcheck disable=SC2086
  for pkg in $WORKER_PACKAGES; do
    IMPORTS="${IMPORTS} import $pkg;"
  done
  IMPORTS="${IMPORTS} print('Layer 1 OK')"

  env -i \
    HOME="$HOME" \
    PATH="/usr/bin:/bin" \
    PYTHONHOME="$STAGE_DIR" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    "$STAGE_DIR/$PYTHON_BIN" -c "$IMPORTS"
else
  echo "[$TRIPLE] cross-target: Layer 1 self-test skipped (verified at CI on native runner)"
fi

# --------------------------------------------------------------------------
# manifest.sha256 — per-file checksums for post-extract tampering detection
# --------------------------------------------------------------------------

echo "[$TRIPLE] generating manifest.sha256"
if command -v sha256sum >/dev/null 2>&1; then
  HASHER="sha256sum"
else
  HASHER="shasum -a 256"
fi
(
  cd "$STAGE_DIR" && \
  find . -type f ! -name manifest.sha256 -print | sort \
    | xargs -I{} $HASHER {} \
    | sed 's| \./| |' \
    > manifest.sha256
)

# --------------------------------------------------------------------------
# tarball — portable sort (find|sort|tar -T -) for byte-reproducibility
# across BSD tar (macOS) and GNU tar (Linux)
# --------------------------------------------------------------------------

echo "[$TRIPLE] packing tarball with zstd -19"
(
  cd "$STAGE_DIR" && \
  find . \( -type f -o -type l \) -print | sort > /tmp/.bundle-files.$$ && \
  tar -cf - -T /tmp/.bundle-files.$$ && \
  rm -f /tmp/.bundle-files.$$
) | zstd -19 -q -o "$OUT_TARBALL"

# --------------------------------------------------------------------------
# tarball sha256 — used by Go-side EmbeddedSHA256 verification
# --------------------------------------------------------------------------

$HASHER "$OUT_TARBALL" | awk '{print $1}' > "$OUT_TARBALL_SHA"

bundle_size="$(du -h "$OUT_TARBALL" | awk '{print $1}')"
echo "[$TRIPLE] done"
echo "[$TRIPLE]   bundle: $OUT_TARBALL ($bundle_size)"
echo "[$TRIPLE]   sha256: $(cat "$OUT_TARBALL_SHA")"
