#!/usr/bin/env bash
# NEGATIVE SELF-TEST for scripts/run-contract-guards.sh.
#
# The strict runner's whole value is that it FAILS where the permissive one
# passes, so what needs proving is the failing, not the passing. This test
# builds a sandbox — a throwaway git checkout holding one fake plugin, a fake
# Minerva checkout beside it, and a fake `godot` that prints canned suite
# output — and asserts the runner's verdict on each planted defect. No real
# Godot, no real plugin build, no network: it runs in about a second.
#
#   scripts/test-contract-runner.sh
#
# Exit 0 only if every case below produced the expected exit code and message.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-contract-guards.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "${SANDBOX}"' EXIT

PLUGINS="${SANDBOX}/minerva-plugins"
HOST="${SANDBOX}/minerva"
# The stand-in for the developer's own profile. The runner must leave it
# byte-identical; nothing in this test ever points at the real one.
DEV_PROFILE="${SANDBOX}/devprofile"

mkdir -p "${PLUGINS}/demo/tests/gd" "${HOST}/src/gdextension/terminal" "${HOST}/src/bin" \
         "${DEV_PROFILE}/godot/app_userdata/Minerva"
echo "existing" > "${DEV_PROFILE}/godot/app_userdata/Minerva/keep.cfg"

echo 'config/name="Minerva"' > "${HOST}/src/project.godot"
cat > "${HOST}/src/gdextension/terminal/terminal.gdextension" <<'GDEXT'
[libraries]
linux.editor.x86_64 = "res://bin/libfake.linux.so"
macos.editor = "res://bin/libfake.macos.framework"
windows.editor.x86_64 = "res://bin/libfake.windows.dll"
GDEXT
case "$(uname -s)" in
  Linux) touch "${HOST}/src/bin/libfake.linux.so" ;;
  Darwin) mkdir -p "${HOST}/src/bin/libfake.macos.framework" ;;
  *) touch "${HOST}/src/bin/libfake.windows.dll" ;;
esac
EXT_LIB="$(find "${HOST}/src/bin" -maxdepth 1 -mindepth 1 | head -n1)"

# The fake plugin. Its manifest's setup stanza is an `exec` step, so the
# runner's manifest-driven builder is exercised for real without a toolchain.
cat > "${PLUGINS}/demo/manifest.json" <<'MF'
{
  "id": "demo",
  "setup": {
    "steps": [
      {"type": "exec", "argv": ["./make-binary.sh"], "artifact": "demo-plugin"}
    ]
  }
}
MF
cat > "${PLUGINS}/demo/make-binary.sh" <<'MB'
#!/usr/bin/env bash
set -eu
[ "${DEMO_BUILD_FAILS:-0}" = "1" ] && exit 3
printf '#!/bin/sh\nexit 0\n' > "$(dirname "$0")/demo-plugin"
chmod +x "$(dirname "$0")/demo-plugin"
MB
chmod +x "${PLUGINS}/demo/make-binary.sh"

echo "test_contract_guard.gd assertions=3" > "${PLUGINS}/demo/tests/gd/EXPECTED_SUITES"
cat > "${PLUGINS}/demo/tests/gd/KNOWN_HARNESS_DIAGNOSTICS" <<'AL'
# The double-load compile cascade every real guard prints before autoloads
# register. Allowlisted here exactly as the real plugins allowlist it.
^SCRIPT ERROR: Compile Error: Identifier not found: SingletonObject @@ at: GDScript::reload \(res://Scripts/
AL
echo "extends SceneTree" > "${PLUGINS}/demo/tests/gd/test_contract_guard.gd"

git -C "${PLUGINS}" init -q
git -C "${PLUGINS}" -c user.email=t@t -c user.name=t add -A
git -C "${PLUGINS}" -c user.email=t@t -c user.name=t commit -qm sandbox
REV="$(git -C "${PLUGINS}" rev-parse HEAD)"

# The fake godot. FAKE_MODE selects the canned suite output; everything else
# behaves like a healthy headless run, including writing into whatever user://
# resolves to, which is how the isolation cases get their evidence.
FAKE_GODOT="${SANDBOX}/fake-godot"
cat > "${FAKE_GODOT}" <<'FG'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version) echo "4.6.dev.custom_build"; exit 0 ;;
esac
for arg in "$@"; do
  if [ "${arg}" = "--import" ]; then
    [ "${FAKE_IMPORT_FAILS:-0}" = "1" ] && { echo "Parse Error: broken"; exit 1; }
    exit 0
  fi
