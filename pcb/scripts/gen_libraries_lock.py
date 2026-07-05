#!/usr/bin/env python3
"""Regenerate pcb/libraries.lock.json from a KiCAD libraries release tag.

This is the ONLY place the curated common-parts subset is defined. Refreshing
to a newer KiCAD libraries release is an explicit, reviewable action:

    python pcb/scripts/gen_libraries_lock.py --tag 9.0.9.1
    git diff pcb/libraries.lock.json   # review what changed before committing

The lock manifest (URLs + sha256 + size — never the library bytes themselves)
is the only thing that lands in the repo; see docs/libraries.md for the
no-FCIB (files-checked-in-blob) policy this enforces.

WHY per-file pinning (not the GitLab archive-subpath mechanism):
Both `kicad-symbols` and `kicad-footprints` are plain GitLab repos. GitLab
supports two ways to fetch a subset of files at a tag:

  1. `.../-/raw/<tag>/<path>` — a single static blob. Verified via GitLab's own
     Cloudflare-backed CDN, serves `Accept-Ranges: bytes` (resumable), and its
     content is byte-stable for a given tag (immutable ref) — trivial to
     sha256-pin and trivial to fetch with a plain HTTP GET + Range resume.
  2. `.../-/archive/<tag>/<project>-<tag>.tar.gz?path=<subdir>` — a
     dynamically generated tarball of a whole subtree. This would let a
     single lock entry pull an entire `*.pretty` library (hundreds of
     footprints), but the archive is generated on request: no guaranteed
     stable ETag/Content-Length for Range-resume, and verifying it means
     unpacking tar+gzip in the fetcher (more moving parts) just to get a few
     curated footprints we could have named directly.

This round's subset is intentionally a curated common-parts set (not "the
whole library"), so option 1 wins outright: every entry is independently
resumable and verifiable with nothing more than net/http + sha256, and the
curated list IS the point (see docs/libraries.md "subset rationale"). A future
child wanting whole-library mirroring should revisit option 2 — the tradeoff
flips once the goal is "every footprint in Resistor_SMD.pretty", not a dozen
common ones.

WHY tag 9.0.9.1 (not the latest 10.0.4 stable tag):
KiCad 10's `kicad-symbols` repo reorganized: each library that used to be one
flat `<Name>.kicad_sym` file is now a `<Name>.kicad_symdir/` DIRECTORY of
per-symbol files. `kicad-footprints` did NOT undergo the equivalent split — its
`*.pretty` dirs of `*.kicad_mod` files are unchanged across 8.x/9.x/10.x. Tag
9.0.9.1 is the newest stable release where BOTH repos still use the flat
single-file-per-library `.kicad_sym` shape this round's check_libraries reads
(and that most KiCad installs in the wild still expect). Revisit when a future
child wants to add `.kicad_symdir` directory-of-files support to libcheck.py.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

SYMBOLS_REPO = "kicad/libraries/kicad-symbols"
FOOTPRINTS_REPO = "kicad/libraries/kicad-footprints"
RAW_URL_FMT = "https://gitlab.com/{repo}/-/raw/{tag}/{path}"

# --- The curated common-parts subset -----------------------------------
# Symbols: whole single-file libraries (kind="symbol_lib"); dest is the bare
# filename, landing flat at the top of lib_dir (matches how a real KiCad
# global library table lays out symbol libs, and how libcheck.list_symbol_libs
# reads them).
SYMBOL_LIBS = [
    "Device.kicad_sym",
    "Connector.kicad_sym",
    "Connector_Generic.kicad_sym",
    "power.kicad_sym",
    "MCU_Module.kicad_sym",
    "Regulator_Linear.kicad_sym",
]

# Footprints: individual .kicad_mod files (kind="footprint"); dest preserves
# the "<Lib>.pretty/<Name>.kicad_mod" shape libcheck.resolve_footprint expects.
FOOTPRINT_FILES = [
    "Resistor_SMD.pretty/R_0402_1005Metric.kicad_mod",
    "Resistor_SMD.pretty/R_0603_1608Metric.kicad_mod",
    "Resistor_SMD.pretty/R_0805_2012Metric.kicad_mod",
    "Capacitor_SMD.pretty/C_0402_1005Metric.kicad_mod",
    "Capacitor_SMD.pretty/C_0603_1608Metric.kicad_mod",
    "Capacitor_SMD.pretty/C_0805_2012Metric.kicad_mod",
    "LED_SMD.pretty/LED_0603_1608Metric.kicad_mod",
    "LED_SMD.pretty/LED_0805_2012Metric.kicad_mod",
    "Connector_PinHeader_2.54mm.pretty/PinHeader_1x02_P2.54mm_Vertical.kicad_mod",
    "Connector_PinHeader_2.54mm.pretty/PinHeader_1x04_P2.54mm_Vertical.kicad_mod",
    "Connector_PinHeader_2.54mm.pretty/PinHeader_2x05_P2.54mm_Vertical.kicad_mod",
    "Package_SO.pretty/SOIC-8_3.9x4.9mm_P1.27mm.kicad_mod",
    "Package_SO.pretty/SOIC-16_3.9x9.9mm_P1.27mm.kicad_mod",
]

DEFAULT_TAG = "9.0.9.1"
SCHEMA_VERSION = 1


def _fetch(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "minerva-pcb-gen-libraries-lock/1"})
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 (fixed https gitlab host)
        return resp.read()


def _entry(name: str, kind: str, repo: str, tag: str, path: str) -> dict:
    url = RAW_URL_FMT.format(repo=repo, tag=tag, path=path)
    try:
        data = _fetch(url)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f"fetch failed for {name!r} at {url}: HTTP {exc.code}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"fetch failed for {name!r} at {url}: {exc}") from exc
    digest = hashlib.sha256(data).hexdigest()
    return {
        "name": name,
        "kind": kind,
        "dest": path,
        "url": url,
        "sha256": digest,
        "size_bytes": len(data),
    }


def generate(tag: str) -> dict:
    entries = []
    print(f"Fetching {len(SYMBOL_LIBS)} symbol libs + {len(FOOTPRINT_FILES)} footprints "
          f"at tag {tag}...", file=sys.stderr)
    for path in SYMBOL_LIBS:
        print(f"  symbol_lib: {path}", file=sys.stderr)
        entries.append(_entry(path, "symbol_lib", SYMBOLS_REPO, tag, path))
    for path in FOOTPRINT_FILES:
        print(f"  footprint:  {path}", file=sys.stderr)
        entries.append(_entry(path, "footprint", FOOTPRINTS_REPO, tag, path))

    return {
        "schema_version": SCHEMA_VERSION,
        "tag": tag,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "symbols_repo": f"https://gitlab.com/{SYMBOLS_REPO}",
            "footprints_repo": f"https://gitlab.com/{FOOTPRINTS_REPO}",
        },
        "entries": entries,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--tag", default=DEFAULT_TAG,
                     help=f"KiCAD libraries release tag common to both repos (default: {DEFAULT_TAG})")
    ap.add_argument("--out", default=None,
                     help="Output path (default: <repo>/pcb/libraries.lock.json)")
    args = ap.parse_args()

    lock = generate(args.tag)

    out_path = args.out
    if out_path is None:
        from pathlib import Path
        out_path = str(Path(__file__).resolve().parents[1] / "libraries.lock.json")

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(lock, f, indent=2)
        f.write("\n")

    total_bytes = sum(e["size_bytes"] for e in lock["entries"])
    print(f"Wrote {out_path} — {len(lock['entries'])} entries, "
          f"{total_bytes / 1024:.1f} KiB total.", file=sys.stderr)


if __name__ == "__main__":
    main()
