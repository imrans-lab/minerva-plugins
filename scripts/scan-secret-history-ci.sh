#!/usr/bin/env bash
set -euo pipefail

# Translates a CI event into a revision range for scan-secret-history.sh. The
# endpoints come from the event payload rather than from a diff against a
# moving branch, so the range is exactly what this push or PR adds — including
# a credential introduced and deleted within the same range.

ROOT="$(git rev-parse --show-toplevel)"
scanner="${PLUGINS_SECRET_SCAN_WRAPPER:-$ROOT/scripts/scan-secret-history.sh}"

sha_pattern='^[0-9a-fA-F]{40}$'
require_commit() {
  [[ "$1" =~ $sha_pattern ]] || { echo "Secret scan endpoint is invalid" >&2; exit 2; }
  git -C "$ROOT" cat-file -e "$1^{commit}" \
    || { echo "Secret scan cannot resolve $1" >&2; exit 2; }
}

case "${GITHUB_EVENT_NAME:-}" in
  workflow_dispatch)
    exec "$scanner" --all-history
    ;;
  pull_request)
    require_commit "${SECRET_SCAN_BASE:-}"
    require_commit "${SECRET_SCAN_HEAD:-}"
    exec "$scanner" --range "$SECRET_SCAN_BASE..$SECRET_SCAN_HEAD"
    ;;
  push)
    require_commit "${SECRET_SCAN_HEAD:-}"
    # A new branch reports an all-zero "before"; scan everything the branch
    # carries that no other ref already has.
    if [[ "${SECRET_SCAN_BASE:-}" == "0000000000000000000000000000000000000000" ]]; then
      exec "$scanner" --range "$SECRET_SCAN_HEAD"
    fi
    require_commit "${SECRET_SCAN_BASE:-}"
    exec "$scanner" --range "$SECRET_SCAN_BASE..$SECRET_SCAN_HEAD"
    ;;
  *)
    echo "Secret scan does not recognize this CI event" >&2
    exit 2
    ;;
esac
