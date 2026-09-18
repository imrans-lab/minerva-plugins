# shellcheck shell=bash
#
# The pass/fail CONTRACT shared by the two GDScript-suite runners:
#   scripts/run-gd-tests.sh          — every suite of ONE plugin (dev/nightly)
#   scripts/run-contract-guards.sh   — only the contract guards (consuming-host CI)
#
# Both must agree, byte for byte, on how EXPECTED_SUITES is read, how the
# "=== Results: N passed, M failed ===" line is parsed, and what counts as a
# fatal Godot diagnostic. A second copy of that logic is how one runner keeps
# enforcing a rule the other quietly stopped enforcing, so there is exactly
# one copy and it lives here.
#
# These functions `exit 2` on a MALFORMED input (manifest/allowlist): a gate
# whose own configuration does not parse has not passed, and both callers
# already use exit 2 for "harness/environment problem".
#
# Callers must `set -u`-safely pre-declare nothing: the arrays below are
# declared here, at the scope of the sourcing script.

# Filled by gd_manifest_parse. Shared NAMES, not just shared shapes, so a
# caller reads the same variable the other caller reads.
declare -a manifest_names=()
declare -A manifest_assertions=()
declare -A manifest_real_worker=()

# Parse a plugin's tests/gd/EXPECTED_SUITES (v2 line format:
#   <filename> [assertions=N] [real-worker]
# ). The first whitespace-separated token is the suite filename; the rest are
# per-suite enforcement attributes. Unknown attributes are a hard error — a
# typo'd `real-workr` that silently parsed as nothing would un-enforce the very
# thing the entry was written to enforce.
gd_manifest_parse() {
  local manifest="$1"
  if [ ! -f "${manifest}" ]; then
    echo "error: suite manifest not found: ${manifest}" >&2
    exit 2
  fi
  manifest_names=()
  manifest_assertions=()
  manifest_real_worker=()
  # A DUPLICATE row inflates the expected suite count while the suite runs
  # once: every suite can pass, the summary prints 50/51, and the runner still
  # exits 0. Duplicate attributes would make conflicting pins "last one wins".
  # Both are manifest corruption: refuse by name, exit 2.
  local -A manifest_seen=()
  local line name attr val
  local -a fields=()
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
      echo "error: ${manifest}: duplicate suite entry '${name}' (a duplicate inflates the suite count while the suite runs once)" >&2
      exit 2
    fi
    manifest_seen["${name}"]=1
    manifest_names+=("${name}")
    for attr in "${fields[@]:1}"; do
      case "${attr}" in
        assertions=*)
          if [ -n "${manifest_assertions[${name}]:-}" ]; then
            echo "error: ${manifest}: suite '${name}' repeats the assertions= attribute (conflicting pins must not be last-one-wins)" >&2
            exit 2
          fi
          val="${attr#assertions=}"
          if ! [[ "${val}" =~ ^[0-9]+$ ]] || [ "${val}" -eq 0 ]; then
            echo "error: ${manifest}: suite '${name}' has non-positive-integer assertions pin '${attr}'" >&2
            exit 2
          fi
          manifest_assertions["${name}"]="${val}"
          ;;
        real-worker)
          if [ -n "${manifest_real_worker[${name}]:-}" ]; then
            echo "error: ${manifest}: suite '${name}' repeats the real-worker attribute" >&2
            exit 2
          fi
          manifest_real_worker["${name}"]=1
          ;;
        *)
          echo "error: ${manifest}: suite '${name}' has unknown attribute '${attr}'" >&2
          echo "  (known: assertions=N, real-worker)" >&2
          exit 2
          ;;
      esac
    done
  done < "${manifest}"

  if [ "${#manifest_names[@]}" -eq 0 ]; then
    echo "error: suite manifest ${manifest} has no entries" >&2
    exit 2
  fi
}

# Strip comments/blanks from a KNOWN_HARNESS_DIAGNOSTICS allowlist into $2 and
# compile-check the patterns.
#
# grep -v -f treats a BLANK line as a match-everything pattern, which would
# filter EVERY diagnostic and silently disarm the whole check. An invalid ERE
# makes the residue grep exit 2, and an unguarded scan would read that as "no
# residue". Both are the gate disarming itself, so both are refused here,
# before anything runs.
gd_allowlist_clean() {
  local allowlist="$1" clean="$2"
  if [ ! -f "${allowlist}" ]; then
    echo "error: known-harness-diagnostics allowlist not found: ${allowlist}" >&2
    echo "  (required for execution runs — every SCRIPT ERROR/failed-script-load" >&2
    echo "   diagnostic not matching it fails the suite that printed it)" >&2
    exit 2
  fi
  grep -Ev '^[[:space:]]*(#|$)' "${allowlist}" > "${clean}" || true
  if [ ! -s "${clean}" ]; then
    echo "error: allowlist ${allowlist} has no patterns (only comments/blanks)" >&2
    rm -f "${clean}"
    exit 2
  fi
  # grep against /dev/null: rc 1 = patterns valid (nothing to match),
  # rc 2 = at least one is malformed.
  grep -E -f "${clean}" /dev/null >/dev/null 2>&1
  local rc=$?
  if [ "${rc}" -ge 2 ]; then
    echo "error: allowlist ${allowlist} contains an invalid extended regex (grep rc ${rc})" >&2
    echo "  (the diagnostics gate cannot run against a pattern set that does not compile)" >&2
    rm -f "${clean}"
    exit 2
  fi
}

# Emit one "MESSAGE @@ at: LOCATION" record per fatal diagnostic in a captured
# suite log. Scope is deliberately the two fatal families — `SCRIPT ERROR:`
# (compile/parse/runtime script errors) and `ERROR: Failed to load script` —
# NOT every `ERROR:` engine line (headless runs legitimately print
# Node-not-found/socket noise that is not a script-layer verdict). The `at:`
# line that follows a diagnostic is glued onto the record so the allowlist can
# pin a message to a location instead of blessing it everywhere.
gd_fatal_diagnostics() {
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

# Parse the suite's own verdict out of a captured log. Sets:
#   GD_RESULTS_LINE  the whole line (carries the wire measurements too), "" if absent
#   GD_N_PASS        passed count, "" when there was no parseable line
#   GD_N_FAIL        failed count, "" likewise
# An absent/unparseable line is reported as EMPTY, never as zero: "no verdict"
# and "a verdict of zero" are different failures and the callers say so
# differently.
gd_results_parse() {
  local log="$1"
  GD_RESULTS_LINE="$(grep -m1 -E '=== Results: [0-9]+ passed, [0-9]+ failed' "${log}" || true)"
  GD_N_PASS=""
  GD_N_FAIL=""
  if [[ "${GD_RESULTS_LINE}" =~ Results:\ ([0-9]+)\ passed,\ ([0-9]+)\ failed ]]; then
    GD_N_PASS="${BASH_REMATCH[1]}"
    GD_N_FAIL="${BASH_REMATCH[2]}"
  fi
}
