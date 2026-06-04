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

# Sanity-check the lock provided the required vars. PIP_PKGS and LAYER1_IMPORTS
# are intentionally NOT required: a plugin whose worker needs only the Python
# stdlib (e.g. codetools' P1.1 substrate skeleton) declares an empty PIP_PKGS.
# The empty-DEPS path below handles that and the worker-package import probe
# still runs. Default them so `set -u` references stay safe.
for v in PBS_TAG CPYTHON WORKER_SOURCE_DIR WORKER_PACKAGES BUNDLE_OUT_DIR; do
  if [ -z "${!v:-}" ]; then
    echo "lock file missing required var: $v" >&2
    exit 65
  fi
done
: "${PIP_PKGS:=}"
: "${LAYER1_IMPORTS:=}"

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
  if [ "$TRIPLE" = "windows-x86_64" ]; then
    # Bundled PBS python on Windows is a native .exe invoked from Git Bash.
    # Env propagation across that boundary is unreliable for the home-dir
    # variables (USERPROFILE / HOMEDRIVE / HOMEPATH / LOCALAPPDATA). When
    # parso (transitive via build123d → IPython → jedi → parso) imports at
    # ANY time and calls Path('~/...').expanduser(), python's gethomedir
    # raises "Could not determine home directory." We:
    #   1. Resolve sensible defaults from whatever vars Git Bash exposes.
    #   2. Print what the bundled python ACTUALLY sees (debug).
    #   3. Explicitly pass the full set on the pip command line so the
    #      child .exe gets them regardless of bash export propagation quirks.
    if [ -z "${USERPROFILE:-}" ] && [ -n "${HOME:-}" ] && command -v cygpath >/dev/null 2>&1; then
      export USERPROFILE="$(cygpath -w "$HOME")"
    fi
    if [ -z "${USERPROFILE:-}" ] && [ -n "${LOCALAPPDATA:-}" ]; then
      export USERPROFILE="$(dirname "$(dirname "$LOCALAPPDATA")")"
    fi
    # Fallback to the known Windows runner default if nothing else worked.
    : "${USERPROFILE:=C:\\Users\\runneradmin}"
    : "${LOCALAPPDATA:=${USERPROFILE}\\AppData\\Local}"
    : "${HOMEDRIVE:=${USERPROFILE%%:*}:}"
    : "${HOMEPATH:=${USERPROFILE#${HOMEDRIVE}}}"
    export USERPROFILE LOCALAPPDATA HOMEDRIVE HOMEPATH

    echo "  bash sees: USERPROFILE=${USERPROFILE} HOMEDRIVE=${HOMEDRIVE} HOMEPATH=${HOMEPATH} LOCALAPPDATA=${LOCALAPPDATA}"
    echo "  python sees:"
    "$STAGE_DIR/$PYTHON_BIN" -c "import os
for v in ['USERPROFILE','HOMEDRIVE','HOMEPATH','HOME','LOCALAPPDATA','APPDATA','TEMP','TMP']:
    print('    %s=%r' % (v, os.environ.get(v)))
