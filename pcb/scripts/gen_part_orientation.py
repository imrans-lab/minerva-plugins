#!/usr/bin/env python3
"""Regenerate ``pcb/library/part_orientation.json`` from the drawings themselves.

WHAT THIS IS
------------
The part-orientation ledger's MEASURED rows are derived, never authored: each
one is ``pcb_worker.part_orientation`` run over one of our seed footprints and
the vendor's package drawing of the part we buy against it. This script is that
derivation, made re-runnable, so the committed file is verifiable by ``git
diff`` rather than by reading it and hoping.

Modelled on ``gen_notice.py``, deliberately: one ``generate()`` that both the
CLI and the test call, a ``--check`` mode that writes nothing and exits 1 on
drift, and a committed output whose byte-identity is pinned by a test. Two
generated library artifacts should be regenerated and gated the same way.

CONVERGENCE
-----------
Measured rows are REPLACED wholesale on every run, so:

* re-running with nothing changed produces byte-identical output;
* re-running after a seed footprint is edited changes exactly that footprint's
  rows, and nothing else drifts along with it;
* a pair removed from the corpus leaves no orphan row behind.

Declared rows — the human-authored "there is nothing to measure here"
statements for mounting holes, test points, fiducials, coupon fixtures and
synthetic composites — are read out of the existing ledger and passed through
UNTOUCHED. They carry no numbers, so there is nothing in them for a machine to
recompute; a generator that rewrote them would only be able to delete them.

NO CLOCK, NO VERSION STAMP
--------------------------
Nothing here writes a timestamp or a tool version into the output. Either would
make every regeneration a diff and destroy the one property the file is for.
When a row was measured is a question ``git log`` answers better.

WHERE THE VENDOR SIDE COMES FROM
--------------------------------
``pcb/worker/tests/testdata/vendor_footprints/`` — the committed LCSC/EasyEDA
package payloads, plus the ``index.json`` that pairs each part with the seed
footprint it is bought for. That directory is the pairing's single source of
truth; this script does not keep a second copy of it.

They live under the test corpus rather than under ``pcb/library/`` ON PURPOSE:
they are third-party vendor content, and ``pcb/library/`` is the shipped tree
whose third-party obligations ``gen_notice.py`` certifies from the acquisition
lock. Moving them there would put unattributed third-party data on the release
path that the NOTICE gate does not walk. The consequence — that a shipped
install cannot re-measure — is why every measured row pins
``footprint_sha256``: our own edits stay detectable without the payloads.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys

from pathlib import Path
from typing import Union

# pcb/scripts/this.py -> pcb/, so the worker package is a sibling directory.
# Same convention as gen_notice.py.
PCB = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PCB / "worker"))

from pcb_worker import orientation_ledger as ol  # noqa: E402
from pcb_worker import part_orientation as po  # noqa: E402
from pcb_worker.footprints import (  # noqa: E402
    DEFAULT_LOCKFILE,
    load_lockfile,
    resolve_footprint,
)

DEFAULT_PAYLOAD_DIR = PCB / "worker" / "tests" / "testdata" / "vendor_footprints"
DEFAULT_LEDGER_PATH = ol.DEFAULT_LEDGER_PATH
REGEN_COMMAND = "python3 pcb/scripts/gen_part_orientation.py"


class GenerationError(RuntimeError):
    """The ledger could not be derived. Never partially written."""


def _index(payload_dir: Path) -> dict:
    """The (part -> {footprint, house}) pairing, read from the corpus."""
    path = payload_dir / "index.json"
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise GenerationError(f"cannot read the pairing index {path}: {exc}") from exc
    if not isinstance(raw, dict) or not raw:
        raise GenerationError(f"{path} must be a non-empty object of part -> pairing")
    for part, entry in sorted(raw.items()):
        for field in ("footprint", "house"):
            value = entry.get(field) if isinstance(entry, dict) else None
            if not isinstance(value, str) or not value.strip():
                raise GenerationError(
                    f"{path}: {part} is missing a non-empty {field!r}. A pairing "
                    f"that does not name both the footprint and the house it is "
                    f"bought from names no orderable part")
    return raw


def generate(payload_dir: Union[str, Path, None] = None,
             ledger_path: Union[str, Path, None] = None,
             lockfile: Union[str, Path, None] = None) -> str:
    """Measure every pair in the corpus and render the whole ledger's bytes.

    Declared rows come from the ledger at *ledger_path* (absent file = none);
    measured rows are recomputed from scratch. The one function both ``main``
    and the test call, so the CLI and the suite can never derive the file two
    different ways.
    """
    payload_dir = Path(payload_dir) if payload_dir else DEFAULT_PAYLOAD_DIR
    ledger_path = Path(ledger_path) if ledger_path else DEFAULT_LEDGER_PATH
    lock = load_lockfile(lockfile if lockfile is not None else DEFAULT_LOCKFILE)

    try:
        base = ol.load_ledger(ledger_path)
    except ol.OrientationLedgerError:
        if ledger_path.exists():
            raise  # a malformed committed ledger must not be silently replaced
        base = ol.OrientationLedger()

    rows = []
    for part, pairing in sorted(_index(payload_dir).items()):
        ref = pairing["footprint"]
        entry = lock.get(ref)
        if entry is None:
            raise GenerationError(
                f"{part}: the corpus pairs it with {ref!r}, which the "
                f"acquisition lock does not carry — the pairing names a "
                f"footprint we do not ship")
        payload_path = payload_dir / f"{part}.json"
        try:
            payload_bytes = payload_path.read_bytes()
        except OSError as exc:
            raise GenerationError(
                f"{part}: cannot read its vendor payload {payload_path}: {exc}"
            ) from exc
        try:
            payload = json.loads(payload_bytes.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise GenerationError(f"{payload_path} is not valid JSON: {exc}") from exc

        # resolve_footprint re-verifies the on-disk bytes against the lock pin,
        # so the sha recorded beside the measurement is the sha of the drawing
        # that was actually measured, not a claim copied out of the lock.
        parsed = resolve_footprint(ref, lockfile=lockfile or DEFAULT_LOCKFILE)
        measurement = po.measure_footprint_against_part(parsed, payload, lcsc=part)
        rows.append(ol.record_from_measurement(
            ref, pairing["house"], part, measurement,
            footprint_sha256=str(entry["sha256"]),
            vendor_sha256=hashlib.sha256(payload_bytes).hexdigest(),
        ))

    return base.with_measured(rows).to_text()


def main(argv: Union[list, None] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--check", action="store_true",
        help="Write nothing; exit 1 if the committed ledger would differ from "
             "what this run derives.")
    ap.add_argument("--payloads", default=None,
                    help="Override the vendor payload + pairing directory.")
    ap.add_argument("--out", default=None,
                    help="Override the ledger path (default: "
                         "pcb/library/part_orientation.json, resolved relative "
                         "to this script, not the caller's cwd).")
    args = ap.parse_args(argv)

    out_path = Path(args.out) if args.out else DEFAULT_LEDGER_PATH
    try:
        body = generate(args.payloads, out_path)
    except Exception as exc:
        print(f"gen_part_orientation: cannot derive the ledger: {exc}",
              file=sys.stderr)
        return 1

    if args.check:
        current = out_path.read_text(encoding="utf-8") if out_path.is_file() else None
        if current == body:
            return 0
        print(f"gen_part_orientation: {out_path} has DRIFTED from the drawings "
              f"it is derived from. Regenerate with `{REGEN_COMMAND}` and READ "
              f"the diff: a changed offset means either the supplier redrew the "
              f"package or our footprint moved, and both need a human to look "
              f"at the board before the next order goes out.", file=sys.stderr)
        return 1

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(body, encoding="utf-8")
    print(f"gen_part_orientation: wrote {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
