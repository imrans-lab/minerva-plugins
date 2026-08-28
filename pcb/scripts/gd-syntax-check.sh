#!/usr/bin/env bash
# Per-file GDScript syntax check that never opens a Minerva project.
#
#   pcb/scripts/gd-syntax-check.sh <file.gd> [<file.gd> ...]
#   pcb/scripts/gd-syntax-check.sh --all
#
# Exit 0 = every file parsed. Exit 1 = at least one parse error. Exit 2 =
# harness problem (no godot, unreadable file, path outside this repo).
#
# WHY THIS EXISTS, and why it is not `run-gd-tests.sh`
# ---------------------------------------------------
# The only other Godot entry point in this repo is scripts/run-gd-tests.sh,
# which EXECUTES suites via `godot --headless --path <minerva>/src`. Opening
# a Minerva project takes that project's single-instance lock: doing it while
# a Minerva instance is running terminates the running app and loses whatever
# is unsaved in it. So there is no way to answer "did my edit break the
# parser?" through the test runner without either shutting Minerva down or
# risking someone else's session.
#
# This script answers only that question, and answers it against a DISPOSABLE
# scratch project under $TMPDIR. It never reads or writes any Minerva
# checkout, so it is safe to run at any time, as often as wanted.
#
# HOW IT READS GODOT'S OUTPUT (the load-bearing detail)
# ----------------------------------------------------
# `--check-only --script` reports two different families of diagnostic:
#
#   parser     — "Unexpected \"Indent\" in class body", "Expected parameter
#                name". These are real defects in the file.
#   resolver   — "Could not find base class \"MinervaPluginPanel\"", "Could
#                not find type \"AnnotationKind\"", "Preload file \"res://
#                test/helpers/...\" does not exist", and the type-inference
#                and depended-script cascades that follow from them. These
#                are the scratch project's fault: the plugin's .gd files
#                extend class_name types and preload helper scripts that
#                only exist inside Minerva's own project.
#
# ONE resolver-family message is re-promoted to a real defect: a missing
# preload whose path points back INTO this repo. Minerva host paths are
# expected to be absent here, but a pcb file preloading a pcb file that does
# not exist is a typo, and typo'd preload paths are the most common way a
# newly-wired dispatch entry or helper fails.
#
# Measured on Godot 4.6.2: when a file contains BOTH kinds of problem, the
# parser error is the ONLY one printed — parsing precedes resolution and
# aborts before it. A file whose diagnostics are all resolver-family is
# therefore proven free of parse errors, which is the entire claim this
# script makes. That is why no host stubs are needed and none are provided:
# stubs would have to mirror the real classes' members or they would invent
# false errors of their own.
#
# WHAT THIS DOES NOT PROVE: that the file resolves, loads, or behaves. Type
# errors, wrong member names, bad signal wiring and every runtime question
# are invisible here. Those need the real host — scripts/run-gd-tests.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PCB_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGINS_ROOT="$(cd "${PCB_DIR}/.." && pwd)"

if ! command -v godot >/dev/null 2>&1; then
  echo "error: 'godot' not found on PATH" >&2
  exit 2
fi

# Resolver-family diagnostics, as extended regexes matched against the
# message line. Anything NOT matching one of these is treated as the file's
# own defect. The list is deliberately narrow: a message family added here
# by guesswork is a hole in the check.
#
# "Could not resolve class" is the SAME fact as "Could not find base class",
# spelled for a base named by path (`extends "res://.../pcb_canvas.gd"`, or an
# inner `class X extends SomePreloadedScript`): the base file exists but does
# not itself resolve here, because IT extends a Minerva class_name. MEASURED on
# 4.6.2, both halves: pcb_canvas.gd alone reports "Could not find type
# \"AnnotationKind\"", and a subclass of a base that DOES resolve (same
# res://../../ escape, plain RefCounted base) reports nothing at all. It does
# NOT mask a typo'd base path — a base file that is absent reports "Could not
# resolve SUPER CLASS PATH", which is not in this list and still fails.
RESOLVER_PATTERNS='Could not find base class|Could not resolve class|Could not resolve script|Could not find type|Cannot infer the type of .* (variable|constant) because the value doesn.t have a set type|Identifier .* not declared in the current scope|Failed to compile depended scripts|Preload file .* does not exist'
# Re-promoted out of the resolver family: a preload of a path inside this repo.
IN_REPO_MISSING_PRELOAD='Preload file "[^"]*minerva-plugins/[^"]*" does not exist'

# Scratch host project. Rooted two levels below a symlink to this repo so the
# literal "res://../../minerva-plugins/..." path the test suites hardcode
# resolves exactly as it does under the real Minerva host — one derivation
# for ui/ files and tests/gd/ files alike.
SCRATCH="${TMPDIR:-/tmp}/pcb-gd-syntax-$(id -u)"
HOST="${SCRATCH}/host/src"
mkdir -p "${HOST}"
if [ ! -f "${HOST}/project.godot" ]; then
  cat > "${HOST}/project.godot" <<'EOF'
config_version=5

[application]

config/name="pcb-gd-syntax-scratch"
config/features=PackedStringArray("4.6")
EOF
fi
ln -sfn "${PLUGINS_ROOT}" "${SCRATCH}/minerva-plugins"

declare -a targets=()
if [ "$#" -eq 0 ]; then
  echo "usage: $0 <file.gd> [...] | --all" >&2
  exit 2
fi
if [ "$1" = "--all" ]; then
  while IFS= read -r f; do targets+=("${f}"); done < <(find "${PCB_DIR}/ui" "${PCB_DIR}/tests" -name '*.gd' | sort)
else
  for arg in "$@"; do
    abs="$(cd "$(dirname "${arg}")" 2>/dev/null && pwd)/$(basename "${arg}")"
    if [ ! -f "${abs}" ]; then
      echo "error: not a readable file: ${arg}" >&2
      exit 2
    fi
    targets+=("${abs}")
  done
fi

rc=0
checked=0
for abs in "${targets[@]}"; do
  case "${abs}" in
    "${PLUGINS_ROOT}"/*) rel="${abs#"${PLUGINS_ROOT}"/}" ;;
    *)
      echo "error: ${abs} is outside ${PLUGINS_ROOT}" >&2
      exit 2
      ;;
  esac
  out="$(timeout 300 godot --headless --path "${HOST}" --check-only \
        --script "res://../../minerva-plugins/${rel}" 2>&1)"
  # Keep only diagnostic message lines; drop the banner, the blank lines and
  # the "at:"/"Failed to load script" follow-ups, which carry no family of
  # their own and would never match a resolver pattern.
  diags="$(printf '%s\n' "${out}" | grep -E '^SCRIPT ERROR: ' || true)"
  residue="$(printf '%s\n' "${diags}" | grep -v '^$' | grep -Ev "${RESOLVER_PATTERNS}" || true)"
  promoted="$(printf '%s\n' "${diags}" | grep -E "${IN_REPO_MISSING_PRELOAD}" || true)"
  [ -n "${promoted}" ] && residue="${residue}${residue:+$'\n'}${promoted}"
  checked=$((checked + 1))
  if [ -n "${residue}" ]; then
    echo "SYNTAX CHECK FAILED  ${rel}"
    printf '%s\n' "${out}" | grep -E '^(SCRIPT ERROR: |[[:space:]]+at: )' | sed 's/^/    /'
    rc=1
  fi
done

if [ "${rc}" -eq 0 ]; then
  echo "gd syntax check passed (${checked} file(s) parsed; resolution NOT checked)"
fi
exit "${rc}"
