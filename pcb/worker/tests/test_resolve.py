"""Footprint-resolve step tests (offline).

Covers:
  (a) resolving the fixture board attaches F.SilkS + F.CrtYd graphics to every
      component; ESP32 (U1) gains its body-outline silk; coincidence passes,
  (b) the fail-closed coincidence guard: a pin nudged 1mm off its footprint pad
      raises ResolveCoincidenceError,
  (c) determinism: resolve twice -> identical output, input not mutated,
  (d) the `resolve` worker method's {ok, board, stats} envelope.

All fixtures are vendored in-repo; no network access.

FIXTURE (docket 019fbe68c5f8, testdata/POLICY.md): this suite used to resolve
``testdata/footprints/smart-remote-orig.yaml``, a REAL Turnrock product board.
It was withdrawn from the corpus on 2026-07-30 because a real design (netlist +
placement) in a public repo is an IP leak. The replacement,
``testdata/footprints/resolve_corners.yaml``, uses the SAME real, public-origin
KiCad library parts (ESP32-S3-DevKitC, DIP-6, EVP-ASAC1A, ...) at new, synthetic
refs/positions/nets — see that file's header for the full rationale. NEVER
repair this module by restoring the deleted fixture from git history.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml

from pcb_worker import resolve
from pcb_worker.methods import handle_request
from pcb_worker.resolve import ResolveCoincidenceError, resolve_board

HERE = Path(__file__).resolve().parent
BOARD_YAML = HERE / "testdata" / "footprints" / "resolve_corners.yaml"
PARITY_CORNERS = HERE / "testdata" / "parity_corners.yaml"


def _load_board() -> dict:
    return yaml.safe_load(BOARD_YAML.read_text(encoding="utf-8"))


def _silk(comp: dict) -> list:
    return [g for g in comp.get("graphics", []) if g["layer"] == "F.SilkS"]


def _crtyd(comp: dict) -> list:
    return [g for g in comp.get("graphics", []) if g["layer"] == "F.CrtYd"]


# ---------------------------------------------------------------------------
# (a) Happy path: every component gains graphics; ESP32 body outline present.
# ---------------------------------------------------------------------------


def test_resolve_attaches_graphics_to_every_component():
    board = _load_board()
    resolved = resolve_board(board)

    total_silk = 0
    total_crtyd = 0
    for comp in resolved["components"]:
        assert "graphics" in comp, f"{comp.get('ref')}: no graphics attached"
        assert all(g["layer"] in {"F.SilkS", "F.CrtYd"} for g in comp["graphics"])
        total_silk += len(_silk(comp))
        total_crtyd += len(_crtyd(comp))

    assert total_silk > 0, "board gained no silkscreen graphics at all"
    assert total_crtyd > 0, "board gained no courtyard graphics at all"


def test_resolve_esp32_gets_body_outline_silk():
    resolved = resolve_board(_load_board())
    u1 = next(c for c in resolved["components"] if c["ref"] == "U1")
    silk_lines = [g for g in _silk(u1) if g["kind"] == "line"]
    assert len(silk_lines) >= 1, "ESP32 (U1) has no F.SilkS body-outline line"
    assert len(_crtyd(u1)) >= 1, "ESP32 (U1) has no courtyard graphic"


def test_resolve_coincidence_passes_for_all_components():
    # No exception == guard passed for all 5 components (renamed from
    # ...for_smart_remote when the fixture moved off the withdrawn product
    # board, docket 019fbe68c5f8 — the assertion is unchanged, just the name).
    resolve_board(_load_board())


# ---------------------------------------------------------------------------
# (a2) Pad geometry: resolve also attaches real per-component pads.
# ---------------------------------------------------------------------------


def test_resolve_attaches_pads_to_every_component():
    resolved = resolve_board(_load_board())
    for comp in resolved["components"]:
        assert comp.get("has_pad_geometry") is True, \
            f"{comp.get('ref')}: has_pad_geometry not set"
        pads = comp.get("pads")
        assert isinstance(pads, list) and len(pads) > 0, \
            f"{comp.get('ref')}: no pads attached"
        # Contract shape consumed by pcb_component.gd::_pads_from_list.
        for pad in pads:
            assert set(pad) >= {
                "number", "type", "shape", "position", "size", "drill", "layers"}
            assert {"x", "y"} <= set(pad["position"])
            assert {"width", "height"} <= set(pad["size"])
            assert {"x", "y"} <= set(pad["drill"])
            assert pad["type"] in {"smd", "thru_hole", "np_thru_hole"}


def test_resolve_pad_counts_match_footprints():
    resolved = resolve_board(_load_board())
    by_ref = {c["ref"]: c for c in resolved["components"]}
    # ESP32-S3-DevKitC-1 (U1) is a 44-pin module; MIC1 is a 6-pin DIP.
    assert len(by_ref["U1"]["pads"]) == 44
    assert len(by_ref["MIC1"]["pads"]) == 6


def test_resolve_pad_shape_and_size_fidelity():
    resolved = resolve_board(_load_board())
    u1 = next(c for c in resolved["components"] if c["ref"] == "U1")
    # Real geometry, not a uniform circle stand-in: some pad is non-rect OR
    # has an asymmetric footprint, and every size is positive.
    real = any(
        pad["shape"] != "rect"
        or pad["size"]["width"] != pad["size"]["height"]
        for pad in u1["pads"])
    assert real, "U1 pads look like uniform stand-ins, not real geometry"
    for pad in u1["pads"]:
        assert pad["size"]["width"] > 0 and pad["size"]["height"] > 0


def test_resolve_tht_vs_smd_drill():
    resolved = resolve_board(_load_board())
    by_ref = {c["ref"]: c for c in resolved["components"]}
    # U1 is thru-hole → drilled copper.
    assert any(pad["drill"]["x"] > 0 for pad in by_ref["U1"]["pads"]), \
        "expected at least one drilled (thru-hole) pad on U1"
    assert all(pad["type"] == "thru_hole" for pad in by_ref["U1"]["pads"])
    # SW1 (EVP-ASAC1A tactile switch) is SMD → EVERY pad drill-less.
    sw1 = by_ref["SW1"]
    assert all(pad["drill"]["x"] == 0 and pad["drill"]["y"] == 0 for pad in sw1["pads"]), \
        "expected all SMD pads on SW1 to be drill-less"
    assert all(pad["type"] == "smd" for pad in sw1["pads"])


def test_resolve_pads_coregister_with_declared_pins():
    board = _load_board()
    resolved = resolve_board(board)
    u1_in = next(c for c in board["components"] if c["ref"] == "U1")
    u1_out = next(c for c in resolved["components"] if c["ref"] == "U1")
    declared = {str(p["number"]): (p["x_mm"], p["y_mm"]) for p in u1_in["pins"]}
    checked = 0
    for pad in u1_out["pads"]:
        pin = declared.get(pad["number"])
        if pin is None:
            continue
        assert abs(pad["position"]["x"] - pin[0]) <= 0.01
        assert abs(pad["position"]["y"] - pin[1]) <= 0.01
        checked += 1
    assert checked > 0, "no U1 pads matched a declared pin number"


# ---------------------------------------------------------------------------
# (b) NEGATIVE: a pin moved off its pad trips the fail-closed guard.
# ---------------------------------------------------------------------------


def test_resolve_fails_when_pin_desyncs_from_pad():
    board = _load_board()
    # Nudge U1 pin 1 by 1mm — far beyond the 0.01mm coincidence tolerance.
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    pin1 = next(p for p in u1["pins"] if str(p["number"]) == "1")
    pin1["x_mm"] += 1.0

    with pytest.raises(ResolveCoincidenceError) as ei:
        resolve_board(board)
    err = ei.value
    assert err.ref == "U1"
    assert err.pin == "1"
    assert err.delta_mm == pytest.approx(1.0, abs=1e-6)


# ---------------------------------------------------------------------------
# (c) Determinism + no input mutation.
# ---------------------------------------------------------------------------


def test_resolve_is_deterministic():
    board = _load_board()
    a = resolve_board(board)
    b = resolve_board(board)
    assert a == b


def test_resolve_does_not_mutate_input():
    board = _load_board()
    snapshot = copy.deepcopy(board)
    resolve_board(board)
    assert board == snapshot, "resolve_board mutated its input"


# ---------------------------------------------------------------------------
# (d) Worker method envelope.
# ---------------------------------------------------------------------------


def _call(method: str, params: dict) -> dict:
    resp = handle_request({"id": "r1", "method": method, "params": params})
    assert resp is not None
    assert resp["id"] == "r1"
    return resp


def test_resolve_method_returns_board_and_stats():
    resp = _call("resolve", {"yaml": BOARD_YAML.read_text(encoding="utf-8")})
    assert resp["ok"] is True
    result = resp["result"]
    assert result["ok"] is True
    assert "components" in result["board"]
    stats = result["stats"]
    assert stats["components"] == len(result["board"]["components"])
    assert stats["silk_graphics"] > 0
    assert stats["courtyard_graphics"] > 0


def test_resolve_method_reports_coincidence_error():
    board = _load_board()
    u1 = next(c for c in board["components"] if c["ref"] == "U1")
    pin1 = next(p for p in u1["pins"] if str(p["number"]) == "1")
    pin1["y_mm"] += 1.0

    resp = _call("resolve", {"board": board})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "coincidence"
    assert resp["error"]["ref"] == "U1"
    assert resp["error"]["pin"] == "1"


def test_resolve_method_parse_error():
    resp = _call("resolve", {})
    assert resp["ok"] is False
    assert resp["error"]["kind"] == "parse"


def test_board_graphic_stats_matches_manual_count():
    resolved = resolve_board(_load_board())
    stats = resolve.board_graphic_stats(resolved)
    manual_silk = sum(len(_silk(c)) for c in resolved["components"])
    manual_crtyd = sum(len(_crtyd(c)) for c in resolved["components"])
    assert stats["silk_graphics"] == manual_silk
    assert stats["courtyard_graphics"] == manual_crtyd


# ---------------------------------------------------------------------------
# SB2 (019f8acfd651): the pad projection must THREAD the fab-affecting fields the
# footprint parser extracts (corner_rratio / solder_mask_margin / rotation) —
# previously dropped, so every resolved roundrect fell back to the emitter's
# default corner ratio and every pad to the global mask clearance. The live
# emitters read `corner_rratio` + `solder_mask_margin` off comp["pads"].
# ---------------------------------------------------------------------------

from pcb_worker.footprints import parse_kicad_mod
from pcb_worker.resolve import _pads_from_parsed

_PAD_FIELDS = HERE / "testdata" / "k1_lossless" / "PAD_FIELDS.kicad_mod"


def test_pads_from_parsed_threads_fab_optionals_from_real_footprint():
    # PAD_FIELDS pad "1": smd roundrect (at -1 0 90), roundrect_rratio 0.25,
    # solder_mask_margin 0.05, solder_paste_margin -0.02. The projection must
    # carry all four (roundrect_rratio NAME-MAPPED to corner_rratio, the key the
    # emitters read); the plain rect pad "3" must carry none of them.
    pads = _pads_from_parsed(parse_kicad_mod(_PAD_FIELDS)["pads"])
    by_num = {p["number"]: p for p in pads}
    p1 = by_num["1"]
    assert p1["corner_rratio"] == pytest.approx(0.25)   # name-mapped from roundrect_rratio
    assert p1["solder_mask_margin"] == pytest.approx(0.05)
    assert p1["solder_paste_margin"] == pytest.approx(-0.02)
    assert p1["rotation"] == pytest.approx(90)
    p3 = by_num["3"]
    for k in ("corner_rratio", "solder_mask_margin", "solder_paste_margin", "rotation"):
        assert k not in p3, f"plain rect pad should not carry {k}"


def test_pads_from_parsed_name_maps_roundrect_rratio_not_hardcoded():
    # A non-default ratio proves the value is threaded, not defaulted to 0.25.
    parsed = [{"number": "9", "type": "smd", "shape": "roundrect",
               "x_mm": 0.0, "y_mm": 0.0, "size": (2.0, 1.0), "layers": ["F.Cu"],
               "roundrect_rratio": 0.4, "solder_mask_margin": 0.12}]
    out = _pads_from_parsed(parsed)[0]
    assert out["corner_rratio"] == 0.4
    assert out["solder_mask_margin"] == 0.12
    # A pad with no optionals stays clean (no None-valued keys injected).
    plain = _pads_from_parsed([{"number": "1", "type": "smd", "shape": "rect",
                                "x_mm": 0.0, "y_mm": 0.0, "size": (1.0, 1.0),
                                "layers": ["F.Cu"]}])[0]
    assert "corner_rratio" not in plain and "solder_mask_margin" not in plain


def test_pads_from_parsed_and_footprint_def_agree_on_fab_optionals():
    # The TWO board-dict projections — resolve._pads_from_parsed and
    # FootprintDefinition.to_board_pad_dicts — must stay byte-identical on the
    # SB2-threaded fields (corner_rratio/margins/rotation), not just the base keys,
    # else the lockstep drifts silently (Fable SB2 note 1: no parity fixture
    # otherwise exercises these). PAD_FIELDS pads "1" (roundrect + margins +
    # rotation) and "3" (plain rect) exercise them. Pad "2" is SKIPPED: its oval
    # drill carries a PRE-EXISTING resolve-vs-footprint_def divergence filed
    # separately (out of SB2 scope).
    from pcb_worker.footprint_def import FootprintDefinition
    parsed = parse_kicad_mod(_PAD_FIELDS)
    from_resolve = {p["number"]: p for p in _pads_from_parsed(parsed["pads"])}
    from_fpdef = {p["number"]: p
                  for p in FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()}
    for num in ("1", "3"):
        assert from_resolve[num] == from_fpdef[num], f"projection drift on pad {num}"
    # Guard against both projections agreeing by both DROPPING the optionals.
    assert from_resolve["1"]["corner_rratio"] == pytest.approx(0.25)
    assert from_resolve["1"]["solder_mask_margin"] == pytest.approx(0.05)
    assert from_resolve["1"]["rotation"] == pytest.approx(90)


# ---------------------------------------------------------------------------
# U4 (019f9509a54c): a footprint pad with NO `(size ...)` node must not get a
# fabricated 1.0x1.0mm land. K25/K14 forbids "no false clean, fictional pad,
# nominal fallback or fabrication-safe result" — this is not a fresh call, it
# is bringing `_pads_from_parsed` into line with the already-tested sibling
# projection `footprint_def.to_board_pad_dicts`
# (test_sizeless_pad_stays_none_instead_of_inventing_geometry), which already
# emits {"width": None, "height": None} for the identical input shape.
#
# The discriminating fixture: a pad whose `(size ...)` node is ABSENT
# entirely — NOT `(size 0 0)`, which is a different (authored-zero) case and
# out of scope here. `footprints._parse_pad` sets size=None only for the
# absent/short-node case (footprints.py:189-192), so a REAL .kicad_mod file
# with no size clause on a pad is the only fixture that actually exercises
# this code path end-to-end through the real KiCad s-expr parser.
# ---------------------------------------------------------------------------

_SIZELESS_PAD_MOD = """\
(footprint "SIZELESS" (layer "F.Cu")
  (pad "1" smd rect (at 0 0) (layers "F.Cu"))
)
"""


def test_pads_from_parsed_leaves_sizeless_pad_as_none_not_1mm(tmp_path):
    fx = tmp_path / "SIZELESS.kicad_mod"
    fx.write_text(_SIZELESS_PAD_MOD, encoding="utf-8")
    parsed = parse_kicad_mod(fx)
    # Prove the discriminating fixture actually discriminates: the parser must
    # have produced size=None (not e.g. a parse failure hiding the real case).
    assert parsed["pads"][0]["size"] is None, "fixture did not exercise the absent-size path"

    out = _pads_from_parsed(parsed["pads"])
    assert len(out) == 1
    size = out[0]["size"]
    assert size == {"width": None, "height": None}
    # Explicit anti-regression: neither the old fabricated 1.0mm default nor a
    # degenerate 0.0 (still an invented, and worse, dimension) may appear.
    assert size["width"] != 1.0 and size["height"] != 1.0
    assert size["width"] != 0.0 and size["height"] != 0.0
    assert size["width"] is None and size["height"] is None


def test_pads_from_parsed_sizeless_matches_footprint_def_projection(tmp_path):
    # Same fixture, run through BOTH board-dict projections — the parity
    # invariant test_footprint_def.py's round-trip tests assert must hold for
    # this case too, not just the sized-pad fixtures they already cover.
    from pcb_worker.footprint_def import FootprintDefinition

    fx = tmp_path / "SIZELESS.kicad_mod"
    fx.write_text(_SIZELESS_PAD_MOD, encoding="utf-8")
    parsed = parse_kicad_mod(fx)

    from_resolve = _pads_from_parsed(parsed["pads"])
    from_fpdef = FootprintDefinition.from_kicad_parsed(parsed).to_board_pad_dicts()
    assert from_resolve == from_fpdef


# ---------------------------------------------------------------------------
# PRINTED REFERENCE DESIGNATORS on the resolve payload (WYSIWYG goal
# 019ff4a5a75a, gap G2).
#
# The fab silk carries a stroke-font designator that exists nowhere in the
# authored board — silk_source synthesizes it at emit time from the component's
# ref. A panel drawing only the resolve's graphics shows a board with NO
# printed designators, so the silk collisions GC9 reports (a designator over a
# neighbour's pad) are invisible in the editor.
#
# WHAT THE REPLY OWES IS THE ANCHOR, NOT THE GLYPHS. The
# reply used to carry the rendered strokes, and a rendering of a ref is a
# PICTURE of one particular name: it survived a copy, a rename and a save, so a
# part copied from its neighbour drew the neighbour's designator ever after.
# The renderer owns the same glyph table and knows the component's own ref; the
# one fact it cannot derive is where the footprint wants the text. These tests
# pin that: a complete anchor on every resolved component, no strokes anywhere
# on the payload, and the anchor is the footprint's own.
# ---------------------------------------------------------------------------

#: The anchor keys every resolved component owes a renderer.
_ANCHOR_KEYS = {"x_mm", "y_mm", "rotation_deg", "size_mm", "hidden"}


def test_resolve_attaches_a_complete_designator_anchor():
    board = resolve_board(_load_board())
    for comp in board["components"]:
        anchor = comp.get("refdes_anchor")
        assert isinstance(anchor, dict) and set(anchor) == _ANCHOR_KEYS, \
            f"{comp['ref']}: incomplete refdes_anchor {anchor!r}"
        assert anchor["size_mm"] > 0 and isinstance(anchor["hidden"], bool)


def test_the_reply_carries_no_rendered_designator_anywhere():
    """THE STALE-PICTURE GUARD, and the double-print guard in one.

    A rendered designator on the payload is a copy of one ref that outlives the
    ref — and if it ever reached comp['graphics'], the loose-dict
    emitters (gerber._emit_silk, kicad's footprint graphics) would print the
    designator they already synthesize themselves a second time. Compared as
    GEOMETRY against silk_source's own output, not by key name, so neither
    defect can come back under a different label."""
    from pcb_worker.footprint_def import ReferenceTextDefinition
    from pcb_worker.silk_source import refdes_strokes

    board = resolve_board(_load_board())
    for comp in board["components"]:
        assert "refdes_graphics" not in comp, (
            f"{comp['ref']}: the reply carries rendered designator strokes — "
            f"a copied or renamed part would keep drawing this one")
        anchor = comp["refdes_anchor"]
        rt = ReferenceTextDefinition(
            position=(anchor["x_mm"], anchor["y_mm"]),
            rotation_deg=anchor["rotation_deg"], size_mm=anchor["size_mm"],
            hidden=anchor["hidden"])
        glyphs = {tuple(poly.points)
                  for poly in refdes_strokes(comp["ref"], 0.0, 0.0, 0.0, rt)}
        drawn = {tuple((x, y) for (x, y) in g.get("points", []))
                 for g in comp["graphics"] if g.get("kind") == "poly"}
        assert not (glyphs & drawn), (
            f"{comp['ref']}: designator strokes leaked into comp['graphics'] — "
            f"the loose-dict emitters would print this designator twice")


def test_the_anchor_places_glyphs_where_the_emitter_prints_them():
    """THE G2 PARITY CLAIM, stated as the theorem it is: rendering the ref at
    the anchor in footprint-local coordinates and then applying the component's
    placement equals the emitter's one-step render at the real placement.

    That is precisely what the panel does — its own mirror of the glyph table
    (pcb/ui/model/pcb_board_font.gd) strokes the component's ref at
    refdes_anchor, and the canvas places the result with the same transform it
    places footprint silk with. If the two disagree, the editor shows the
    designator somewhere the fab does not print it, which is the defect class
    this feature exists to remove. Checked on both sides and at a rotation,
    against silk_source's own placement function, so it cannot drift from the
    emitter without failing."""
    from pcb_worker.footprint_def import ReferenceTextDefinition
    from pcb_worker.resolved_board import Side
    from pcb_worker.silk_source import _place, refdes_strokes

    rt = ReferenceTextDefinition(position=(0.4, -1.9), rotation_deg=15.0,
                                 size_mm=1.2)
    for side in (Side.TOP, Side.BOTTOM):
        for cx, cy, rot in ((10.0, 8.0, 0.0), (3.5, 12.25, 90.0),
                            (7.0, 7.0, 37.5)):
            local = refdes_strokes("U7", 0.0, 0.0, 0.0, rt)
            emitted = refdes_strokes("U7", cx, cy, rot, rt, side)
            placed = [tuple(_place(cx, cy, rot, side, x, y)
                            for (x, y) in poly.points) for poly in local]
            assert placed == [poly.points for poly in emitted], \
                f"identity-extraction does not commute at side={side} rot={rot}"


def test_the_anchor_is_the_footprints_own_authored_one():
    """A footprint with an authored fp_text reference anchor must report THAT,
    not the default offset — the coupon's U1 authors one at x=12.7, far from
    the default (x-centred, y=-1.5), so a reply that ignored the anchor cannot
    accidentally satisfy this. The fixture carrying the far-offset anchor is
    itself asserted, so the test can never silently go vacuous."""
    resolved = resolve_board(_load_board())
    comp = next(c for c in resolved["components"] if c["ref"] == "U1")
    rt = resolve.resolve_footprint(comp["footprint"]).get("reference_text")
    assert rt is not None and rt["x_mm"] == pytest.approx(12.7), (
        "the fixture no longer authors the far-offset anchor this test needs")
    assert comp["refdes_anchor"]["x_mm"] == pytest.approx(rt["x_mm"])
    assert comp["refdes_anchor"]["y_mm"] == pytest.approx(rt["y_mm"])


def test_a_footprint_with_no_authored_anchor_reports_the_emitters_default():
    """The other half: silk_source falls back to REFDES_LOCAL_Y_MM /
    REFDES_TEXT_SIZE_MM when a footprint authors no reference fp_text, so a
    reply that omitted the anchor (or invented a different default) would move
    every such designator on the canvas away from where it prints."""
    from pcb_worker import silk_source

    anchor = resolve._refdes_anchor({}, {})
    assert anchor == {"x_mm": 0.0, "y_mm": silk_source.REFDES_LOCAL_Y_MM,
                      "rotation_deg": 0.0,
                      "size_mm": silk_source.REFDES_TEXT_SIZE_MM,
                      "hidden": False}


def test_resolve_states_the_component_level_resolved_fact():
    """footprint_resolved (bug 019ff4a9a0d7) rides every resolved component —
    including one whose footprint has pads — and is what a pad-less silk-only
    footprint has INSTEAD of has_pad_geometry. Absence (best-effort leaves a
    failing component pristine) is the unresolved signal."""
    board = resolve_board(_load_board())
    for comp in board["components"]:
        assert comp.get("footprint_resolved") is True, comp["ref"]

    from pcb_worker.resolve import resolve_board_best_effort
    broken = _load_board()
    broken["components"][0]["footprint"] = "No_Such:Footprint"
    tolerant = resolve_board_best_effort(broken)
    assert "footprint_resolved" not in tolerant["components"][0], (
        "a component whose footprint did NOT resolve must stay pristine — "
        "stamping the fact here would retire the unresolved badge falsely")


def test_resolved_pads_stay_footprint_local_so_the_compile_round_trip_is_stable():
    """A resolved component's ``pads`` are footprint-LOCAL, with the FOOTPRINT's
    own layer names — even for a part mounted on the BOTTOM.

    That is not an oversight, it is the contract this dict has with
    ``inline_footprint``: the panel persists what resolve returns, and a board
    carrying a ``pads`` key compiles from those bytes instead of the library, so
    ``compile_board`` applies the placement — the bottom mirror and the F/B layer
    swap included — to whatever is in here. Baking the side in at resolve time
    would flip a bottom part twice: its copper would land back on the top of the
    board, and its offsets back where the un-mirrored ones were.

    Pinned by compiling the SAME board both ways. The side belongs to the
    PLACEMENT, and a consumer that reads these pads without placing them (the
    connectivity harvest does place them, via geometry.component_transform) is
    the thing that has to change, not this frame.
    """
    from pcb_worker import compile_board as cb
    from pcb_worker import inline_footprint

    board = yaml.safe_load(PARITY_CORNERS.read_text(encoding="utf-8"))
    resolved = resolve.resolve_board_best_effort(board)

    # SW10 is the bottom-side SMD part; its footprint states the FRONT layers.
    sw10 = next(c for c in resolved["components"] if c["ref"] == "SW10")
    assert sw10["layer"] == "bottom"
    assert inline_footprint.carries_full_geometry(sw10)
    assert sw10["pads"][0]["layers"] == ["F.Cu", "F.Mask", "F.Paste"]
    assert (sw10["pads"][0]["position"], sw10["pads"][1]["position"]) == (
        {"x": -3.0, "y": 0.0}, {"x": 3.0, "y": 0.0})

    def placed(compiled):
        comp = next(c for c in compiled.board.components if c.ref == "SW10")
        return {pad.source_id: (pad.position, tuple(l.id for l in pad.layers))
                for pad in comp.placed_pads}

    from_library = placed(cb.compile_board(board))
    from_resolved = placed(cb.compile_board(resolved))
    assert from_resolved == from_library
    assert from_library["pad:1:0"] == ((17.0, 12.0), ("B.Cu", "B.Mask", "B.Paste"))


def test_pad_fallback_box_measures_a_rotated_land_at_its_turned_extent():
    """A graphics-free footprint's body box comes from the LANDS, turned.

    ``_body_box`` falls back to the union of the PARSED pads when a footprint
    declares neither courtyard nor silk/fab outline. A land carries its own
    ``rotation``, so measuring ``+/- half_w, +/- half_h`` about its centre
    understates a turned one — the box the panel hit-tests and the placement
    checks keep clear would then be smaller than the copper. A 2.0 x 1.0 mm land
    at 45 degrees spans (2.0 + 1.0) / sqrt(2) = 2.1213 mm on BOTH axes.
    """
    import math

    pad = {"number": "1", "x_mm": 0.0, "y_mm": 0.0, "size": (2.0, 1.0),
           "rotation": 45.0}
    box = resolve._body_box({"graphics": [], "pads": [pad]})
    span = 3.0 / math.sqrt(2.0)
    assert box["width"] == pytest.approx(span)
    assert box["height"] == pytest.approx(span)
    assert (box["center_x"], box["center_y"]) == pytest.approx((0.0, 0.0))

    # The unrotated land is unchanged by the same path — no key, no turn.
    flat = resolve._body_box({"graphics": [], "pads": [dict(pad, rotation=0.0)]})
    assert (flat["width"], flat["height"]) == pytest.approx((2.0, 1.0))


def test_footprint_geometry_carries_a_complete_designator_anchor():
    """``resolve.footprint_geometry`` answers for a ref with NO component yet.

    It is the only caller of the anchor rule that has no board component to
    overlay, so it takes the FOOTPRINT half: the .kicad_mod's own reference
    fp_text when it declares one, else the anchor derived from the body. This
    is the path the panel's add-by-library-ref runs through, and a break here
    is invisible to every board-level test — the add is simply refused.

    Oracle: the two .kicad_mod files parsed here. D_SMA states its own
    reference placement, so the reply must reproduce those numbers verbatim;
    R_0805_2012Metric states none, so the reply must still be a COMPLETE
    anchor and must sit clear above the land it would otherwise print over.
    """
    library = Path(__file__).parents[2] / "library" / "footprints"

    def authored(lib: str, name: str):
        parsed = parse_kicad_mod(
            (library / f"{lib}.pretty" / f"{name}.kicad_mod").read_text(
                encoding="utf-8"))
        return parsed, parsed.get("reference_text")

    _, sma_text = authored("Diode_SMD", "D_SMA")
    assert sma_text is not None, "D_SMA stopped authoring a reference fp_text"
    sma = resolve.footprint_geometry("Diode_SMD:D_SMA")["refdes_anchor"]
    for key in ("x_mm", "y_mm", "rotation_deg", "size_mm"):
        assert sma[key] == pytest.approx(sma_text[key]), (
            f"footprint_geometry moved D_SMA's authored {key}: {sma}")
    assert sma["hidden"] is False

    plain_parsed, plain_text = authored("Resistor_SMD", "R_0805_2012Metric")
    assert plain_text is None, "R_0805_2012Metric started authoring an fp_text"
    plain = resolve.footprint_geometry(
        "Resistor_SMD:R_0805_2012Metric")["refdes_anchor"]
    assert set(plain) == {"x_mm", "y_mm", "rotation_deg", "size_mm", "hidden"}
    top = min(p["y_mm"] for p in plain_parsed["pads"])
    assert plain["y_mm"] < top, (
        f"the derived anchor {plain} is not clear of the lands (top {top})")
    assert plain["size_mm"] > 0.0 and plain["hidden"] is False
