#!/usr/bin/env bash
# Runs the pcb plugin's GDScript test suite (pcb/tests/gd/*.gd) using a
# Minerva checkout as the Godot host. NOTHING else ran these tests before
# this script existed — see round A1a.
#
# Usage:
#   pcb/scripts/run-gd-tests.sh <path-to-minerva-checkout>
#
# <path-to-minerva-checkout> must be a Minerva repo checkout with a src/
# directory (godot --path <minerva>/src). It does NOT need to be a sibling
# of minerva-plugins on disk — the script computes the relative res://
# path each test's preloads expect ("res://../../minerva-plugins/...")
# from the actual location of THIS repo, so it works regardless of where
# the two checkouts happen to sit relative to each other.
#
# Exit code: 0 if every test's SceneTree exited 0, non-zero otherwise (the
# first non-zero exit code encountered, or 1 if any test crashed without a
# numeric code). This is a REAL pass/fail signal: every test in
# pcb/tests/gd/ ends its _init() with `quit(1 if _fail > 0 else 0)`, so the
# Godot process's own exit code IS the test result — no scraping stdout.
#
# 3 of the 7 tests (test_workspace_persistence, test_workspace_ingest,
# test_parity_bridge) additionally preload
# res://test/helpers/plugin_panel_driver.gd, which must exist inside the
# Minerva checkout's src/test/helpers/. A stock Minerva checkout has it;
# this script does not vendor or fake it.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_ROOT="$(cd "${PCB_DIR}/.." && pwd)"
GD_TEST_DIR="${PCB_DIR}/tests/gd"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <path-to-minerva-checkout>" >&2
  exit 2
fi

MINERVA_DIR="$(cd "$1" 2>/dev/null && pwd)"
if [ -z "${MINERVA_DIR}" ] || [ ! -d "${MINERVA_DIR}/src" ]; then
  echo "error: '$1' does not look like a Minerva checkout (no src/ dir)" >&2
  exit 2
fi

if ! command -v godot >/dev/null 2>&1; then
  echo "error: 'godot' not found on PATH" >&2
  exit 2
fi

# The tests' own preloads are hardcoded to the literal string
# "res://../../minerva-plugins/pcb/...", which only resolves if the
# minerva-plugins checkout is actually named "minerva-plugins" and sits
# two levels above src/ relative to the Minerva checkout (i.e. as a
# sibling directory: <parent>/Minerva/src and <parent>/minerva-plugins).
# Detect the mismatch up front with a clear error instead of letting every
# test fail with an opaque "Cannot open file" from Godot.
EXPECTED_SIBLING="$(cd "${MINERVA_DIR}/../minerva-plugins" 2>/dev/null && pwd)"
ACTUAL_PLUGINS="$(cd "${PLUGINS_ROOT}" && pwd)"
if [ "${EXPECTED_SIBLING}" != "${ACTUAL_PLUGINS}" ]; then
  echo "error: this checkout of minerva-plugins is not at <minerva-parent>/minerva-plugins" >&2
  echo "  Minerva checkout:     ${MINERVA_DIR}" >&2
  echo "  expected sibling dir: ${MINERVA_DIR}/../minerva-plugins" >&2
  echo "  actual plugins repo:  ${ACTUAL_PLUGINS}" >&2
  echo "  (test preloads hardcode res://../../minerva-plugins/... — see any test_*.gd header)" >&2
  exit 2
fi

shopt -s nullglob
tests=("${GD_TEST_DIR}"/test_*.gd)
shopt -u nullglob

if [ "${#tests[@]}" -eq 0 ]; then
  echo "error: no test_*.gd files found in ${GD_TEST_DIR}" >&2
  exit 2
fi

overall_rc=0
declare -a results=()

echo "Running ${#tests[@]} pcb GDScript test(s) via Minerva host at ${MINERVA_DIR}"
echo

for test_path in "${tests[@]}"; do
  name="$(basename "${test_path}")"
  res_script="res://../../minerva-plugins/pcb/tests/gd/${name}"
  echo "=== ${name} ==="
  godot --headless --path "${MINERVA_DIR}/src" --script "${res_script}"
  rc=$?
  echo "--- ${name} exited ${rc} ---"
  echo

  if [ "${rc}" -eq 0 ]; then
    results+=("PASS  ${name}")
  else
    results+=("FAIL  ${name} (exit ${rc})")
    if [ "${overall_rc}" -eq 0 ]; then
      overall_rc="${rc}"
    fi
  fi
done

echo "=== Summary ==="
for line in "${results[@]}"; do
  echo "${line}"
done

if [ "${overall_rc}" -ne 0 ]; then
  echo
  echo "gd test suite FAILED"
else
  echo
  echo "gd test suite passed (${#tests[@]}/${#tests[@]})"
fi

exit "${overall_rc}"
