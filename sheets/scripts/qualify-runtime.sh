#!/usr/bin/env bash
# Exact-runtime preset for an assembled Minerva agent-container job.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  echo "usage: $0 PATH_TO_ASSEMBLED_MINERVA" >&2
  exit 2
fi
host_root="$(cd "$1" && pwd -P)"
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ -z "${MINERVA_JOB_ID:-}" || "$host_root" != /tmp/job/Minerva || "$plugin_root" != /tmp/job/minerva-plugins/sheets ]]; then
  echo "Refusing runtime qualification outside an assembled agent-container job" >&2
  exit 2
fi
log_directory="${MINERVA_TEST_LOG_DIR:-$host_root/sheets-runtime-evidence}"
if [[ "$log_directory" != /* ]]; then
  log_directory="$host_root/$log_directory"
fi
mkdir -p "$log_directory"
export MINERVA_TEST_LOG_DIR="$log_directory"
(
  cd "$host_root"
  python3 -B scripts/container-build/dev-natives.py &&
    godot --headless --path src --import &&
    cd "$plugin_root" &&
    go vet ./... &&
    go test ./... &&
    xvfb-run -a env MINERVA_TEST_DISPLAY=test_sheets_staging.gd bash scripts/run-gd-tests.sh "$host_root"
) 2>&1 | tee "$log_directory/sheets-runtime.log"
