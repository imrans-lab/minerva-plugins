"""STANDING GUARD 1 — fabrication-output DETERMINISM GATE.

Load-bearing invariant of the hermetic-CAM story: the SAME canonical board must
compile to BYTE-IDENTICAL fabrication output every run. If it does not, goldens
are meaningless, diffs are noise, and "reproducible build" is a lie.

This is a REAL functional test: it runs the production emitter
(``pcb_worker.gerber.build_gerbers``) twice over real fixture boards and compares
the emitted bytes. No mocking, no golden files — two live emissions.

EMITTER DETERMINISM, AS FOUND (see pcb_worker/gerber.py docstring + _dump):
  * The ONLY wall-clock-volatile bytes gerber-writer would emit are the
    ``TF.CreationDate`` X2 attribute (Gerber) and the ``CREATED_BY=... <date>``
    header line (Excellon). The emitter PINS both to ``PINNED_CREATION_DATE``
    ("1970-01-01T00:00:00", SOURCE_DATE_EPOCH-style) by default, and exposes a
    ``creation_date=`` injection point for callers who want a real dated stamp.
  * Everything else — layer order, aperture assignment, drill tool numbering,
    coordinate emission — is deterministic by construction (ascending-sorted
    tool tables, fixed layer sequence, gerber-writer aperture reuse).

CONSEQUENCE FOR THIS GATE: because the timestamp is pinned by DEFAULT, the gate
needs NO normalization at all. It asserts RAW byte-identity, so ordering
(layers/apertures/drills) is fully in scope — if any of it varied run-to-run,
this gate would catch it. True byte-reproducibility IS met by current code
(injection-point case (a), docket SB.3); no field is normalized away.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import gerber

HERE = Path(__file__).resolve().parent  # pcb/worker/tests
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE / "testdata" / "gerber_boards" / "drilltest.yaml"

CASES = [(SPIKE_BOARD, "board"), (DRILL_BOARD, "drilltest")]


def _load(path: Path) -> dict:
    return yaml.safe_load(path.read_text(encoding="utf-8"))


@pytest.mark.parametrize("board_path,base", CASES)
def test_emit_is_byte_identical_across_runs(board_path, base):
    """Same board, two live emissions -> byte-identical file set.

    RAW comparison, DELIBERATELY un-normalized: no timestamp scrubbing, no
    ordering sort. The timestamp is already pinned by the emitter default, so any
    difference here would be a genuine determinism bug (volatile field, unstable
    layer/aperture/drill ordering, dict-iteration nondeterminism). That is
    exactly what this guard exists to catch.
    """
    board = _load(board_path)

    first = gerber.build_gerbers(board, name=base)
    second = gerber.build_gerbers(board, name=base)

    # File SET (names + order) is identical.
    assert list(first.keys()) == list(second.keys()), (
        f"{base}: emitted file set/order changed between runs: "
        f"{list(first.keys())} vs {list(second.keys())}"
    )

    # Every file is byte-for-byte identical.
    diffs = [name for name in first if first[name] != second[name]]
    assert not diffs, (
        f"{base}: non-deterministic output in {diffs} — the emitter produced "
        f"different bytes for the same input on a second run"
    )


@pytest.mark.parametrize("board_path,base", CASES)
def test_creation_date_is_the_only_volatile_field(board_path, base):
    """Proof/justification that ONE field (the creation timestamp) is the sole
    wall-clock-volatile byte, and that it is fully controlled by the injection
    point (so pinning it is sufficient for reproducibility).

    We emit the SAME board with two DIFFERENT explicit ``creation_date`` values
    and assert the file set is identical and the ONLY lines that differ are the
    timestamp-bearing ones (``TF.CreationDate`` in Gerber, ``CREATED_BY`` in
    Excellon). This documents WHY the default pin makes the gate above truly
    green: there is nothing else to normalize.
    """
    board = _load(board_path)

    a = gerber.build_gerbers(board, name=base, creation_date="2001-01-01T00:00:00")
    b = gerber.build_gerbers(board, name=base, creation_date="2099-12-31T23:59:59")

    assert list(a.keys()) == list(b.keys())

    for name in a:
        la = a[name].splitlines()
        lb = b[name].splitlines()
        assert len(la) == len(lb), (
            f"{name}: timestamp change altered line COUNT — that means a "
            f"non-timestamp byte moved, i.e. more than one volatile field"
        )
        differing = [(x, y) for x, y in zip(la, lb) if x != y]
        for x, y in differing:
            marker = "TF.CreationDate" in x or "CREATED_BY" in x
            assert marker, (
                f"{name}: a NON-timestamp line differs between two creation "
                f"dates: {x!r} vs {y!r} — there is more than one volatile field"
            )
