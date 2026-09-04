Embedded Python runtime bundles land here, built by
`scripts/build-python-runtime-bundle.sh` and consumed by `go:embed` in
`embed_<triple>.go`.

The `runtime-bundle-*.tar.zst` and `.sha256` files committed here are
zero-byte placeholders. They make every target's Go package compile in a
fresh clone; an empty embedded bundle makes `sharedruntime.PythonPath` fall
through to the developer runtime tiers. The package CI job overwrites the
placeholders with the real, platform-specific bundle before building and must
never commit that output (CAD's OCP bundle is roughly 150–250 MiB).

`embed_test.go` deliberately rejects a placeholder bundle. It is the release
guard for package jobs, while local `go build` remains a useful startup/smoke
check without first constructing a runtime archive.
