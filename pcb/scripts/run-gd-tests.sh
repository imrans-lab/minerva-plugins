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
# Exit code: 0 only if every suite BOTH exited 0 AND printed a parseable
# "=== Results: N passed, M failed ===" line with N > 0. A suite's process
# exit code alone is NOT trusted as the pass/fail signal: every test in
# pcb/tests/gd/ ends its _init() with `quit(1 if _fail > 0 else 0)`, but a
# suite that returns/quits early — an accidental early `return`, an aborted
# fixture, a `quit(0)` planted above the first assertion — exits 0 without
# running a single check() and would read as a pass on exit code alone.
# Measured directly (round 019fa603827b): inserting `quit(0); return` at the
# top of test_pcb_panel_ui.gd::_init() made the exit code lie — 0 passed,
# 22 real assertions skipped — while the process itself exited clean.
#
# To close that hole the runner captures each suite's stdout+stderr and, in
# addition to checking $?, parses the Results line and enforces a floor: a
# suite FAILS if the process exited non-zero, OR the Results line is absent
# (the process quit/crashed before reporting), OR it reports zero total
# assertions, OR it reports zero passed. See "How pass/fail is signalled" in
# pcb/docs/gd-tests.md for the full contract.
#
# Several suites additionally preload res://test/helpers/plugin_panel_driver.gd
# and/or res://test/helpers/panel_tool_registry_driver.gd from Minerva core,
# to drive a real PCBPanel instead of a stand-in. A stock Minerva checkout has
# both; this script does not vendor or fake them.
#
# SETUP STEP (chore 019fb6632a4e / round B5u1): any suite that exercises a
# REAL plugin subprocess start (PluginManager.start_plugin -> MCP STDIO
# transport — e.g. test_pcb_backend_lifecycle.gd, test_pcb_plugin_smoke.gd)
# needs the Minerva checkout's `terminal` GDExtension BUILT, i.e.
# <minerva-checkout>/src/bin/libterminal.<platform>.*.so/.dylib/.dll must
# exist (see CLAUDE.md "Building C++ Extensions" / scripts/build-extensions.sh
# in the Minerva repo). That extension registers the native `SubProcess`
# class MCPServerConnection.gd's STDIO transport requires
# (ClassDB.class_exists("SubProcess")); a checkout/scaffold without a src/bin/
# directory at all has never run build-extensions.sh and fails EVERY
# start_plugin call with "Subprocess failed to start: Unavailable" /
# "SubProcess GDExtension not available - STDIO transport not supported" —
# for every plugin, not just pcb. This is a scaffold-config gap, not a
# pcb-plugin defect: verified on this host by running the pcb-plugin binary
# directly (`pcb/pcb-plugin --help`) and confirming it starts fine; the
# failure is entirely on the Godot-host side of the STDIO pipe.
#
# Suite-count floor: the per-suite checks above catch a suite that runs but
# reports nothing. They do NOT catch a suite that never runs at all — the
# test list is `${GD_TEST_DIR}/test_*.gd`, a bare glob, and a deleted or
# renamed suite file simply drops out of it with nothing left to fail. Before
# anything else runs, the runner cross-checks that glob against a checked-in
# manifest (pcb/tests/gd/EXPECTED_SUITES, one filename per line) and fails
# fast, by name, in both directions: a manifest entry with no file on disk
# (deletion/rename), or a test_*.gd file with no manifest entry (addition
# without registration). Adding a suite is meant to be a deliberate one-line
# edit to that manifest; the count itself is never hardcoded here for exactly
# that reason — a hardcoded integer goes stale the moment a suite is added
# and gets "fixed" by lowering it, which is the same failure as deleting a
# suite, performed by a different hand.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_ROOT="$(cd "${PCB_DIR}/.." && pwd)"
GD_TEST_DIR="${PCB_DIR}/tests/gd"

PREFLIGHT_ONLY=0
declare -a positional=()
for arg in "$@"; do
  case "${arg}" in
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    -*)
      echo "error: unknown option '${arg}'" >&2
      echo "usage: $0 [--preflight-only] <path-to-minerva-checkout>" >&2
      exit 2
      ;;
    *) positional+=("${arg}") ;;
  esac
