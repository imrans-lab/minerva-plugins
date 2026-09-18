#!/usr/bin/env bash
# STRICT contract-guard runner — the ONE entrypoint a consuming host's CI calls
# to prove that this minerva-plugins revision still honours the host contract.
#
#   scripts/run-contract-guards.sh \
#       --minerva /path/to/Minerva --godot /path/to/godot \
#       --plugin-rev <sha of this checkout> --out /path/to/artifacts \
#       [--plugins "cad pcb"] [--timeout 900]
#
# WHY IT IS NOT scripts/run-gd-tests.sh. That script is the developer/nightly
# runner for ALL of one plugin's suites, and it is deliberately forgiving in
# ways a gate must not be: it swallows `--import` failures with `|| true`, it
# runs in the developer's own user:// profile, and a guard whose worker binary
# is missing prints `SKIP:` and still reports a green Results line. Every one
# of those is a FALSE GREEN here, so every one of them is a failure below.
#
# WHAT THE GUARDS EXERCISE. Each selected plugin's tests/gd/test_contract_guard.gd
# drives SIX domain-defined cases (empty / small-happy / small-unhappy /
# large-happy / large-unhappy / large-error-reply) through the REAL current
# host: a real PluginManager, the real PluginScenePanelBroker, the plugin's
# real panel scene, and the plugin's real worker subprocess over stdio. There
# is no double anywhere between an assertion and the subprocess, which is why
# this runner needs a real Minerva checkout with its native extensions BUILT
# (`SubProcess` comes from the terminal GDExtension; without it every
# start_plugin fails and the guard cannot mount) and why it builds each
# worker from source before running.
#
# DEPENDENCIES, as the selected guards actually require them:
#   cad      Go >=1.22 and Python >=3.12 (manifest builds cad-plugin and an
#            editable venv under cad/worker/.venv for the OCCT worker)
#   pcb      Go >=1.22 (pcb-plugin; its Python worker ships in-tree)
#   council  Go >=1.22 (council-plugin)
#   drive    Rust/cargo >=1.70 (drive-plugin, built --release --locked)
#   always   git, python3 (arg-free helper scripts), coreutils `timeout`,
#            sha256sum, and a Godot 4.6.x binary passed as --godot.
# Nothing is downloaded and Minerva is never built: an incomplete --minerva
# fails closed instead.
#
# ISOLATED USER DATA. Every run points Godot's user:// at a fresh scratch dir
# under --out (`<out>/userdata`) by exporting XDG_DATA_HOME, XDG_CONFIG_HOME
# and XDG_CACHE_HOME, so the plugin DB, policy.json, drive state and anything
# else written to user:// never touch the developer's profile.
#   * Linux (the target platform, verified here): Godot's data/config/cache
#     paths honour those three XDG variables, so user:// resolves to
#     <out>/userdata/godot/app_userdata/Minerva.
#   * macOS and Windows are UNVERIFIED and almost certainly NOT isolated by
#     this mechanism: Godot resolves user:// through ~/Library/Application
#     Support and %APPDATA% respectively, neither of which reads XDG_*. This
#     runner therefore ALSO fingerprints the developer's real user-data
#     directory before and after the run and fails if a single byte-size,
#     mtime or path changed — that check is platform-independent and is what
#     actually enforces the isolation claim.
#
# EXACT INVOCATION for a consuming host's functional CI job, from a workspace
# that already holds the two checkouts SIDE BY SIDE and has built Minerva's
# native extensions:
#
#   minerva-plugins/scripts/run-contract-guards.sh \
#     --minerva  "${GITHUB_WORKSPACE}/Minerva" \
#     --godot    "${GODOT_BIN}" \
#     --plugin-rev "$(git -C minerva-plugins rev-parse HEAD)" \
#     --plugins  "cad council drive pcb" \
#     --timeout  900 \
#     --out      "${GITHUB_WORKSPACE}/contract-guard-artifacts"
#
# Drop --plugins to run every guard in the repo (the same four today); keep it
# to pin the set a given job promises to run, so a guard that stops being
# discovered fails the job instead of quietly shrinking it. Archive --out:
# summary.json is the machine-readable verdict and logs/ holds each guard's
# full output.
#
# EXIT CODES: 0 = every selected guard passed. 1 = a guard failed. 2 = a
# harness/environment problem (bad arguments, missing extensions, layout
# mismatch, failed build, corrupt manifest) — a gate that could not run is
# never reported as a gate that passed.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CONTRACT_GUARDS_PLUGINS_ROOT is the self-test seam ONLY
# (scripts/test-contract-runner.sh points it at a sandbox of fake plugins with
# a fake godot). Real callers never set it.
PLUGINS_ROOT="$(cd "${CONTRACT_GUARDS_PLUGINS_ROOT:-${SCRIPT_DIR}/..}" && pwd)"

