# cad/licenses

Licence texts for third-party content that ships inside the cad plugin's
embedded Python runtime bundle. The whole directory is copied into the bundle
(`licenses/` beside the interpreter) by
`scripts/build-python-runtime-bundle.sh` — the lock file's
`BUNDLE_LICENSE_DIR` names it — and into the release tarball beside the
plugin binary, so a recipient of the binary distribution has the notices and
disclaimers the BSD/MIT terms require to be "provided with the distribution".

`runtime/` holds the texts, named `<distribution>-<version>.<upstream file>`.
The inventory that maps components to them lives in
`cad/scripts/notice_inventory.py`; the gate that refuses a release when the
two disagree is `cad/scripts/gen_notice.py`; the rendered result is
`cad/NOTICE.md`.

What the inventory is checked against is `cad/scripts/runtime-bundle.manifest`
— a census of every distribution in the BUILT bundle's site-packages, not the
two pins in `runtime-bundle.lock`. pip resolves the transitive tree, so the
lock names two distributions and the bundle contains forty-seven.

## Adding or bumping a runtime dependency

1. Build a bundle, then re-census it:
   `python3 cad/scripts/gen_notice.py --census <stage>/lib/python3.12/site-packages`
2. Take the licence TEXT from the new distribution's installed dist-info —
   wheels ship it under `LICENSE`, `LICENSE.txt`, `COPYING`, or inside
   `dist-info/licenses/` — and copy it into `runtime/` under the naming
   convention above. Where a wheel ships none, take it from the upstream
   project's tagged source and say so in the entry's note.
3. Add the entry to `notice_inventory.py`, then `python3
   cad/scripts/gen_notice.py` and commit the regenerated `NOTICE.md`.

The gate fails in every direction: a census distribution with no entry, an
entry for something no longer in the census, a version the census disagrees
with, a missing or empty text, a text no entry references, an unrecognised
licence, and a licence with an undischarged source-availability obligation.