done

if [ "${#positional[@]}" -lt 1 ]; then
  echo "usage: $0 [--preflight-only] <path-to-minerva-checkout>" >&2
  exit 2
fi

MINERVA_DIR="$(cd "${positional[0]}" 2>/dev/null && pwd)"
if [ -z "${MINERVA_DIR}" ] || [ ! -d "${MINERVA_DIR}/src" ]; then
  echo "error: '${positional[0]}' does not look like a Minerva checkout (no src/ dir)" >&2
  exit 2
fi

# HOST CONTRACT — the three paths the suites cannot load without. Checked HERE,
# in the script, and not only in the CI workflow (Codex review 019ff34dd1cf,
# blocking finding 2): the workflow asserted these in its relocation step, so CI
# happened to be covered, but a direct `--preflight-only` invocation could pass
# a host that cannot load a single suite — while this script's own comments
# claimed local and CI run "one implementation" that cannot drift. They did
# drift, in the direction that made the claim false.
#
# `src/` alone is not the contract: 9 relocated suites preload
# plugin_panel_driver.gd and 7 preload panel_tool_registry_driver.gd (round
# 019f70a26607), both by res:// path against Minerva's res:// root. A pinned SHA
# that drops either one breaks the harness rather than the code, which is a
# failure worth naming precisely rather than discovering as "Cannot open file".
_host_missing=()
for _required in \
  "src/project.godot" \
  "src/test/helpers/plugin_panel_driver.gd" \
  "src/test/helpers/panel_tool_registry_driver.gd"
do
  [ -f "${MINERVA_DIR}/${_required}" ] || _host_missing+=("${_required}")
done
if [ "${#_host_missing[@]}" -gt 0 ]; then
  echo "error: Minerva host at ${MINERVA_DIR} is missing required file(s):" >&2
  for _required in "${_host_missing[@]}"; do
    echo "    - ${_required}" >&2
  done
  echo "  (the suites preload the helpers by res:// path; if you just bumped the" >&2
  echo "   pinned Minerva SHA, re-check that both helpers still exist there)" >&2
  exit 2
fi

# --preflight-only needs NO Godot: everything it checks is filesystem state.
# That is the whole point — see the WHAT CI CAN AND CANNOT CHECK note in the
# header. Requiring godot here would put the CI gate back behind the very
# dependency it exists to avoid.
if [ "${PREFLIGHT_ONLY}" -eq 0 ] && ! command -v godot >/dev/null 2>&1; then
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

# Suite-count floor (pre-flight, before --import and before the loop below,
# same "harness/environment problem" exit 2 convention as the guards above):
# cross-check the glob against the checked-in manifest of expected suite
# names. This is what makes deleting/renaming a suite a loud, named failure
# instead of a smaller-but-still-green run — see the header comment.
MANIFEST="${GD_TEST_DIR}/EXPECTED_SUITES"
if [ ! -f "${MANIFEST}" ]; then
  echo "error: suite manifest not found: ${MANIFEST}" >&2
  exit 2
fi

declare -a manifest_names=()
while IFS= read -r line; do
  case "${line}" in
    ""|"#"*) continue ;;
  esac
  manifest_names+=("${line}")
done < "${MANIFEST}"

if [ "${#manifest_names[@]}" -eq 0 ]; then
  echo "error: suite manifest ${MANIFEST} has no entries" >&2
  exit 2
fi

declare -a disk_names=()
for test_path in "${tests[@]}"; do
  disk_names+=("$(basename "${test_path}")")
done

declare -a missing_suites=()
for name in "${manifest_names[@]}"; do
  found=0
  for d in "${disk_names[@]}"; do
    if [ "${d}" = "${name}" ]; then
      found=1
      break
    fi
  done
  if [ "${found}" -eq 0 ]; then
    missing_suites+=("${name}")
  fi
done

declare -a unregistered_suites=()
for d in "${disk_names[@]}"; do
  found=0
  for name in "${manifest_names[@]}"; do
    if [ "${d}" = "${name}" ]; then
      found=1
      break
    fi
  done
  if [ "${found}" -eq 0 ]; then
    unregistered_suites+=("${d}")
  fi
done

