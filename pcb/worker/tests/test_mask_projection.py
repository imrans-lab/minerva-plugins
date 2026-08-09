"""Solder mask in the geometric-DRC projection (epoch CP2 station S4).

AUTHORED, NOT EXECUTED during CP2: this epoch writes tests at every station and
runs them for the first time at the boundary (S10), after the Codex round.

THE CLAIM THIS FILE DEFENDS is the same one ``test_silk_projection.py`` defends,
with the stakes raised. For silk, a checker that harvests independently ends up
measuring artwork the fab does not print. For MASK, the dangerous direction is
the missing aperture: a mask-sliver check that never sees two openings reports
no sliver between them, and "no finding" is indistinguishable from "passed".
That is a false clean of the exact kind the cardinal rule forbids, so the
emitter and the checker are required to enumerate mask through ONE owner and
this file is what proves they still do.

The load-bearing test drives both surfaces off the same compiled board and
compares FULL GEOMETRY per side — position, shape, both dimensions, corner
ratio and angle — not counts. Equal counts survive a coordinate corruption, and
a mask aperture at the wrong coordinate is a board that solders wrong.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest
import yaml

from pcb_worker import gerber, mask_source
from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import project_board, run_geometric_drc
from pcb_worker.resolved_board import ResolutionSuccess, Side

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"


def _board(untent_vias: bool = False) -> dict:
    """The coupon, optionally with its vias UNTENTED.

    The coupon authors no ``tented`` key, so every via defaults to tented and
    contributes no mask opening at all. That makes the default board silent
    about the one entity where copper and mask genuinely disagree, so the
    untented variant exists to exercise it end-to-end rather than only in the
    owner's unit tests.
    """
    board = yaml.safe_load(COUPON.read_text(encoding="utf-8"))
    if untent_vias:
        for via in board.get("vias") or []:
            via["tented"] = False
    return board


def _compiled(untent_vias: bool = False):
    result = compile_board(_board(untent_vias))
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result.board


def _norm(entry) -> tuple:
    """One mask aperture, rounded, in a form comparable across both surfaces."""
    x, y, shape, w, h, rratio, angle = entry
    return (round(x, 9), round(y, 9), shape, round(w, 9), round(h, 9),
            None if rratio is None else round(rratio, 9), round(angle, 9))


def _emitter_mask(rb) -> dict:
    """Mask as the EMITTER will flash it.

    FRAME NOTE: ``gerber._harvest_ir`` returns AFTER ``to_gerber_frame()``, so
    these are in the GERBER frame — Y negated. The projection is board-frame and
    ``_projected_mask`` converts to match, rather than either side pretending
    the two frames are already aligned.
    """
    g = gerber._harvest_ir(rb, mask_source.resolve_ir_mask_clearance(rb))
    return {Side.TOP: sorted(_norm(e) for e in g.mask_top),
            Side.BOTTOM: sorted(_norm(e) for e in g.mask_bot)}


def _projected_mask(rb) -> dict:
    """The same mask as the CHECKER sees it, board frame -> gerber frame."""
    out = {Side.TOP: [], Side.BOTTOM: []}
    for opening in project_board(rb).mask:
        x, y, shape, w, h, rratio, angle = opening.as_emitter_tuple()
        out[opening.side].append(_norm((x, -y, shape, w, h, rratio, angle)))
    return {side: sorted(items) for side, items in out.items()}


@pytest.mark.parametrize("untent_vias", [False, True],
                         ids=["vias-tented", "vias-untented"])
def test_projection_and_emitter_agree_on_every_mask_aperture(untent_vias):
    """THE LOAD-BEARING TEST OF THE MASK HALF OF STATION S4.

    If these disagree, a mask DFM check is measuring apertures the board house
    will not receive. Run with vias tented AND untented because tenting is the
    only place where "there is copper here" and "mask opens here" come apart —
    a tented-only board would pass even if the checker inferred openings
    straight from copper.
    """
    rb = _compiled(untent_vias)
    assert _projected_mask(rb) == _emitter_mask(rb)


def test_untenting_adds_apertures_on_both_sides_and_tenting_removes_them():
    """The tenting lever actually moves the surface it claims to move.

    Without this, the parametrisation above could be comparing two identical
    boards and still read as covering tenting.
    """
    tented = _projected_mask(_compiled(False))
    untented = _projected_mask(_compiled(True))
    for side in (Side.TOP, Side.BOTTOM):
        assert len(untented[side]) > len(tented[side]), (
            f"untenting the coupon's vias added no {side} mask openings")


def test_every_via_aperture_is_absent_while_tented():
    """Stated positively against the ORIGIN tag rather than by counting: a
    tented via must contribute nothing whatever else is on the board."""
    proj = project_board(_compiled(False))
    assert not [o for o in proj.mask if o.origin == mask_source.ORIGIN_VIA]
    untented = project_board(_compiled(True))
    assert [o for o in untented.mask if o.origin == mask_source.ORIGIN_VIA]


def test_projected_mask_carries_the_shared_owner_type_not_a_remodelled_copy():
    """The projection stores mask_source's own dataclass. If this ever becomes a
    locally re-modelled shape, the two surfaces have stopped sharing a
    definition and the agreement test degrades into a coincidence."""
    proj = project_board(_compiled())
    assert proj.mask
    for opening in proj.mask:
        assert isinstance(opening, mask_source.MaskOpening)
        assert opening.side in (Side.TOP, Side.BOTTOM)
        assert opening.origin


def test_every_projected_opening_is_attributed_to_a_kind():
    """A finding must be able to say WHICH feature opened the mask. An untagged
    aperture is one a report cannot explain, which makes it one a human cannot
    act on."""
    known = {mask_source.ORIGIN_SMD_PAD, mask_source.ORIGIN_TH_PAD,
             mask_source.ORIGIN_NPTH_PAD, mask_source.ORIGIN_BOARD_HOLE,
             mask_source.ORIGIN_NPTH_BOARD_HOLE, mask_source.ORIGIN_VIA}
    assert {o.origin for o in project_board(_compiled(True)).mask} <= known


def test_openings_are_never_zero_or_negative():
    """A collapsed opening is a fail-closed condition in the owner, so none may
    reach a projection. This is the invariant a mask-sliver check will rest on:
    a zero-size aperture would make a sliver measurement meaningless rather than
    merely wrong."""
    for opening in project_board(_compiled(True)).mask:
        assert opening.width > 0 and opening.height > 0


def test_projecting_mask_did_not_disturb_the_existing_checks():
    """S4 adds projection families and NO checks. The coupon must still compile
    to a determinately clean geometric DRC — if this moved, the station exceeded
    its contract."""
    drc = run_geometric_drc(_compiled())
    assert drc["verdict"] == "clean"
    assert not drc.get("findings")


def test_the_emitter_no_longer_owns_any_mask_enumeration():
    """The structural half of the claim, checked at the source.

    The agreement test proves the two surfaces MATCH today. This proves they
    match for the durable reason — that gerber.py asks mask_source instead of
    deciding — rather than by two implementations happening to coincide. A
    reintroduced ``g.mask_top.append(...)`` in the emitter is precisely the
    regression that would restore the drift S4 removed, and it would keep the
    agreement test green until the two copies diverged.
    """
    src = Path(gerber.__file__).read_text(encoding="utf-8")
    for forbidden in ("g.mask_top.append", "g.mask_bot.append"):
        assert forbidden not in src, (
            f"gerber.py appends to a mask bucket directly ({forbidden}) — mask "
            "enumeration belongs to mask_source, and a second enumeration is "
            "how a checker starts measuring apertures the fab never receives")


def test_no_module_level_name_in_the_emitter_is_defined_twice():
    """No top-level name in gerber.py is bound twice.

    THIS GUARDS A DEFECT THAT ACTUALLY HAPPENED, and it is here because every
    cheap check missed it. The mask adapter was first called ``_add_mask`` —
    a name already taken further down the module by the layer writer that
    flashes the finished buckets into a DataLayer. Python bound the later
    definition, so all three emitter call sites silently resolved to the wrong
    function and would have unpacked MaskOpening dataclasses as 7-tuples.

    py_compile passed. The module imported. pytest collected every suite. A
    shadowed definition is invisible to all three, because it only fails when
    the shadowed path actually runs — so on an epoch that defers execution, a
    name collision can sit undetected behind a station reported as complete.
    Hence a structural test rather than trust in the next reader noticing.

    Scoped to module-level `def`/`class`/assignment targets. A conditional
    re-binding inside a function or an `if` is legitimate and not what this is
    about.
    """
    tree = ast.parse(Path(gerber.__file__).read_text(encoding="utf-8"))
    seen: dict[str, int] = {}
    dupes: list[str] = []
    for node in tree.body:
        names: list[str] = []
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names = [node.name]
        elif isinstance(node, ast.Assign):
            names = [t.id for t in node.targets if isinstance(t, ast.Name)]
        for name in names:
            if name in seen:
                dupes.append(f"{name} (lines {seen[name]} and {node.lineno})")
            seen[name] = node.lineno
    assert not dupes, (
        "gerber.py binds these module-level names more than once, so the later "
        "definition shadows the earlier one and its call sites silently resolve "
        f"to the wrong object: {'; '.join(dupes)}")