"
  fi
  if [ ${#DEPS[@]} -gt 0 ]; then
    # --no-compile sidesteps the byte-compile pass.
    # PYTHONNOUSERSITE=1 is REQUIRED: without it pip on dev boxes will see deps
    # in ~/.local/lib/python3.12/site-packages (developer-installed) and skip
    # installing them INTO the bundle. The bundle then shipping/extracting to a
    # production user with no user-site triggers ModuleNotFoundError at runtime.
    # For Windows we ALSO force-pass home-dir env on the command line in case
    # bash export isn't propagating those vars to the native python subprocess.
    if [ "$TRIPLE" = "windows-x86_64" ]; then
      PYTHONNOUSERSITE=1 \
      USERPROFILE="${USERPROFILE}" \
      LOCALAPPDATA="${LOCALAPPDATA}" \
      HOMEDRIVE="${HOMEDRIVE}" \
      HOMEPATH="${HOMEPATH}" \
        "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile "${DEPS[@]}"
    else
      PYTHONNOUSERSITE=1 \
        "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile "${DEPS[@]}"
    fi
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
# rg (ripgrep) injection — P2.1 file-primitive tools.
#
# The worker locates rg via rg_finder.py: it looks for <bundle>/bin/rg
# (alongside the bundled python3 interpreter), then falls back to PATH.
#
# Source: pinned prebuilt GitHub release from BurntSushi/ripgrep.
# Version pinned here; update in lockstep with any worker rg_finder.py change.
# We use the musl variant for linux to maximise glibc-version portability.
# The macos universal binary covers both arm64 and amd64.
# Windows uses the MSVC zip.
#
# For cross-target builds (TRIPLE != HOST_TRIPLE) the binary must be fetched
# from the release page for that target. Each triple is handled below.
# If a fetch fails for a non-must-have triple, a warning is emitted and the
# bundle is produced without rg (the worker falls back to Python grep).
# --------------------------------------------------------------------------

RG_VERSION="15.1.0"
RG_CACHE_DIR="$BUILD_DIR/cache/rg"
mkdir -p "$RG_CACHE_DIR"

case "$TRIPLE" in
  linux-x86_64)
    RG_ASSET="ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl.tar.gz"
    RG_BIN_IN_ARCHIVE="ripgrep-${RG_VERSION}-x86_64-unknown-linux-musl/rg"
    RG_MUST_HAVE=true
    ;;
  linux-arm64)
    RG_ASSET="ripgrep-${RG_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
    RG_BIN_IN_ARCHIVE="ripgrep-${RG_VERSION}-aarch64-unknown-linux-gnu/rg"
    RG_MUST_HAVE=false
    ;;
  macos-arm64|macos-amd64)
    # macOS universal binary covers both architectures.
    RG_ASSET="ripgrep-${RG_VERSION}-aarch64-apple-darwin.tar.gz"
    RG_BIN_IN_ARCHIVE="ripgrep-${RG_VERSION}-aarch64-apple-darwin/rg"
    # TODO: use the x86_64 variant for macos-amd64 once we have a CI runner to test.
    RG_MUST_HAVE=false
    ;;
  windows-x86_64)
    RG_ASSET="ripgrep-${RG_VERSION}-x86_64-pc-windows-msvc.zip"
    RG_BIN_IN_ARCHIVE="ripgrep-${RG_VERSION}-x86_64-pc-windows-msvc/rg.exe"
    RG_MUST_HAVE=false
    ;;
  *)
    echo "[$TRIPLE] WARNING: no rg asset mapping for triple $TRIPLE — rg not bundled" >&2
    RG_ASSET=""
    RG_MUST_HAVE=false
    ;;
esac

if [ -n "${RG_ASSET:-}" ]; then
  RG_URL="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${RG_ASSET}"
  RG_CACHED="$RG_CACHE_DIR/$RG_ASSET"
  RG_BIN_NAME="rg"
  [ "$TRIPLE" = "windows-x86_64" ] && RG_BIN_NAME="rg.exe"

  if [ ! -f "$RG_CACHED" ]; then
    echo "[$TRIPLE] downloading rg ${RG_VERSION}: $RG_URL"
    if ! curl -fL --retry 3 -o "$RG_CACHED.tmp" "$RG_URL"; then
      echo "[$TRIPLE] WARNING: failed to download rg from $RG_URL" >&2
      rm -f "$RG_CACHED.tmp"
      RG_CACHED=""
    else
      mv "$RG_CACHED.tmp" "$RG_CACHED"
    fi
  else
    echo "[$TRIPLE] rg cached: $RG_CACHED"
  fi

  if [ -n "$RG_CACHED" ] && [ -f "$RG_CACHED" ]; then
    # Extract just the rg binary into a temp dir, then place it in bundle bin/.
    RG_EXTRACT_DIR="$BUILD_DIR/rg-extract-$TRIPLE"
    rm -rf "$RG_EXTRACT_DIR"
    mkdir -p "$RG_EXTRACT_DIR"
    case "$RG_ASSET" in
      *.tar.gz)
        tar -xzf "$RG_CACHED" -C "$RG_EXTRACT_DIR" --strip-components=1 \
          "$(basename "$RG_BIN_IN_ARCHIVE")" 2>/dev/null || \
          tar -xzf "$RG_CACHED" -C "$RG_EXTRACT_DIR"
        ;;
      *.zip)
        unzip -q "$RG_CACHED" -d "$RG_EXTRACT_DIR" "$(basename "$RG_BIN_IN_ARCHIVE")" 2>/dev/null || \
          unzip -q "$RG_CACHED" -d "$RG_EXTRACT_DIR"
        ;;
    esac
    # Find the rg binary anywhere in the extract dir.
    RG_EXTRACTED="$(find "$RG_EXTRACT_DIR" -name "$RG_BIN_NAME" -type f | head -1)"
    if [ -n "$RG_EXTRACTED" ] && [ -f "$RG_EXTRACTED" ]; then
      chmod +x "$RG_EXTRACTED"
      # PBS's Windows install_only layout puts python.exe at the bundle ROOT
      # (no bin/ dir), unlike linux/macos where python lives in bin/. Ensure the
      # rg destination dir exists or this cp fails with "No such file or
      # directory" on Windows. No-op where bin/ already exists.
      mkdir -p "$STAGE_DIR/bin"
      cp "$RG_EXTRACTED" "$STAGE_DIR/bin/$RG_BIN_NAME"
      echo "[$TRIPLE] rg ${RG_VERSION} injected into bundle: bin/$RG_BIN_NAME"
    else
      echo "[$TRIPLE] WARNING: rg binary not found in extracted archive $RG_ASSET" >&2
      if [ "$RG_MUST_HAVE" = "true" ]; then
        echo "[$TRIPLE] ERROR: rg is required for linux-x86_64 (must-have triple)" >&2
        exit 72
      fi
    fi
  else
    if [ "$RG_MUST_HAVE" = "true" ]; then
      echo "[$TRIPLE] ERROR: rg download failed and it is required for linux-x86_64" >&2
      exit 72
    fi
    echo "[$TRIPLE] WARNING: rg not bundled — grep will use Python fallback at runtime" >&2
  fi
