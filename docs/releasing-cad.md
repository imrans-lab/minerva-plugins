# CAD releases and the marketplace registry

1. Bump `cad/manifest.json` and `cad/main.go` to the same new version.
2. Push `main`. The CAD workflow builds and tests the platform packages, then
   publishes `cad-v<version>`. Do not push a separate tag: main owns publication.
3. Wait for the CAD workflow to succeed and check the release assets.
4. Run `git fetch --tags`, then `python3 scripts/regen_registry.py`.
5. Run `python3 scripts/regen_registry.py --check --published`, then commit and
   push `registry.json` so the marketplace advertises the verified release.

Registry generation uses manifests from release tags, including their platform
lists. The committed registry pins those releases. Validation checks those pins,
not the newest development manifest or whichever tags have just arrived. A
manifest bump can therefore pass CI while the registry still advertises the
previous usable release. The published check uses `gh` authentication and checks
that GitHub lists every advertised asset as uploaded and nonempty; it does not
replace package smoke tests.

A main push with an existing CAD version runs CI but preserves that version's
release assets. Its new artifacts are available from the workflow run. Bump the
version to publish changed runtime code. Tag pushes do not start another CAD
build. A workflow rerun after publication also preserves the release.

A tag left behind by a failed publication needs investigation and explicit
recovery; it is not automatically overwritten. `dcr/**` branch prereleases keep
their existing branch-tag behavior and are excluded from the marketplace.
