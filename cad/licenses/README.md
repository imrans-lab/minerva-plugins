# cad/licenses

Licence texts for third-party content that ships inside the cad plugin's
embedded Python runtime bundle. The whole directory is copied into the bundle
(`licenses/` beside the interpreter) by
`scripts/build-python-runtime-bundle.sh` — the lock file's
`BUNDLE_LICENSE_DIR` names it — and into the release tarball beside the
plugin binary, so a recipient of the binary distribution has the notices and
disclaimers the BSD/MIT terms require to be "provided with the distribution".

`runtime/` holds one file per component. The inventory that maps components to
these files, and the gate that refuses a release when the two disagree, is
`cad/scripts/gen_notice.py`; the rendered inventory is `cad/NOTICE.md`.

Adding a runtime dependency means adding its licence text here AND its entry
in `gen_notice.py`. The gate fails in both directions: an inventory entry
whose text file is missing, and a text file no entry references.
