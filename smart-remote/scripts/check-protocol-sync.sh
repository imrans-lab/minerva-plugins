#!/usr/bin/env bash
# Read-only cross-repository contract check; README records repository ownership.
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1" ]]; then
  echo "Usage: $0 /path/to/ccsandbox/smart-remote-v2/protocol" >&2
  exit 2
fi
scripts="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$scripts/check_protocol_sync.py" "$1"