# The pass/fail contract shared with scripts/run-gd-tests.sh: EXPECTED_SUITES
# parsing, the diagnostics allowlist cleaner, the fatal-diagnostic extractor
# and the Results-line parser. One copy, two runners.
# shellcheck source=lib/gd_test_contract.sh
. "${SCRIPT_DIR}/lib/gd_test_contract.sh"

GUARD_REL="tests/gd/test_contract_guard.gd"
GUARD_NAME="test_contract_guard.gd"
LOG_CAP_BYTES=$((5 * 1024 * 1024))

USAGE="usage: $0 --minerva <path> --godot <path> --plugin-rev <sha> --out <dir> [--plugins \"<ids>\"] [--timeout <sec>]"

MINERVA_ARG=""
GODOT_BIN=""
PLUGIN_REV=""
OUT_ARG=""
PLUGIN_SELECTION=""
SUITE_TIMEOUT=900

die() { echo "error: $*" >&2; exit 2; }

need_value() {
  [ "$2" -gt 0 ] || die "$1 needs a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --minerva) shift; need_value --minerva "$#"; MINERVA_ARG="$1" ;;
    --minerva=*) MINERVA_ARG="${1#--minerva=}" ;;
    --godot) shift; need_value --godot "$#"; GODOT_BIN="$1" ;;
    --godot=*) GODOT_BIN="${1#--godot=}" ;;
    --plugin-rev) shift; need_value --plugin-rev "$#"; PLUGIN_REV="$1" ;;
    --plugin-rev=*) PLUGIN_REV="${1#--plugin-rev=}" ;;
    --plugins) shift; need_value --plugins "$#"; PLUGIN_SELECTION="$1" ;;
    --plugins=*) PLUGIN_SELECTION="${1#--plugins=}" ;;
    --timeout) shift; need_value --timeout "$#"; SUITE_TIMEOUT="$1" ;;
    --timeout=*) SUITE_TIMEOUT="${1#--timeout=}" ;;
    --out) shift; need_value --out "$#"; OUT_ARG="$1" ;;
    --out=*) OUT_ARG="${1#--out=}" ;;
    -h|--help) echo "${USAGE}"; exit 0 ;;
    *) echo "${USAGE}" >&2; die "unknown argument '$1'" ;;
  esac
  shift
done

[ -n "${MINERVA_ARG}" ] || { echo "${USAGE}" >&2; die "--minerva is required"; }
[ -n "${GODOT_BIN}" ] || { echo "${USAGE}" >&2; die "--godot is required"; }
[ -n "${PLUGIN_REV}" ] || { echo "${USAGE}" >&2; die "--plugin-rev is required"; }
[ -n "${OUT_ARG}" ] || { echo "${USAGE}" >&2; die "--out is required"; }
[[ "${SUITE_TIMEOUT}" =~ ^[0-9]+$ ]] && [ "${SUITE_TIMEOUT}" -gt 0 ] \
  || die "--timeout must be a positive integer number of seconds (got '${SUITE_TIMEOUT}')"

# ---------------------------------------------------------------------------
# 1. The plugins checkout IS the revision under test
# ---------------------------------------------------------------------------
# A CI job that builds rev A and runs the suites of rev B reports a verdict
# about neither, so the caller must name the rev and it must match.
HEAD_REV="$(git -C "${PLUGINS_ROOT}" rev-parse HEAD 2>/dev/null)" \
  || die "${PLUGINS_ROOT} is not a git checkout — cannot prove which revision is under test"
if [ "${HEAD_REV}" != "${PLUGIN_REV}" ]; then
  # Accept an unambiguous short sha, refuse anything else.
  case "${HEAD_REV}" in
    "${PLUGIN_REV}"*) : ;;
    *) die "--plugin-rev ${PLUGIN_REV} is not the checkout under test (${PLUGINS_ROOT} HEAD is ${HEAD_REV})" ;;
  esac
