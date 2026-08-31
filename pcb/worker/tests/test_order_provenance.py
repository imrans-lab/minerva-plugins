"""The design revision a board carries, and the digest projection that lets it.

THE ORACLE EACH TEST TURNS ON:

  * THE FIXED POINT. The digest is computed over the board source, and the board
    source contains the digest. The failure this catches is the obvious one:
    stamping the computed digest into the silk changes the bytes, so recomputing
    gives a different answer, so no board can ever print a digest that is true
    of itself. The projection is what breaks the loop, and the proof is that
    stamping is idempotent — measured, not asserted by the projection's own
    description of itself.
  * WHAT IS STILL HASHED. A projection that normalized too much would be a
    digest that stops noticing changes. The revision, the board name and every
    unrelated silk string must still move it.
  * ABSENCE IS NOT A MISMATCH. A board is authored before it is stamped, and the
    task that stamps it needs a package first. A refusal on absence would make
    the first package of every board impossible; a refusal on a STALE stamp is
    the one that matters, because that board's silkscreen names a design the
    files are not.
"""

from __future__ import annotations

import pytest

from pcb_worker import order_provenance as prov

BOARD_NAME = "OrderProv"
REV = "rev-b"


def _board(*graphics, **overrides) -> dict:
    board = {
        "version": 1, "name": BOARD_NAME, "width_mm": 30, "height_mm": 20,
        "components": [], "nets": [],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.25,
                         "via_diameter_mm": 0.6, "via_drill_mm": 0.3},
    }
    if graphics:
        board["board_graphics"] = list(graphics)
    board.update(overrides)
    return board


def _text(text: str, **extra) -> dict:
    entry = {"layer": "F.SilkS", "kind": "text", "text": text,
             "position": {"x_mm": 5.0, "y_mm": 5.0}, "size_mm": 1.0}
    entry.update(extra)
    return entry


def _slot(board: dict, digest: str) -> dict:
    """The same board with the provenance graphic's digest slot rewritten."""
    stamped = {key: value for key, value in board.items()}
    stamped["board_graphics"] = [
        _text(prov.provenance_text(BOARD_NAME, REV, digest))]
    return stamped


# ---------------------------------------------------------------------------
# The fixed point.
# ---------------------------------------------------------------------------


def test_stamping_the_computed_digest_does_not_move_the_digest():
    """THE LOAD-BEARING PROOF. Author the slot unstamped, compute, write the
    result in, compute again — the same digest both times.

    Stated as a measurement of two boards rather than of one projection, so it
    would fail if the projection ever stopped covering the slot."""
    unstamped = _board(_text(prov.provenance_text(
        BOARD_NAME, REV, prov.DIGEST_SENTINEL)))
    first = prov.source_digest(unstamped)

    stamped = _slot(unstamped, first[:prov.DIGEST_CHARS])
    second = prov.source_digest(stamped)

    assert second == first, (
        "the digest moved when it was stamped: the projection is not covering "
        "the slot, so the board can never print a digest true of itself")
    record, advisories = prov.check(stamped)
    assert record["state"] == prov.STATE_VERIFIED
    assert advisories == ()


def test_every_value_of_the_slot_projects_to_the_same_bytes():
    """The invariant behind the fixed point, stated directly: the projection is
    the same whatever the slot holds. A projection that only happened to agree
    for the one value we computed would pass the test above and fail on the next
    board."""
    boards = [_board(_text(prov.provenance_text(BOARD_NAME, REV, value)))
              for value in (prov.DIGEST_SENTINEL, "00000000", "deadbeef",
                            "0123abcd")]
    projections = {prov.canonical_bytes(board) for board in boards}
    assert len(projections) == 1


def test_the_revision_is_still_hashed():
    """Only the eight digest characters are normalized. A revision bump is a
    real change to the design record and must move the digest — otherwise two
    revisions of one board are indistinguishable to an auditor."""
    one = _board(_text(prov.provenance_text(BOARD_NAME, "rev-a",
                                            prov.DIGEST_SENTINEL)))
    two = _board(_text(prov.provenance_text(BOARD_NAME, "rev-b",
                                            prov.DIGEST_SENTINEL)))
    assert prov.source_digest(one) != prov.source_digest(two)


def test_an_unrelated_silk_string_is_hashed_verbatim():
    """The projection anchors on the board's OWN name, so other artwork is
    ordinary board data. A projection that fired on any string ending in eight
    hex characters would quietly stop hashing real silk."""
    plain = _board(_text("Minerva"))
    changed = _board(_text("Minerva deadbeef"))
    assert prov.source_digest(plain) != prov.source_digest(changed)
    assert prov.stamps(changed) == ()


