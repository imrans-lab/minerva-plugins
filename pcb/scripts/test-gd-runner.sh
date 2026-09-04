#!/usr/bin/env bash
# Negative self-tests for run-gd-tests.sh: a planted compile error, a forced
# worker failure, the pinned assertion counts, the fatal-diagnostics allowlist
# and the Results-line floor must each make the runner exit nonzero AND say
# why.
#
# Usage:
#   pcb/scripts/test-gd-runner.sh <path-to-minerva-checkout>
#
# It drives pcb's wrapper, so what it certifies is the SHARED runner at
# scripts/run-gd-tests.sh — the same implementation cad and every later plugin
# run. A change to that script is not done until this script exits 0.
#
# Each case plants a defective (or healthy) suite into a sandbox dir and
# points run-gd-tests.sh at it via RUN_GD_TESTS_SUITE_DIR (the runner's
# documented self-test seam). The sandbox lives INSIDE the minerva-plugins
# checkout so a sandbox suite's derived res:// path has the exact same
# ../..-shape as a real suite's — no novel path shapes on the godot side.
#
# This EXECUTES godot against the Minerva host, so everything true of the
# real gd run is true here: it kills a running Minerva instance, and it
# needs Minerva's native GDExtensions built. It is a local gate, run at
# testex next to the real suite run. A runner change is not done until this
# script exits 0.
#
# Why a healthy control comes first: a runner broken into failing EVERYTHING
# would pass every negative case below for the wrong reason. The control
# proves the runner can still say yes before the cases prove it knows how to
# say no.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_ROOT="$(cd "${PCB_DIR}/.." && pwd)"
RUNNER="${SCRIPT_DIR}/run-gd-tests.sh"
REAL_ALLOWLIST="${PCB_DIR}/tests/gd/KNOWN_HARNESS_DIAGNOSTICS"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <path-to-minerva-checkout>" >&2
  exit 2
fi
MINERVA_ARG="$1"

if [ ! -f "${REAL_ALLOWLIST}" ]; then
  echo "error: real allowlist not found at ${REAL_ALLOWLIST}" >&2
  exit 2
fi

SANDBOX_ROOT="$(mktemp -d "${PLUGINS_ROOT}/.gd-selftest.XXXXXX")"
CAPTURE="$(mktemp)"
trap 'rm -rf "${SANDBOX_ROOT}" "${CAPTURE}"' EXIT

fails=0
case_num=0

# _case <name> <zero|nonzero> <required-output-regex>
# Runs the runner against ${SANDBOX_ROOT}/<name>, checks the exit-code
# expectation AND that the runner's output explains itself with the given
# regex — an exit code alone can be right by accident.
_case() {
  local name="$1" want="$2" pattern="$3"
  local dir="${SANDBOX_ROOT}/${name}"
  case_num=$((case_num + 1))
  # A case may author its OWN allowlist (the invalid-regex case does); the
  # real one is the default.
  if [ ! -f "${dir}/KNOWN_HARNESS_DIAGNOSTICS" ]; then
    cp "${REAL_ALLOWLIST}" "${dir}/KNOWN_HARNESS_DIAGNOSTICS"
  fi
  RUN_GD_TESTS_SUITE_DIR="${dir}" "${RUNNER}" "${MINERVA_ARG}" >"${CAPTURE}" 2>&1
  local rc=$?
  local ok=1
  if [ "${want}" = "zero" ] && [ "${rc}" -ne 0 ]; then ok=0; fi
  if [ "${want}" = "nonzero" ] && [ "${rc}" -eq 0 ]; then ok=0; fi
  if ! grep -Eq "${pattern}" "${CAPTURE}"; then ok=0; fi
  if [ "${ok}" -eq 1 ]; then
    echo "PASS  case ${case_num}: ${name} (exit ${rc}, wanted ${want}; output matched /${pattern}/)"
  else
    fails=$((fails + 1))
    echo "FAIL  case ${case_num}: ${name} — exit ${rc} (wanted ${want}), pattern /${pattern}/ $(grep -Eq "${pattern}" "${CAPTURE}" && echo matched || echo NOT matched)"
    echo "----- runner output (last 40 lines) -----"
    tail -n 40 "${CAPTURE}" | sed 's/^/    /'
    echo "-----------------------------------------"
  fi
}

# ── case 1: healthy control — the runner can still say yes ───────────────────
d="${SANDBOX_ROOT}/control"; mkdir -p "${d}"
cat > "${d}/test_selftest_ok.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	print("=== selftest: healthy control ===")
	print("  PASS: a")
	print("  PASS: b")
	print("  PASS: c")
	print("\n=== Results: 3 passed, 0 failed ===")
	quit(0)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF'
test_selftest_ok.gd assertions=3
EOF
_case "control" zero "gd test suite passed \(1/1 suites, 3 assertions\)"

# ── case 2: planted compile error — suite never runs, runner must refuse ─────
d="${SANDBOX_ROOT}/compile-error"; mkdir -p "${d}"
cat > "${d}/test_selftest_compile_error.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	this line is deliberately not GDScript (a planted compile error)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF'
test_selftest_compile_error.gd
EOF
_case "compile-error" nonzero "FAIL  test_selftest_compile_error\.gd"

# ── case 3: forced worker failure — green assertions, canned worker ──────────
d="${SANDBOX_ROOT}/worker-false"; mkdir -p "${d}"
cat > "${d}/test_selftest_worker_false.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	print("=== selftest: forced canned-worker run ===")
	print("  PASS: looks fine")
	print("\n=== Results: 5 passed, 0 failed (real_worker_used=false) ===")
	quit(0)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF'
