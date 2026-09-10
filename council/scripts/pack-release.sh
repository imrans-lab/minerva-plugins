#!/usr/bin/env bash
# Assemble the marketplace archive for one release target.
#
#   scripts/pack-release.sh --print-name linux-x86_64
#   scripts/pack-release.sh linux-x86_64 build/council-plugin dist
#
# Run from the plugin directory (the one holding manifest.json). The archive is
# written to <outdir>/council-<version>-<target>.tar.gz with every member at the
# archive ROOT, because the host extracts it directly into the plugin directory:
# a wrapping top-level folder would put manifest.json one level below where the
# installer looks for it.
#
# What ships is derived from the manifest wherever the manifest declares it —
# backend.entrypoint, the panel's entry_scene and its scripts — so a newly
# declared script is packed without editing this file, and a file the manifest
# does not declare cannot reach the archive by sitting in the same directory.
# The rest is an explicit list: assets the host reads at runtime (the page the
# wrapper stages, the schemas and the shipped councils) and the text a recipient
# needs (README, docs, licence). ui/src and ui/tests are the panel's build
# sources and its screenshot harness — about 3 MB the panel never reads — and
# are excluded by construction, since nothing names them.
#
# The packed manifest has `setup` removed BEFORE SHA256SUMS is written, so the
# checksum covers the file that ships. `setup` is the source lane's instruction
# to run `go build` against a checkout; the archive carries that build's output
# and no checkout, and a host that ran the stanza anyway would fail on source
# that was never packaged.
set -euo pipefail

# --print-name answers with the name this script would write, computed from the
# same line that names the file. The registry advertises a download URL built
# from its own convention, and scripts/test_registry.py compares that URL to
# THIS answer — so the check is only worth anything while the two paths share
# one derivation. Restating the convention here would make the parity test pass
# over a renamed archive.
print_name=false
if [ "${1:-}" = "--print-name" ]; then
  print_name=true
  shift
fi

target=${1:?usage: pack-release.sh [--print-name] <target> [built-binary] [outdir]}

# The target has to be one the manifest says this build is for. Packing an
# undeclared target would produce an asset the registry never advertises, or —
# worse, once release_targets grows — one it advertises without validation.
python3 - "$target" <<'GUARD'
import json, sys
targets = json.load(open("manifest.json")).get("release_targets") or []
if sys.argv[1] not in targets:
    raise SystemExit(f"manifest release_targets is {targets}; refusing to pack {sys.argv[1]!r}")
GUARD

version=$(python3 -c 'import json; print(json.load(open("manifest.json"))["version"])')
archive="council-${version}-${target}.tar.gz"

if $print_name; then
  echo "$archive"
  exit 0
fi

binary=${2:?usage: pack-release.sh <target> <built-binary> <outdir>}
outdir=${3:?usage: pack-release.sh <target> <built-binary> <outdir>}
entrypoint=$(python3 -c 'import json; print(json.load(open("manifest.json"))["backend"]["entrypoint"])')

packdir="${outdir}/council-${version}-${target}"
rm -rf "$packdir"
mkdir -p "$packdir"

# backend.entrypoint is a path relative to the plugin root ("./council-plugin"),
# and the host starts exactly that path. Copying the build output to any other
# name produces an archive that installs and then fails to start.
install -m 0755 "$binary" "$packdir/${entrypoint#./}"

python3 - "$packdir" <<'PY'
import json, os, shutil, sys

packdir = sys.argv[1]
manifest = json.load(open("manifest.json"))

# The panel's own files, named by the manifest the host audits the scene against.
paths = []
for panel in manifest.get("ui", {}).get("panels", []):
    paths.append(panel["entry_scene"])
    paths.extend(panel.get("scripts", []))

# Assets the manifest does not name file by file. The page is staged by
# council_bridge.gd rather than declared, and the schemas and presets are also
# embedded in the binary — they ship beside it so the archive can be read and
# checked without running anything.
paths.append("ui/panel.html")
for directory in ("schemas", "presets"):
    paths.extend(sorted(
        f"{directory}/{name}" for name in os.listdir(directory) if name.endswith(".json")))

# docs/ is NOT globbed. Most of it is maintainer text with no reader on an
# installed machine — a validation record naming /tmp logs, a packaging
# procedure for people with a checkout. architecture.md is the one document
# that answers a question a user of the installed plugin can have.
paths.append("docs/architecture.md")
paths.append("README.md")

for path in paths:
    destination = os.path.join(packdir, path)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    shutil.copy2(path, destination)

# The repository licence covers everything here: the backend has no dependency
# outside the Go standard library and the page loads nothing at runtime, so
# there is no third-party notice to carry.
shutil.copy2("../LICENSE.md", os.path.join(packdir, "LICENSE.md"))

manifest.pop("setup", None)
with open(os.path.join(packdir, "manifest.json"), "w") as out:
    json.dump(manifest, out, indent=2)
    out.write("\n")
PY

# Two spaces between the digest and the name: that is the format `sha256sum -c`
# reads, and the verifier re-checks these sums after extraction.
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$packdir" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 sha256sum | sed 's|  \./|  |' > SHA256SUMS)
else
  (cd "$packdir" && find . -type f ! -name SHA256SUMS -print0 | sort -z \
    | xargs -0 shasum -a 256 | sed 's|  \./|  |' > SHA256SUMS)
fi

# A reproducible tarball: the same tree packs to the same bytes on any machine
# and at any time, so two builds of one commit can be compared rather than
# trusted. --sort=name fixes member order, --mtime/--owner/--group erase the
# timestamps and ids the staging tree happens to carry, and gzip -n keeps the
# filename and the current time out of the gzip header — which is what -z would
# otherwise write, and is on its own enough to make every archive unique.
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -cf - -C "$packdir" . | gzip -n > "${outdir}/${archive}"
echo "${outdir}/${archive}"
