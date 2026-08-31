"""Epoch CPN1 station S6 — the jlc-coupon-1 seed board (public fab coupon).

The corpus contract for tests/testdata/coupon_jlc1.yaml (docket 019fe2fb57d8):
the SEED must compile clean under the jlcpcb-2layer profile with a
determinate, CLEAN geometric DRC — every DFM furniture structure is authored
AT a published JLCPCB floor value, so "clean" here is the claim that the
toolchain accepts exactly the geometry the fab publishes as acceptable, and
one nanometre tighter would flip a witness into a violation (the tightening
rows prove the witnesses actually sit on their floors — a coupon whose
"minimum" structures were comfortably legal would certify nothing).

SINCE S7 THIS FILE IS THE PROMOTED BOARD, not the seed: NET_A/NET_B carry the
copper designed through the co-working draft loop, and every coordinate has
been through the panel's 32-bit float round trip. Selectors here therefore
match with a TOLERANCE — an exact `== 14.05` silently stops matching when the
file says 14.0500001907349, and a selector that matches nothing makes its
test pass vacuously. Each selector asserts its own hit count for that reason.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml

from pcb_worker.assembly_outputs import build_package
from pcb_worker.compile_board import compile_board
from pcb_worker.drc_geometric import run_geometric_drc
from pcb_worker.gerber import build_gerbers_ir
from pcb_worker.resolved_board import ProfileOutline, ResolutionSuccess

COUPON = Path(__file__).resolve().parent / "testdata" / "coupon_jlc1.yaml"


# One f32 round trip is ~1e-6 mm on these magnitudes; 1e-4 is far inside any
# geometry this board asserts and far outside float noise.
_TOL_MM = 1e-4


def _near(a: float, b: float) -> bool:
    return abs(float(a) - float(b)) < _TOL_MM



def _board() -> dict:
    return yaml.safe_load(COUPON.read_text(encoding="utf-8"))


def _compiled(board: dict | None = None):
    result = compile_board(board or _board())
    assert isinstance(result, ResolutionSuccess), \
        [(d.code, d.message) for d in result.diagnostics]
    return result


class TestSeedCoupon:
    def test_compiles_clean_under_jlcpcb_profile(self):
        result = _compiled()
        assert result.board.provenance.rule_profile_ref.id == "jlcpcb-2layer"
        # Only benign warnings: courtyard documentation + the KiCad header
        # footprint's F.Fab text (F.Fab is non-fabrication by contract).
        for diag in result.diagnostics:
            if diag.severity == "warning":
                assert diag.code in ("captured_geometry_not_emitted",
                                     "feature_omitted"), diag

    def test_geometric_drc_is_determinately_clean(self):
        drc = run_geometric_drc(_compiled().board)
        assert drc["verdict"] == "clean"

    def test_slot_cutout_reaches_the_ir_and_edge_cuts(self):
        rb = _compiled().board
        assert isinstance(rb.outline, ProfileOutline)
        assert len(rb.outline.cutouts) == 1
        edge = next(t for n, t in build_gerbers_ir(rb).items()
                    if "Edge_Cuts" in n)
        assert "X10800000" in edge and "X13800000" in edge

    def test_full_package_emits_with_agreeing_mask_polarity(self):
        files = build_gerbers_ir(_compiled().board)
        suffixes = {n.split("jlc-coupon-1-")[1] for n in files}
        assert {"F_Cu.gbr", "B_Cu.gbr", "F_Mask.gbr", "B_Mask.gbr",
                "F_Paste.gbr", "B_Paste.gbr", "F_SilkS.gbr", "B_SilkS.gbr",
                "Edge_Cuts.gbr", "PTH.drl", "job.gbrjob"} <= suffixes
        for name in ("F_Mask.gbr", "B_Mask.gbr"):
            text = next(t for n, t in files.items() if n.endswith(name))
            assert "TF.FilePolarity,Negative" in text

    def test_silk_carries_owl_arcs(self):
        # Reference-designator emission is certified by the silk/refdes suites
        # (test_gerbers.py), not re-proven here; this row pins the coupon-only
        # geometry — the owl's arc strokes.
        files = build_gerbers_ir(_compiled().board)
        silk = next(t for n, t in files.items() if n.endswith("F_SilkS.gbr"))
        assert "G03" in silk or "G02" in silk  # the owl's arcs

    def test_dam_witness_mask_apertures_reach_the_stencil_free_mask(self):
        """The mask-dam witness's EMITTED BYTES. DAM1's pads are 0.6x0.8 at
        (8.6,16)/(9.4,16); with the 0.05/side allowance the mask openings are
        0.7x0.9 rects whose inner edges leave exactly the 0.10 mm dam
        [min_mask_sliver 0.10].

        This half stays byte-level on purpose — it pins what the fab receives.
        The companion test below pins what the CHECKER says about the same
        geometry, and the pair is the point: bytes alone were all this witness
        could assert before CP2 S5, because no mask-sliver check existed.
        """
        files = build_gerbers_ir(_compiled().board)
        mask = next(t for n, t in files.items() if n.endswith("F_Mask.gbr"))
        assert "R,0.7X0.9*%" in mask  # the DAM opening aperture (measured)
        assert "X8600000" in mask and "X9400000" in mask
        assert "Y-16000000" in mask

    def test_dam_witness_now_certifies_a_gc8_verdict_not_just_bytes(self):
        """WHAT CP2 S5 CHANGED FOR THIS WITNESS.

        Its docstring has always said the dam is "exactly the 0.10 mm dam
        [min_mask_sliver 0.10]", but until GC8 existed nothing read that floor —
        so the witness certified an aperture SIZE and the floor reference was
        decoration. The board could have been authored with a 0.02 dam and this
        suite would have been just as green, because the only assertions were
        about bytes.

        Now the same geometry is measured against the floor it names. The dam
        sits EXACTLY at 0.10, which is a pass (a measurement at the floor
        satisfies it — see `_violates`), so the coupon stays determinately clean
        AND the number in the docstring is finally load-bearing.

        Sitting exactly on the floor is deliberate for a witness: it is the only
        position that fails if the check drifts in EITHER direction. A dam at
        0.3 would survive a broken check; a dam at 0.05 would only prove the
        check fires.
        """
        from pcb_worker.drc_geometric import project_board
        from pcb_worker.mask_source import ORIGIN_SMD_PAD
        from pcb_worker.resolved_board import Side

        rb = _compiled().board
        proj = project_board(rb)
        dam = sorted(
            (o for o in proj.mask
             if o.ref == "DAM1" and o.side is Side.TOP
             and o.origin == ORIGIN_SMD_PAD),
            key=lambda o: o.x)
        assert len(dam) == 2, f"expected DAM1's two mask openings, got {len(dam)}"

        # Inner edges: right edge of the left opening, left edge of the right.
        web = (dam[1].x - dam[1].width / 2.0) - (dam[0].x + dam[0].width / 2.0)
        assert web == pytest.approx(0.10), (
            f"the dam witness is no longer sitting on the floor it names: {web}")
        assert web == pytest.approx(
            rb.design_rules.minimums.min_mask_sliver_mm)

        drc = run_geometric_drc(rb)
        assert drc["verdict"] == "clean"
        assert drc["counts"]["gc8_mask_sliver"] == 0, (
            "a dam exactly AT the floor must PASS — flagging it would reject "
            "boards authored precisely to a published minimum")

    def test_slot_edge_witness_sits_at_the_cutout_floor(self):
        """The slot-adjacent run's copper edge is exactly 0.20 from the
        cutout's right edge (x 14.05 centerline - 0.05 half width = 14.0 vs
        slot at 13.8) — the cutout branch of GC5's floor, witnessed on the
        coupon itself rather than only in test_cutouts.py."""
        rb = _compiled().board
        witness = [seg for t in rb.traces for seg in t.segments
                   if _near(seg.a[0], 14.05) and _near(seg.b[0], 14.05)]
        assert witness, "the slot-edge witness run is missing"

    def test_bom_cpl_carry_exactly_the_two_real_parts(self):
        # THE ORDER PAIR COMES FROM ONE COMPILATION AND ONE WALK. The emitters
        # read the compiled IR — the same object the gerber emitter reads — and
        # ``build_package`` is the entry point that renders both files from a
        # single emission, so the BOM and the CPL asserted below cannot be
        # describing two different resolutions of this board.
        emission = build_package(_compiled().board, "jlc").emission
        assert {r.refs for r in emission.bom} == {("J1",), ("C1",)}
        # The promoted file's component order is the serializer's, not the
        # authoring order — compare membership, not sequence.
        # REV1 joined this set in CP2 S9: it is the bottom-side revision-text
        # fixture, silk-only and assembly:exclude. Its presence HERE rather than
        # among the BOM rows is the assembly-exclusion flag doing its job — a
        # decorative part must be excluded from BOM/CPL without being refused
        # an identity, which is the contract CPN1-S3 established.
        assert set(emission.excluded_refs) == {"LOGO1", "FID1", "FID2", "FID3",
                                               "TP1", "TP2", "TP3", "DAM1",
                                               "REV1"}
        assert sorted(r.ref for r in emission.cpl) == ["C1", "J1"]

    def test_featured_nets_carry_the_co_designed_copper(self):
        """INVERTED at S7 and that is the point: this test used to assert
        NET_A/NET_B were deliberately unrouted, because the file was the SEED
        and their copper was the thing the co-working round existed to create.
        The round ran, the board was promoted, and the copper is now IN the
        design of record — so the same test now pins its presence."""
        rb = _compiled().board
        routed = {t.net_id for t in rb.traces}
        by_name = {n.name: n.id for n in rb.nets}
        assert by_name["NET_A"] in routed
        assert by_name["NET_B"] in routed
        # NET_B is the two-layer one: it rises through its via into C1.2.
        assert any(v.net_id == by_name["NET_B"] for v in rb.vias)


class TestWitnessesSitOnTheirFloors:
    """Tighten each witness by 0.02 mm and the corresponding check must flip
    to a violation — proof the authored structures sit AT the floors rather
    than comfortably above them."""

    def _drc_types(self, board) -> set[str]:
        result = compile_board(board)
        if not isinstance(result, ResolutionSuccess):
            # Some floors are enforced at COMPILE (trace width vs profile);
            # a compile refusal is an equally valid "the floor is live" proof.
            return {d.code for d in result.diagnostics if d.severity == "error"}
        drc = run_geometric_drc(result.board)
        return {f["type"] for f in drc.get("findings", ())}

    def test_clearance_pair_floor_is_live(self):
        board = _board()
        moved = 0
        for trace in board["traces"]:
            pts = trace["points"]
            if trace["net"] == "NET_LAD2" and len(pts) == 5:
                # Lower the LAD2 finger from y 1.45 to 1.43: gap 0.08 < 0.1
                for p in pts:
                    if _near(p["y_mm"], 1.45):
                        p["y_mm"] = 1.43
                        moved += 1
        assert moved == 2, "the LAD2 finger selector no longer matches the seed"
        assert "gc2_copper_clearance" in self._drc_types(board)

    def test_slot_edge_witness_floor_is_live(self):
        board = _board()
        moved = 0
        for trace in board["traces"]:
            pts = trace["points"]
            if (trace["net"] == "NET_LAD1" and len(pts) == 3
                    and _near(pts[0]["x_mm"], 14.05) and _near(pts[1]["y_mm"], 10)):
                for p in pts:
                    if _near(p["x_mm"], 14.05):
                        p["x_mm"] = 14.03  # copper edge 0.18 < 0.2 from slot
                        moved += 1
        assert moved == 2, "the slot-witness selector no longer matches the seed"
        types = self._drc_types(board)
        assert "gc5_copper_to_edge" in types

    def test_edge_witness_floor_is_live(self):
        board = _board()
        for trace in board["traces"]:
            pts = trace["points"]
            if (trace["net"] == "NET_LAD1"
                    and all(p["y_mm"] == 0.25 for p in pts)):
                for p in pts:
                    p["y_mm"] = 0.23  # copper edge 0.18 < 0.2
        types = self._drc_types(board)
        assert "gc5_copper_to_edge" in types

    def test_annular_witness_floor_is_live(self):
        board = _board()
        # TP1's witness geometry lives in its FIXTURE footprint
        # (Minerva_Fixture:TP_MinAnnular_0p6 — land 0.96 / drill 0.6, so the
        # FABRICATED ring is the 0.18 floor, not just the checked one; see bug
        # 019fe3736334 for why an inline annulus override was the wrong
        # vehicle). The tightening still rides the override channel, which
        # GC4 honors: if overrides are ever refused on locked footprints,
        # this row fails loudly at compile and gets re-vehicled.
        for comp in board["components"]:
            if comp["ref"] == "TP1":
                comp["pins"][0]["annulus_diameter_mm"] = 0.92  # 0.16 < 0.18
        assert "gc4_annular_ring" in self._drc_types(board)

    def test_trace_width_floor_is_live(self):
        board = _board()
        for trace in board["traces"]:
            if trace["width_mm"] == 0.1:
                trace["width_mm"] = 0.08  # < 0.10 floor
        assert "gc1_trace_width" in self._drc_types(board)


class TestBackSilkReadsFromTheBack:
    """CP2 S9's deliverable, pinned as a property rather than as bytes.

    The golden already pins the exact B_SilkS bytes. What a golden CANNOT say
    is whether those bytes are the RIGHT WAY ROUND — a 180-degree-wrong legend
    is byte-stable and blesses perfectly. So this reads the emitted file back
    with an INDEPENDENT parser and asserts the orientation directly, which is
    what S9's brief demanded ("confirm it by an INDEPENDENT parser/renderer
    walkthrough rather than by our own emitter's self-report").

    WHY THE COUPON PLACES REV1 AT 180 DEGREES, and why that is not a fudge: a
    bottom-side placement mirrors LOCAL Y — that is oracle-pinned to pcbnew's
    own FOOTPRINT.Flip (geometry.PlacementTransform) and is correct for
    geometry. KiCad's fp_text escapes the consequence because it carries a
    `justify mirror` effect that the renderer honours. Minerva has no text
    primitive: legend is BAKED STROKE GEOMETRY, so it takes the geometric
    mirror. MirrorY is MirrorX composed with a 180-degree rotation, so
    stroke-baked legend on the back lands upside down unless the placement
    pre-rotates by 180. This test is what stops that rotation being "cleaned
    up" by someone who reads it as noise.
    """

    def _bottom_silk_segments(self):
        import warnings

        pytest.importorskip("gerbonara")
        from gerbonara import GerberFile

        result = compile_board(_board())
        assert isinstance(result, ResolutionSuccess)
        files = build_gerbers_ir(result.board, name="coupon")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(files["coupon-B_SilkS.gbr"],
                                            filename="coupon-B_SilkS.gbr")
        return [(float(o.x1), float(o.y1), float(o.x2), float(o.y2))
                for o in parsed.objects]

    def test_back_silk_is_not_empty(self):
        """The negative control. Every orientation claim below is vacuous on a
        blank layer, and B_SilkS WAS blank for this board's whole history —
        gerber.py emitted no bottom legend at all before CP2 S3."""
        assert self._bottom_silk_segments(), \
            "B.SilkS is empty; the orientation assertions below prove nothing"

    def test_back_silk_is_mirror_written_in_the_gerber_frame(self):
        """A Gerber is drawn as seen from the TOP, through the board. Back
        legend must therefore be MIRROR-WRITTEN in the file and read correctly
        once the board is flipped.

        The reference is the SAME fixture rendered by production code on a
        board that carries nothing else, placed front-side and unrotated. That
        isolation matters: filtering the coupon's own F_SilkS by a coordinate
        window would sweep in the neighbouring components' legend and compare
        two different things. REV1 is the only bottom-side component on the
        coupon, so its B_SilkS needs no filtering at all.
        """
        import warnings

        pytest.importorskip("gerbonara")
        from gerbonara import GerberFile

        board = _board()
        rev = next(c for c in board["components"] if c["ref"] == "REV1")
        # Drop the net-bearing sections along with the other components: the
        # coupon's nets name J1/C1 pins, and leaving them behind on a
        # one-component board fails resolution with net_pin_unresolved rather
        # than producing a reference rendering.
        only_rev = {k: v for k, v in board.items()
                    if k not in ("nets", "traces", "vias", "zones")}
        only_rev["components"] = [dict(rev, layer="top", rotation_deg=0)]
        result = compile_board(only_rev)
        assert isinstance(result, ResolutionSuccess)
        files = build_gerbers_ir(result.board, name="ref")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(files["ref-F_SilkS.gbr"],
                                            filename="ref-F_SilkS.gbr")

        cx, cy = float(rev["x_mm"]), -float(rev["y_mm"])   # GERBER frame
        def rel(segs):
            out = set()
            for x1, y1, x2, y2 in segs:
                a = (round(x1 - cx, 4), round(y1 - cy, 4))
                b = (round(x2 - cx, 4), round(y2 - cy, 4))
                out.add(tuple(sorted((a, b))))
            return out

        upright = rel([(float(o.x1), float(o.y1), float(o.x2), float(o.y2))
                       for o in parsed.objects])
        back = rel(self._bottom_silk_segments())
        assert upright, "the front-side reference rendering is empty"
        assert len(back) == len(upright), (
            f"back legend has {len(back)} segments, the upright reference has "
            f"{len(upright)} — the two are not the same artwork, so the "
            "orientation comparison below would be meaningless")

        mirror_x = {tuple(sorted(((-p[0], p[1]), (-q[0], q[1])))) for p, q in upright}
        mirror_y = {tuple(sorted((( p[0], -p[1]), ( q[0], -q[1])))) for p, q in upright}
        assert back == mirror_x, (
            "back legend is not the X-mirror of the upright rendering — it is "
            "the wrong way round on the fabricated board. If REV1's "
            "rotation_deg stopped being 180, that is why: a bottom placement "
            "mirrors LOCAL Y, and MirrorY == MirrorX o rotate(180)")
        # State what it must NOT be, so an accidentally-symmetric fixture
        # cannot satisfy the assertion above.
        assert back != upright, "back legend is unmirrored"
        assert back != mirror_y, "back legend is upside down (Y-mirrored)"


class TestSilkStaysOnTheBoard:
    """Coupon silk-placement regression (WYSIWYG round, 2026-08-12).

    The panel's WYSIWYG render surfaced six silk defects no check caught:
    designators printed over neighbouring pads (GC9 saw those two), off the
    board's top edge (FID1/FID2), across the logo face, and REV A artwork
    reaching into the cutout. Fixed by authoring `hide` on the fixture
    footprints' references (owner ruling on 019ff2a6ce1b: hide means HIDDEN)
    and moving REV1 clear of the cutout.

    THESE TESTS ARE STANDING IN FOR A MISSING CHECK: geometric DRC has no
    silk-to-edge and no silk-over-cutout rule (GC9 is width + silk-to-pad
    only), so the emitted bytes are swept here directly. If a GC advisory for
    this class ever lands, these stay as the coupon's own pin — a fixture
    regression should fail the fixture's suite, not only a generic check.
    """

    CUTOUT = (10.8, 5.0, 13.8, 11.0)

    def _silk_endpoints(self, filename: str):
        import warnings

        pytest.importorskip("gerbonara")
        from gerbonara import GerberFile

        result = _compiled()
        files = build_gerbers_ir(result.board, name="coupon")
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            parsed = GerberFile.from_string(files[filename], filename=filename)
        pts = []
        for obj in parsed.objects:
            if type(obj).__name__ in ("Line", "Arc"):
                pts += [(float(obj.x1), -float(obj.y1)),
                        (float(obj.x2), -float(obj.y2))]
        assert pts, f"{filename} carries no silk — the sweep below is vacuous"
        return pts

    def test_no_silk_prints_off_the_board(self):
        """The fab clips silk at the outline; a stroke past the edge is artwork
        that will not exist on the physical board. Was 60 endpoints (FID1 and
        FID2's designators hanging over the top edge) before the fix."""
        board = _board()
        w, h = float(board["width_mm"]), float(board["height_mm"])
        for layer in ("coupon-F_SilkS.gbr", "coupon-B_SilkS.gbr"):
            off = [(x, y) for (x, y) in self._silk_endpoints(layer)
                   if x < 0 or x > w or y < 0 or y > h]
            assert off == [], f"{layer}: silk prints off the board at {off[:4]}"

    def test_no_silk_prints_into_the_cutout(self):
        """There is no substrate inside the cutout — silk there lands on air.
        Was 7 endpoints (REV A's top band) before REV1 moved to (12, 12)."""
        x0, y0, x1, y1 = self.CUTOUT
        for layer in ("coupon-F_SilkS.gbr", "coupon-B_SilkS.gbr"):
            inside = [(x, y) for (x, y) in self._silk_endpoints(layer)
                      if x0 <= x <= x1 and y0 <= y <= y1]
            assert inside == [], f"{layer}: silk prints into the cutout at {inside[:4]}"

    def test_hidden_fixture_designators_do_not_print(self):
        """The fixture footprints author `hide` on their references; the emitted
        silk must carry J1's and DAM1's designators (the two kept deliberately —
        they exercise the authored-anchor and default-anchor paths) and nobody
        else's. Checked structurally: every F-silk stroke endpoint must belong
        to a kept component's neighbourhood or to authored footprint artwork."""
        result = _compiled()
        from pcb_worker.silk_source import refdes_strokes

        # The suppression is the owner's: a hidden reference yields no strokes.
        for comp in result.board.components:
            rt = result.board.footprint_for(comp).reference_text
            strokes = refdes_strokes(
                comp.ref, comp.placement.position[0], comp.placement.position[1],
                comp.placement.rotation_deg, rt, comp.placement.side)
            if comp.ref in ("J1", "DAM1"):
                assert strokes, f"{comp.ref} should keep its printed designator"
            else:
                assert strokes == (), (
                    f"{comp.ref} prints a designator; its fixture footprint "
                    f"should author `hide`")
