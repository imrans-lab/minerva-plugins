#!/usr/bin/env bash
# Runs ONE plugin's GDScript test suite (<plugin>/tests/gd/*.gd) using a
# Minerva checkout as the Godot host. It is the only thing that runs these
# suites: no CI job and no editor action executes them.
#
# Usage:
#   scripts/run-gd-tests.sh --plugin <id> [--preflight-only] <path-to-minerva-checkout>
#
# Each plugin ships a one-line wrapper (<plugin>/scripts/run-gd-tests.sh) that
# supplies its own --plugin, so callers and CI keep the familiar per-plugin
# entry point while there is exactly ONE implementation of the pass/fail
# contract. A copy per plugin is how the two halves of a gate drift apart
# until only one of them is still enforcing anything.
#
# EVERYTHING PLUGIN-SPECIFIC IS DATA, NOT CODE, and all of it lives under
# that plugin's tests/gd:
#   EXPECTED_SUITES         the pinned suite manifest (required)
#   KNOWN_HARNESS_DIAGNOSTICS   the fatal-diagnostic allowlist (required for
#                           execution runs)
#   REQUIRED_HOST_FILES     extra host paths the suites preload (optional)
# plus an optional <plugin>/scripts/probe-worker-methods.py, run only when the
# manifest marks a suite `real-worker`.
#
# <path-to-minerva-checkout> must be a Minerva repo checkout with a src/
# directory (godot --path <minerva>/src). It does NOT need to be a sibling
# of minerva-plugins on disk — the script computes the relative res://
# path each test's preloads expect ("res://../../minerva-plugins/...")
# from the actual location of THIS repo AND of the suite file, so it works
# for any plugin regardless of where the two checkouts sit relative to each
# other.
#
# Exit code: 0 only if every suite BOTH exited 0 AND printed a parseable
# "=== Results: N passed, M failed ===" line with N > 0. A suite's process
# exit code alone is NOT trusted as the pass/fail signal: every test in
# a plugin's tests/gd/ ends its _init() with `quit(1 if _fail > 0 else 0)`, but a
# suite that returns/quits early — an accidental early `return`, an aborted
# fixture, a `quit(0)` planted above the first assertion — exits 0 without
# running a single check() and would read as a pass on exit code alone.
# A `quit(0); return` at the top of a suite's _init() makes the exit code
# lie: zero assertions run, every one of them skipped, and the process still
# exits clean.
#
# To close that hole the runner captures each suite's stdout+stderr and, in
# addition to checking $?, parses the Results line and enforces a floor: a
# suite FAILS if the process exited non-zero, OR the Results line is absent
# (the process quit/crashed before reporting), OR it reports zero total
# assertions, OR it reports zero passed. See "How pass/fail is signalled" in
# pcb/docs/gd-tests.md for the full contract (written for pcb, true for every
# plugin this runner serves).
#
# Several suites additionally preload res://test/helpers/plugin_panel_driver.gd
# and/or res://test/helpers/panel_tool_registry_driver.gd from Minerva core,
# to drive a real PCBPanel instead of a stand-in. A stock Minerva checkout has
# both; this script does not vendor or fake them.
#
# SETUP STEP: any suite that exercises a REAL plugin subprocess start
# (PluginManager.start_plugin -> MCP STDIO transport — e.g.
# test_pcb_backend_lifecycle.gd, test_pcb_plugin_smoke.gd)
# needs the Minerva checkout's `terminal` GDExtension BUILT, i.e.
# <minerva-checkout>/src/bin/libterminal.<platform>.*.so/.dylib/.dll must
# exist (see CLAUDE.md "Building C++ Extensions" / scripts/build-extensions.sh
# in the Minerva repo). That extension registers the native `SubProcess`
# class MCPServerConnection.gd's STDIO transport requires
# (ClassDB.class_exists("SubProcess")); a checkout/scaffold without a src/bin/
# directory at all has never run build-extensions.sh and fails EVERY
# start_plugin call with "Subprocess failed to start: Unavailable" /
# "SubProcess GDExtension not available - STDIO transport not supported" —
# for every plugin. This is a scaffold-config gap, not a plugin defect:
# verified on this host by running the pcb-plugin binary directly
# (`pcb/pcb-plugin --help`) and confirming it starts fine; the failure is
# entirely on the Godot-host side of the STDIO pipe.
#
# Suite-count floor: the per-suite checks above catch a suite that runs but
# reports nothing. They do NOT catch a suite that never runs at all — the
# test list is `${GD_TEST_DIR}/test_*.gd`, a bare glob, and a deleted or
# renamed suite file simply drops out of it with nothing left to fail. Before
# anything else runs, the runner cross-checks that glob against a checked-in
# manifest (<plugin>/tests/gd/EXPECTED_SUITES) and fails fast, by name, in both
# directions: a manifest entry with no file on disk (deletion/rename), or a
# test_*.gd file with no manifest entry (addition without registration).
# Adding a suite is meant to be a deliberate one-line edit to that manifest;
# the count itself is never hardcoded here for exactly that reason — a
# hardcoded integer goes stale the moment a suite is added and gets "fixed"
# by lowering it, which is the same failure as deleting a suite, performed by
# a different hand.
#
# FALSE-GREEN HARDENING. This runner is the ONLY execution gate for this
# layer — CI stops at --preflight-only — so what it certifies has to be true.
# Three enforcement layers beyond the Results-line floor, all fail-closed:
#
#   1. FATAL DIAGNOSTICS. Every `SCRIPT ERROR:` / `ERROR: Failed to load
#      script` line in a suite's output fails that suite UNLESS the
#      diagnostic (message + its `at:` location, as one record) matches a
#      pattern in the checked-in allowlist tests/gd/KNOWN_HARNESS_DIAGNOSTICS.
#      The allowlist exists because godot --script DOUBLE-LOADS the suite:
#      the first pass runs before autoloads register, so every suite whose
#      preload chain reaches SingletonObject prints a compile-noise cascade
#      and then runs fine on the second pass. That noise is the harness's,
#      not the suite's; anything NOT on the list is treated as the suite's
#      and fails it — even when the Results line is green, which is the case
#      an exit-code-only runner certifies as passing.
#
#   2. PINNED ASSERTION COUNTS. A manifest entry may carry `assertions=N`;
#      the suite then fails unless it reports exactly N total (passed+failed).
#      The per-suite floor used to be `n_pass > 0`, which a
#      `check(true); quit(0)` at the top of _init() satisfies while every
#      real assertion silently skips. Growing a suite
#      means re-pinning — a deliberate, reviewed manifest edit, same
#      philosophy as adding the suite itself.
#
#   3. REAL-WORKER PROOF. A manifest entry may carry `real-worker`; the suite
#      then fails unless its Results line proves `real_worker_used=true`.
#      The E2E suites' worker seams fall back to canned results when the
#      binary/wrapper invocation fails, and that fallback is allowed to keep
#      the suite RUNNABLE — but it can never satisfy an E2E acceptance, so
#      the gate refuses it. The seam prints a REAL-WORKER INVOCATION FAILED
#      line with the actual worker error before falling back; read that, not
#      the green assertion count.
#
#   4. STALE-BUNDLE PRE-FLIGHT. Layer 3 catches the fallback
#      but not its most common cause — the binary running a stale worker out
#      of the INSTALLED runtime bundle instead of worker/. scripts/probe-worker-
#      methods.py diffs the two method registries and fails the whole run, by
#      method name, before the first suite launches. Execution only; skipped
#      under the sandbox seam. See the block just above the allowlist below.
#
# The first three are covered by negative self-tests: pcb/scripts/test-gd-runner.sh
# plants a compile error, a forced worker-false, an assertion-count drift, a
# mid-suite SCRIPT ERROR, an invalid allowlist regex, a duplicate manifest
# row and a duplicate attribute into sandbox suite dirs and asserts this
# script exits nonzero on each (and zero on the healthy control).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGINS_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

