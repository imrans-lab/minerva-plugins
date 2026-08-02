#!/usr/bin/env bash
# HERMETIC FABRICATION-GATE REHEARSAL (C9, docket 019fc13019e6).
#
# Dry run of "does this repo, compiled from a CLEAN checkout, produce a
# COMPLETE and DETERMINISTIC fabrication package?" — the question a real
# fab-gate has to answer before a board is ever sent to a house. This script
# answers it by compiling the SAME board TWICE, each time from a throwaway
# `git worktree` at HEAD (no dirty working tree, no stale __pycache__, no
# .pcbskel sidecar), and comparing the two output trees byte-for-byte.
#
# Usage:
#   pcb/scripts/hermetic-fab-check.sh [board_path]
#
#   board_path   Optional. Defaults to the synthetic full-feature fixture
#                (pcb/worker/tests/testdata/zone_fill.yaml — pours + a
#                keepout + named refs [-> silk designators, automatic on any
#                compiled board] + assembly-identity-clean components
#                [value+mpn], i.e. every v1 fab output in one board; see that
#                file's header for why it — not a fourth new fixture — was
#                extended for this).
#                A RELATIVE path is resolved inside the hermetic worktree
#                (i.e. must be a path that is actually COMMITTED at HEAD —
#                the whole point of the rehearsal is "what HEAD produces",
#                not "what my working tree happens to contain right now").
#                An ABSOLUTE path is read from disk AS GIVEN, untouched by
#                the worktree step — this is how the OWNER runs this same
#                script against their PRIVATE canonical product board, which
#                per POLICY.md must never enter this repo:
#
#                  pcb/scripts/hermetic-fab-check.sh \
#                      ~/gitlab/ccsandbox/smart-remote/EDA/minerva-fab/smart-remote-canonical.yaml
#
#                Nothing about the private board's content, name, or path is
#                written back into this repo by the script (no golden files,
#                no fixture copy) — only the two throwaway output trees,
#                which are cleaned up on exit unless HERMETIC_FAB_KEEP_TMP=1.
#
# INTERPRETER CONTRACT — read before "fixing" a ModuleNotFoundError:
#   The venv (`pcb/worker/.venv`) is `.gitignore`d (see pcb/worker/.gitignore
#   entry `.venv/`) and is a LOCAL BUILD ARTIFACT, not a tracked path — so
#   `git worktree add` does NOT bring it along; a fresh worktree has no
#   `.venv` at all (verified empirically while building this script). Two
#   consequences, deliberately not "fixed" into something more symmetric:
#
#     1. The PYTHON INTERPRETER (and every installed dependency: pyyaml,
#        gerber-writer, pyclipper, ...) comes from the INVOKING checkout's
#        venv — `pcb/worker/.venv/bin/python`, resolved relative to THIS
#        SCRIPT's own location, never relative to the worktree. Building a
#        fresh venv per worktree run would make this script slow AND would
#        make it test dependency-install reproducibility, which is a
#        different question from the one this gate asks (source
#        reproducibility, at a pinned dependency set).
#
#     2. The SOURCE CODE that interpreter imports comes from the WORKTREE
#        (`PYTHONPATH=<worktree>/pcb/worker`), not from the invoking
#        checkout. This matters because `pcb/worker/.venv` is an EDITABLE
#        install (`pip install -e .`) whose `.pth` file hardcodes an
#        ABSOLUTE path back to the invoking checkout
#        (`.venv/lib/python3.12/site-packages/_editable_impl_pcb_plugin_worker.pth`)
#        — so simply invoking the venv's python WITHOUT setting PYTHONPATH
#        would silently import the invoking checkout's (possibly dirty,
#        possibly stale-pyc) `pcb_worker`, defeating the entire point of the
#        worktree. Verified empirically: with PYTHONPATH set to the
#        worktree, `pcb_worker.__file__` resolves inside the worktree,
#        overriding the .pth entry (PYTHONPATH is searched before the
#        site-packages-injected path).
#
#   Net effect: RUNTIME is pinned to the invoking checkout's venv (fast,
#   deterministic dependency set); SOURCE is pinned to HEAD via the worktree
#   (the thing actually under test). If you need to test a dependency
#   version bump too, rebuild pcb/worker/.venv first — this script does not.
#
# WHAT "MINIMUM MANIFEST" MEANS AND WHY IT RUNS BEFORE THE HASH COMPARE:
#   A sha256-of-tree comparison is trivially GREEN on an EMPTY tree, or on a
#   tree where compile silently produced nothing — "two identical trees" is
#   still true of two empty trees. That is the adjudicated fail-closed bug
#   this script exists to not repeat (epoch-C brief review, C9). So EACH of
#   the two output trees is checked, BEFORE any comparison, against a
#   hardcoded minimum manifest: all 9 Gerber layer suffixes (mirrors
#   pcb_worker.fab_capability.EMITTED_GERBER_SUFFIXES — these 9 are ALWAYS
#   written, even for a layer with no content on the board, per gerber.py's
#   own "an absent file is worse than an empty one" policy, so hardcoding
#   the 9 names is safe for ANY board, not just the synthetic fixture), the
#   .gbrjob job file, the BOM csv, the CPL csv (all always-written), and AT
#   LEAST ONE Excellon drill file (PTH/NPTH are conditional on the board
#   actually having plated/unplated holes — the synthetic default fixture
#   has both; a board with only one hole class would still legitimately
#   pass with one). Every required file must additionally be NON-ZERO bytes
#   — present-but-empty is treated the same as absent.
#
#   NO NORMALIZATION, EVER, in the hash compare below. The emitter pins its
#   one wall-clock-volatile field (Gerber TF.CreationDate / Excellon
#   CREATED_BY) to a fixed epoch by default (see
#   pcb/worker/tests/test_determinism_gate.py, STANDING GUARD 1) — so a raw,
#   un-normalized byte compare is ALREADY the correct comparison. If this
#   script ever grows a "scrub timestamps before comparing" step, that is
#   reopening the exact hole test_determinism_gate.py refuses; don't.
#
# WHAT THIS SCRIPT REUSES RATHER THAN REINVENTS:
#   The two-runs-byte-identical PROOF already exists and already runs, every
#   CI run, in pcb/worker/tests/test_determinism_gate.py (STANDING GUARD 1) —
#   including a `zone_fill.yaml` row (id="zonefill-production") added by C6.
#   That test is the FAST, unit-level version of the same claim. This script
#   is the SLOW, END-TO-END version: it adds the "compiled from a genuinely
#   clean checkout" dimension (a stale .pyc, an uncommitted local edit, or a
#   leftover .pcbskel sidecar could make the unit test's in-process
#   determinism claim true while a real clean-checkout build still differs),
#   plus the BOM/CPL rows and the minimum-manifest fail-closed check, neither
#   of which the unit gate performs. It calls the SAME production entry
#   point the unit gate and the real Go<->Python bridge both call —
#   `pcb_worker.methods.handle_request({"method": "gerbers"/"assembly_bom"/
#   "assembly_cpl", ...})` — not a bespoke reimplementation of the compile
#   path.
#
# EXIT CODES: 0 = green (manifest complete on both trees, byte-identical).
#             1 = a real, NAMED failure — a missing/empty manifest entry, a
#                 byte divergence (first offending file named), or a
#                 STRUCTURED refusal surfaced by the compile/assembly path
#                 itself (e.g. a missing MPN on an assembly-required
#                 component) — printed verbatim, never swallowed into a
#                 generic harness error.
#             2 = harness/environment problem: bad args, missing venv,
#                 missing git, worktree failure, or the python driver
#                 crashing UNSTRUCTURED (an uncaught traceback — methods.py's
#                 own "kind": "python"/"internal" backstop, never a named
#                 refusal). Never conflated with a "the artifact is wrong" 1
#                 — see run_compile()'s exit-code branch below for exactly
#                 how the two are told apart.
#
# SELF-TEST: run with `--self-test [board_path]` to prove the fail-closed
# claim above is real, not asserted: it runs one real compile, confirms the
# manifest check PASSES on the honest tree, then deletes one required file
# and confirms the SAME check FAILS, by name, on the mutated tree. This is
# the "deliberate-break run" the epoch-C brief review asked to see, kept as
# a runnable regression rather than a one-off manual demonstration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PCB_DIR}/.." && pwd)"
VENV_PYTHON="${REPO_ROOT}/pcb/worker/.venv/bin/python"
DEFAULT_BOARD_REL="pcb/worker/tests/testdata/zone_fill.yaml"
BASE_NAME="hermetic"

