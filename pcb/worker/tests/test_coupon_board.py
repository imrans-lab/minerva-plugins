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

from pcb_worker.assembly_outputs import build_bom, build_cpl
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
        board = _board()
        bom = build_bom(board, "jlc")
        cpl = build_cpl(board, "jlc")
        assert {r.refs for r in bom.rows} == {("J1",), ("C1",)}
        # The promoted file's component order is the serializer's, not the
        # authoring order — compare membership, not sequence.
        assert set(bom.excluded_refs) == {"LOGO1", "FID1", "FID2", "FID3",
                                          "TP1", "TP2", "TP3", "DAM1"}
        assert sorted(r.ref for r in cpl.rows) == ["C1", "J1"]

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