USAGE="usage: $0 --plugin <id> [--preflight-only] <path-to-minerva-checkout>"

PREFLIGHT_ONLY=0
PLUGIN_ID=""
declare -a positional=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --preflight-only) PREFLIGHT_ONLY=1 ;;
    --plugin)
      shift
      if [ "$#" -eq 0 ]; then
        echo "error: --plugin needs a plugin id" >&2
        echo "${USAGE}" >&2
        exit 2
      fi
      PLUGIN_ID="$1"
      ;;
    --plugin=*) PLUGIN_ID="${1#--plugin=}" ;;
    -*)
      echo "error: unknown option '$1'" >&2
      echo "${USAGE}" >&2
      exit 2
      ;;
    *) positional+=("$1") ;;
  esac
  shift
done

# The plugin id is REQUIRED and never defaulted. A default (pcb, say) would
# make a wrapper that forgot to pass its own id run someone else's suites and
# report them as its own — a green run about the wrong plugin.
if [ -z "${PLUGIN_ID}" ]; then
  echo "error: --plugin <id> is required" >&2
  echo "${USAGE}" >&2
  exit 2
fi
PLUGIN_DIR="$(cd "${PLUGINS_ROOT}/${PLUGIN_ID}" 2>/dev/null && pwd)"
if [ -z "${PLUGIN_DIR}" ]; then
  echo "error: no plugin directory ${PLUGINS_ROOT}/${PLUGIN_ID}" >&2
  exit 2