def test_board_geometry_still_moves_the_digest():
    """The negative control for the whole projection: if a board can be edited
    without moving its digest, the digest is not describing the board."""
    before = _board(_text("Minerva"))
    after = _board(_text("Minerva"), width_mm=31)
    assert prov.source_digest(before) != prov.source_digest(after)


def test_the_digest_ignores_formatting_but_not_content():
    """Two loads of one design hash alike whatever order the keys arrived in —
    a digest that depended on mapping order would change every time a file was
    re-serialized."""
    board = _board(_text("Minerva"))
    reordered = {key: board[key] for key in reversed(list(board))}
    assert prov.source_digest(reordered) == prov.source_digest(board)


# ---------------------------------------------------------------------------
# The three things a board can say about itself.
# ---------------------------------------------------------------------------


def test_absent_provenance_is_an_advisory_and_never_a_refusal():
    """A board with no revision printed on it still exports. The task that
    authors the provenance runs AFTER the exporter exists, so a refusal here
    would block every package that could ever be produced."""
    record, advisories = prov.check(_board())
    assert record["state"] == prov.STATE_ABSENT
    assert record["design_revision"] is None
    assert [item["code"] for item in advisories] == [prov.ADVISORY_ABSENT]
    assert record["source_digest"][:prov.DIGEST_CHARS] in advisories[0]["message"]


def test_an_unstamped_slot_is_an_advisory_that_names_the_value_to_write():
    """The authoring path: the graphic exists, the slot is still the sentinel.
    Advisory, and it carries the eight characters to type in."""
    board = _board(_text(prov.provenance_text(BOARD_NAME, REV,
                                              prov.DIGEST_SENTINEL)))
    record, advisories = prov.check(board)
    assert record["state"] == prov.STATE_UNSTAMPED
    assert record["design_revision"] == REV
    assert [item["code"] for item in advisories] == [prov.ADVISORY_UNSTAMPED]
    assert record["source_digest"][:prov.DIGEST_CHARS] in advisories[0]["message"]


def test_a_stale_printed_digest_refuses_by_name():
    """THE ONE REFUSAL. The board prints a digest this source does not produce,
    so the bare board would name a design these files are not."""
    board = _slot(_board(), "deadbeef")
    with pytest.raises(prov.ProvenanceError) as caught:
        prov.check(board)
    assert caught.value.code == "assembly_provenance_mismatch"
    assert "deadbeef" in str(caught.value)


def test_two_disagreeing_provenance_strings_refuse():
    """A board that prints two different revisions names more than one design;
    there is no honest single answer to record in the manifest."""
    board = _board(
        _text(prov.provenance_text(BOARD_NAME, "rev-a", "deadbeef")),
        _text(prov.provenance_text(BOARD_NAME, "rev-b", "deadbeef")))
    with pytest.raises(prov.ProvenanceError):
        prov.check(board)


def test_one_stamped_and_one_unstamped_slot_refuses_for_the_right_reason():
    """Front silk stamped, back silk still on the sentinel, ONE revision on
    both. Refusing is right — the two sides of the bare board would not carry
    the same identity — but the message must name the DIGESTS, because a reader
    sent to look for two different revisions finds two identical ones and stops
    trusting the refusal."""
    board = _board(_text(prov.provenance_text(BOARD_NAME, REV, "deadbeef")),
                   _text(prov.provenance_text(BOARD_NAME, REV,
                                              prov.DIGEST_SENTINEL),
                         layer="B.SilkS"))
    with pytest.raises(prov.ProvenanceError) as caught:
        prov.check(board)
    message = str(caught.value)
    assert "different digest slots" in message
    assert "different design revisions" not in message
    assert REV in message


def test_a_board_repeating_one_correct_stamp_is_accepted():
    """Front and back silk may both carry the revision. Two identical strings
    are one claim, not two, and both slots are normalized — so stamping the pair
    is still a single-step fixed point."""
    sentinel = prov.provenance_text(BOARD_NAME, REV, prov.DIGEST_SENTINEL)
    unstamped = _board(_text(sentinel), _text(sentinel, layer="B.SilkS"))
    digest = prov.source_digest(unstamped)

    text = prov.provenance_text(BOARD_NAME, REV, digest[:prov.DIGEST_CHARS])
    stamped = _board(_text(text), _text(text, layer="B.SilkS"))
    assert prov.source_digest(stamped) == digest
    record, advisories = prov.check(stamped)
    assert record["state"] == prov.STATE_VERIFIED
    assert advisories == ()