fi
PLUGINS_DIRTY=false
if [ -n "$(git -C "${PLUGINS_ROOT}" status --porcelain 2>/dev/null)" ]; then
  PLUGINS_DIRTY=true
fi

# ---------------------------------------------------------------------------
# 2. The Minerva checkout is real, complete and PRE-BUILT
# ---------------------------------------------------------------------------
MINERVA_DIR="$(cd "${MINERVA_ARG}" 2>/dev/null && pwd)" \
  || die "--minerva '${MINERVA_ARG}' does not exist"
[ -f "${MINERVA_DIR}/src/project.godot" ] \
  || die "--minerva '${MINERVA_DIR}' has no src/project.godot — not a Minerva checkout (this runner never clones or builds Minerva)"

# Native extensions. The guards mount a REAL plugin subprocess, which needs the
# native `SubProcess` class from the terminal GDExtension; without the built
# library every start_plugin fails with "SubProcess GDExtension not available"
# and the guard degrades to a skip. The library list is read from the
# .gdextension files themselves rather than hardcoded, so a new extension is
# covered the day it is added. Platform tag: Godot's headless EDITOR binary
# (what --script runs under) loads the `<os>.editor.<arch>` entries.
case "$(uname -s)" in
  Linux) EXT_OS="linux" ;;
  Darwin) EXT_OS="macos" ;;
  *) EXT_OS="windows" ;;
esac
EXT_ARCH="$(uname -m)"
missing_libs=()
checked_libs=0
while IFS= read -r gdext; do
  while IFS= read -r res_path; do
    rel="${res_path#res://}"
    checked_libs=$((checked_libs + 1))
    [ -e "${MINERVA_DIR}/src/${rel}" ] || missing_libs+=("${MINERVA_DIR}/src/${rel}  (from ${gdext})")
  done < <(grep -E "^[[:space:]]*${EXT_OS}\.editor(\.${EXT_ARCH})?[[:space:]]*=" "${gdext}" \
             | sed -E 's/.*"(res:\/\/[^"]+)".*/\1/' | sort -u)
done < <(find "${MINERVA_DIR}/src/gdextension" -name '*.gdextension' 2>/dev/null | sort)

if [ "${checked_libs}" -eq 0 ]; then
  die "no ${EXT_OS}.editor entries found under ${MINERVA_DIR}/src/gdextension — cannot verify that the native extensions are built, and an unverifiable precondition is a failed one"
fi
if [ "${#missing_libs[@]}" -gt 0 ]; then
  echo "error: --minerva '${MINERVA_DIR}' has UNBUILT native extensions:" >&2
  for lib in "${missing_libs[@]}"; do echo "  missing: ${lib}" >&2; done
  echo "  Build them in the Minerva checkout (scripts/build-extensions.sh) and re-run." >&2
  echo "  Without them the guards cannot start a real plugin subprocess and would skip." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 3. SIBLING LAYOUT — the guards' preloads are absolute-by-convention
# ---------------------------------------------------------------------------
# Every guard preloads "res://../../minerva-plugins/<plugin>/..." literally, so
# <minerva>/../minerva-plugins MUST be this checkout. Nothing is symlinked or
# copied to make that true: a runner that quietly repairs the layout is a
# runner that can test a different tree than the caller believes.
SIBLING_EXPECT="$(cd "${MINERVA_DIR}/.." 2>/dev/null && pwd)/minerva-plugins"
SIBLING_REAL="$(cd "${SIBLING_EXPECT}" 2>/dev/null && pwd || true)"
if [ "${SIBLING_REAL}" != "${PLUGINS_ROOT}" ]; then
  echo "error: sibling-layout mismatch — the guards preload res://../../minerva-plugins/..." >&2
  echo "  <minerva>/../minerva-plugins resolves to: ${SIBLING_REAL:-<nonexistent> ${SIBLING_EXPECT}}" >&2
  echo "  the checkout under test is:               ${PLUGINS_ROOT}" >&2
  echo "  Place the two checkouts side by side; this runner will not symlink or copy them into place." >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 4. Plugin selection