fi

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
  # Start from LAYER1_IMPORTS only if the lock declared any — a stdlib-only
  # worker (empty LAYER1_IMPORTS) must NOT produce a leading ';' which is a
  # Python SyntaxError. The worker-package probe below is the real check there.
  IMPORTS=""
  if [ -n "${LAYER1_IMPORTS:-}" ]; then
    IMPORTS="${LAYER1_IMPORTS};"
  fi
  # shellcheck disable=SC2086
  for pkg in $WORKER_PACKAGES; do
    IMPORTS="${IMPORTS} import $pkg;"
  done
  IMPORTS="${IMPORTS} print('Layer 1 OK')"
  # Trim any leading whitespace: when LAYER1_IMPORTS is empty the first loop
  # append leaves a leading space, which Python rejects as an IndentationError.
  IMPORTS="$(printf '%s' "$IMPORTS" | sed 's/^[[:space:]]*//')"

  # env -i wipes the host env so the bundle's python only sees what we hand
  # it. On Windows, parso (transitive via build123d → IPython → jedi) reads
  # LOCALAPPDATA + USERPROFILE at module-import time to construct its cache
  # path; if either is missing, parso falls back to `Path('~')` and
  # pathlib.expanduser raises "Could not determine home directory." So
  # Windows needs the full Windows home-dir env set passed through.
  if [ "$TRIPLE" = "windows-x86_64" ]; then
    env -i \
      HOME="${HOME:-}" \
      PATH="${PATH:-/usr/bin:/bin}" \
      USERPROFILE="${USERPROFILE:-}" \
      LOCALAPPDATA="${LOCALAPPDATA:-}" \
      HOMEDRIVE="${HOMEDRIVE:-}" \
      HOMEPATH="${HOMEPATH:-}" \
      APPDATA="${APPDATA:-}" \
      TEMP="${TEMP:-}" \
      TMP="${TMP:-}" \
      PYTHONHOME="$STAGE_DIR" \
      PYTHONDONTWRITEBYTECODE=1 \
      PYTHONUNBUFFERED=1 \
      "$STAGE_DIR/$PYTHON_BIN" -c "$IMPORTS"
  else
    env -i \
      HOME="$HOME" \
      PATH="/usr/bin:/bin" \
      PYTHONHOME="$STAGE_DIR" \
      PYTHONDONTWRITEBYTECODE=1 \
      PYTHONUNBUFFERED=1 \
      "$STAGE_DIR/$PYTHON_BIN" -c "$IMPORTS"
  fi
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
) | zstd -19 -q -f -o "$OUT_TARBALL"

# --------------------------------------------------------------------------
# tarball sha256 — used by Go-side EmbeddedSHA256 verification
# --------------------------------------------------------------------------

$HASHER "$OUT_TARBALL" | awk '{print $1}' > "$OUT_TARBALL_SHA"

bundle_size="$(du -h "$OUT_TARBALL" | awk '{print $1}')"
echo "[$TRIPLE] done"
echo "[$TRIPLE]   bundle: $OUT_TARBALL ($bundle_size)"
echo "[$TRIPLE]   sha256: $(cat "$OUT_TARBALL_SHA")"
