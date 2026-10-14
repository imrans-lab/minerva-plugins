#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# Public plugin source is allowed; product board data stays private.
tracked=$(git ls-files)
while IFS= read -r path; do
  [[ "$path" =~ [sS][mM][aA][rR][tT][-_]?[rR][eE][mM][oO][tT][eE] ]] || continue
  case "$path" in
    .github/workflows/smart-remote.yml) continue ;;
    smart-remote/proto/espressif/*.proto) continue ;;
    smart-remote/ui/PairingPanel.tscn|smart-remote/ui/pairing_panel.gd|smart-remote/ui/pairing_panel.gd.uid) continue ;;
    smart-remote/*.rs|smart-remote/*.md|smart-remote/*.py) continue ;;
    smart-remote/Cargo.toml|smart-remote/Cargo.lock|smart-remote/manifest.json|smart-remote/.gitignore|smart-remote/deny.toml) continue ;;
    smart-remote/protocol/schema/*.json|smart-remote/protocol/examples/*.jsonl) continue ;;
    smart-remote/scripts/check-protocol-sync.sh|smart-remote/scripts/protocol-owner-amendment.json) continue ;;
  esac
  echo "::error::product board file is banned: $path (see pcb/worker/tests/testdata/POLICY.md)"
  exit 1
done <<< "$tracked"
# A renamed file still declares its identity in the canonical
# board contract's `name:` field — ban the identity itself.
status=0
git grep -nE '^[[:space:]]*name:[[:space:]]*["'"'"']?smart[-_]?remote' -- '*.yml' '*.yaml' ':!.github/workflows/smart-remote.yml' || status=$?
if [[ $status -eq 0 ]]; then
  echo "::error::the smart-remote board definition is banned from this public repo (see pcb/worker/tests/testdata/POLICY.md)"
  exit 1
elif [[ $status -ne 1 ]]; then
  echo "Corpus identity scan failed" >&2
  exit "$status"
fi
