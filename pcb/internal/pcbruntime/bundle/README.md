Embedded Python runtime bundles land here, built by
scripts/build-python-runtime-bundle.sh from pcb/scripts/runtime-bundle.lock
and consumed by go:embed in embed_<triple>.go.

The `runtime-bundle-*.tar.zst` / `.sha256` files COMMITTED here are ZERO-BYTE
PLACEHOLDERS: an empty embed makes sharedruntime.PythonPath fall through to
the dev tiers (worker/.venv, then python3 on PATH), so the plugin compiles
and tests on a fresh checkout with no bundle build. CI's package job
overwrites them with real bundles before go build (never commit those) —
roughly 25-110MB per platform: bare CPython plus three small wheels, NOT
cad's OCP-sized 150-250MB. The per-plugin 40MB binary-size assertion in
pcb.yml catches a release accidentally built from placeholders.