fi

# RUN_GD_TESTS_SUITE_DIR is the self-test seam (pcb/scripts/test-gd-runner.sh
# points it at a sandbox of planted-defect suites). Everything derived from
# the suite dir — glob, manifest, allowlist, host-file list — follows it;
# nothing else does.
GD_TEST_DIR="${RUN_GD_TESTS_SUITE_DIR:-${PLUGIN_DIR}/tests/gd}"

if [ "${#positional[@]}" -lt 1 ]; then
  echo "${USAGE}" >&2
  exit 2
fi

MINERVA_ARG="${positional[0]}"
MINERVA_DIR="$(cd "${MINERVA_ARG}" 2>/dev/null && pwd)"
if [ -z "${MINERVA_DIR}" ] || [ ! -d "${MINERVA_DIR}/src" ]; then
  echo "error: '${positional[0]}' does not look like a Minerva checkout (no src/ dir)" >&2
  exit 2
fi

# HOST CONTRACT — the paths the suites cannot load without. Checked HERE, in
# the script, and not only in the CI workflow. A workflow-side assertion covers
# CI and nothing else: a direct `--preflight-only` invocation would then pass a
# host that cannot load a single suite, and the two paths drift apart in the
# direction that makes the gate useless.
#
# `src/project.godot` is the only universal requirement. Anything further is
# per-plugin data: pcb's 9 relocated suites preload plugin_panel_driver.gd and
# 7 preload panel_tool_registry_driver.gd, both by res:// path against
# Minerva's res:// root, so pcb lists them in its own
# tests/gd/REQUIRED_HOST_FILES (one host-relative path per line, # comments and
# blanks ignored). A pinned SHA that drops one of those breaks the harness
# rather than the code, which is a failure worth naming precisely rather than
# discovering as "Cannot open file". A plugin whose suites need nothing beyond
# the project file simply ships no such file.
declare -a _required_host=("src/project.godot")
HOST_FILES_LIST="${GD_TEST_DIR}/REQUIRED_HOST_FILES"
if [ -f "${HOST_FILES_LIST}" ]; then
  while IFS= read -r _line; do
    _line="${_line%$'\r'}"
    [[ "${_line}" =~ ^[[:space:]]*(#|$) ]] && continue
    _required_host+=("${_line}")
  done < "${HOST_FILES_LIST}"
fi

_host_missing=()
for _required in "${_required_host[@]}"; do
  [ -f "${MINERVA_DIR}/${_required}" ] || _host_missing+=("${_required}")
done
if [ "${#_host_missing[@]}" -gt 0 ]; then
  echo "error: Minerva host at ${MINERVA_DIR} is missing required file(s):" >&2
  for _required in "${_host_missing[@]}"; do
    echo "    - ${_required}" >&2
  done
  echo "  (the suites preload these by res:// path; if you just bumped the" >&2
  echo "   pinned Minerva SHA, re-check ${HOST_FILES_LIST})" >&2
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
# python3 has two execution-path jobs: deriving each suite's res:// path (one
# derivation for default and sandbox suite dirs alike), and the E2E suites'
# own e2e_route_stdio.py worker bridge. Preflight needs neither.
if [ "${PREFLIGHT_ONLY}" -eq 0 ] && ! command -v python3 >/dev/null 2>&1; then
  echo "error: 'python3' not found on PATH" >&2
  exit 2
fi

# The tests' own preloads are hardcoded to the literal string
# "res://../../minerva-plugins/<plugin>/...", which only resolves if the
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

# An EMPTY glob is deliberately NOT special-cased here. It used to be, and it
# hid the very failure this runner exists to name: for a plugin with one
# registered suite, deleting that suite emptied the glob and the run died with
# "no test_*.gd files found in <dir>" — a true statement that names the
# directory instead of the missing suite. The manifest cross-check below
# handles the empty set like any other mismatch and reports every registered
# name that is missing from disk. A manifest with no entries is its own error,
# so an empty glob can never reach the run loop.

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

# Manifest v2 line format:  <filename> [assertions=N] [real-worker]
# The first whitespace-separated token is the suite filename (what preflight
# and the both-direction set check match on); the rest are per-suite
# enforcement attributes. Unknown attributes are a hard error — a typo'd
# `real-workr` that silently parsed as nothing would un-enforce the very
# thing the entry was written to enforce.
declare -a manifest_names=()
declare -A manifest_assertions=()
declare -A manifest_real_worker=()
# A DUPLICATE row inflates EXPECTED_SUITE_COUNT while the suite runs once:
# every suite can pass, the summary prints 50/51, and the runner still exits
# 0. Duplicate attributes would make conflicting pins "last one wins". Both
# are manifest corruption: refuse by name, exit 2.
declare -A manifest_seen=()
while IFS= read -r line; do
  case "${line}" in
    ""|"#"*) continue ;;
  esac
  read -r -a fields <<< "${line}"
  if [ "${#fields[@]}" -eq 0 ]; then
    continue  # whitespace-only line
  fi
  name="${fields[0]}"
  if [ -n "${manifest_seen[${name}]:-}" ]; then
    echo "error: ${MANIFEST}: duplicate suite entry '${name}' (a duplicate inflates the suite count while the suite runs once)" >&2
    exit 2
  fi
  manifest_seen["${name}"]=1
  manifest_names+=("${name}")
  for attr in "${fields[@]:1}"; do
    case "${attr}" in
      assertions=*)
        if [ -n "${manifest_assertions[${name}]:-}" ]; then
          echo "error: ${MANIFEST}: suite '${name}' repeats the assertions= attribute (conflicting pins must not be last-one-wins)" >&2
          exit 2
        fi
        val="${attr#assertions=}"
        if ! [[ "${val}" =~ ^[0-9]+$ ]] || [ "${val}" -eq 0 ]; then
          echo "error: ${MANIFEST}: suite '${name}' has non-positive-integer assertions pin '${attr}'" >&2
          exit 2
        fi
        manifest_assertions["${name}"]="${val}"
        ;;
      real-worker)
        if [ -n "${manifest_real_worker[${name}]:-}" ]; then
          echo "error: ${MANIFEST}: suite '${name}' repeats the real-worker attribute" >&2
          exit 2
        fi
        manifest_real_worker["${name}"]=1
        ;;
      *)
        echo "error: ${MANIFEST}: suite '${name}' has unknown attribute '${attr}'" >&2
        echo "  (known: assertions=N, real-worker)" >&2
        exit 2
        ;;
    esac
  done
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
# WHAT IT PROVES, stated narrowly because the obvious wider reading is false:
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
# CI has no business building — see the SETUP STEP note in this header.
# Without src/bin/ every suite that starts a real
# plugin subprocess fails, and scripts that reach the FFmpeg-backed
# VideoRecorder fail to COMPILE, cascading into SingletonObject and taking
# unrelated suites down with them. That is a host-scaffold gap, not a signal
# about the plugin, and running the suites there produced a red job that told
# nobody anything for five consecutive commits.
#
# So: EXECUTION IS A LOCAL GATE. Run this script without the flag on a
# developer machine with build-extensions.sh already run. See
# pcb/docs/gd-tests.md.
if [ "${PREFLIGHT_ONLY}" -eq 1 ]; then
  echo "gd pre-flight PASSED (${PLUGIN_ID}): suite-registry + host-contract compatibility only"
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

