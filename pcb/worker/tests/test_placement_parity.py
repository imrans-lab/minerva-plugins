"""EXACTLY ONE placement rule for the loose-dict readers, proved on the corpus.

Three surfaces read a canonical board DICT and each has to decide where a
component's pads physically are: the connectivity census (``drc._harvest_pads``),
the raw Gerber emitter (``gerber._harvest``) and the legacy routing bridge
(``route_bridge.board_to_router``). The compiled path has no such problem — one
``geometry.PlacementTransform`` places everything — but the dict readers each
used to compose their own, and a rule composed three times is a rule that can
disagree with itself. It did: rotation was applied everywhere and the
BOTTOM-SIDE MIRROR only in the census, so a back-mounted part's copper was
checked in one place, flashed in another and routed in a third.

THE ORACLE IS THE CENSUS. ``drc._harvest_pads`` delegates to
``geometry.component_transform``, the same object ``compile_board`` builds, so it
is the rule the fabricated board obeys. These tests do not restate that rule —
restating it is exactly the failure they exist to catch. They drive the three
production entry points on real corpus boards and compare their OUTPUTS.

WHAT IS COMPARED, and why each is a separate question:

  * the pad CENTRE — the mirror's whole visible effect on position;
  * the pad's SIDE — the layer flip, which the census reads off the pad's own
    declared layers and the emitter off the component's placement, so agreement
    is two independent derivations meeting, not one value copied;
  * the ROUTER's pad positions, which come from ``pins`` rather than ``pads``
    and are therefore a third reading of the same placement.

Per-component boards, not whole ones: a Gerber harvest also flashes vias and
board-level holes, and a board-level plated hole lands in the same bucket as a
through-hole pad. Isolating one component removes that ambiguity entirely and
still drives the real harvest.
"""

from __future__ import annotations

from pathlib import Path

import pytest
import yaml

from pcb_worker import drc, gerber, route_bridge
from pcb_worker.pad_source import PadGeometryError
from pcb_worker.resolve import resolve_board_best_effort

TESTDATA = Path(__file__).resolve().parent / "testdata"

# Board-level keys a one-component board has to keep: the census reads the
# clearance, the emitter the stack, the router the extents.
_BOARD_KEYS = ("version", "name", "width_mm", "height_mm", "layers",
               "design_rules")

# mm. Coordinates are composed by float trig on both sides, so compare at a
# tolerance far below any fabricable feature and far above float noise.
_TOL_MM = 1e-9


def _corpus() -> list[tuple[str, dict]]:
    """Every corpus board that declares components, resolved the way the
    fabrication path resolves one (tolerantly — a component the library cannot
    explain keeps its inline pins, which is a placement case in its own right).
    """
    out: list[tuple[str, dict]] = []
    for path in sorted([*TESTDATA.glob("*.yaml"), *TESTDATA.glob("*/*.yaml")]):
        board = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(board, dict):
            continue
        if not isinstance(board.get("components"), list) or not board["components"]:
            continue
        out.append((path.name, resolve_board_best_effort(board)))
    assert out, f"no component-bearing boards under {TESTDATA}"
    return out


CORPUS = _corpus()


def _solo(board: dict, comp: dict) -> dict:
    """One component alone on its own board, keeping the board-level facts the
    three readers consult."""
    solo = {key: board[key] for key in _BOARD_KEYS if key in board}
    solo["components"] = [comp]
    solo["nets"] = []
    return solo


def _census_pads(board: dict) -> list:
    return drc._harvest_pads(board)


def _gerber_copper(board: dict):
    """Every COMPONENT copper flash the raw emitter produces, as
    ``(x_mm, y_mm, top)`` in the BOARD frame — or None when the emitter FAILS
    CLOSED on this component.

    ``_harvest`` returns gerber-frame geometry (Y-up), so Y is negated back — the
    one frame boundary in the emitter, undone here rather than approximated.
    ``top`` is None for a through-hole land: its copper is on both faces, so it
    makes no side claim to compare.

    ``PadGeometryError`` is the emitter refusing to invent copper it has no size
    for (a sizeless SMD land, a plated round barrel with no annulus). There is
    then no emitted geometry to compare a placement against — it is a component
    the fab path declines to state, not two surfaces disagreeing about where its
    copper is. The refusal itself is tested where it lives; the coverage test at
    the bottom is what keeps this from quietly swallowing the whole corpus.
    """
    try:
        g = gerber._harvest(board, gerber.DEFAULT_MASK_CLEARANCE_MM)
    except PadGeometryError:
        return None
    out: list[tuple[float, float, bool | None]] = []
    for (x, y, _w, _h, _a, top, _shape, _rr) in g.smd_pads:
        out.append((x, -y, bool(top)))
    for (x, y, _dia, func) in g.th_annuli:
        if func == "ComponentPad":
            out.append((x, -y, None))
    for (x, y, *_rest) in g.th_shaped:
        out.append((x, -y, None))
    return out


def _key(x: float, y: float) -> tuple[float, float]:
    """A coordinate pair as a comparable key — rounded well below the tolerance
    the two paths could ever differ by for a real placement error."""
    return (round(x, 6), round(y, 6))


def _census_side(pad) -> bool | None:
    """Which face the census believes a pad's copper is on: True front, False
    back, None both-or-unconstrained.

    Read off ``_Pad.contact``'s layer set, which the census derives from the
    pad's OWN declared layers put through the placement flip — a different
    derivation from the emitter's, which asks the component's side directly.
    """
    if pad.through_hole:
        return None
    layers = pad.contact.layers if pad.contact is not None else None
    if not layers or len(layers) != 1:
        return None
    return next(iter(layers)) == "top"