# The 9 Gerber suffixes gerber.py ALWAYS writes. AUTHORITY:
# pcb_worker.fab_capability.EMITTED_GERBER_SUFFIXES — hardcoded here
# deliberately (not imported: this script has no import-time dependency on
# the worktree existing yet, and must run its pre-flight checks before any
# worktree/venv wiring happens). DRIFT GUARD: this exact literal
# (`GERBER_SUFFIXES=(...)` on one line) is read back and compared against
# fab_capability.EMITTED_GERBER_SUFFIXES by a PARKED pin,
# pcb/worker/tests/pending_hermetic_check.py::
# test_script_gerber_suffix_list_matches_fab_capability_authority — a 10th
# emitted layer added to fab_capability.py without updating this line fails
# THAT pin at the epoch boundary, not silently here.
GERBER_SUFFIXES=(F_Cu B_Cu F_Mask B_Mask F_SilkS B_SilkS Edge_Cuts F_Paste B_Paste)
DRILL_SUFFIXES=(PTH NPTH)

# N1: gerbv exits 0 and writes a valid-but-empty (e.g. 1x1) PNG for
# garbage/truncated/empty Gerber input — `[ -s ]` (nonzero bytes) does NOT
# prove a real render happened. A real 9-layer smoke-load measured 89x71px
# during review; this floor just has to sit well below any genuine render
# and well above a 1x1/tiny placeholder.
MIN_VIEWER_PNG_DIM=8

