"""EXACTLY ONE placement rule for the loose-dict readers, proved on the corpus.

Four surfaces read a canonical board DICT and each has to decide where a
component's pads physically are: the connectivity census (``drc._harvest_pads``),
the raw Gerber emitter (``gerber._harvest``), the legacy routing bridge
(``route_bridge.board_to_router``) and the KiCad exporter
(``kicad.generate_kicad_pcb``). The compiled path has no such problem — one
``geometry.PlacementTransform`` places everything — but the dict readers each
used to compose their own, and a rule composed four times is a rule that can
disagree with itself. It did: rotation was applied everywhere and the
BOTTOM-SIDE MIRROR only in the census, so a back-mounted part's copper was
checked in one place, flashed in another, routed in a third and exported to
KiCad in a fourth.

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
    and are therefore a third reading of the same placement;
  * the .kicad_pcb TEXT, re-read as a fab house would: each stored pad is
    footprint-LOCAL under its footprint's own ``(at)``, so the absolute is
    re-derived by the same translate+rotate KiCad performs on load, and the
    stored copper LAYER is a fourth independent side claim.

Per-component boards, not whole ones: a Gerber harvest also flashes vias and
board-level holes, and a board-level plated hole lands in the same bucket as a
through-hole pad. Isolating one component removes that ambiguity entirely and
still drives the real harvest.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

import pytest
import yaml

from pcb_worker import drc, gerber, kicad, refdes_anchor, route_bridge, silk_source
from pcb_worker.geometry import PlacementTransform, place_point, rotation_radians
from pcb_worker.pad_source import PadGeometryError
from pcb_worker.resolve import resolve_board_best_effort
from pcb_worker.resolved_board import Side

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


# One emitted footprint header / pad line. The emitter writes both on a single
# line in a fixed shape, so the file is read back with two regexes rather than a
# general s-expression parser — and reading the TEXT is what makes this an
# independent measurement: none of the emitter's internal placement decision is
# reused, only the bytes a fab house receives.
_FOOTPRINT_LINE = re.compile(
    r'^\s*\(footprint "(?:[^"\\]|\\.)*" \(layer "[^"]+"\) '
    r"\(at (\S+) (\S+) (\S+)\)\s*$")
_PAD_LINE = re.compile(
    r'^\s*\(pad "(?:[^"\\]|\\.)*" (\S+) \S+ \(at (\S+) (\S+)(?: \S+)?\)'
    r"(?:.*?)\(layers ([^)]*)\)")


def _kicad_copper(board: dict):
    """Every COMPONENT pad the .kicad_pcb emitter STORES, as ``(x_mm, y_mm,
    top)`` in the BOARD frame — or None when the emitter FAILS CLOSED on this
    component (same ``PadGeometryError`` reasoning as ``_gerber_copper``).

    A .kicad_pcb stores each pad footprint-LOCAL beneath its footprint's own
    ``(at x y rot)``; KiCad reproduces the absolute on load by applying that
    translate+rotate and NEVER re-flips a bottom-side footprint, so the same
    ``place_point`` is applied here to recover what the file actually means.
    The bottom-side MIRROR must therefore already be in the stored local
    coordinate — which is precisely what this comparison measures.

    ``top`` is read off the pad's own stored copper layer, a different
    derivation from the census's: None when the pad claims no side (a
    through-hole land's ``*.Cu``, or a stencil-only aperture with no copper
    layer at all).
    """
    try:
        text = kicad.generate_kicad_pcb(board)
    except PadGeometryError:
        return None
    out: list[tuple[float, float, bool | None]] = []
    fx = fy = frot = 0.0
    seen_footprint = False
    for line in text.splitlines():
        header = _FOOTPRINT_LINE.match(line)
        if header is not None:
            fx, fy, frot = (float(header.group(1)), float(header.group(2)),
                            float(header.group(3)))
            seen_footprint = True
            continue
        pad = _PAD_LINE.match(line)
        if pad is None or not seen_footprint:
            continue
        layers = pad.group(4)
        # COPPER ONLY, matching the two classes the census deliberately drops
        # (drc._harvest_pads): a bare unplated bore (np_thru_hole — no barrel,
        # no land) and a paste-only stencil aperture (a QFN thermal pad's
        # sub-nodes, which name no copper layer). Counting either here would be
        # a stored "pad" no census point can ever claim — a comparison artefact,
        # not a placement disagreement.
        if pad.group(1) == "np_thru_hole" or ".Cu" not in layers:
            continue
        ax, ay = place_point(fx, fy, frot,
                             float(pad.group(2)), float(pad.group(3)))
        side: bool | None = None
        if '"F.Cu"' in layers:
            side = True
        elif '"B.Cu"' in layers:
            side = False
        out.append((ax, ay, side))
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


@pytest.mark.parametrize("name,board", CORPUS, ids=[n for n, _ in CORPUS])
def test_the_kicad_export_stores_pads_where_the_census_checks_them(
        name: str, board: dict) -> None:
    """The fourth surface — the .kicad_pcb — stores copper at the census's points.

    Paired both directions for the same reason the Gerber comparison is: a
    census pad with no stored pad is a dropped land, and a stored pad no census
    pad claims is copper nothing checks.

    THE FAULT THIS CATCHES: the loose-dict footprint path wrote the raw
    footprint-local pad offset, so a ``layer: bottom`` part's pads were stored
    UNMIRRORED and KiCad reproduced them where the part's top-side twin would
    sit. The other three surfaces had already been brought onto the one
    ``geometry.component_transform`` rule; this emitter had not, so the same
    board fabricated one way and exported another.
    """
    for comp in _components(board):
        solo = _solo(board, comp)
        ref = comp.get("ref")
        stored = _kicad_copper(solo)
        if stored is None:
            continue
        census = _census_pads(solo)

        census_pts = [(p.x, p.y) for p in census]
        unclaimed = [(x, y) for (x, y, _side) in stored]
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
            f"census checks pads at {sorted(census_pts)} and the .kicad_pcb "
            f"stores copper at {sorted((x, y) for (x, y, _s) in stored)} — "
            f"census pads with no stored pad within {_TOL_MM}mm: {unmatched}; "
            f"stored copper no census pad claims: {unclaimed}. One of them is "
            f"not using geometry.component_transform")

        # Side, per point, matched the same way. A through-hole land claims no
        # side in either reading and drops out rather than being compared.
        for pad in census:
            hit = _take_nearest(
                (pad.x, pad.y), [(x, y) for (x, y, _side) in stored])
            got = stored[hit][2] if hit is not None else None
            want = _census_side(pad)
            if got is None or want is None:
                continue
            assert got is want, (
                f"{name}:{ref} pad {pad.pin} at ({pad.x}, {pad.y}): the census "
                f"reads its copper on the {'front' if want else 'back'} and the "
                f".kicad_pcb stores it on the {'front' if got else 'back'}")


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
        assert _kicad_copper(solo), f"{ref}: the .kicad_pcb stored no pad to compare"

    # U2 is the rotated one; without that, a fixture could drift to all-zero
    # placements and the mirror/rotation composition would stop being separable.
    assert float(by_ref["U2"].get("rotation_deg") or 0.0) % 360.0 != 0.0

    # SW10's lands are SMD, so each states a side the census and the emitter
    # derive independently — the layer-flip half of the rule.
    sides = {side for (_x, _y, side) in _gerber_copper(_solo(board, by_ref["SW10"]))}
    assert sides == {False}, f"SW10's lands should flash on the back, got {sides}"

    # The same claim read out of the .kicad_pcb text: a bottom-side SMD land is
    # STORED on B.Cu, so the layer half of the rule is measured on the emitter
    # this file's fourth arm covers, not only on the Gerber one.
    stored_sides = {side for (_x, _y, side)
                    in _kicad_copper(_solo(board, by_ref["SW10"]))}
    assert stored_sides == {False}, (
        f"SW10's lands should be stored on B.Cu, got {stored_sides}")


# ---------------------------------------------------------------------------
# The designator, on the same mirrored frame
# ---------------------------------------------------------------------------

#: A designator anchor far enough above the body that the bottom-side mirror
#: MOVES the label (13 mm between the two answers) instead of folding it onto
#: itself, which a near-zero offset would.
_AUTHORED_REF_Y_MM = -6.5

#: Ink is a stroke centreline swept by half a width; a point on the box edge is
#: allowed that much slack before it counts as outside.
_INK_SLACK_MM = 0.1

_REFERENCE_LINE = re.compile(
    r'^\s*\(fp_text reference "([^"]*)" \(at (\S+) (\S+)(?: (\S+))?\)')


def _kicad_reference(text: str, ref: str) -> tuple[float, float]:
    """The BOARD-frame point one component's STORED reference text sits at.

    Read the way KiCad reads it: the fp_text ``(at)`` is footprint-LOCAL beneath
    its footprint's own ``(at x y rot)``, and KiCad applies that translate+rotate
    on load and never re-flips a bottom-side footprint. So the same
    ``place_point`` recovers what the file means, and the bottom-side mirror has
    to be in the stored coordinate already.
    """
    fx = fy = frot = 0.0
    for line in text.splitlines():
        header = _FOOTPRINT_LINE.match(line)
        if header is not None:
            fx, fy, frot = (float(header.group(1)), float(header.group(2)),
                            float(header.group(3)))
            continue
        found = _REFERENCE_LINE.match(line)
        if found is not None and found.group(1) == ref:
            return place_point(fx, fy, frot,
                               float(found.group(2)), float(found.group(3)))
    raise AssertionError(f"no fp_text reference for {ref} in the emitted .kicad_pcb")


def _ink_box(points) -> tuple[float, float, float, float]:
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return min(xs), min(ys), max(xs), max(ys)


def _inside(box, point) -> bool:
    return (box[0] - _INK_SLACK_MM <= point[0] <= box[2] + _INK_SLACK_MM
            and box[1] - _INK_SLACK_MM <= point[1] <= box[3] + _INK_SLACK_MM)


def test_the_kicad_reference_sits_on_the_silk_the_fab_prints_for_a_bottom_part() -> None:
    """The fifth thing a footprint stores is WHERE its designator prints, and it
    lives in the same flipped frame the pads do.

    ORACLE: the designator ink itself — ``silk_source.refdes_strokes``, the one
    glyph owner every silk consumer (the B.SilkS Gerber, the DRC projection)
    draws through. The stored fp_text is re-read exactly as KiCad reproduces it
    and must land inside that ink; the UNMIRRORED anchor, which is what a
    footprint-local coordinate stored raw produces, must land outside it. The
    two are 13 mm apart on this part, so neither assertion can pass by accident.
    """
    board = yaml.safe_load(
        (TESTDATA / "parity_corners.yaml").read_text(encoding="utf-8"))
    authored = next(c for c in board["components"] if c.get("ref") == "SW10")
    assert str(authored.get("layer", "")).strip().lower() == "bottom", (
        "SW10 is the bottom-side part this case rests on")
    authored[refdes_anchor.COMPONENT_REFDES_KEY] = {"y_mm": _AUTHORED_REF_Y_MM}

    resolved = resolve_board_best_effort(board)
    comp = next(c for c in resolved["components"] if c.get("ref") == "SW10")
    anchor = refdes_anchor.loose_reference_text(comp)
    assert anchor is not None and anchor.position[1] == pytest.approx(
        _AUTHORED_REF_Y_MM), f"the authored anchor did not survive resolve: {anchor}"

    cx, cy = float(comp["x_mm"]), float(comp["y_mm"])
    rot = float(comp.get("rotation_deg") or 0.0)
    ink = _ink_box([point
                    for stroke in silk_source.refdes_strokes(
                        "SW10", cx, cy, rot, anchor, Side.BOTTOM)
                    for point in stroke.points])
    unmirrored = place_point(cx, cy, rot, *anchor.position)
    assert not _inside(ink, unmirrored), (
        "the fixture no longer separates the mirrored anchor from the raw one")

    stored = _kicad_reference(kicad.generate_kicad_pcb(_solo(resolved, comp)),
                              "SW10")
    assert _inside(ink, stored), (
        f"the .kicad_pcb stores SW10's reference at {stored}, outside the "
        f"B.SilkS designator ink {ink} the fab prints — the bottom-side mirror "
        f"is in the pads' stored coordinate but not in the text's")


# ---------------------------------------------------------------------------
# The pad's OWN turn, on the back
# ---------------------------------------------------------------------------

#: A local pad angle that no rectangle's symmetry can hide. Every multiple of 90
#: maps a rect onto itself, so a sign error there is invisible; 30 degrees on a
#: 2.4 x 1.0 land moves all four corners.
_LOCAL_PAD_ROTATION_DEG = 30.0
_LOCAL_PAD_SIZE_MM = (2.4, 1.0)

#: The pad line with its ANGLE and SIZE captured — the two facts that together
#: state where a land's copper actually is. ``_PAD_LINE`` above deliberately
#: ignores both (it compares centres only), so this is a second reading of the
#: same bytes rather than a widened one.
_PAD_POSE_LINE = re.compile(
    r'^\s*\(pad "((?:[^"\\]|\\.)*)" \S+ \S+ '
    r"\(at (\S+) (\S+)(?: (\S+))?\) \(size (\S+) (\S+)\)")


def _turned_corners(center: tuple[float, float], width: float, height: float,
                    rotation_deg: float) -> list[tuple[float, float]]:
    """The four corners of a land of *width* x *height* centred at *center* and
    turned by *rotation_deg*, sorted so two readings can be compared as sets."""
    theta = rotation_radians(rotation_deg)
    cos_t, sin_t = math.cos(theta), math.sin(theta)
    half_w, half_h = width / 2.0, height / 2.0
    return sorted(
        (center[0] + dx * cos_t - dy * sin_t, center[1] + dx * sin_t + dy * cos_t)
        for dx, dy in ((-half_w, -half_h), (half_w, -half_h),
                       (half_w, half_h), (-half_w, half_h)))


def _kicad_pad_poses(text: str) -> dict[str, tuple[float, float, float, float, float]]:
    """``{pad number: (board_x, board_y, angle_deg, width, height)}`` for every
    stored pad, read the way KiCad reads the file: the ``(at)`` beneath the
    footprint's own ``(at)`` is footprint-local and gets that translate+rotate,
    while the pad's third value is the pad's ABSOLUTE orientation."""
    out: dict[str, tuple[float, float, float, float, float]] = {}
    fx = fy = frot = 0.0
    for line in text.splitlines():
        header = _FOOTPRINT_LINE.match(line)
        if header is not None:
            fx, fy, frot = (float(header.group(1)), float(header.group(2)),
                            float(header.group(3)))
            continue
        pad = _PAD_POSE_LINE.match(line)
        if pad is None:
            continue
        ax, ay = place_point(fx, fy, frot,
                             float(pad.group(2)), float(pad.group(3)))
        angle = float(pad.group(4)) if pad.group(4) else 0.0
        out[pad.group(1)] = (ax, ay, angle,
                             float(pad.group(5)), float(pad.group(6)))
    return out


def test_the_kicad_export_mirrors_a_bottom_pads_own_rotation() -> None:
    """A pad's LOCAL rotation belongs to the same flipped frame its position
    does, and the .kicad_pcb has to store it that way.

    THE FAULT THIS CATCHES: the loose-dict footprint path mirrored a bottom
    part's pad COORDINATES and wrote its pad ANGLE raw, so a non-square land
    turned 30 degrees was exported at its top-side twin's orientation with its
    centre in the right place — copper the census, the Gerber and KiCad no
    longer agree about.

    ORACLE: ``geometry.PlacementTransform`` — the rule the compiled path places
    everything with, and the one the other three surfaces were already brought
    onto. Its ``point`` is applied to the land's four LOCAL corners and its
    ``angle`` to the land's local turn; the emitted bytes are re-read
    independently and rebuilt into corners from the stored size and angle. A
    dropped or unmirrored angle moves every corner, because 30 degrees is
    outside the rectangle's own symmetry.
    """
    board = yaml.safe_load(
        (TESTDATA / "parity_corners.yaml").read_text(encoding="utf-8"))
    resolved = resolve_board_best_effort(board)
    comp = next(c for c in resolved["components"] if c.get("ref") == "SW10")
    assert str(comp.get("layer", "")).strip().lower() == "bottom", (
        "SW10 is the bottom-side part this case rests on")
    assert not comp.get("pads_pre_placed"), (
        "this is the LOOSE-dict arm; a pre-placed IR component carries an "
        "already-absolute pad angle and must not be mirrored again")
    for pad in comp["pads"]:
        pad["size"] = {"width": _LOCAL_PAD_SIZE_MM[0],
                       "height": _LOCAL_PAD_SIZE_MM[1]}
        pad["rotation"] = _LOCAL_PAD_ROTATION_DEG

    transform = PlacementTransform(
        position=(float(comp["x_mm"]), float(comp["y_mm"])),
        rotation_deg=float(comp.get("rotation_deg") or 0.0),
        side=Side.BOTTOM)
    stored = _kicad_pad_poses(kicad.generate_kicad_pcb(_solo(resolved, comp)))
    assert len(stored) == len(comp["pads"]) and stored, (
        f"expected one stored pad per resolved land, got {sorted(stored)}")

    want_angle = transform.angle(_LOCAL_PAD_ROTATION_DEG)
    for pad in comp["pads"]:
        number = str(pad["number"])
        ax, ay, angle, width, height = stored[number]
        assert angle == pytest.approx(want_angle), (
            f"pad {number}: the .kicad_pcb stores its orientation as {angle} "
            f"degrees; the placement rule says {want_angle} on the back")
        assert (width, height) == pytest.approx(_LOCAL_PAD_SIZE_MM), (
            f"pad {number}: the land's own dimensions were not preserved")

        # The corners, both ways. This is the claim the angle number stands for,
        # and it fails on a dropped mirror even if the angle happened to read
        # back plausibly.
        local = _turned_corners(
            (float(pad["position"]["x"]), float(pad["position"]["y"])),
            width, height, _LOCAL_PAD_ROTATION_DEG)
        want = sorted(transform.point(point) for point in local)
        got = _turned_corners((ax, ay), width, height, angle)
        for want_point, got_point in zip(want, got):
            assert got_point == pytest.approx(want_point, abs=_TOL_MM), (
                f"pad {number}: the .kicad_pcb puts its copper at {got}, the "
                f"placement rule at {want}")
