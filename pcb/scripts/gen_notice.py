#!/usr/bin/env python3
"""Generate pcb/NOTICE.md — the release-gate license/attribution inventory
for this project's third-party content.

TWO INVENTORIES, because third-party content arrives two ways
--------------------------------------------------------------
1. ACQUIRED FILES — footprints vendored into ``pcb/library/``, pinned with
   their provenance in ``footprints.lock.json``. The bulk of this file.
2. SOURCE-EMBEDDED DATA TABLES — a glyph table, lookup table or coefficient
   set copied from a third-party source and stored as literal CONSTANTS
   inside one of our own source files (:data:`EMBEDDED_DATA_TABLES`).

(2) exists because (1) CANNOT see it: a file-provenance lock inventories FILES,
and a table of numbers inside a ``.py`` is not a file, so nothing in the
acquired-file walk below can reach one. :data:`EMBEDDED_DATA_TABLES` is empty
and the section renders anyway — an empty declared list is a claim a reader can
check, where an absent section is only silence.

WHAT THE FOOTPRINT INVENTORY IS AND WHY IT EXISTS
--------------------------------------------------
``pcb/library/footprints.lock.json`` (acquisition-lock schema v2, see
``pcb_worker.footprints`` and ``pcb/docs/libraries.md``) pins every footprint
the seed library ships, together with its provenance: ``source_kind``,
``source_ref``, ``license``, ``retrieved_at``. The census test
(``pcb/worker/tests/test_library_lock.py``) already walks that lock in dev
CI and fails on any entry missing provenance or whose vendored bytes drifted
from its sha pin — but it is a DEV gate: it accepts any non-empty license
string, including one a human marked ``"UNKNOWN"`` while an attribution
question was still open. That is the right behaviour for day-to-day
development (an in-progress entry should not block every unrelated PR) and
the wrong behaviour for a marketplace release, which must never ship a part
whose license is not actually settled.

This script is the RELEASE gate. It reuses the same one authority the census
test reads from — :func:`pcb_worker.footprints.load_lock_document` and
:data:`pcb_worker.footprints.LOCK_SOURCE_KINDS` — but refuses (rather than
merely flags) an entry whose license is unresolved, and turns every entry
that DOES pass into a human-readable, per-license NOTICE the marketplace
release pipeline (docket 019f985bd921 co-design) reads directly from this
same acquisition-lock schema.

GATE SEMANTICS (fail-closed)
-----------------------------
An entry FAILS the release gate — refusing the whole run, exit 1, naming
EVERY offending ref — if any of the following holds:

* ``source_kind`` is empty, missing, or not one of
  :data:`pcb_worker.footprints.LOCK_SOURCE_KINDS`;
* ``license`` is empty or missing, or contains the substring ``"unknown"``
  (case-insensitive) anywhere in it;
* ``source_ref`` is empty or missing.

The same three axes apply to every :data:`EMBEDDED_DATA_TABLES` entry, on its
own fields (``module``, ``license``, ``source_ref``, ``attribution``) — a
declared table with an unresolved licence must not ship either — plus a fourth
that only a source-embedded table needs: its declared ``module`` path must
exist, so a declaration cannot attribute a file that is not in the tree.

There are currently zero violations in the shipped lock — every entry is
fully provenanced. The rule exists for the future entry that is NOT: the
census test above deliberately lets a human stage a part with
``license: "UNKNOWN — pending legal review"`` so the board keeps compiling
and every OTHER PR keeps passing dev CI while that one question is open.
This generator is what stops that same entry from ever reaching a shipped
NOTICE — and therefore a release — while its license remains unresolved.

DETERMINISM
-----------
The output is a pure function of the lock document's entries and of
:data:`EMBEDDED_DATA_TABLES`: refs, licenses and tables are visited in sorted
order, and nothing here reads the clock or the environment. The only
filesystem reads are the lockfile and one existence check per declared
embedded table (the gate axis above) — neither reaches the OUTPUT, so running
this script twice against an unchanged lock produces byte-identical output.

MODES
-----
``python3 pcb/scripts/gen_notice.py``
    Writes ``pcb/NOTICE.md`` (paths resolved relative to this script's own
    location, never the caller's cwd — so ``cd`` before invoking it never
    changes what gets read or written).

``python3 pcb/scripts/gen_notice.py --check``
    Writes NOTHING. Exits 1 if the committed ``pcb/NOTICE.md`` differs from
    what this run would generate (drift gate) OR if the release gate above
    refuses the lock. Exits 0 only when the committed file is byte-identical
    to a fresh generation AND every entry passes the gate. This is the mode
    CI runs.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import NamedTuple, Union

# pcb/scripts/this.py -> pcb/, so the worker package is a sibling directory.
# Same convention as pcb/scripts/capture_emitter_golden.py.
PCB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PCB / "worker"))

from pcb_worker.footprints import (  # noqa: E402
    DEFAULT_LOCKFILE,
    LOCK_SOURCE_KINDS,
    load_lock_document,
)

DEFAULT_NOTICE_PATH = PCB / "NOTICE.md"
REGEN_COMMAND = "python3 pcb/scripts/gen_notice.py"

# Attribution language stated PLAINLY for every third-party license the seed
# library carries today. The proprietary note applies ONLY to the explicit
# internal LicenseRef (PROPRIETARY_LICENSE); any OTHER license without an
# entry here is a GATE VIOLATION (Codex 1160 P2) — a fallback that labeled an
# unmapped MIT part "internal, no third-party obligation" would make the
# release gate certify a materially false NOTICE. Widening the seed library
# to a new third-party license means adding its attribution entry here.
THIRD_PARTY_ATTRIBUTION = {
    "CC-BY-SA-4.0 WITH KiCad-libraries-exception": (
        "These entries are drawn from KiCad's official libraries "
        "(kicad-footprints), licensed CC-BY-SA-4.0 WITH the "
        "KiCad-libraries-exception. Redistribution requires attribution to "
        "the KiCad project — see "
        "https://gitlab.com/kicad/libraries/kicad-footprints/-/blob/master/LICENSE.md "
        "for the exception text this NOTICE satisfies."
    ),
    "Apache-2.0": (
        "These entries are drawn from Espressif's kicad-libraries, licensed "
        "under the Apache License, Version 2.0. Redistribution must retain "
        "the copyright notice and this attribution — see "
        "https://github.com/espressif/kicad-libraries/blob/master/LICENSE."
    ),
}

class EmbeddedDataTable(NamedTuple):
    """One third-party DATA TABLE stored as literal constants in our source.

    ``module`` is the repo-relative path of the file that holds it (so a
    reader can go look), ``what`` names the table itself, and the remaining
    three fields carry the same obligations an acquired file's lock entry
    carries: which licence, where it came from, and the attribution text the
    NOTICE must print to satisfy it.

    A NamedTuple rather than a dataclass on purpose: ``test_notice.py`` loads
    this script by file path WITHOUT registering it in ``sys.modules`` (it is
    a script, not an importable package member), and under ``from __future__
    import annotations`` ``@dataclass`` resolves its field types through
    ``sys.modules[cls.__module__]`` — which is ``None`` for such a module, so
    the class definition itself raises at import time. NamedTuple keeps the
    annotations as strings and does not.
    """

    module: str
    what: str
    license: str
    source_ref: str
    attribution: str


#: Every third-party data table embedded in this repository's own source.
#:
#: EMPTY IS THE CORRECT STATE, and it is a state that has to be maintained
#: rather than assumed: adding an entry here is the ONLY sanctioned way to
#: embed third-party data in a source file, and
#: ``worker/tests/test_notice.py`` fails if the shipped source grows an
#: undeclared table carrying one of the KNOWN glyph-table signatures it greps
#: for (family names and Newstroke's coordinate fingerprint) — it is a
#: signature check, not a general detector. Entries render in ``module`` order.
#:
#: A table whose licence is incompatible with this repository's
#: (``LICENSE.md``) does not belong here at all — declaring it does not make
#: it shippable, it only makes it visible. This list is for third-party data
#: we are ENTITLED to redistribute and OBLIGED to attribute.
EMBEDDED_DATA_TABLES: tuple = ()

EMBEDDED_SECTION_TITLE = "Source-embedded third-party data tables"

EMBEDDED_SECTION_INTRO = (
    "Data tables — glyph outlines, lookup tables, coefficient sets — taken "
    "from a third-party source and stored as literal constants inside this "
    "project's own source files. The footprint inventory above cannot see "
    "these: it inventories acquired FILES, and a table of constants inside a "
    "source file is not a file. This section is the second inventory, and it "
    "is maintained by hand in `EMBEDDED_DATA_TABLES` in "
    "`pcb/scripts/gen_notice.py`."
)

EMBEDDED_SECTION_EMPTY = (
    "**None.** Every data table in this project's source is authored "
    "in-house. Adding a third-party one means declaring it here."
)


PROPRIETARY_LICENSE = "LicenseRef-TurnRock-Proprietary"

PROPRIETARY_NOTE = (
    "Internal / TurnRock-authored parts. No third-party attribution "
    "obligation applies to the entries below."
)


class NoticeGateError(Exception):
    """Raised when the acquisition lock fails the release gate (fail-closed).

    The message names EVERY offending ref, never just the first — a release
    engineer fixing one violation and re-running should not discover the
    second one only on the next attempt.
    """


def _gate_violations(entries: dict) -> list:
    """Every release-gate violation in *entries*, one line per offending ref,
    refs visited in sorted order for a deterministic (and diffable) message.

    A single entry can fail on more than one axis (e.g. both an empty
    ``source_kind`` and an empty ``license``) — each axis is reported
    separately so a release engineer sees the whole problem at once instead
    of fixing one field, re-running, and discovering the next.
    """
    violations: list = []
    for ref in sorted(entries):
        entry = entries[ref]
        if not isinstance(entry, dict):
            violations.append(f"{ref}: entry is not an object ({entry!r})")
            continue

        source_kind = entry.get("source_kind")
        license_ = entry.get("license")
        source_ref = entry.get("source_ref")

        if not source_kind:
            violations.append(f"{ref}: missing/empty source_kind")
        elif source_kind not in LOCK_SOURCE_KINDS:
            violations.append(
                f"{ref}: source_kind {source_kind!r} is outside LOCK_SOURCE_KINDS "
                f"({sorted(LOCK_SOURCE_KINDS)})"
            )

        if not license_:
            violations.append(f"{ref}: missing/empty license")
        elif "unknown" in license_.lower():
            violations.append(
                f"{ref}: license {license_!r} contains \"unknown\" — the release "
                f"gate refuses an unresolved license even though dev CI's census "
                f"test allows it"
            )
        elif (license_ != PROPRIETARY_LICENSE
              and license_ not in THIRD_PARTY_ATTRIBUTION):
            violations.append(
                f"{ref}: license {license_!r} has no attribution mapping — add "
                f"its section text to THIRD_PARTY_ATTRIBUTION in "
                f"scripts/gen_notice.py; the generator refuses to guess "
                f"(labeling an unmapped third-party license as internal would "
                f"certify a false NOTICE)"
            )

        if not source_ref:
            violations.append(f"{ref}: missing/empty source_ref")

    return violations


def _embedded_violations(tables) -> list:
    """Every release-gate violation among the declared embedded data tables.

    Same three axes as an acquired footprint (missing provenance, an
    unresolved ``UNKNOWN`` licence, a missing source_ref), because a declared
    table carries exactly the same redistribution obligations as a vendored
    file — the only difference is that nothing else in the repository would
    have noticed it.

    Plus one axis an acquired footprint gets for free from its sha pin: the
    declared ``module`` must be a repo-relative path to a file that EXISTS
    inside the repository (:func:`_module_path_violations`). Nothing else
    resolves that path — the source scan in ``worker/tests/test_notice.py``
    only skips files it matches against it — so a typo, a rename or a deletion
    would otherwise leave a NOTICE attributing a file that is not there while
    silently un-skipping the file that is.
    """
    violations: list = []
    for table in sorted(tables, key=lambda t: t.module):
        for field in ("module", "what", "license", "source_ref", "attribution"):
            if not getattr(table, field, None):
                violations.append(
                    f"{table.module or '<unnamed table>'}: missing/empty {field}")
        if table.license and "unknown" in table.license.lower():
            violations.append(
                f"{table.module}: license {table.license!r} contains \"unknown\" "
                f"— an embedded third-party table must not ship with an "
                f"unresolved licence")
        if table.module:
            violations.extend(_module_path_violations(table.module))
    return violations


def _module_path_violations(module: str) -> list:
    """Why *module* is not a usable declaration path, or an empty list.

    SHAPE BEFORE EXISTENCE. The source scan in ``worker/tests/test_notice.py``
    skips a file by comparing its path RELATIVE TO THE REPOSITORY ROOT against
    this string, so only a repo-relative path can ever match one. An absolute
    path, or one climbing out through ``..``, would satisfy a bare
    ``is_file()`` against some file outside the repository while matching
    nothing the scan offers it — attributing a file this repository does not
    ship and leaving the in-tree file undeclared at the same time. Resolved
    once more after joining, so a symlink cannot walk out either.
    """
    path = Path(module)
    root = PCB.parent.resolve()
    if path.is_absolute() or ".." in path.parts:
        return [f"{module}: declared module must be a repository-relative path "
                f"(no leading separator, no \"..\"), the only form the source "
                f"scan can match"]
    resolved = (root / path).resolve()
    if not resolved.is_relative_to(root):
        return [f"{module}: declared module resolves outside the repository "
                f"root {root}"]
    if not resolved.is_file():
        return [f"{module}: declared module does not exist (paths are "
                f"relative to the repository root, the same form the source "
                f"scan compares against)"]
    return []


def _render_embedded_section(tables) -> list:
    """The embedded-data-table section's lines.

    It renders even when the list is EMPTY, and that is the point: a section
    that disappears when there is nothing to declare cannot tell a reader
    whether the inventory is clean or absent."""
    lines = [f"## {EMBEDDED_SECTION_TITLE}", "", EMBEDDED_SECTION_INTRO, ""]
    if not tables:
        lines.append(EMBEDDED_SECTION_EMPTY)
        lines.append("")
        return lines
    for table in sorted(tables, key=lambda t: t.module):
        lines.append(f"### `{table.module}` — {table.what}")
        lines.append("")
        lines.append(f"License: {table.license}")
        lines.append("")
        lines.append(f"Source: {table.source_ref}")
        lines.append("")
        lines.append(table.attribution)
        lines.append("")
    return lines


def _attribution_note(license_name: str) -> str:
    """The attribution paragraph for a license section.

    The proprietary note applies ONLY to the explicit internal LicenseRef;
    every other license must have a THIRD_PARTY_ATTRIBUTION entry. The gate
    (:func:`_gate_violations`) refuses unmapped licenses before rendering, so
    the KeyError branch here is unreachable through public entry points — it
    exists so a future caller that skips the gate crashes loudly instead of
    emitting the proprietary text for a third-party part."""
    if license_name == PROPRIETARY_LICENSE:
        return PROPRIETARY_NOTE
    return THIRD_PARTY_ATTRIBUTION[license_name]


def render_notice(entries: dict) -> str:
    """Render the deterministic NOTICE.md body for lock *entries*.

    Raises :class:`NoticeGateError` (naming every offending ref) if any entry
    fails the release gate — see the GATE SEMANTICS section of this module's
    docstring. The gate runs BEFORE any output is built, so a refused run
    never partially renders a NOTICE around the entries that did pass.
    """
    violations = _gate_violations(entries) + _embedded_violations(EMBEDDED_DATA_TABLES)
    if violations:
        raise NoticeGateError(
            "the NOTICE release gate refuses (fail-closed) — every offending "
            "footprint ref and embedded data table:\n  "
            + "\n  ".join(violations)
        )

    by_license: dict = {}
    for ref, entry in entries.items():
        by_license.setdefault(entry["license"], []).append(ref)

    lines: list = []
    lines.append("# NOTICE")
    lines.append("")
    lines.append("**This file is GENERATED. Do not hand-edit it.**")
    lines.append("")
    lines.append("Regenerate with:")
    lines.append("")
    lines.append(f"    {REGEN_COMMAND}")
    lines.append("")
    lines.append(
        "This is the license and attribution inventory for the footprint "
        "seed library pinned in `pcb/library/footprints.lock.json` "
        "(acquisition-lock schema v2 — see `pcb/docs/libraries.md`). It is "
        "the RELEASE gate: an entry with an unresolved (`UNKNOWN`) license, "
        "an out-of-vocabulary `source_kind`, or a missing `source_ref` "
        "refuses generation outright rather than shipping. One section "
        "below per DISTINCT license carried by the shipped lock; each entry "
        "lists its footprint ref and its acquisition `source_ref`. A final "
        "section inventories third-party data tables embedded directly in "
        "source, which no file-provenance lock can see."
    )
    lines.append("")

    for license_name in sorted(by_license):
        refs = sorted(by_license[license_name])
        lines.append(f"## {license_name}")
        lines.append("")
        lines.append(_attribution_note(license_name))
        lines.append("")
        for ref in refs:
            entry = entries[ref]
            piece = f"- `{ref}` — {entry['source_ref']}"
            provenance_note = entry.get("provenance_note")
            if provenance_note:
                piece += f" ({provenance_note})"
            lines.append(piece)
        lines.append("")

    lines.extend(_render_embedded_section(EMBEDDED_DATA_TABLES))

    lines.append(f"Total entries: {len(entries)} footprints, "
                 f"{len(EMBEDDED_DATA_TABLES)} embedded data tables")
    lines.append("")
    return "\n".join(lines)


def generate(lockfile: Union[str, Path, None] = None) -> str:
    """Load *lockfile* (default: the shipped seed lock) and render its
    NOTICE body. The one function both ``main`` and tests call so the CLI
    and the test suite can never read the lock two different ways."""
    doc = load_lock_document(lockfile if lockfile is not None else DEFAULT_LOCKFILE)
    return render_notice(doc["entries"])


def main(argv: Union[list, None] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check", action="store_true",
        help="Write nothing; exit 1 if the committed NOTICE.md would differ "
             "from what this run generates, or if the acquisition lock "
             "fails the release gate.",
    )
    ap.add_argument(
        "--lockfile", default=None,
        help="Override the acquisition lock path (default: "
             "pcb/library/footprints.lock.json, resolved relative to this "
             "script, not the caller's cwd).",
    )
    ap.add_argument(
        "--out", default=None,
        help="Override the NOTICE.md output path (default: pcb/NOTICE.md, "
             "resolved relative to this script, not the caller's cwd).",
    )
    args = ap.parse_args(argv)

    lockfile = Path(args.lockfile) if args.lockfile else DEFAULT_LOCKFILE
    out_path = Path(args.out) if args.out else DEFAULT_NOTICE_PATH

    try:
        body = generate(lockfile)
    except NoticeGateError as exc:
        print(f"gen_notice: RELEASE GATE REFUSED\n{exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # lockfile missing/unreadable/unsupported schema
        print(f"gen_notice: cannot load lockfile {lockfile}: {exc}", file=sys.stderr)
        return 1

    if args.check:
        if not out_path.is_file():
            print(f"gen_notice --check: {out_path} does not exist; "
                  f"run `{REGEN_COMMAND}`", file=sys.stderr)
            return 1
        current = out_path.read_text(encoding="utf-8")
        if current != body:
            print(f"gen_notice --check: {out_path} is stale (drift detected); "
                  f"regenerate with `{REGEN_COMMAND}` and commit the result",
                  file=sys.stderr)
            return 1
        print(f"gen_notice --check: {out_path} is up to date "
              f"({len(load_lock_document(lockfile)['entries'])} entries).")
        return 0

    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(body)
    print(f"gen_notice: wrote {out_path} "
          f"({len(load_lock_document(lockfile)['entries'])} entries).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