# STALE-RUNTIME-BUNDLE PRE-FLIGHT. Execution only: it needs
# the built plugin binary, which --preflight-only deliberately does without.
#
# The real-worker gate at the bottom of the loop can say a suite fell back to
# canned results; it cannot say WHY. The usual why is invisible from here: the
# binary resolves its interpreter to the INSTALLED PBS runtime bundle, whose
# site-packages carries its own worker copy that shadows the repo worker/
# tree the binary's log line names. A worker method added after that bundle was
# built answers "unknown method", every real-worker suite calling it degrades to
# canned, and a plugin reinstall does not refresh the bundle. Name the missing
# methods here instead of after a full suite run.
#
# Skipped under RUN_GD_TESTS_SUITE_DIR (the pcb/scripts/test-gd-runner.sh
# sandbox seam): those planted suites print canned Results lines and never
# reach a worker, so a stale bundle is not a fact about them.
#
# The probe itself is the plugin's, not this script's — it knows that
# plugin's binary and method registry. A plugin with real-worker suites and
# no probe is refused rather than run unprobed: the attribute is a claim
# about a live worker, and the check that the worker is the right one is not
# optional just because it was never written.
WORKER_PROBE="${PLUGIN_DIR}/scripts/probe-worker-methods.py"
if [ "${#manifest_real_worker[@]}" -gt 0 ] && [ -z "${RUN_GD_TESTS_SUITE_DIR:-}" ]; then
  if [ ! -f "${WORKER_PROBE}" ]; then
    echo "error: ${MANIFEST} marks ${#manifest_real_worker[@]} suite(s) real-worker but ${WORKER_PROBE} does not exist" >&2
    exit 2
  fi
  echo "Probing the live ${PLUGIN_ID} worker's method set (stale-bundle check)..."
  python3 "${WORKER_PROBE}"
  probe_rc=$?
  if [ "${probe_rc}" -ne 0 ]; then
    echo "error: refusing to run ${#manifest_real_worker[@]} real-worker suite(s) against this worker (see above)" >&2
    exit "${probe_rc}"
  fi
  echo