test_selftest_worker_false.gd assertions=5 real-worker
EOF
_case "worker-false" nonzero "did not prove real_worker_used=true"

# ── case 4: assertion-count drift — quit(0) after early checks ───────────────
d="${SANDBOX_ROOT}/count-drift"; mkdir -p "${d}"
cat > "${d}/test_selftest_count_drift.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	print("=== selftest: shrunken suite ===")
	print("  PASS: the one check that still runs")
	print("\n=== Results: 2 passed, 0 failed ===")
	quit(0)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF'
test_selftest_count_drift.gd assertions=10
EOF
_case "count-drift" nonzero "assertion count drifted"

# ── case 5: mid-suite SCRIPT ERROR with a green Results line ─────────────────
d="${SANDBOX_ROOT}/runtime-error"; mkdir -p "${d}"
cat > "${d}/test_selftest_runtime_error.gd" <<'EOF'
extends SceneTree
func _boom() -> void:
	var x = null
	x.explode()
func _init() -> void:
	print("=== selftest: runtime script error mid-suite ===")
	_boom()
	print("  PASS: soldiered on past the error")
	print("\n=== Results: 2 passed, 0 failed ===")
	quit(0)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF'
test_selftest_runtime_error.gd assertions=2
EOF
_case "runtime-error" nonzero "fatal Godot diagnostics not on the known-harness allowlist"

# ── case 6: invalid allowlist regex — the gate must refuse to run, not
# silently disarm (F2, Codex 1188: grep rc 2 behind `|| true` read as "no
# residue")
d="${SANDBOX_ROOT}/bad-allowlist"; mkdir -p "${d}"
cat > "${d}/test_selftest_ok2.gd" <<'EOF_GD'
extends SceneTree
func _init() -> void:
	print("=== selftest: healthy suite under a broken allowlist ===")
	print("  PASS: fine")
	print("\n=== Results: 1 passed, 0 failed ===")
	quit(0)
EOF_GD
cat > "${d}/EXPECTED_SUITES" <<'EOF_M'
test_selftest_ok2.gd
EOF_M
cat > "${d}/KNOWN_HARNESS_DIAGNOSTICS" <<'EOF_A'
# deliberately malformed ERE (unbalanced group)
(((
EOF_A
_case "bad-allowlist" nonzero "invalid extended regex"

# ── case 7: duplicate manifest row — count inflation (F6) ────────────────────
d="${SANDBOX_ROOT}/dup-row"; mkdir -p "${d}"
cat > "${d}/test_selftest_ok3.gd" <<'EOF_GD'
extends SceneTree
func _init() -> void:
	print("=== selftest: duplicate manifest row ===")
	print("  PASS: fine")
	print("\n=== Results: 1 passed, 0 failed ===")
	quit(0)
EOF_GD
cat > "${d}/EXPECTED_SUITES" <<'EOF_M'
test_selftest_ok3.gd assertions=1
test_selftest_ok3.gd assertions=1
EOF_M
_case "dup-row" nonzero "duplicate suite entry"

# ── case 8: duplicate attribute — conflicting pins must not last-one-win (F6)
d="${SANDBOX_ROOT}/dup-attr"; mkdir -p "${d}"
cat > "${d}/test_selftest_ok4.gd" <<'EOF_GD'
extends SceneTree
func _init() -> void:
	print("=== selftest: duplicate attribute ===")
	print("  PASS: fine")
	print("\n=== Results: 1 passed, 0 failed ===")
	quit(0)
EOF_GD
cat > "${d}/EXPECTED_SUITES" <<'EOF_M'
test_selftest_ok4.gd assertions=1 assertions=2
EOF_M
_case "dup-attr" nonzero "repeats the assertions= attribute"

# ── case 9: every registered suite deleted — the empty glob must still name
# the missing suite, not the directory. The runner used to short-circuit an
# empty glob with "no test_*.gd files found in <dir>": true, but it named the
# wrong thing, and for a plugin with a single suite (cad) deleting that suite
# produced exactly that message instead of the suite's name.
d="${SANDBOX_ROOT}/all-deleted"; mkdir -p "${d}"
cat > "${d}/EXPECTED_SUITES" <<'EOF_M'
test_selftest_deleted.gd assertions=1
EOF_M
# The suite name appears in the output ONLY in the by-name "missing on disk"
# listing, so matching it is matching the acceptance.
_case "all-deleted" nonzero "test_selftest_deleted\.gd"

# ── case 10: a suite that REPORTS failures but exits 0. The Results line is
# the documented truth about a suite; an exit code is only what the suite
# chose to return. A harness that trusts the exit code alone certifies a red
# suite as green.
d="${SANDBOX_ROOT}/green-exit-red-results"; mkdir -p "${d}"
cat > "${d}/test_selftest_green_exit.gd" <<'EOF'
extends SceneTree
func _init() -> void:
	print("=== selftest: reports a failure, exits 0 ===")
	print("  PASS: a")
	print("  PASS: b")
	print("  FAIL: c")
	print("\n=== Results: 2 passed, 1 failed ===")
	quit(0)
EOF
cat > "${d}/EXPECTED_SUITES" <<'EOF_M'
test_selftest_green_exit.gd assertions=3
EOF_M
_case "green-exit-red-results" nonzero "reports 1 failed assertions despite exit 0"

echo
if [ "${fails}" -gt 0 ]; then
  echo "gd-runner self-test FAILED (${fails}/${case_num} cases)"
  exit 1
fi
echo "gd-runner self-test passed (${case_num}/${case_num} cases)"
exit 0