log()  { echo "[hermetic-fab-check] $*" >&2; }
fail() { echo "[hermetic-fab-check] FAIL: $*" >&2; exit 1; }
harness_fail() { echo "[hermetic-fab-check] harness error: $*" >&2; exit 2; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    harness_fail "neither sha256sum nor shasum is on PATH"
  fi
}

# --- Pre-flight -------------------------------------------------------------

if [ ! -x "${VENV_PYTHON}" ]; then
  harness_fail "venv interpreter not found at ${VENV_PYTHON} — build it first" \
    "(pcb/worker/.venv is gitignored, a local build artifact; see this" \
    "script's INTERPRETER CONTRACT header comment)"
fi

if ! command -v git >/dev/null 2>&1; then
  harness_fail "'git' not found on PATH"
fi

SELF_TEST=0
BOARD_ARG="${1:-}"
if [ "${BOARD_ARG}" = "--self-test" ]; then
  SELF_TEST=1
  BOARD_ARG="${2:-}"
fi
if [ -z "${BOARD_ARG}" ]; then
  BOARD_ARG="${DEFAULT_BOARD_REL}"
fi

# --- Hermetic worktree -------------------------------------------------------

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/hermetic-fab-check.XXXXXX")"
TMPWT="${TMPROOT}/worktree"
OUT1="${TMPROOT}/out1"
OUT2="${TMPROOT}/out2"
DRIVER="${TMPROOT}/driver.py"

cleanup() {
  if [ "${HERMETIC_FAB_KEEP_TMP:-0}" = "1" ]; then
    log "HERMETIC_FAB_KEEP_TMP=1 set — leaving ${TMPROOT} in place"
    return
  fi
  if [ -d "${TMPWT}" ]; then
    git -C "${REPO_ROOT}" worktree remove --force "${TMPWT}" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPROOT}"
}
trap cleanup EXIT

HEAD_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
log "worktree at HEAD (${HEAD_SHA}) -> ${TMPWT}"
git -C "${REPO_ROOT}" worktree add --detach --quiet "${TMPWT}" "${HEAD_SHA}" \
  || harness_fail "git worktree add failed"

