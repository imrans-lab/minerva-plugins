"""The PYTHON end of BT-81's cross-language cutout contract (campaign-2 boundary).

BT-81's stated oracle is "a board authored through the GDScript tool path and
validated by the Python validator: two languages, one contract".  Only the GD
half was ever wired: it serialized a board to ``user://pcb_cutout_gd_handoff.json``
and nothing read it, so the contract was one language (completeness critic, gap
6).  This file is the reader.

WHY A COMMITTED FIXTURE AND NOT A GENERATED FILE — the choice, recorded.
``.github/workflows/pcb.yml`` runs the GDScript suite in the ``panel`` job and
pytest in ``test`` / ``test-crossplatform`` / ``oracle``.  Those are separate
jobs on separate runners with separate checkouts, and Godot's ``user://`` is not
inside the repo at all.  A file written by one job simply does not exist for the
other.  Committing a *generated* artifact would leave this test reading whatever
some developer's laptop last produced — stale by construction and green anyway.

So ``testdata/gd_handoff_cutout.yaml`` is a hand-derived literal that BOTH sides
pin:

  * ``pcb/tests/gd/test_pcb_cutout.gd::_test_cross_language_handoff`` authors the
    same board through the canvas cutout tool and asserts its serializer emits
    EXACTLY this content (canonical, sorted-key, byte for byte);
  * this module asserts the shared-boundary validator ACCEPTS that same content
    and the compiler REFUSES it with the unsupported-feature code.

Drift on either side of the seam reds one of the two.  The fixture body is JSON
— a strict subset of YAML 1.2 — so GDScript's JSON parser and ``yaml.safe_load``
read identical bytes with stock parsers and no shared serializer.  That is also
why it carries no comments: ``#`` is legal YAML and illegal JSON, and only one of
the two readers would survive it.

The one field that cannot be a literal is the minted persistent id
(``mint_entity_id`` is fresh randomness per board).  It is pinned by SHAPE on
both sides — ``cutout:`` plus 32 lowercase hex — and the GD side substitutes the
fixture's id before comparing.  Stated in both files so the substitution is not
mistaken for the test excusing itself.
"""

from __future__ import annotations

import copy
import re
from pathlib import Path

import yaml

from pcb_worker.board_validate import validate_board_v2
from pcb_worker.compile_board import compile_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    ProfileOutline,
    ResolutionFailure,
    ResolutionSuccess,
)

FIXTURE = Path(__file__).parent / "testdata" / "gd_handoff_cutout.yaml"

# The SAME shape pin test_pcb_cutout.gd applies to the id it mints.
MINTED_ID = re.compile(r"^cutout:[0-9a-f]{32}$")


def _board() -> dict:
    return yaml.safe_load(FIXTURE.read_text())


def _errors(result) -> list[str]:
    return [d.code for d in result.diagnostics
            if d.severity is DiagnosticSeverity.ERROR]


# --- the key contract, asserted from this side too --------------------------
# Not redundant with the GD half: that one pins what the SERIALIZER emits, this
# one pins what the CONSUMER requires.  Both have to name the same keys or the
# hand-off is two independent beliefs about a shared file.


def test_fixture_carries_the_cutout_key_contract():
    board = _board()
    assert board["version"] == 1 and isinstance(board["version"], int)
    cutouts = board["cutouts"]
    assert isinstance(cutouts, list) and len(cutouts) == 1
    cutout = cutouts[0]
    assert sorted(cutout) == ["id", "outline"]
    assert MINTED_ID.match(cutout["id"]), cutout["id"]
    outline = cutout["outline"]
    # board_validate._check_cutouts' one content rule: a polygon needs 3 points.
    assert isinstance(outline, list) and len(outline) == 3
    for point in outline:
        # THE key contract the GD half never pinned before this round: mm-suffixed
        # keys, not {x, y}.  A serializer emitting {x, y} would round-trip inside
        # GDScript forever and mean nothing here.
        assert sorted(point) == ["x_mm", "y_mm"], point
        assert all(isinstance(point[k], (int, float)) for k in point)


# --- the two halves of the contract -----------------------------------------


def test_board_validate_accepts_the_gd_authored_board():
    """AUTHORABLE: the shared boundary raises nothing at all."""
    assert validate_board_v2(_board()) == []


def test_compile_board_compiles_the_gd_authored_board():
    """COMPILABLE since epoch CPN1 (docket 019fe2faf76e).

    This test is the inverse of what it used to assert, and the flip is the
    point: it pinned the campaign-2 refusal (``unsupported_board_feature``),
    which existed only to hold back fail-open 019fbd30f7 — a cutout that
    compiled would have shipped a board with no opening in it. That fail-open
    is fixed, so the GD-authored board now compiles and its cutout survives
    into the IR, which is what the cross-language handoff was always FOR."""
    result = compile_board(_board())
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert "unsupported_board_feature" not in _errors(result)


def test_the_gd_authored_cutout_survives_into_the_ir():
    """ATTRIBUTION, inverted with the refusal above: the cutout the GD side
    authored is present in the compiled outline with its authored geometry —
    so this stays a CUTOUT pin rather than a "the fixture compiles" pin."""
    result = compile_board(_board())
    assert isinstance(result, ResolutionSuccess), _errors(result)
    outline = result.board.outline
    assert isinstance(outline, ProfileOutline), type(outline).__name__
    assert len(outline.cutouts) == 1
    corners = {(round(seg.a[0], 6), round(seg.a[1], 6))
               for seg in outline.cutouts[0].contour.segments}
    assert corners == {(8.0, 6.0), (16.0, 6.0), (16.0, 14.0)}, corners


def test_a_two_point_outline_from_the_same_path_is_rejected():
    """The floor the GD side asserts (3 points) is a real floor over here: drop a
    point from the shared fixture and the shared boundary refuses it."""
    board = copy.deepcopy(_board())
    board["cutouts"][0]["outline"] = board["cutouts"][0]["outline"][:2]
    assert "invalid_cutout_outline" in validate_board_v2(board)