if [ "${#missing_suites[@]}" -gt 0 ] || [ "${#unregistered_suites[@]}" -gt 0 ]; then
  echo "error: gd suite manifest mismatch against ${MANIFEST}" >&2
  if [ "${#missing_suites[@]}" -gt 0 ]; then
    echo "  in manifest but missing on disk (deleted/renamed?):" >&2
    for name in "${missing_suites[@]}"; do
      echo "    - ${name}" >&2
    done
  fi
  if [ "${#unregistered_suites[@]}" -gt 0 ]; then
    echo "  on disk but not registered in manifest (add it there):" >&2
    for name in "${unregistered_suites[@]}"; do
      echo "    - ${name}" >&2
    done
  fi
  exit 2
fi

EXPECTED_SUITE_COUNT="${#manifest_names[@]}"

# --preflight-only stops HERE, and this is the boundary CI runs to.
#
# WHAT IT PROVES, stated narrowly because the first version of this comment
# overclaimed and a cold review caught it (019ff34dd1cf, blocking finding 1):
# SUITE-REGISTRY AND HOST-CONTRACT COMPATIBILITY. The host exists and carries
# both driver helpers, the sibling layout the res:// preloads hardcode is
# correct, and the suite set on disk matches the checked-in manifest in both
# directions.
#
# WHAT IT DOES NOT PROVE, and this is the part the earlier wording blurred: it
# is NOT evidence that the GDScript layer builds, parses, or behaves. A .gd
# file can be syntactically invalid, fail to preload, or regress outright while
# its filename sits happily in EXPECTED_SUITES and this check stays green.
# Nothing here executes, so nothing here is a test result.
#
# Everything BELOW needs a Godot host with Minerva's native GDExtensions
# BUILT, which a plain `actions/checkout` of Minerva does not have and which
# CI has no business building — see the SETUP STEP note in this header
# (chore 019fb6632a4e). Without src/bin/ every suite that starts a real
# plugin subprocess fails, and scripts that reach the FFmpeg-backed
# VideoRecorder fail to COMPILE, cascading into SingletonObject and taking
# unrelated suites down with them. That is a host-scaffold gap, not a signal
# about pcb, and running the suites there produced a red job that told
# nobody anything for five consecutive commits.
#
# So: EXECUTION IS A LOCAL GATE. Run this script without the flag on a
# developer machine with build-extensions.sh already run. See
# pcb/docs/gd-tests.md.
if [ "${PREFLIGHT_ONLY}" -eq 1 ]; then
  echo "gd pre-flight PASSED: suite-registry + host-contract compatibility only"
  echo "  (${EXPECTED_SUITE_COUNT} suites registered and present)"
  echo "  host:     ${MINERVA_DIR}"
  echo "  sibling:  ${ACTUAL_PLUGINS}"
  echo "  manifest: ${MANIFEST}"
  echo "NOTE: NOTHING WAS EXECUTED. This is not evidence that the GDScript layer"
  echo "      builds, parses or behaves — a .gd file can be invalid while its"
  echo "      filename sits in EXPECTED_SUITES and this check stays green."
  echo "      Execution needs Minerva's native GDExtensions built and is a"
  echo "      local gate — see pcb/docs/gd-tests.md."
  exit 0
fi

overall_rc=0
declare -a results=()
total_pass=0
total_suites_ok=0

# Scratch file for capturing one suite's combined stdout+stderr so the
# Results line can be parsed after the process exits. Reused across
# iterations; cleaned up on any exit path.
RESULTS_TMP="$(mktemp)"
trap 'rm -f "${RESULTS_TMP}"' EXIT

# Import the host project before running anything. Godot resolves `class_name`
# globals through .godot/global_script_class_cache.cfg, which is generated on
# import and is NOT tracked in git. On a FRESH Minerva clone (any CI runner, or
# a colleague who just cloned) that cache does not exist, so autoloads
# referencing class_name types fail to parse:
#
#   Parse Error: Could not find type "DocumentBuffer" in the current scope.
#     at: GDScript::reload (res://Scripts/Services/Watcher/WatcherRuntime.gd:71)
#
# and the tests that touch those paths fail for a reason that has nothing to do
# with the code under test. A warm local checkout hides this completely — it
# cost one red CI run to find. Idempotent and near-free once .godot exists.
echo "Importing Minerva host project (generates .godot class cache if absent)..."
godot --headless --path "${MINERVA_DIR}/src" --import >/dev/null 2>&1 || true
echo

