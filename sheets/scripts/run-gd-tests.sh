#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
preflight=false
for argument in "$@"; do
  if [[ "$argument" == --preflight-only ]]; then preflight=true; fi
done
if [[ "$preflight" == false ]]; then
  (cd "$SCRIPT_DIR/.." && go build -o tests/proxy/sheets-proxy ./tests/proxy)
fi
exec "${SCRIPT_DIR}/../../scripts/run-gd-tests.sh" --plugin sheets "$@"
