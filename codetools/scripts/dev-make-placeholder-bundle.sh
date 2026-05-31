#!/usr/bin/env bash
#
# Dev-only: stage a tiny PLACEHOLDER embedded bundle for the HOST triple so
# `go build` / `go test` compile locally WITHOUT building the full PBS runtime.
#
# go:embed requires the embedded file to exist at compile time. This writes a
# few bytes (not a valid tar.zst) plus its matching .sha256, so:
#   - the binary compiles, and
#   - EnsureRuntime rejects it at runtime (sha matches but it isn't zstd), so
#     the Go shim falls through to Tier-3 (system python3) — enough to run the
#     worker and exercise the full MCP path locally.
#
# CI builds the REAL embedded bundle via scripts/build-python-runtime-bundle.sh.
# Placeholder files are git-ignored (bundle/.gitignore), so this never commits.
set -euo pipefail

cd "$(dirname "$0")/.."  # -> codetools/

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)  T=macos-arm64 ;;
  Darwin-x86_64) T=macos-amd64 ;;
  Linux-x86_64)  T=linux-x86_64 ;;
  Linux-aarch64) T=linux-arm64 ;;
  *) echo "unsupported host: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

OUT="internal/runtime/bundle/runtime-bundle-$T"
printf 'placeholder-not-a-real-bundle' > "$OUT.tar.zst"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$OUT.tar.zst" | awk '{print $1}' > "$OUT.sha256"
else
  shasum -a 256 "$OUT.tar.zst" | awk '{print $1}' > "$OUT.sha256"
fi
echo "staged placeholder bundle for $T:"
echo "  $OUT.tar.zst ($(wc -c < "$OUT.tar.zst") bytes) + .sha256"
echo "build/test now compile; the worker runs via system python3 (Tier 3)."