done
# user:// write, so a run proves where its profile actually landed.
target="${FAKE_STOMP_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/godot/app_userdata/Minerva}"
mkdir -p "${target}" && echo "written by the fake host" > "${target}/plugins.db"
# Harness noise every healthy guard prints: on the plugin's allowlist.
echo "SCRIPT ERROR: Compile Error: Identifier not found: SingletonObject"
echo "   at: GDScript::reload (res://Scripts/Models/singleton_object.gd:12)"
case "${FAKE_MODE:-healthy}" in
  healthy) echo "=== Results: 3 passed, 0 failed === | wire: small req=10B reply=20B"; exit 0 ;;
  skip)    echo "SKIP: demo-plugin binary not built at '/nowhere/demo-plugin'."
           echo "=== Results: 0 passed, 0 failed ==="; exit 0 ;;
  setup)   echo "SETUP FAILED — the real chain did not mount; cases not run"
           echo "=== Results: 3 passed, 0 failed ==="; exit 0 ;;
  silent)  echo "quit before reporting"; exit 0 ;;
  failing) echo "=== Results: 2 passed, 1 failed ==="; exit 1 ;;
  greenfail) echo "=== Results: 2 passed, 1 failed ==="; exit 0 ;;
  diag)    echo "SCRIPT ERROR: Invalid call. Nonexistent function 'evaluate' in base 'Node'."
           echo "   at: _case_small_happy (res://../../minerva-plugins/demo/tests/gd/test_contract_guard.gd:99)"
           echo "=== Results: 3 passed, 0 failed ==="; exit 0 ;;
  hang)    sleep 120; exit 0 ;;
esac
FG
chmod +x "${FAKE_GODOT}"

PASS=0
FAIL=0
run_case() {
  # run_case <name> <expected-exit> <expected-substring-in-output> [extra runner args...]
  local name="$1" want_rc="$2" want_msg="$3"; shift 3
  local out_dir="${SANDBOX}/out-${name}"
  local log="${SANDBOX}/${name}.out"
  rm -rf "${out_dir}"
  CONTRACT_GUARDS_PLUGINS_ROOT="${PLUGINS}" XDG_DATA_HOME="${DEV_PROFILE}" \
    "${RUNNER}" --minerva "${HOST}" --godot "${FAKE_GODOT}" --plugin-rev "${REV}" \
    --out "${out_dir}" "$@" > "${log}" 2>&1
  local rc=$?
  local ok=1
  [ "${rc}" -eq "${want_rc}" ] || ok=0
  if [ -n "${want_msg}" ] && ! grep -qF "${want_msg}" "${log}"; then ok=0; fi
  if [ "${ok}" -eq 1 ]; then
    PASS=$((PASS + 1))
    echo "ok    ${name} (exit ${rc})"
  else
    FAIL=$((FAIL + 1))
    echo "FAIL  ${name}: expected exit ${want_rc} and '${want_msg}', got exit ${rc}"
    sed -n '1,40p' "${log}" | sed 's/^/        /'
  fi
}

echo "=== control: a healthy guard passes (and its allowlisted compile noise does not red it) ==="
FAKE_MODE=healthy run_case healthy 0 "ALL GUARDS PASSED"

# Isolation, positive and negative. The control run must have written user://
# under --out and left the stand-in developer profile untouched.
if [ -f "${SANDBOX}/out-healthy/userdata/data/godot/app_userdata/Minerva/plugins.db" ]; then
  PASS=$((PASS + 1)); echo "ok    isolation: user:// landed under --out"
else
  FAIL=$((FAIL + 1)); echo "FAIL  isolation: nothing written under --out/userdata"
fi
if [ "$(cat "${DEV_PROFILE}/godot/app_userdata/Minerva/keep.cfg")" = "existing" ] \
   && [ ! -e "${DEV_PROFILE}/godot/app_userdata/Minerva/plugins.db" ]; then
  PASS=$((PASS + 1)); echo "ok    isolation: the developer profile is untouched"
else
  FAIL=$((FAIL + 1)); echo "FAIL  isolation: the developer profile was written to"
fi
if grep -qE '^demo +PASS 3/3 assertions \(0 failed\), exit 0, [0-9]+s, worker [0-9a-f]{12}$' "${SANDBOX}/healthy.out"; then
  PASS=$((PASS + 1)); echo "ok    the human summary row is column-aligned"
else
  FAIL=$((FAIL + 1)); echo "FAIL  human summary row is malformed:"; grep -A3 "contract guards ==" "${SANDBOX}/healthy.out" | sed 's/^/        /'
fi
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["guards"][0]["verdict"]=="PASS" and d["guards"][0]["pinned"]==3 and d["guards"][0]["binary_sha256"] else 1)' \
     "${SANDBOX}/out-healthy/summary.json"; then
  PASS=$((PASS + 1)); echo "ok    summary.json records the verdict, the pin and the worker sha256"
else
  FAIL=$((FAIL + 1)); echo "FAIL  summary.json is missing the verdict/pin/sha"
fi

