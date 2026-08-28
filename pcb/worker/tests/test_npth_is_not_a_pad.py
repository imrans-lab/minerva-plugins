"""An UNPLATED BORE IS NOT A PAD, and both surfaces read it the same way.

A ``np_thru_hole`` is drilled and never plated: no barrel, no land, no copper.
KiCad still writes ``(layers *.Cu)`` on its pad line — that says where copper
must be kept AWAY, not where copper IS — so every reader has to decide for
itself, and the two readers of one board used to decide differently. The
compiled IR's connectivity projection dropped it (``IRPad.carries_copper``);
the raw census kept it as a copper-free node. One board, two answers to "is
this a pad".

WHY THE DISAGREEMENT MATTERED, and it is not tidiness. A board may legitimately
hang a net on a chassis-ground M3 hole. Kept as a pad, that hole is an island of
its net that nothing can ever join, so the census reports the net PARTIAL
forever — a defect with no fix, on a board the router has already told you it
excluded the hole from. Dropped, the census reports only the joins that are
genuinely owed.

THE ORACLE IS THE FIXTURE, not either implementation: hitl_bench declares
``MH5.1`` on ``R5_A`` and ``MH4.1`` as the sole member of ``R4_N``, both
``MountingHole:MountingHole_3.2mm_M3``, and it says in its own text what each
row owes. Its plated neighbours on the same nets are asserted PRESENT beside the
holes' absence, so this cannot pass by dropping pads wholesale.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import compile_board, drc
from pcb_worker.ir_connectivity import connectivity_board
from pcb_worker.resolved_board import ResolutionSuccess

BENCH = Path(__file__).resolve().parent / "testdata" / "hitl_bench.yaml"

# The bench's two unplated bores, and the plated pads that share their nets.
NPTH_PINS = {("MH4", "1"), ("MH5", "1")}
PLATED_NEIGHBOURS = {("TP5T", "1"), ("TP5B", "1")}


@pytest.fixture(scope="module")
def bench() -> dict:
    return yaml.safe_load(BENCH.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def compiled(bench: dict):
    result = compile_board.compile_board(
        bench, requested_outputs=compile_board.V1_ROUTING_OUTPUTS)
    assert isinstance(result, ResolutionSuccess), (
        [d.message for d in result.diagnostics if d.severity.value == "error"][:5])
    return result.board


def _raw_census_pins(board: dict) -> set[tuple[str, str]]:
    return {(str(p.ref), str(p.pin)) for p in drc._harvest_pads(board)}


def _projected_pins(rb) -> set[tuple[str, str]]:
    projection = connectivity_board(rb)
    return {(str(comp["ref"]), str(pin["number"]))
            for comp in projection["components"]
            for pin in comp["pins"]}


def test_the_fixture_really_hangs_a_net_on_an_unplated_bore(bench: dict) -> None:
    """Guard the oracle before trusting it: an absence proves nothing about a
    board that never had the thing. Both holes must still be authored, and still
    be named on nets, or the assertions below are vacuous.
    """
    refs = {str(c.get("ref")): c for c in bench["components"]}
    for ref, _pin in sorted(NPTH_PINS):
        assert ref in refs, f"{ref} is gone from the bench"
        assert "MountingHole" in str(refs[ref].get("footprint")), refs[ref]

    named = {pin for net in bench["nets"] for pin in net["pins"]}
    assert "MH5.1" in named and "MH4.1" in named, sorted(named)[:20]


def test_the_raw_census_and_the_ir_projection_agree_about_the_bore(
        bench: dict, compiled) -> None:
    """Neither surface offers an unplated bore as a pad — and both still offer
    the plated pads sharing its net, so agreement is not agreement on nothing.
    """
    raw = _raw_census_pins(bench)
    projected = _projected_pins(compiled)

    assert NPTH_PINS.isdisjoint(raw), sorted(NPTH_PINS & raw)
    assert NPTH_PINS.isdisjoint(projected), sorted(NPTH_PINS & projected)
    assert PLATED_NEIGHBOURS <= raw, sorted(PLATED_NEIGHBOURS - raw)
    assert PLATED_NEIGHBOURS <= projected, sorted(PLATED_NEIGHBOURS - projected)


def test_the_bore_is_not_an_island_of_its_own_net(bench: dict) -> None:
    """R5_A's census count is the two probe pads it can actually join.

    The row owes a top-to-bottom join that only a plated via delivers, so the net
    stays PARTIAL at 2 — the real defect, still reported. A third island would be
    MH5 standing alone, which is a defect the router cannot clear because its own
    projection already excludes that hole.
    """
    assert drc.net_pin_group_count(bench, "R5_A") == 2


def test_the_bore_does_not_swallow_the_open_ends_it_sits_between(
        bench: dict) -> None:
    """The other error direction, pinned in the same place.

    Row 5's two runs stop 2.1 mm short of the hole centre — 0.5 mm clear of the
    3.2 mm bore — because there is no copper there to land on. Reading the bore's
    ``*.Cu`` line as a 3.2 mm all-layer land would bridge them into one island
    and credit both ends as landed, reporting a board with a gap in it clean.
    """
    result = drc.run_drc(bench)
    dangling = sorted(tuple(f["at"]) for f in result["findings"]
                      if f["type"] == "dangling_endpoint")
    assert (22.9, 56.0) in dangling, dangling
    assert (27.1, 56.0) in dangling, dangling