# ---------------------------------------------------------------------------
declare -a PLUGINS=()
if [ -n "${PLUGIN_SELECTION}" ]; then
  # shellcheck disable=SC2206
  PLUGINS=(${PLUGIN_SELECTION//,/ })
  for plugin in "${PLUGINS[@]}"; do
    [ -f "${PLUGINS_ROOT}/${plugin}/${GUARD_REL}" ] \
      || die "--plugins names '${plugin}', which has no ${GUARD_REL}"
  done
else
  while IFS= read -r guard_path; do
    PLUGINS+=("$(basename "$(dirname "$(dirname "$(dirname "${guard_path}")")")")")
  done < <(find "${PLUGINS_ROOT}" -mindepth 4 -maxdepth 4 -path "*/${GUARD_REL}" | sort)
fi
[ "${#PLUGINS[@]}" -gt 0 ] || die "no plugin under ${PLUGINS_ROOT} has ${GUARD_REL}"

# ---------------------------------------------------------------------------
# 5. Output tree and ISOLATED user data
# ---------------------------------------------------------------------------
mkdir -p "${OUT_ARG}" || die "cannot create --out '${OUT_ARG}'"
OUT_DIR="$(cd "${OUT_ARG}" && pwd)"
LOG_DIR="${OUT_DIR}/logs"
USER_DATA="${OUT_DIR}/userdata"
rm -rf "${USER_DATA}"
mkdir -p "${LOG_DIR}" "${USER_DATA}/data" "${USER_DATA}/config" "${USER_DATA}/cache"

# The developer profile this run must NOT touch, fingerprinted by metadata
# only (path, size, mtime) so the check costs a stat walk rather than a read.
REAL_DATA_HOME="${XDG_DATA_HOME:-${HOME:-/nonexistent}/.local/share}"
REAL_USER_DATA="${REAL_DATA_HOME}/godot/app_userdata/Minerva"
PROFILE_BEFORE="${OUT_DIR}/profile-before.txt"
PROFILE_AFTER="${OUT_DIR}/profile-after.txt"
fingerprint_profile() {
  if [ -d "${REAL_USER_DATA}" ]; then
    find "${REAL_USER_DATA}" -printf '%P\t%s\t%T@\n' 2>/dev/null | LC_ALL=C sort
  else
    echo "<absent>"
  fi
}
fingerprint_profile > "${PROFILE_BEFORE}"

# ---------------------------------------------------------------------------
# 6. Read every pin BEFORE building anything
# ---------------------------------------------------------------------------
# EXPECTED_SUITES is the single source of truth for the pinned assertion count;
# this runner adds no second manifest. A guard with no pin is a guard whose
# shrinking cannot be detected, so an unpinned guard is refused here.
declare -A PINNED=()
declare -A ALLOWLIST_OF=()
declare -a ALLOWLIST_TMPS=()
for plugin in "${PLUGINS[@]}"; do
  gd_manifest_parse "${PLUGINS_ROOT}/${plugin}/tests/gd/EXPECTED_SUITES"
  pin="${manifest_assertions[${GUARD_NAME}]:-}"
  [ -n "${pin}" ] \
    || die "${plugin}/tests/gd/EXPECTED_SUITES has no 'assertions=N' pin for ${GUARD_NAME} — an unpinned guard cannot prove it did not shrink"
  PINNED["${plugin}"]="${pin}"
  clean="$(mktemp)"
  ALLOWLIST_TMPS+=("${clean}")
  gd_allowlist_clean "${PLUGINS_ROOT}/${plugin}/tests/gd/KNOWN_HARNESS_DIAGNOSTICS" "${clean}"
  ALLOWLIST_OF["${plugin}"]="${clean}"
done
trap 'rm -f "${ALLOWLIST_TMPS[@]}"' EXIT

GODOT_VERSION="$("${GODOT_BIN}" --version 2>/dev/null | tail -n1)" \
  || die "--godot '${GODOT_BIN}' did not answer --version"
[ -n "${GODOT_VERSION}" ] || die "--godot '${GODOT_BIN}' printed no version"
MINERVA_REV="$(git -C "${MINERVA_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
MINERVA_DIRTY=false
if [ -n "$(git -C "${MINERVA_DIR}" status --porcelain 2>/dev/null)" ]; then
  MINERVA_DIRTY=true
fi

echo "contract guards: ${PLUGINS[*]}"
echo "  plugins  ${PLUGINS_ROOT} @ ${HEAD_REV} (dirty=${PLUGINS_DIRTY})"
echo "  host     ${MINERVA_DIR} @ ${MINERVA_REV} (dirty=${MINERVA_DIRTY})"
echo "  godot    ${GODOT_BIN} — ${GODOT_VERSION}"
echo "  user://  ${USER_DATA}/data/godot/app_userdata/Minerva (isolated)"
echo

# ---------------------------------------------------------------------------
# 7. Build each selected worker FROM THIS REVISION
# ---------------------------------------------------------------------------
# Only the selected plugins are built: a run of --plugins pcb must not spend
# fifteen minutes on cad's OCCT venv, and must not silently refresh a binary
# whose guard is not being run.
declare -A BINARY_SHA=()
for plugin in "${PLUGINS[@]}"; do
  plugin_dir="${PLUGINS_ROOT}/${plugin}"
  echo "=== building ${plugin} from its manifest's setup steps ==="
  python3 "${SCRIPT_DIR}/build_plugin_from_manifest.py" "${plugin_dir}" \
    > "${LOG_DIR}/${plugin}-build.json" 2> >(tee "${LOG_DIR}/${plugin}-build.log" >&2) \
    || die "${plugin}: build failed (see ${LOG_DIR}/${plugin}-build.log)"
  binary="${plugin_dir}/${plugin}-plugin"
  [ -x "${binary}" ] || binary="${binary}.exe"
  [ -x "${binary}" ] \
    || die "${plugin}: no executable ${plugin_dir}/${plugin}-plugin after the build — the guard would SKIP, which this runner reports as a failure, so it refuses to start"
  BINARY_SHA["${plugin}"]="$(sha256sum "${binary}" | cut -d' ' -f1)"
  echo "    ${binary}  sha256=${BINARY_SHA[${plugin}]}"
  echo
done

# Godot, and only Godot, runs with the isolated profile. The exports land here
# rather than before the builds because cargo and go read XDG_CACHE_HOME for
# their build caches, and a per-run cache would mean a cold rebuild every time.
export XDG_DATA_HOME="${USER_DATA}/data"
export XDG_CONFIG_HOME="${USER_DATA}/config"
export XDG_CACHE_HOME="${USER_DATA}/cache"

# ---------------------------------------------------------------------------
# 8. Import the host project ONCE — and FAIL if it fails
# ---------------------------------------------------------------------------
# Godot resolves class_name globals through .godot/global_script_class_cache.cfg,
# which is generated on import and not tracked in git. run-gd-tests.sh swallows
# this step's exit code; here a failed import means every suite afterwards is
# testing a half-loaded project, so it is fatal.
echo "=== importing host project (${MINERVA_DIR}/src) ==="
if ! "${GODOT_BIN}" --headless --path "${MINERVA_DIR}/src" --import > "${LOG_DIR}/import.log" 2>&1; then
  echo "error: godot --import exited nonzero (see ${LOG_DIR}/import.log)" >&2
  tail -n 40 "${LOG_DIR}/import.log" >&2
  exit 2
fi
echo

# ---------------------------------------------------------------------------
# 9. Run the guards
# ---------------------------------------------------------------------------
RECORDS="$(mktemp)"
ALLOWLIST_TMPS+=("${RECORDS}")
overall_rc=0

for plugin in "${PLUGINS[@]}"; do
  plugin_dir="${PLUGINS_ROOT}/${plugin}"
  guard_path="${plugin_dir}/${GUARD_REL}"
  log="${LOG_DIR}/${plugin}-contract-guard.log"
  # ONE derivation of the res:// path, from where the suite actually is
  # relative to the host's res:// root. Given the sibling check above this
  # yields exactly the "res://../../minerva-plugins/..." string the guard's own
  # preloads hardcode.
  res_script="res://$(python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' "${guard_path}" "${MINERVA_DIR}/src")"

  # The guards locate their worker from MINERVA_<ID>_PLUGIN_DIR, falling back
  # to $HOME/github/minerva-plugins/<id> — the author's own layout. Exporting
  # it is what makes the guard exercise the binary THIS runner just built from
  # --plugin-rev rather than whatever is installed in the developer's home.
  plugin_env_var="MINERVA_$(echo "${plugin}" | tr '[:lower:]-' '[:upper:]_')_PLUGIN_DIR"

  echo "=== ${plugin} contract guard (pin ${PINNED[${plugin}]} assertions, timeout ${SUITE_TIMEOUT}s) ==="
  started="$(date +%s)"
  env "${plugin_env_var}=${plugin_dir}" \
    timeout --kill-after=15 "${SUITE_TIMEOUT}" \
    "${GODOT_BIN}" --headless --path "${MINERVA_DIR}/src" --script "${res_script}" 2>&1 \
    | tee "${log}"
  rc="${PIPESTATUS[0]}"
  duration=$(( $(date +%s) - started ))

  # Bound the kept log; a runaway suite must not fill the artifact store.
  log_bytes="$(wc -c < "${log}")"
  if [ "${log_bytes}" -gt "${LOG_CAP_BYTES}" ]; then
    head -c "${LOG_CAP_BYTES}" "${log}" > "${log}.trunc"
    printf '\n*** TRUNCATED: %s bytes of output, capped at %s ***\n' "${log_bytes}" "${LOG_CAP_BYTES}" >> "${log}.trunc"
    mv "${log}.trunc" "${log}"
  fi

  gd_results_parse "${log}"
  results_line="${GD_RESULTS_LINE}"
  n_pass="${GD_N_PASS}"
  n_fail="${GD_N_FAIL}"
  total=0
  [ -n "${n_pass}" ] && total=$((n_pass + n_fail))

  ok=1
  reason=""
  if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
    ok=0
    reason="timed out after ${SUITE_TIMEOUT}s (exit ${rc})"
  elif [ "${rc}" -ne 0 ]; then
    ok=0
    reason="godot exited ${rc}"
  fi

  # A guard that reports a missing worker, or a chain that did not mount, has
  # asserted NOTHING about the contract. run-gd-tests.sh lets those cases
  # through with a green Results line; here they are the loudest failure there
  # is, because "the gate did not run" is the false green this runner exists
  # to remove.
  if [ "${ok}" -eq 1 ] && grep -qE '^(SKIP:|[[:space:]]*SETUP FAILED)' "${log}"; then
    ok=0
    reason="the guard skipped or failed setup: $(grep -m1 -E '^(SKIP:|[[:space:]]*SETUP FAILED)' "${log}")"
  fi

  if [ "${ok}" -eq 1 ] && [ -z "${n_pass}" ]; then
    ok=0
    reason="no '=== Results: N passed, M failed' line — the guard quit or crashed before reporting"
  elif [ "${ok}" -eq 1 ] && [ "${n_fail}" -ne 0 ]; then
    ok=0
    reason="${n_fail} failed assertion(s)"
  elif [ "${ok}" -eq 1 ] && [ "${total}" -ne "${PINNED[${plugin}]}" ]; then
    ok=0
    reason="assertion count drifted: reported ${total}, ${plugin}/tests/gd/EXPECTED_SUITES pins ${PINNED[${plugin}]} — re-pin there in a deliberate commit if the guard legitimately changed, otherwise assertions are being skipped"
  fi

  # Fatal Godot diagnostics. DEVIATION, stated plainly: this is NOT "any
  # SCRIPT ERROR / Compilation failed line fails the run". `godot --script`
  # double-loads the suite and the first pass runs before autoloads register,
  # so EVERY healthy guard prints a compile-noise cascade ("Identifier not
  # found: SingletonObject", "Compilation failed"). Failing on the raw strings
  # would red every green run. The rule enforced instead is the strictly
  # stronger one the plugins already carry: a diagnostic fails the guard
  # unless it matches that plugin's checked-in
  # tests/gd/KNOWN_HARNESS_DIAGNOSTICS allowlist, which pins each known
  # harness message to the location that may emit it.
  if [ "${ok}" -eq 1 ]; then
    residue="$(gd_fatal_diagnostics "${log}" | grep -Ev -f "${ALLOWLIST_OF[${plugin}]}")"
    diag_rc=$?
    if [ "${diag_rc}" -ge 2 ]; then
      ok=0
      reason="fatal-diagnostics scan itself failed (grep rc ${diag_rc}) — a gate that cannot run is not a gate that passed"
    elif [ -n "${residue}" ]; then
      ok=0
      reason="fatal Godot diagnostics not on ${plugin}/tests/gd/KNOWN_HARNESS_DIAGNOSTICS"
      echo "!!! ${plugin}: unexplained fatal diagnostics:" >&2
      while IFS= read -r diag_line; do echo "      ${diag_line}" >&2; done <<< "${residue}"
    fi
  fi

  [ "${ok}" -eq 1 ] || overall_rc=1
  # A tab is IFS whitespace, so `read` COLLAPSES an empty field: the reader
  # below would silently shift every column left on a passing row. "-" stands
  # in for the empty reason for exactly that reason.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "${plugin}" "$([ "${ok}" -eq 1 ] && echo PASS || echo FAIL)" "${reason:--}" \
    "${BINARY_SHA[${plugin}]}" "${rc}" "${n_pass:--}" "${n_fail:--}" \
    "${PINNED[${plugin}]}" "${duration}" "${results_line}" >> "${RECORDS}"
  echo "--- ${plugin}: $([ "${ok}" -eq 1 ] && echo PASS || echo "FAIL — ${reason}") (${duration}s) ---"
  echo
done

# ---------------------------------------------------------------------------
# 10. The developer's profile must be byte-identical
# ---------------------------------------------------------------------------
fingerprint_profile > "${PROFILE_AFTER}"
if ! diff -q "${PROFILE_BEFORE}" "${PROFILE_AFTER}" >/dev/null; then
  echo "error: this run modified the real user-data directory ${REAL_USER_DATA}:" >&2
  diff "${PROFILE_BEFORE}" "${PROFILE_AFTER}" | head -n 20 >&2
  echo "  user:// isolation did not hold (or a Minerva instance was running alongside this run)." >&2
  overall_rc=2
fi

# ---------------------------------------------------------------------------
# 11. Record
# ---------------------------------------------------------------------------
SUMMARY="${OUT_DIR}/summary.json"
MINERVA_DIR="${MINERVA_DIR}" MINERVA_REV="${MINERVA_REV}" MINERVA_DIRTY="${MINERVA_DIRTY}" \
PLUGINS_ROOT="${PLUGINS_ROOT}" HEAD_REV="${HEAD_REV}" PLUGINS_DIRTY="${PLUGINS_DIRTY}" \
GODOT_BIN="${GODOT_BIN}" GODOT_VERSION="${GODOT_VERSION}" LOG_DIR="${LOG_DIR}" \
OVERALL_RC="${overall_rc}" USER_DATA_ROOT="${XDG_DATA_HOME}" REAL_USER_DATA="${REAL_USER_DATA}" \
python3 -c '
import json, os, sys
rows = []
for line in open(sys.argv[1], encoding="utf-8"):
    p, verdict, reason, sha, rc, npass, nfail, pin, secs, results = line.rstrip("\n").split("\t")
    rows.append({
        "plugin": p, "verdict": verdict, "reason": "" if reason == "-" else reason,
        "binary_sha256": sha, "exit": int(rc),
        "passed": int(npass) if npass.isdigit() else None,
        "failed": int(nfail) if nfail.isdigit() else None,
        "pinned": int(pin), "duration_s": int(secs),
        "results_line": results,
        "log": os.path.join(os.environ["LOG_DIR"], p + "-contract-guard.log"),
    })
json.dump({
    "host": {"path": os.environ["MINERVA_DIR"], "revision": os.environ["MINERVA_REV"],
             "dirty": os.environ["MINERVA_DIRTY"] == "true"},
    "plugins": {"path": os.environ["PLUGINS_ROOT"], "revision": os.environ["HEAD_REV"],
                "dirty": os.environ["PLUGINS_DIRTY"] == "true"},
    "godot": {"binary": os.environ["GODOT_BIN"], "version": os.environ["GODOT_VERSION"]},
    "user_data": {"isolated_root": os.environ["USER_DATA_ROOT"],
                  "developer_profile": os.environ["REAL_USER_DATA"]},
    "exit_code": int(os.environ["OVERALL_RC"]),
    "guards": rows,
}, open(sys.argv[2], "w"), indent=2)
' "${RECORDS}" "${SUMMARY}"

echo "================ contract guards ================"
while IFS=$'\t' read -r plugin verdict reason sha rc npass nfail pin secs _results; do
  total="?"
  [ "${npass}" = "-" ] || total=$((npass + nfail))
  printf '%-8s %-4s %s/%s assertions (%s failed), exit %s, %ss, worker %s\n' \
    "${plugin}" "${verdict}" "${total}" "${pin}" "${nfail}" "${rc}" "${secs}" "${sha:0:12}"
  [ "${reason}" = "-" ] || printf '       %s\n' "${reason}"
done < "${RECORDS}"
echo "summary: ${SUMMARY}"
echo "logs:    ${LOG_DIR}"
echo "verdict: $([ "${overall_rc}" -eq 0 ] && echo "ALL GUARDS PASSED" || echo "FAILED (exit ${overall_rc})")"
exit "${overall_rc}"