echo
echo "=== planted defects ==="
# (c) a guard that skips, or whose chain did not mount, is a FAILURE
FAKE_MODE=skip    run_case skip 1 "the guard skipped or failed setup"
FAKE_MODE=setup   run_case setup_failed 1 "SETUP FAILED"
# a guard that never reports, and one that reports failures while exiting 0
FAKE_MODE=silent  run_case no_results 1 "quit or crashed before reporting"
FAKE_MODE=failing run_case failing 1 "godot exited 1"
FAKE_MODE=greenfail run_case failed_but_exit_zero 1 "1 failed assertion"
# an unexplained fatal diagnostic, against the same allowlist the real plugins use
FAKE_MODE=diag    run_case unallowlisted_diagnostic 1 "not on demo/tests/gd/KNOWN_HARNESS_DIAGNOSTICS"
# (b) a pin off by one
sed -i 's/assertions=3/assertions=4/' "${PLUGINS}/demo/tests/gd/EXPECTED_SUITES"
FAKE_MODE=healthy run_case pin_off_by_one 1 "assertion count drifted"
sed -i 's/assertions=4/assertions=3/' "${PLUGINS}/demo/tests/gd/EXPECTED_SUITES"
# a guard with no pin at all cannot prove it did not shrink
sed -i 's/ assertions=3//' "${PLUGINS}/demo/tests/gd/EXPECTED_SUITES"
FAKE_MODE=healthy run_case unpinned_guard 2 "has no 'assertions=N' pin"
echo "test_contract_guard.gd assertions=3" > "${PLUGINS}/demo/tests/gd/EXPECTED_SUITES"
# a timeout is a failure, not a pass
FAKE_MODE=hang    run_case timeout 1 "timed out after 2s" --timeout 2
# (e) the developer's profile must come back byte-identical
FAKE_MODE=healthy FAKE_STOMP_DIR="${DEV_PROFILE}/godot/app_userdata/Minerva" \
  run_case profile_stomped 2 "modified the real user-data directory"
rm -f "${DEV_PROFILE}/godot/app_userdata/Minerva/plugins.db"
# a failed build never reaches the suite
DEMO_BUILD_FAILS=1 FAKE_MODE=healthy run_case build_failure 2 "build failed"
# a toolchain older than the manifest's own `requires` minimum never builds
python3 - "${PLUGINS}/demo/manifest.json" <<'PYMF'
import json, sys
path = sys.argv[1]
mf = json.load(open(path))
mf["setup"]["requires"] = [{"tool": "go", "min": "99.0"}]
json.dump(mf, open(path, "w"))
PYMF
FAKE_MODE=healthy run_case toolchain_too_old 2 "older than the manifest's required 99.0"
python3 - "${PLUGINS}/demo/manifest.json" <<'PYMF'
import json, sys
path = sys.argv[1]
mf = json.load(open(path))
mf["setup"].pop("requires")
json.dump(mf, open(path, "w"))
PYMF
# a failed --import is fatal (the permissive runner swallows it with || true)
FAKE_IMPORT_FAILS=1 FAKE_MODE=healthy run_case import_failure 2 "godot --import exited nonzero"

echo
echo "=== preconditions ==="
# (a) a host without built native extensions
mv "${EXT_LIB}" "${SANDBOX}/stashed-lib"
FAKE_MODE=healthy run_case unbuilt_extensions 2 "UNBUILT native extensions"
mv "${SANDBOX}/stashed-lib" "${EXT_LIB}"
# (d) sibling-layout mismatch names BOTH paths
mkdir -p "${SANDBOX}/elsewhere"
cp -r "${HOST}" "${SANDBOX}/elsewhere/minerva"
out="${SANDBOX}/out-sibling"
CONTRACT_GUARDS_PLUGINS_ROOT="${PLUGINS}" XDG_DATA_HOME="${DEV_PROFILE}" \
  "${RUNNER}" --minerva "${SANDBOX}/elsewhere/minerva" --godot "${FAKE_GODOT}" \
  --plugin-rev "${REV}" --out "${out}" > "${SANDBOX}/sibling.out" 2>&1
rc=$?
if [ "${rc}" -eq 2 ] && grep -q "sibling-layout mismatch" "${SANDBOX}/sibling.out" \
   && grep -qF "${PLUGINS}" "${SANDBOX}/sibling.out"; then
  PASS=$((PASS + 1)); echo "ok    sibling_mismatch (exit 2, both paths named)"
else
  FAIL=$((FAIL + 1)); echo "FAIL  sibling_mismatch: exit ${rc}"; sed -n '1,20p' "${SANDBOX}/sibling.out"
fi
# a revision that is not the checkout under test
out="${SANDBOX}/out-rev"
CONTRACT_GUARDS_PLUGINS_ROOT="${PLUGINS}" XDG_DATA_HOME="${DEV_PROFILE}" \
  "${RUNNER}" --minerva "${HOST}" --godot "${FAKE_GODOT}" \
  --plugin-rev 0000000000000000000000000000000000000000 --out "${out}" \
  > "${SANDBOX}/rev.out" 2>&1
rc=$?
if [ "${rc}" -eq 2 ] && grep -q "is not the checkout under test" "${SANDBOX}/rev.out"; then
  PASS=$((PASS + 1)); echo "ok    plugin_rev_mismatch (exit 2)"
else
  FAIL=$((FAIL + 1)); echo "FAIL  plugin_rev_mismatch: exit ${rc}"; sed -n '1,20p' "${SANDBOX}/rev.out"
fi
# an unknown plugin id
FAKE_MODE=healthy run_case unknown_plugin 2 "has no tests/gd/test_contract_guard.gd" --plugins nosuch

echo
echo "${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
