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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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
# Wheels installed WITHOUT their declared dependencies — for a package whose
# metadata pulls in more than the code path we ship ever imports. Each entry
# must then be covered by LAYER1_IMPORTS, which is what proves the omission
# was safe.
: "${PIP_NO_DEPS_PKGS:=}"
# Wheels whose compiled extension resolves a C++ runtime DLL from the machine
# instead of carrying its own. On the windows target these are downloaded and
# repaired (delvewheel) before installation so the bundle does not depend on
# the USER having a Visual C++ redistributable — a dependency that is
# invisible on CI, where every runner has one. Entries must appear verbatim in
# PIP_NO_DEPS_PKGS. Ignored on every other target.
: "${WHEEL_REPAIR_PKGS:=}"
: "${WHEEL_REPAIR_TOOL:=}"
# Extra arguments passed to the repair tool. Which ones a wheel needs is a
# property OF THAT WHEEL (where it keeps its own DLLs, whether their
# dependencies must be analysed), so the plugin declares them rather than this
# script guessing.
: "${WHEEL_REPAIR_ARGS:=}"
# Directory (relative to the plugin dir) copied into the bundle as licenses/:
# the licence texts a binary redistribution has to carry.
: "${BUNDLE_LICENSE_DIR:=}"
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
# input verification (acceptance check K23, DCR/work item 019ffc543d1d)
# --------------------------------------------------------------------------
#
# WHAT THIS IS NOT: the manifest.sha256 generated near the end of this script
# hashes the bundle's OWN OUTPUT so post-extract tampering is detectable. That
# is a different guarantee entirely. K23 asks whether the bytes we DOWNLOADED
# and then EXTRACTED AND EXECUTED were the bytes we intended, and nothing
# checked that: a version pin is not an immutable identity, because the same
# tag can serve different bytes after a re-upload, a compromised mirror, or a
# truncated transfer that still exits 0.
#
# VERIFIED BEFORE USE, INCLUDING ON A CACHE HIT. A cached artifact is the more
# dangerous case, not the safer one: it was fetched at some earlier time under
# conditions nobody can now inspect, and on CI the cache is a shared, writable
# store keyed by a hash of the lock file rather than of the payload.
verify_sha256() {
  _vf_file="$1"; _vf_expect="$2"; _vf_what="$3"
  if [ -z "$_vf_expect" ]; then
    # NOT silently skipped: an unpinned input is a real gap in this bundle's
    # provenance, and the build says so every single time rather than letting
    # the omission read as "verified". The gate that turns this into a hard
    # failure lives in the test suite, so populating a pin is tracked work
    # instead of an invisible hole. See tests/test_runtime_input_pins.py.
    echo "[$TRIPLE] WARNING: $_vf_what has NO pinned sha256 — bytes NOT verified (K23 gap)" >&2
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    _vf_actual="$(sha256sum "$_vf_file" | cut -d" " -f1)"
  else
    _vf_actual="$(shasum -a 256 "$_vf_file" | cut -d" " -f1)"
  fi
  if [ "$_vf_actual" != "$_vf_expect" ]; then
    echo "[$TRIPLE] FATAL: $_vf_what failed verification" >&2
    echo "  expected sha256 $_vf_expect" >&2
    echo "  actual   sha256 $_vf_actual" >&2
    echo "  file     $_vf_file" >&2
    # The cached copy is REMOVED. Leaving corrupt bytes in the cache would
    # make every later build fail the same way with no path out except manual
    # cleanup, and a poisoned cache entry that merely fails loudly is still a
    # poisoned cache entry.
    rm -f "$_vf_file"
    exit 1
  fi
  echo "[$TRIPLE] verified $_vf_what (sha256 $_vf_actual)"
}

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

# Verified on BOTH paths — see verify_sha256's note on why the cache hit is the
# more dangerous one. The expected value is selected per triple, because a PBS
# asset is platform-specific and one hash cannot cover the matrix.
eval "PBS_EXPECT=\${PBS_SHA256_$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_'):-}"
verify_sha256 "$PBS_CACHED" "${PBS_EXPECT:-}" "python-build-standalone $CPYTHON+$PBS_TAG ($TRIPLE)"

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