fi

# Known-harness-diagnostics allowlist (execution only — preflight executes
# nothing, so it has nothing to scan). Comments/blanks are stripped into a
# scratch copy before use: grep -v -f treats a blank line as a
# match-everything pattern, which would filter EVERY diagnostic and silently
# disarm the whole check — the exact failure mode this runner exists to
# prevent, so it is treated as a harness-config error instead.
ALLOWLIST="${GD_TEST_DIR}/KNOWN_HARNESS_DIAGNOSTICS"
if [ ! -f "${ALLOWLIST}" ]; then
  echo "error: known-harness-diagnostics allowlist not found: ${ALLOWLIST}" >&2
  echo "  (required for execution runs — every SCRIPT ERROR/failed-script-load" >&2
  echo "   diagnostic not matching it fails the suite that printed it)" >&2
  exit 2
fi
ALLOWLIST_CLEAN="$(mktemp)"
grep -Ev '^[[:space:]]*(#|$)' "${ALLOWLIST}" > "${ALLOWLIST_CLEAN}" || true
if [ ! -s "${ALLOWLIST_CLEAN}" ]; then
  echo "error: allowlist ${ALLOWLIST} has no patterns (only comments/blanks)" >&2
  rm -f "${ALLOWLIST_CLEAN}"
  exit 2
fi
# COMPILE-CHECK the patterns before anything runs.
# An invalid ERE makes the residue grep exit 2, and an unguarded scan would
# read that as "no residue" — the gate silently disarming itself on a typo is
# the exact fail-open this runner exists to prevent. grep against /dev/null:
# rc 1 = patterns valid (nothing to match), rc 2 = at least one is malformed.
grep -E -f "${ALLOWLIST_CLEAN}" /dev/null >/dev/null 2>&1
_allowlist_rc=$?
if [ "${_allowlist_rc}" -ge 2 ]; then
  echo "error: allowlist ${ALLOWLIST} contains an invalid extended regex (grep rc ${_allowlist_rc})" >&2
  echo "  (the diagnostics gate cannot run against a pattern set that does not compile)" >&2
  rm -f "${ALLOWLIST_CLEAN}"
  exit 2
fi

# Emit one "MESSAGE @@ at: LOCATION" record per fatal diagnostic in a
# captured suite log. Scope is deliberately the two fatal families the
# acceptance names — `SCRIPT ERROR:` (compile/parse/runtime script errors)
# and `ERROR: Failed to load script` — NOT every `ERROR:` engine line
# (headless runs legitimately print Node-not-found/socket noise that is not
# a script-layer verdict). The `at:` line that follows a diagnostic is glued
# onto the record so the allowlist can pin a message to a location instead
# of blessing it everywhere.
_fatal_diagnostics() {
  awk '
    /^SCRIPT ERROR: / || /^ERROR: Failed to load script / {
      if (pending != "") print pending " @@ "
      pending = $0
      next
    }
    /^[ \t]+at: / {
      if (pending != "") {
        loc = $0
        sub(/^[ \t]+/, "", loc)
        print pending " @@ " loc
        pending = ""
      }
      next
    }
    {
      if (pending != "") {
        print pending " @@ "
        pending = ""
      }
    }
    END { if (pending != "") print pending " @@ " }
  ' "$1"
}

overall_rc=0
declare -a results=()
total_pass=0
total_suites_ok=0

