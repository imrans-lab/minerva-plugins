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

# The shared corpus orientation statement, autouse in this module: these
# boards are drawn on this repository's own land patterns, and orientation
# is measured by test_assembly_orientation.py, not here.
from tests.orientation_corpus import corpus_orientation  # noqa: F401
from tests.gerber_fab import (build_assembly_bom, build_assembly_cpl, build_fab,
                               build_raw_emitter)

HERE = Path(__file__).resolve().parent  # pcb/worker/tests
SPIKE_BOARD = HERE.parents[1] / "spikes" / "gerber" / "board.yaml"
DRILL_BOARD = HERE / "testdata" / "gerber_boards" / "drilltest.yaml"
QUAD_BOARD = HERE / "testdata" / "gerber_boards" / "quadlayer.yaml"
ZONE_BOARD = HERE / "testdata" / "zone_fill.yaml"
# The COMPILABLE assembly fixture: BOM/CPL are now derived from a strict
# compilation, so the determinism claim has to be measured on a board that
# has one. Its uncompilable twin (assembly_fixture.yaml) is the refusal
# fixture in test_assembly_outputs.py.
ASSEMBLY_BOARD = HERE / "testdata" / "assembly_boards" / "assembly_resolved.yaml"


# (board path, base name, builder). Spike -> PRODUCTION fab path (compile -> IR);
# drilltest -> raw loose-dict emitter (explicit drift fixture, not production).
CASES = [
    pytest.param(SPIKE_BOARD, "board", build_fab, id="board-production"),
    pytest.param(DRILL_BOARD, "drilltest", build_raw_emitter, id="drilltest-raw"),
    # ZONE FILL — added when pours became fabricable copper (C6).
    #
    # This gate is normally left alone during an epoch and this row is the
    # deliberate exception, for a reason specific to what a fill is. Every other
    # emitted feature is a direct transcription of an authored number: a pad is
    # where the author put it, a trace runs where the author drew it. A pour is
    # the only geometry the compiler DERIVES, through a polygon-boolean pipeline
    # with an offset kernel, a hole-to-outer assignment, a sort, and a fracture
    # step — four places where an unstable iteration order would produce
    # different-but-plausible copper on a second run, and nothing else in the
    # suite would notice. The fill is claimed to be deterministic BY
    # CONSTRUCTION (exact integer arithmetic in nanometres, no floats in the
    # booleans); this row is what turns that claim into something checked.
    #
    # It is also the gate that guards the fab story: two runs of the same board
    # must produce the same Gerber, or a "reproducible" fabrication package is a
    # lie the moment a pour is on the board.
    pytest.param(ZONE_BOARD, "zonefill", build_fab, id="zonefill-production"),
    # ASSEMBLY OUTPUTS — added when BOM/CPL became emitted artifacts (C8,
    # docket 019f763cdf5b), the SAME "extend the standing gate with one data
    # row" pattern C6 used for zonefill above. Two rows, not one: BOM and CPL
    # are two independent emitters (assembly_outputs.build_bom /
    # .build_cpl), each with its own file-set/ordering/formatting code path —
    # a determinism bug in one would not show up in the other.
    pytest.param(ASSEMBLY_BOARD, "afix", build_assembly_bom, id="assembly-bom-production"),
    pytest.param(ASSEMBLY_BOARD, "afix", build_assembly_cpl, id="assembly-cpl-production"),
    # QUAD LAYER (epoch GA-3) — same one-data-row pattern as zonefill above,
    # for the same reason applied to a new derivation surface: the N-layer
    # emitter DERIVES its file set, .gbrjob copper rows and per-layer object
    # streams from the declared stack (a loop, where the 2-layer path was
    # straight-line code), and an unstable iteration order there would
    # produce different-but-plausible fabrication on a second run. This row
    # checks the whole 4-layer package (inner copper files included) is
    # byte-identical across runs.
    pytest.param(QUAD_BOARD, "quadlayer", build_fab, id="quadlayer-production"),
]


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_emit_is_byte_identical_across_runs(board_path, base, builder):
    """Same board, two live emissions -> byte-identical file set.

    RAW comparison, DELIBERATELY un-normalized: no timestamp scrubbing, no
    ordering sort. The timestamp is already pinned by the emitter default, so any
    difference here would be a genuine determinism bug (volatile field, unstable
    layer/aperture/drill ordering, dict-iteration nondeterminism). That is
    exactly what this guard exists to catch.

    The spike goes through the ACTUAL production fab path, exactly as
    methods._gerbers does (K4 phase 1): COMPILE (strict) -> build_gerbers_ir.
    drilltest's hand-authored footprints aren't in the seed lib, so it is the
    explicit raw loose-dict drift fixture (build_raw_emitter, all-TH at rotation
    0) — determinism must hold on both the production and the raw emit path.
    """
    first = builder(board_path, base)
    second = builder(board_path, base)

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


@pytest.mark.parametrize("board_path,base,builder", CASES)
def test_creation_date_is_the_only_volatile_field(board_path, base, builder):
    """Proof/justification that ONE field (the creation timestamp) is the sole
    wall-clock-volatile byte, and that it is fully controlled by the injection
    point (so pinning it is sufficient for reproducibility).

    We emit the SAME board with two DIFFERENT explicit ``creation_date`` values
    and assert the file set is identical and the ONLY lines that differ are the
    timestamp-bearing ones (``TF.CreationDate`` in Gerber, ``CREATED_BY`` in
    Excellon). This documents WHY the default pin makes the gate above truly
    green: there is nothing else to normalize.
    """
    a = builder(board_path, base, creation_date="2001-01-01T00:00:00")
    b = builder(board_path, base, creation_date="2099-12-31T23:59:59")

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
            # The three timestamp spellings across the emitted artifact kinds:
            # Gerber X2 attribute, Excellon header comment, and the .gbrjob
            # manifest's JSON field (F1). Adding a spelling here is safe only
            # because the assertion below still requires EVERY differing line to
            # be a recognized timestamp — an unrecognized volatile byte still fails.
            marker = ("TF.CreationDate" in x or "CREATED_BY" in x
                      or '"CreationDate":' in x)
            assert marker, (
                f"{name}: a NON-timestamp line differs between two creation "
                f"dates: {x!r} vs {y!r} — there is more than one volatile field"
            )