# Hoisted above the install section because the wheel-repair step below
# also drives the bundled python.exe and needs the same home-dir env.
if [ "$TRIPLE" = "windows-x86_64" ] && [ "$TRIPLE" = "$HOST_TRIPLE" ]; then
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

# --------------------------------------------------------------------------
# build dep list from lock var (plugin-agnostic: PIP_PKGS is the only source)
# --------------------------------------------------------------------------

# shellcheck disable=SC2206
DEPS=( $PIP_PKGS )
# shellcheck disable=SC2206
NODEPS=( $PIP_NO_DEPS_PKGS )
# shellcheck disable=SC2206
REPAIR=( $WHEEL_REPAIR_PKGS )

if [ ${#DEPS[@]} -eq 0 ]; then
  echo "[$TRIPLE] WARNING: PIP_PKGS empty in lock file (only worker source will be bundled)" >&2
fi

# --------------------------------------------------------------------------
# windows wheel repair — bundle the C++ runtime the extension expects
# --------------------------------------------------------------------------
#
# A wheel that was never delvewheel-repaired upstream links against a runtime
# DLL it does not ship (MSVCP140.dll for an MSVC-built extension), and
# python-build-standalone's windows distribution ships only the VCRUNTIME140
# pair. The import then succeeds on any machine with a Visual C++
# redistributable installed — every CI runner — and fails on a bare user
# machine. delvewheel copies the missing DLL into the wheel under a
# name-mangled path (it deliberately skips vcruntime140, which Python already
# ships), which is the same shape the cadquery-ocp wheel already arrives in.
#
# REPAIRED_WHEEL_DIR is consumed by the install section below: repaired
# packages install from there instead of from PyPI.
REPAIRED_WHEEL_DIR=""
if [ ${#REPAIR[@]} -gt 0 ] && [ "$TRIPLE" = "windows-x86_64" ]; then
  # A cross-built windows bundle CANNOT be repaired: delvewheel resolves the
  # DLL from the build machine's own Visual Studio installation, and a linux
  # or macOS host has none. Failing here is the point — silently packing
  # unrepaired wheels is exactly the "works on CI, fails for the user" defect
  # this block exists to remove.
  if [ "$TRIPLE" != "$HOST_TRIPLE" ]; then
    echo "[$TRIPLE] FATAL: WHEEL_REPAIR_PKGS is set but this is a cross build" >&2
    echo "  the repair needs the windows host's VC++ runtime; build this target natively" >&2
    exit 73
  fi
  if [ -z "$WHEEL_REPAIR_TOOL" ]; then
    echo "[$TRIPLE] FATAL: WHEEL_REPAIR_PKGS is set but WHEEL_REPAIR_TOOL is empty" >&2
    exit 65
  fi
  # Every repaired package must also be declared --no-deps, so the repaired
  # local wheel is the ONLY way it can enter the bundle. Without this check a
  # spec present in PIP_PKGS but repaired here would be installed twice, the
  # PyPI copy last, quietly undoing the repair.
  for spec in "${REPAIR[@]}"; do
    found=false
    # `if` rather than `test && found=true`: under `set -e` a failing test as
    # the last command of a loop body aborts the script.
    for nd in ${NODEPS[@]+"${NODEPS[@]}"}; do
      if [ "$spec" = "$nd" ]; then found=true; fi
    done
    if [ "$found" != "true" ]; then
      echo "[$TRIPLE] FATAL: WHEEL_REPAIR_PKGS entry '$spec' is not listed verbatim in PIP_NO_DEPS_PKGS" >&2
      exit 65
    fi
  done

  REPAIR_TOOLING="$BUILD_DIR/wheel-repair-tooling"
  REPAIR_DL="$BUILD_DIR/wheel-repair-$TRIPLE"
  REPAIRED_WHEEL_DIR="$REPAIR_DL/repaired"
  rm -rf "$REPAIR_TOOLING" "$REPAIR_DL"
  mkdir -p "$REPAIR_TOOLING" "$REPAIR_DL" "$REPAIRED_WHEEL_DIR"

  echo "[$TRIPLE] installing wheel-repair tool: $WHEEL_REPAIR_TOOL"
  # Into its own --target, never into the stage: the repair tool is build
  # machinery and must not end up inside the shipped bundle.
  PYTHONNOUSERSITE=1 "$STAGE_DIR/$PYTHON_BIN" -m pip install \
    --no-cache-dir --no-input --no-compile --only-binary=:all: \
    --target "$REPAIR_TOOLING" $WHEEL_REPAIR_TOOL

  echo "[$TRIPLE] downloading wheels to repair: ${REPAIR[*]}"
  PYTHONNOUSERSITE=1 "$STAGE_DIR/$PYTHON_BIN" -m pip download \
    --no-cache-dir --no-input --only-binary=:all: --no-deps \
    -d "$REPAIR_DL" "${REPAIR[@]}"

  for whl in "$REPAIR_DL"/*.whl; do
    echo "[$TRIPLE] delvewheel repair: $(basename "$whl")"
    # shellcheck disable=SC2086 — WHEEL_REPAIR_ARGS is a word list by design.
    PYTHONNOUSERSITE=1 PYTHONPATH="$REPAIR_TOOLING" \
      "$STAGE_DIR/$PYTHON_BIN" -m delvewheel repair \
      $WHEEL_REPAIR_ARGS \
      -w "$REPAIRED_WHEEL_DIR" "$whl"
  done
  echo "[$TRIPLE] repaired wheels:"
  ls -la "$REPAIRED_WHEEL_DIR"
  # delvewheel writes an output wheel even when it vendored nothing, so the
  # repair is proven by content: every repaired wheel must carry a vendored
  # C++ runtime DLL, or the bundle would import only on machines that
  # already have the redistributable installed.
  # Listed with python's zipfile rather than `unzip`: Git for Windows does not
  # reliably ship unzip, and a missing tool must not read as a failed repair.
  for whl in "$REPAIRED_WHEEL_DIR"/*.whl; do
    if ! "$STAGE_DIR/$PYTHON_BIN" -c "
import sys, zipfile, re
names = zipfile.ZipFile(sys.argv[1]).namelist()
sys.exit(0 if any(re.search(r'msvcp140.*\.dll$', n, re.I) for n in names) else 1)
" "$whl"; then
      echo "[$TRIPLE] wheel repair vendored no msvcp140 DLL into $(basename "$whl")" >&2
      exit 74
    fi
  done
fi

# Repaired packages are removed from the PyPI --no-deps list and installed
# from REPAIRED_WHEEL_DIR instead.
NODEPS_PYPI=()
for spec in ${NODEPS[@]+"${NODEPS[@]}"}; do
  repaired=false
  if [ -n "$REPAIRED_WHEEL_DIR" ]; then
    for r in "${REPAIR[@]}"; do
      if [ "$spec" = "$r" ]; then repaired=true; fi
    done
  fi
  [ "$repaired" = "true" ] || NODEPS_PYPI+=( "$spec" )
done

# --------------------------------------------------------------------------
# pip install — native uses bundle's python; cross uses host python + --platform
# --------------------------------------------------------------------------

if [ "$TRIPLE" = "$HOST_TRIPLE" ]; then
  echo "[$TRIPLE] native build: pip install via bundled python"
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
        "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile --only-binary=:all: "${DEPS[@]}"
    else
      PYTHONNOUSERSITE=1 \
        "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile --only-binary=:all: "${DEPS[@]}"
    fi
  fi
  if [ ${#NODEPS_PYPI[@]} -gt 0 ]; then
    PYTHONNOUSERSITE=1 \
      "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile --only-binary=:all: --no-deps "${NODEPS_PYPI[@]}"
  fi
  if [ -n "$REPAIRED_WHEEL_DIR" ]; then
    # --no-index: the repaired local wheel is the only acceptable source. A
    # fall-through to PyPI here would install the UNREPAIRED wheel and the
    # bundle would once again depend on the user's machine having the C++
    # runtime, with nothing in the build output saying so.
    echo "[$TRIPLE] installing repaired wheels: ${REPAIR[*]}"
    PYTHONNOUSERSITE=1 \
      "$STAGE_DIR/$PYTHON_BIN" -m pip install --no-cache-dir --no-input --no-compile \
        --no-deps --no-index --find-links "$REPAIRED_WHEEL_DIR" "${REPAIR[@]}"
  fi
else
  echo "[$TRIPLE] cross build: pip install via host python with --platform=$WHEEL_PLATS"
  # --only-binary=:all: on the native path above (review of 019ffc543d1d):
  # without it a missing wheel falls back to an SDIST, whose build backend runs
  # ARBITRARY CODE during packaging — a strictly larger hole than the missing
  # hash pins this work is about, and one no hash would have closed because
  # the sdist would have been the artifact we hashed. The cross path already
  # implies binary-only via --platform, which pip refuses to combine with a
  # source build.
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
  if [ ${#NODEPS_PYPI[@]} -gt 0 ]; then
    "$HOST_PY" -m pip install --no-cache-dir --no-input \
      --target "$SITE_PACKAGES" \
      "${PLAT_ARGS[@]}" \
      --python-version "$PY_MAJOR_MINOR" \
      --abi "$ABI" \
      --only-binary=:all: --no-deps \
      "${NODEPS_PYPI[@]}"
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
    # Verified before extraction, same rule as PBS. rg is a third-party
    # EXECUTABLE that ships inside the bundle, so unverified bytes here would
    # be shipped to every user of the plugin — the highest-consequence input
    # in this script, and the one whose download path already tolerates
    # failure most readily.
    eval "RG_EXPECT=\${RG_SHA256_$(echo "$TRIPLE" | tr 'a-z-' 'A-Z_'):-}"
    verify_sha256 "$RG_CACHED" "${RG_EXPECT:-}" "ripgrep $RG_VERSION ($TRIPLE)"
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
# licence texts — carried INSIDE the bundle
# --------------------------------------------------------------------------
#
# BSD/MIT binary redistribution requires the copyright notice, the conditions
# and the disclaimer to be provided "in the documentation and/or other
# materials provided with the distribution", and a wheel routinely ships only
# its own text while vendoring compiled copies of other projects. The plugin
# curates the full set; this copy is what makes the set travel with the bytes
# it covers, wherever the bundle is extracted. Hashed by manifest.sha256 below
# like everything else, so a stripped licence text is a tamper detection.
if [ -n "$BUNDLE_LICENSE_DIR" ]; then
  LICENSE_SRC="$PLUGIN_DIR/$BUNDLE_LICENSE_DIR"
  if [ ! -d "$LICENSE_SRC" ]; then
    echo "[$TRIPLE] FATAL: BUNDLE_LICENSE_DIR set but not a directory: $LICENSE_SRC" >&2
    exit 74
  fi
  echo "[$TRIPLE] copying licence texts from $LICENSE_SRC"
  rm -rf "${STAGE_DIR:?}/licenses"
  cp -r "$LICENSE_SRC" "$STAGE_DIR/licenses"
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
  # The probe lives in its own script so CI can aim the SAME import list at a
  # CROSS-built stage through a translator (RUNTIME_PROBE_PREFIX="arch -x86_64"
  # for the macos-amd64 slice of the universal build), which is the one stage
  # nothing here can execute.
  bash "$SCRIPT_DIR/probe-python-runtime-bundle.sh" "$PLUGIN_DIR" "$TRIPLE"
else
  echo "[$TRIPLE] cross-target: Layer 1 self-test skipped here — CI probes this"
  echo "[$TRIPLE] stage with scripts/probe-python-runtime-bundle.sh under a translator"
fi

# --------------------------------------------------------------------------
# manifest.sha256 — per-file checksums for post-extract tampering detection
# --------------------------------------------------------------------------

# One line per file: "<sha256>  <relative path>". Both hashers print that on
# POSIX; Git-for-Windows sha256sum hashes in binary mode and marks it
# "<sha256> *<path>", which the runtime verifier (shared/runtime/extract.go
# manifestValid) would reject — so the sed below canonicalises either form.
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
    | sed -E 's|^([0-9a-fA-F]{64}) [ *]\./|\1  |' \
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
