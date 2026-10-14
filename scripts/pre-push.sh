#!/usr/bin/env bash
set -euo pipefail
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 UPSTREAM_REF RUST_PLUGIN_DIRECTORY" >&2
  exit 2
fi
cd "$(git rev-parse --show-toplevel)"
base=$(git rev-parse --verify --end-of-options "$1^{commit}")
head=$(git rev-parse --verify HEAD)
git merge-base --is-ancestor "$base" "$head" || {
  echo "Upstream must be an ancestor of HEAD; reconcile before pushing" >&2
  exit 2
}
plugin=$2
[[ "$plugin" =~ ^[a-zA-Z0-9_-]+$ && -f "$plugin/Cargo.toml" ]] || {
  echo "Expected a Rust plugin directory at the repository root" >&2
  exit 2
}
[[ -z "$(git status --porcelain --untracked-files=normal)" ]] || {
  echo "Pre-push requires a clean checkout of the exact candidate" >&2
  exit 2
}
echo "Pre-push candidate: $base..$head ($plugin)"
scripts/check-corpus-policy.sh
scripts/scan-secret-history.sh --range "$base..$head"
(cd -- "./$plugin" && cargo fmt --all -- --check && cargo clippy --locked --all-targets -- -D warnings)
echo "Pre-push checks passed for $head"
