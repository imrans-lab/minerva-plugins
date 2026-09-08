#!/usr/bin/env bash
# Release jobs must fetch tags before calling this guard.
set -euo pipefail
release_tag=$1
prerelease=$2
publish=true
if [ "$prerelease" = false ] && git rev-parse --verify "refs/tags/$release_tag" >/dev/null 2>&1; then
  publish=false
  echo "::notice::Keeping existing $release_tag unchanged. Bump the manifest version for a new release."
  echo "Existing tag $release_tag preserved; CI artifacts are available for this commit." >> "$GITHUB_STEP_SUMMARY"
fi
echo "publish=$publish" >> "$GITHUB_OUTPUT"