# Resolve the board file. Absolute path = read as-is (private product board,
# never copied into the repo). Relative path = resolved INSIDE the worktree,
# so the rehearsal compiles what HEAD actually has committed.
case "${BOARD_ARG}" in
  /*) BOARD_FILE="${BOARD_ARG}" ;;
  *)  BOARD_FILE="${TMPWT}/${BOARD_ARG}" ;;
esac
[ -f "${BOARD_FILE}" ] || harness_fail "board file not found: ${BOARD_FILE}"

mkdir -p "${OUT1}" "${OUT2}"

# --- Python driver ------------------------------------------------------------
# Ephemeral — written into the tmp root, never committed. Calls the SAME
# dispatch entry point the Go<->Python bridge uses (pcb_worker.methods.
# handle_request), so this is not a parallel reimplementation of the fab path.
cat > "${DRIVER}" <<'PYEOF'
import sys

board_path, out_dir, base = sys.argv[1], sys.argv[2], sys.argv[3]
with open(board_path, "r", encoding="utf-8") as fh:
    board_yaml = fh.read()

from pcb_worker import methods

# Exit-code taxonomy this driver hands back to the bash wrapper (N2): a
# STRUCTURED, NAMED refusal from the compile/assembly path (e.g. a missing
# MPN, an invalid design rule) is a real answer about THIS board, not a
# harness problem — exit 3, so run_compile() below can map it to the
# script's own exit-1 "artifact is wrong" lane instead of exit-2
# "environment is wrong". Only methods.py's OWN "never crash the loop"
# backstop kinds ("python"/"internal" — see methods.handle_request's except
# Exception clause) are genuinely unstructured and stay on the plain exit-1
# path below, which the wrapper treats as a driver crash (-> exit 2).
REFUSAL_EXIT = 3
CRASH_EXIT = 1


def call(method, **extra):
    req = {
        "id": 1,
        "method": method,
        "params": {"yaml": board_yaml, "out_dir": out_dir, "name": base, **extra},
    }
    resp = methods.handle_request(req)
    if not resp.get("ok"):
        err = resp.get("error") or {}
        kind = err.get("kind")
        message = err.get("message")
        if kind not in (None, "python", "internal"):
            print(f"HERMETIC-DRIVER-REFUSAL method={method} kind={kind} message={message}",
                  file=sys.stderr)
            sys.exit(REFUSAL_EXIT)
        print(f"HERMETIC-DRIVER-FAIL method={method} error={err}", file=sys.stderr)
        sys.exit(CRASH_EXIT)
    return resp["result"]


# All v1 fab outputs: copper (incl. pour fill)/mask/paste/silk/drill via the
# Gerber+Excellon emitter, then the two assembly artifacts. Same three calls,
# same order, both runs — order only matters for readability here, not for
# byte content (each call writes its own distinct filenames).
call("gerbers")
call("assembly_bom", profile="jlc")
call("assembly_cpl", profile="jlc")
print("HERMETIC-DRIVER-OK")
PYEOF

# N2 exit-code taxonomy: the driver hands back 0 (ok), 3 (a NAMED,
# STRUCTURED refusal — e.g. missing MPN), or 1 (an unstructured crash — a
# bare traceback, or methods.py's own "python"/"internal" backstop kind).
# Only case 3 is a real, board-specific answer this script should report as
# its own exit-1 "artifact is wrong"; case 1 stays a harness problem (exit
# 2) because there is nothing NAMED to show the caller.
run_compile() {
  local out_dir="$1"
  local out rc
  set +e
  out="$(PYTHONPATH="${TMPWT}/pcb/worker" "${VENV_PYTHON}" "${DRIVER}" \
    "${BOARD_FILE}" "${out_dir}" "${BASE_NAME}" 2>&1)"
  rc=$?
  set -e
  case "${rc}" in
    0) return 0 ;;
    3)
      echo "${out}" >&2
      fail "board refused: ${BOARD_ARG} (structured refusal above, not a harness problem)"
      ;;
    *)
      echo "${out}" >&2
      harness_fail "python driver crashed unexpectedly (exit ${rc}) for ${out_dir} — see output above"
      ;;
  esac
}

# --- Minimum-manifest assertion (FIRST, before any hash compare) -----------
#
# ADJUDICATED FAIL-CLOSED FIX (epoch-C brief review, C9): a tree comparison
# is vacuously green on two empty trees. This function is what stops that —
# it is called on EACH tree independently, before the two are ever compared
# to each other, so "compile silently produced nothing" fails HERE, not as
# a false "identical" a few lines down.
check_manifest() {
  local dir="$1"
  local missing=()
  local f

  for suf in "${GERBER_SUFFIXES[@]}"; do
    f="${dir}/${BASE_NAME}-${suf}.gbr"
    [ -s "${f}" ] || missing+=("${f}")
  done
  f="${dir}/${BASE_NAME}-job.gbrjob"
  [ -s "${f}" ] || missing+=("${f}")
  f="${dir}/${BASE_NAME}-bom-jlc.csv"
  [ -s "${f}" ] || missing+=("${f}")
  f="${dir}/${BASE_NAME}-cpl-jlc.csv"
  [ -s "${f}" ] || missing+=("${f}")

  local drill_ok=0
  for suf in "${DRILL_SUFFIXES[@]}"; do
    [ -s "${dir}/${BASE_NAME}-${suf}.drl" ] && drill_ok=1
  done
  [ "${drill_ok}" = "1" ] || missing+=("${dir}/${BASE_NAME}-{PTH,NPTH}.drl (at least one)")

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "[hermetic-fab-check] MINIMUM-MANIFEST FAIL in ${dir}:" >&2
    for f in "${missing[@]}"; do echo "    missing/empty: ${f}" >&2; done
    return 1
  fi
  return 0
}

# --- Self-test mode: prove the fail-closed claim, then exit -----------------
if [ "${SELF_TEST}" = "1" ]; then
  log "self-test: compiling once into ${OUT1}"
  run_compile "${OUT1}"
  if check_manifest "${OUT1}"; then
    log "self-test: manifest check correctly PASSES on the honest tree"
  else
    fail "self-test: manifest check should have passed on an honest tree and did not"
  fi

  BROKEN_FILE="${OUT1}/${BASE_NAME}-F_Cu.gbr"
  log "self-test: deliberately deleting ${BROKEN_FILE}"
  rm -f "${BROKEN_FILE}"
  if check_manifest "${OUT1}"; then
    fail "self-test: manifest check should have FAILED after deleting ${BROKEN_FILE} and it did not — fail-closed claim is FALSE"
  else
    log "self-test: manifest check correctly FAILS on the mutated (sub-minimum) tree — see MINIMUM-MANIFEST FAIL lines above"
  fi
  log "self-test: PASS (both directions proven)"
  exit 0
fi

# --- Real run: compile twice, check both, compare ----------------------------

log "run 1/2 -> ${OUT1}"
run_compile "${OUT1}"
log "run 2/2 -> ${OUT2}"
run_compile "${OUT2}"

# TEST-ONLY SEAM, unset by default and never set by a real invocation of this
# script. Its sole purpose is letting pcb/worker/tests/pending_hermetic_check.py
# drive the "first divergent file is named correctly" pin via a real subprocess
# call — the production compile path is deterministic BY DESIGN (that is the
# thing this whole script exists to prove), so there is no honest way to
# provoke a real divergence from outside; this is the documented, narrow
# exception. If set, it names a file (relative to OUT2) to corrupt (append one
# byte to) right before the comparison below, so the divergence-naming path
# actually executes instead of only being asserted-by-reading.
if [ -n "${HERMETIC_FAB_INJECT_DIVERGENCE:-}" ]; then
  log "TEST-ONLY: HERMETIC_FAB_INJECT_DIVERGENCE=${HERMETIC_FAB_INJECT_DIVERGENCE} set — corrupting that file in run 2's output"
  printf '\n' >> "${OUT2}/${HERMETIC_FAB_INJECT_DIVERGENCE}"
fi

log "minimum-manifest check: run 1"
check_manifest "${OUT1}" || fail "run 1 output tree is sub-minimum (see above)"
log "minimum-manifest check: run 2"
check_manifest "${OUT2}" || fail "run 2 output tree is sub-minimum (see above)"
log "minimum-manifest: PASS on both trees"

# File SET must match before file-by-file content is even meaningful.
LIST1="$(cd "${OUT1}" && find . -type f | sort)"
LIST2="$(cd "${OUT2}" && find . -type f | sort)"
if [ "${LIST1}" != "${LIST2}" ]; then
  fail "emitted file SET differs between runs:
run1:
${LIST1}
run2:
${LIST2}"
fi

# Byte-for-byte, file by file, no normalization. Report the FIRST divergence
# by name and stop — that is the useful signal, not a full diff dump.
while IFS= read -r rel; do
  h1="$(sha256_of "${OUT1}/${rel}")"
  h2="$(sha256_of "${OUT2}/${rel}")"
  if [ "${h1}" != "${h2}" ]; then
    fail "non-deterministic output — first divergent file: ${rel} (sha256 ${h1} vs ${h2})"
  fi
done <<< "${LIST1}"

log "determinism: PASS — $(echo "${LIST1}" | wc -l) files byte-identical across two runs"
log "board: ${BOARD_ARG}"
log "HEAD: ${HEAD_SHA}"

# --- Independent-viewer smoke-load (best-effort, non-fatal) -----------------
#
# `gerbv` (Gerber/Excellon viewer) is present on this host — checked, not
# assumed. If it, or `kicad-cli`, is ever absent on a future host, this step
# degrades to printing the artifact list plus the manual HITL step below,
# rather than failing the whole gate over a viewer that isn't the point of
# the rehearsal.
# Reads a PNG's IHDR width/height directly (no PIL/Pillow dependency —
# neither is in pcb/worker/.venv, and this is 8 bytes of struct-unpacking,
# not worth adding one for). Prints "0 0" for anything that isn't a valid
# PNG with a readable IHDR. Uses VENV_PYTHON purely as "a python that is
# guaranteed to exist on this host" (already checked executable in
# pre-flight) — no pcb_worker import, no PYTHONPATH needed.
png_dims() {
  local png="$1"
  "${VENV_PYTHON}" - "${png}" <<'PYEOF'
import struct, sys

path = sys.argv[1]
try:
    with open(path, "rb") as fh:
        data = fh.read(24)
except OSError:
    data = b""
if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
    print("0 0")
else:
    w, h = struct.unpack(">II", data[16:24])
    print(f"{w} {h}")
PYEOF
}

viewer_smoke_load() {
  local dir="$1"
  local png="${TMPROOT}/viewer-smoke.png"
  local gerbers=("${dir}/${BASE_NAME}"-*.gbr)
  local png_w png_h

  if command -v gerbv >/dev/null 2>&1; then
    local gerbv_cmd=(gerbv -x png -o "${png}" -B 5 "${gerbers[@]}")
    if [ -z "${DISPLAY:-}" ] && command -v xvfb-run >/dev/null 2>&1; then
      gerbv_cmd=(xvfb-run -a "${gerbv_cmd[@]}")
    fi
    if "${gerbv_cmd[@]}" >/dev/null 2>&1 && [ -s "${png}" ]; then
      read -r png_w png_h < <(png_dims "${png}")
      # N1: gerbv exits 0 and writes a valid-but-trivial (e.g. 1x1) PNG for
      # garbage/truncated/empty Gerber input — nonzero bytes alone is NOT
      # proof of a real render. Gate on decoded IHDR dimensions instead.
      if [ "${png_w:-0}" -gt "${MIN_VIEWER_PNG_DIM}" ] && [ "${png_h:-0}" -gt "${MIN_VIEWER_PNG_DIM}" ]; then
        log "independent-viewer smoke-load: PASS (gerbv rendered ${#gerbers[@]} layers -> $(basename "${png}"), ${png_w}x${png_h}px)"
        return 0
      fi
      log "independent-viewer smoke-load: gerbv exited 0 and wrote ${png_w:-0}x${png_h:-0}px" \
          "(<= ${MIN_VIEWER_PNG_DIM}px floor — a decorative/placeholder render, not a real" \
          "one) — falling back to the manual step"
    else
      log "independent-viewer smoke-load: gerbv is installed but the render failed" \
          "(likely no display and no xvfb-run) — falling back to the manual step"
    fi
  fi

  log "independent-viewer smoke-load: no working headless viewer — manual HITL step:"
  log "  open the ${#gerbers[@]} *.gbr + drill files in ${dir} with gerbv or a KiCad"
  log "  Gerber viewer (File > Import > Gerber) and visually confirm the pour,"
  log "  keepout void, silk designators (R1/R2) and board outline all render."
  log "  Artifact list:"
  ( cd "${dir}" && find . -maxdepth 1 -type f | sort ) | while read -r f; do
    log "    ${f}"
  done
  return 0
}

viewer_smoke_load "${OUT1}"

log "GREEN: manifest complete + byte-identical across two runs + viewer step done"