def _components(board: dict) -> list[dict]:
    return [c for c in board["components"] if isinstance(c, dict)]


@pytest.mark.parametrize("name,board", CORPUS, ids=[n for n, _ in CORPUS])
def test_the_gerber_harvest_flashes_copper_where_the_census_checks_it(
        name: str, board: dict) -> None:
    """Every pad the census places, the emitter flashes — same point, same side.

    Set equality in BOTH directions on purpose. Missing points would be a
    dropped land; extra points would be copper the census never checks, which is
    the same defect read the other way.
    """
    for comp in _components(board):
        solo = _solo(board, comp)
        ref = comp.get("ref")
        flashed = _gerber_copper(solo)
        if flashed is None:
            continue
        census = _census_pads(solo)

        census_pts = sorted(_key(p.x, p.y) for p in census)
        flash_pts = sorted(_key(x, y) for (x, y, _side) in flashed)
        assert census_pts == flash_pts, (
            f"{name}:{ref} at ({comp.get('x_mm')}, {comp.get('y_mm')}) "
            f"rot {comp.get('rotation_deg')} layer {comp.get('layer')}: the "
            f"census checks pads at {census_pts} and the emitter flashes copper "
            f"at {flash_pts} — one of them is not using "
            f"geometry.component_transform")

        # Side, per point. A through-hole land claims no side on either surface,
        # so it drops out of the comparison rather than being asserted equal to
        # a value neither produces.
        flash_side = {}
        for (x, y, side) in flashed:
            flash_side.setdefault(_key(x, y), side)
        for pad in census:
            got = flash_side.get(_key(pad.x, pad.y))
            want = _census_side(pad)
            if got is None or want is None:
                continue
            assert got is want, (
                f"{name}:{ref} pad {pad.pin} at ({pad.x}, {pad.y}): the census "
                f"reads its copper on the {'front' if want else 'back'} and the "
                f"emitter flashes it on the {'front' if got else 'back'}")


@pytest.mark.parametrize("name,board", CORPUS, ids=[n for n, _ in CORPUS])
def test_the_router_bridge_projects_pads_where_the_census_checks_them(
        name: str, board: dict) -> None:
    """The legacy raw-dict router projection lands on the census's own points.

    It reads ``pins``, not ``pads``, so this is a genuinely independent third
    reading. The two agree pad-for-pad because resolve refuses a footprint whose
    pads disagree with the routed pins; what is under test is the PLACEMENT
    applied to them, not that correspondence.

    A component the bridge refuses (no readable side, no authored copper size) is
    not a placement disagreement and is skipped by its own named exception — the
    bridge's fail-closed contract, tested where it lives.
    """
    for comp in _components(board):
        solo = _solo(board, comp)
        ref = str(comp.get("ref", ""))
        try:
            projected = route_bridge.board_to_router(solo)
        except (route_bridge.UnresolvableComponentLayer,
                route_bridge.UnsupportedGeometry):
            continue

        census = {(p.ref, p.pin): (p.x, p.y) for p in _census_pads(solo)}
        for pad in projected.pads:
            want = census.get((ref, pad.number))
            if want is None:
                continue  # a pin with no census pad (an unplated bore) — not a place
            assert (abs(pad.position[0] - want[0]) < _TOL_MM
                    and abs(pad.position[1] - want[1]) < _TOL_MM), (
                f"{name}:{ref}.{pad.number} on layer {comp.get('layer')} at "
                f"rot {comp.get('rotation_deg')}: the router projects "
                f"{pad.position} and the census checks {want}")


def test_the_corpus_walk_actually_compares_a_flipped_part() -> None:
    """The comparisons above are vacuous on an all-front board, and they skip a
    component the emitter fails closed on. Either could hollow them out silently,
    so name the parts the mirror needs and require that they are really measured.

    parity_corners carries both classes on purpose: U2 is a BOTTOM-side
    through-hole part that is ALSO rotated (so a missing mirror and a missing
    rotation are separable faults), and SW10 is a bottom-side SMD with two
    off-origin lands (so the mirror MOVES copper instead of cancelling out, and
    the land's SIDE is a real answer rather than "both faces").
    """
    board = dict(CORPUS)["parity_corners.yaml"]
    by_ref = {str(c.get("ref")): c for c in board["components"]}

    for ref in ("U2", "SW10"):
        comp = by_ref.get(ref)
        assert comp is not None, sorted(by_ref)
        assert str(comp.get("layer", "")).strip().lower() == "bottom", comp.get("layer")

        solo = _solo(board, comp)
        flashed = _gerber_copper(solo)
        assert flashed, f"{ref}: the emitter flashed no copper to compare"
        assert _census_pads(solo), f"{ref}: the census harvested no pad to compare"

    # U2 is the rotated one; without that, a fixture could drift to all-zero
    # placements and the mirror/rotation composition would stop being separable.
    assert float(by_ref["U2"].get("rotation_deg") or 0.0) % 360.0 != 0.0

    # SW10's lands are SMD, so each states a side the census and the emitter
    # derive independently — the layer-flip half of the rule.
    sides = {side for (_x, _y, side) in _gerber_copper(_solo(board, by_ref["SW10"]))}
    assert sides == {False}, f"SW10's lands should flash on the back, got {sides}"