# Scratch file for capturing one suite's combined stdout+stderr so the
# Results line can be parsed after the process exits. Reused across
# iterations; cleaned up on any exit path.
RESULTS_TMP="$(mktemp)"
trap 'rm -f "${RESULTS_TMP}" "${ALLOWLIST_CLEAN}"' EXIT

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

echo "Running ${#tests[@]} ${PLUGIN_ID} GDScript test(s) via Minerva host at ${MINERVA_DIR}"
echo

for test_path in "${tests[@]}"; do
  name="$(basename "${test_path}")"
  # res:// path derived from where the suite file actually is, relative to
  # the host's res:// root — ONE derivation for the default dir (yields the
  # exact "res://../../minerva-plugins/..." string the suites' own preloads
  # hardcode, given the sibling check above) and for a self-test sandbox
  # alike. Two hand-maintained path strings that must agree is how the
  # preflight/CI drift documented at the HOST CONTRACT note happened.
  res_script="res://$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${test_path}" "${MINERVA_DIR}/src")"
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
  elif [ "${n_fail}" -ne 0 ]; then
    # The Results line is the documented truth, not the exit code: a suite
    # that reports failures and still exits 0 has failed.
    suite_ok=0
    fail_reason="Results line reports ${n_fail} failed assertions despite exit 0"
  fi

  # Pinned assertion count (manifest `assertions=N`): reported total must
  # equal the pin exactly. `quit(0)` planted after one early check, or a
  # silently skipped test block, reads exactly like a shrunken total with a
  # green exit — the pre-pin floor (`n_pass > 0`) blessed both.
  if [ "${suite_ok}" -eq 1 ] && [ -n "${manifest_assertions[${name}]:-}" ]; then
    pinned="${manifest_assertions[${name}]}"
    reported_total=$((n_pass + n_fail))
    if [ "${reported_total}" -ne "${pinned}" ]; then
      suite_ok=0
      fail_reason="assertion count drifted: reported ${reported_total} total, manifest pins ${pinned} — if the suite legitimately grew or shrank, re-pin in EXPECTED_SUITES (deliberate own-commit); otherwise assertions are being skipped"
    fi
  fi

  # Real-worker proof (manifest `real-worker`): the Results line must carry
  # real_worker_used=true. =false or an absent field means the suite ran its
  # canned subprocess-boundary fake — fine for keeping the suite runnable,
  # never fine as E2E evidence. The seam prints REAL-WORKER INVOCATION
  # FAILED with the worker's actual error before falling back; that line in
  # the log above is the thing to fix.
  if [ "${suite_ok}" -eq 1 ] && [ -n "${manifest_real_worker[${name}]:-}" ]; then
    if [[ "${results_line}" != *"real_worker_used=true"* ]]; then
      suite_ok=0
      fail_reason="real-worker-required suite did not prove real_worker_used=true (Results line: '${results_line}') — canned fallback cannot satisfy an E2E acceptance; see the REAL-WORKER INVOCATION FAILED line in the output above"
    fi
  fi

  # Fatal diagnostics not on the known-harness allowlist fail the suite even
  # when everything above was green: SCRIPT ERROR lines and failed script
  # loads can fill the log while the assertion tally still reads 47/47.
  if [ "${suite_ok}" -eq 1 ]; then
    # grep's rc is consulted, never discarded — 0 = residue survived the
    # filter, 1 = every diagnostic matched the allowlist, >=2 = the scan
    # itself failed, which is a harness error and FAILS the suite (fail
    # closed) rather than reading as an empty residue.
    diag_residue="$(_fatal_diagnostics "${RESULTS_TMP}" | grep -Ev -f "${ALLOWLIST_CLEAN}")"
    diag_rc=$?
    if [ "${diag_rc}" -ge 2 ]; then
      suite_ok=0
      fail_reason="fatal-diagnostics scan itself failed (grep rc ${diag_rc}) — a gate that cannot run is not a gate that passed"
    elif [ -n "${diag_residue}" ]; then
      suite_ok=0
      fail_reason="fatal Godot diagnostics not on the known-harness allowlist (${ALLOWLIST}):"
      echo "!!! ${name}: unexplained fatal diagnostics:" >&2
      while IFS= read -r diag_line; do
        echo "      ${diag_line}" >&2
      done <<< "${diag_residue}"
      echo "    If (and only if) a diagnostic is provably the harness's and not" >&2
      echo "    the suite's, allowlist it in ${ALLOWLIST} with a dated comment." >&2
    fi
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
