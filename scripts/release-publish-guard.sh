#!/usr/bin/env bash
# Release jobs must fetch tags before calling this guard.
set -euo pipefail
release_tag=$1
prerelease=$2
publish=true
# Explicit tag callers prove identity without treating their required tag as a
# pre-existing manual release. Legacy two-argument callers keep their behavior.
plugin_id="${3:-}"
if [[ -n "$plugin_id" && "${GITHUB_EVENT_NAME:-}" == push && "${GITHUB_REF:-}" == "refs/tags/$release_tag" ]]; then
  [[ "$prerelease" == false ]] || { echo "::error::A tagged release must be stable"; exit 1; }
  [[ "$(git cat-file -t "refs/tags/$release_tag")" == tag ]] || { echo "::error::An annotated tag is required"; exit 1; }
  [[ "$(git rev-parse "refs/tags/$release_tag^{commit}")" == "$(git rev-parse HEAD)" ]] || { echo "::error::Tag does not name this source"; exit 1; }
  version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$plugin_id/manifest.json")
  [[ "$release_tag" == "$plugin_id-v$version" ]] || { echo "::error::Tag and manifest version differ"; exit 1; }
elif [ "$prerelease" = false ] && git rev-parse --verify "refs/tags/$release_tag" >/dev/null 2>&1; then
  publish=false
  echo "::notice::Keeping existing $release_tag unchanged. Bump the manifest version for a new release."
  echo "Existing tag $release_tag preserved; CI artifacts are available for this commit." >> "$GITHUB_STEP_SUMMARY"
elif [[ -n "$plugin_id" && "$prerelease" == false ]]; then
  echo "::error::Push an annotated manifest-matching tag to publish a stable release"
  exit 1
fi
echo "publish=$publish" >> "$GITHUB_OUTPUT"
