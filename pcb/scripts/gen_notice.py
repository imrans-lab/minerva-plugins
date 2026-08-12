#!/usr/bin/env python3
"""Generate pcb/NOTICE.md — the release-gate license/attribution inventory
for the footprint seed library (epoch LIB1, DCR 019ff568e203 station S5/B6).

WHAT THIS FILE IS AND WHY IT EXISTS
------------------------------------
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

There are currently zero violations in the shipped lock — every entry is
fully provenanced. The rule exists for the future entry that is NOT: the
census test above deliberately lets a human stage a part with
``license: "UNKNOWN — pending legal review"`` so the board keeps compiling
and every OTHER PR keeps passing dev CI while that one question is open.
This generator is what stops that same entry from ever reaching a shipped
NOTICE — and therefore a release — while its license remains unresolved.

DETERMINISM
-----------
The output is a pure function of the lock document's entries: refs and
licenses are visited in sorted order, and nothing here reads the clock, the
environment, or the filesystem beyond the lockfile itself. Running this
script twice against an unchanged lock produces byte-identical output.

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
from typing import Union

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
    violations = _gate_violations(entries)
    if violations:
        raise NoticeGateError(
            "footprint acquisition lock fails the NOTICE release gate "
            "(fail-closed) — every offending ref:\n  " + "\n  ".join(violations)
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
        "lists its footprint ref and its acquisition `source_ref`."
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

    lines.append(f"Total entries: {len(entries)}")
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