echo "Running ${#tests[@]} pcb GDScript test(s) via Minerva host at ${MINERVA_DIR}"
echo

for test_path in "${tests[@]}"; do
  name="$(basename "${test_path}")"
  res_script="res://../../minerva-plugins/pcb/tests/gd/${name}"
  echo "=== ${name} ==="

  # Tee so the run stays human-watchable live (nothing regresses for a
  # person reading the terminal), while also capturing the output to parse
  # the Results line. PIPESTATUS[0] is godot's own exit code, not tee's.
  godot --headless --path "${MINERVA_DIR}/src" --script "${res_script}" 2>&1 | tee "${RESULTS_TMP}"
  rc="${PIPESTATUS[0]}"
  echo "--- ${name} exited ${rc} ---"
  echo

  # Parse "=== Results: N passed, M failed ===" (every suite in the manifest
  # prints this exact prefix; a few append "(real_worker_used=%s)" inside the
  # parens, which the pattern below does not need to match).
  results_line="$(grep -m1 -E '=== Results: [0-9]+ passed, [0-9]+ failed' "${RESULTS_TMP}" || true)"
  n_pass=""
  n_fail=""
  if [[ "${results_line}" =~ Results:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed ]]; then
    n_pass="${BASH_REMATCH[1]}"
    n_fail="${BASH_REMATCH[2]}"
  fi

  # FAIL CLOSED: an absent or unparseable Results line is a FAIL, never a
  # PASS — that is the exact case a `quit(0)` planted before the first
  # assertion produces. A suite also fails if it reports zero total
  # assertions, or zero passed, even when the process exit code was 0.
  suite_ok=1
  fail_reason=""
  if [ "${rc}" -ne 0 ]; then
    suite_ok=0
    if [ -n "${n_pass}" ]; then
      fail_reason="exit ${rc} (${n_pass} passed, ${n_fail} failed)"
    else
      fail_reason="exit ${rc}, no Results line (crashed or quit before reporting)"
    fi
  elif [ -z "${n_pass}" ]; then
    suite_ok=0
    fail_reason="no '=== Results: N passed, M failed' line in output — suite exited 0 without reporting (this is the quit(0)-before-assertions case)"
  elif [ "$((n_pass + n_fail))" -eq 0 ]; then
    suite_ok=0
    fail_reason="Results line reports 0 total assertions"
  elif [ "${n_pass}" -eq 0 ]; then
    suite_ok=0
    fail_reason="Results line reports 0 passed assertions"
  fi

  if [ "${suite_ok}" -eq 1 ]; then
    results+=("PASS  ${name}  (${n_pass} passed, ${n_fail} failed)")
    total_pass=$((total_pass + n_pass))
    total_suites_ok=$((total_suites_ok + 1))
  else
    results+=("FAIL  ${name}  -- ${fail_reason}")
    if [ "${overall_rc}" -eq 0 ]; then
      if [ "${rc}" -ne 0 ]; then
        overall_rc="${rc}"
      else
        overall_rc=1
      fi
    fi
  fi
done

echo "=== Summary ==="
for line in "${results[@]}"; do
  echo "${line}"
done
echo
echo "Suites reporting real assertions: ${total_suites_ok}/${#tests[@]}"
echo "Total assertions passed: ${total_pass}"

if [ "${overall_rc}" -ne 0 ]; then
  echo
  echo "gd test suite FAILED"
else
  echo
  # ${total_suites_ok} and ${EXPECTED_SUITE_COUNT} are independent counts
  # (suites that actually reported a passing verdict, vs. suites the
  # manifest says must exist) — NOT the same variable printed over itself.
  # A tautological N/N here (the pre-fix bug) would read as 100% coverage
  # even after suites silently dropped out of the glob.
  echo "gd test suite passed (${total_suites_ok}/${EXPECTED_SUITE_COUNT} suites, ${total_pass} assertions)"
fi

exit "${overall_rc}"
