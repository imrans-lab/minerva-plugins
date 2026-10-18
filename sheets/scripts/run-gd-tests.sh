#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" != --preflight-only ]]; then
  (cd "$SCRIPT_DIR/.." && go build -o tests/proxy/sheets-proxy ./tests/proxy)
fi
exec "${SCRIPT_DIR}/../../scripts/run-gd-tests.sh" --plugin sheets "$@"
