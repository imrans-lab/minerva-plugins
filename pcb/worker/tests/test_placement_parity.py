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

# mm. Coordinates are composed by float trig on both sides and the router
# bridge carries single-precision residue (~1e-8 at board scale), so compare at
# a tolerance far below any fabricable feature and above that noise.
_TOL_MM = 1e-6


# THE BOARDS THIS PARITY IS MEASURED ON, named rather than globbed.
#
# A glob over testdata makes coverage a property of whichever files happen to
# sit there: a fixture added for an unrelated reason silently joins the
# comparison, and the one board that carries the mirror could be deleted without
# a single assertion changing. What is under test is a placement COMPOSITION, so
# a board whose parts are all front-side at rotation 0 composes an identity and
# can prove nothing — each entry below states which half of the rule it carries.
#
# Deliberately excluded, and why: footprints/resolve_corners.yaml,
# gerber_boards/drilltest.yaml and gerber_boards/quadlayer.yaml are all
# front-side at rotation 0; assembly_boards/assembly_fixture.yaml declares pins
# offset from its library pads on purpose, which the fail-closed coincidence
# check refuses before any placement can be read. gd_handoff_cutout.yaml has NO
# components at all (it is the GD cut-out hand-off board), so there is no
# placement on it to compose.
#
# No corpus board carries an OFF-AXIS rotation, and every multiple of 90 hides
# a sign error under a rectangle's own symmetry — so the corpus is extended
# in-test with parity_corners' bottom-side U2 turned to 45 (see _corpus).
_PARITY_BOARDS: tuple[tuple[str, str], ...] = (
    # The purpose-built fixture. U2 is bottom-side AND rotated 90, so a missing
    # mirror and a missing rotation are separable faults; SW10 is bottom-side
    # SMD with off-origin lands, so the mirror MOVES copper instead of
    # cancelling and each land states a side the two surfaces derive
    # independently; J1/SW9 cover top-side 90 and U3 top-side 180.
    ("parity_corners.yaml",
     "bottom-side THT rotated 90 (U2), bottom-side SMD off-origin (SW10), "
     "top-side 90 and 180"),
    # A promoted coupon, not a fixture: REV1 is bottom-side and rotated 180 —
    # the composition on a board that really went to fab.
    ("coupon_jlc1.yaml", "bottom-side rotated 180 (REV1), on real board source"),
    # The largest board here (48 components) and the closest to a real design:
    # a bottom-side pair (BS23A/BS23B) and a mirrored rotation pair (R8A at 90,
    # R8B at 270), which is where a one-sided sign error shows as asymmetry.
    ("hitl_bench.yaml",
     "bottom-side pair (BS23A/BS23B) and mirrored rotations (R8A/R8B)"),
    # Rotation with NO mirror, so the rotation half is pinned on a board where
    # the flip cannot be covering for it.
    ("zone_fill.yaml", "top-side rotated 90 (R2), no bottom-side part"),
)


def _corpus() -> list[tuple[str, dict]]:
    """The named boards above, resolved the way the fabrication path resolves
    one (tolerantly — a component the library cannot explain keeps its inline
    pins, which is a placement case in its own right).
    """
    out: list[tuple[str, dict]] = []
    for rel, why in _PARITY_BOARDS:
        path = TESTDATA / rel
        assert path.is_file(), f"named parity board is missing: {path} ({why})"
        board = yaml.safe_load(path.read_text(encoding="utf-8"))
        assert isinstance(board, dict) and isinstance(board.get("components"), list) \
            and board["components"], \
            f"{rel} declares no components, so it exercises no placement ({why})"
        out.append((path.name, resolve_board_best_effort(board)))
    # The off-axis case: the same bottom-side part at 45, where neither the
    # mirror nor the rotation can hide behind the land's own symmetry.
    base = yaml.safe_load((TESTDATA / "parity_corners.yaml").read_text(encoding="utf-8"))
    u2 = next(c for c in base["components"] if c.get("ref") == "U2")
    u2["rotation_deg"] = 45
    out.append(("parity_corners.yaml@U2-45", resolve_board_best_effort(base)))
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


def _take_nearest(point: tuple[float, float],
                  pool: list[tuple[float, float]]) -> int | None:
    """Index in *pool* of the point within ``_TOL_MM`` of *point*, or None.

    NOT a rounded key. Both sides compose their coordinates by float trig, so
    two agreeing paths can land either side of a rounding boundary — 1.0000004999
    and 1.0000005001 round to different 1e-6 keys and compare unequal while
    differing by 2e-13. Matching each point to its nearest partner and judging
    that distance against the SAME tolerance the router arm uses makes the
    comparison measure disagreement rather than which side of a boundary the
    noise fell on.
    """
    best: int | None = None
    best_d = _TOL_MM
    for i, (px, py) in enumerate(pool):
        d = max(abs(px - point[0]), abs(py - point[1]))
        if d < best_d:
            best, best_d = i, d
    return best


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

        # PAIRED, not set-compared: each census pad claims the nearest unclaimed
        # flashed point within _TOL_MM, and both sides must end up empty. Missing
        # points would be a dropped land; leftover flashed points would be copper
        # the census never checks, which is the same defect read the other way.
        census_pts = [(p.x, p.y) for p in census]
        unclaimed = [(x, y) for (x, y, _side) in flashed]
        unmatched = []
        for pt in census_pts:
            hit = _take_nearest(pt, unclaimed)
            if hit is None:
                unmatched.append(pt)
            else:
                unclaimed.pop(hit)
        assert not unmatched and not unclaimed, (
            f"{name}:{ref} at ({comp.get('x_mm')}, {comp.get('y_mm')}) "
            f"rot {comp.get('rotation_deg')} layer {comp.get('layer')}: the "
            f"census checks pads at {sorted(census_pts)} and the emitter flashes "
            f"copper at {sorted((x, y) for (x, y, _s) in flashed)} — "
            f"census pads with no copper within {_TOL_MM}mm: {unmatched}; "
            f"flashed copper no census pad claims: {unclaimed}. One of them is "
            f"not using geometry.component_transform")

        # Side, per point, matched the same way. A through-hole land claims no
        # side on either surface, so it drops out of the comparison rather than
        # being asserted equal to a value neither produces.
        for pad in census:
            hit = _take_nearest(
                (pad.x, pad.y), [(x, y) for (x, y, _side) in flashed])
            got = flashed[hit][2] if hit is not None else None
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
