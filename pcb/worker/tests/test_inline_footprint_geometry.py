"""A board that carries its own resolved geometry compiles without the library.

The behaviour under test: when a component carries a ``pads`` list, that list is
the geometry authority and the footprint library is not consulted at all — so a
board survives a machine that does not stock the part it was authored against.
When it does not, nothing changes: the library is the authority and inline
``pins`` remain per-pad-number overrides.

THE ORACLE for the reader itself is the LIBRARY. ``test_inline_geometry_is_the
_library_geometry`` compiles one fixture twice — once resolving every footprint
from the seed library, once from the pad dicts ``resolve_board`` wrote out of
that same library — and demands the two placed-pad projections match field for
field. Any mis-mapping in the inline reader (a dropped corner ratio, a drill
read as a diameter, a shape token read off the wrong key) moves a value on one
side only, and the library says which side is wrong. That is an observation
independent of the reader: it is the parser's own answer for the same part.
"""

from __future__ import annotations

import copy
from pathlib import Path

import pytest
import yaml

from pcb_worker.compile_board import compile_board
from pcb_worker.inline_footprint import (
    BOARD_LIBRARY_LAYER,
    InlineGeometryError,
    carries_full_geometry,
    footprint_from_component,
)
from pcb_worker.resolve import resolve_board
from pcb_worker.resolved_board import (
    DiagnosticSeverity,
    ResolutionFailure,
    ResolutionSuccess,
)

TESTDATA = Path(__file__).parent / "testdata"

#: A footprint ref no library layer supplies. The whole point of the inline
#: path is that this must stop mattering once the board carries its geometry.
UNKNOWN_REF = "Nowhere:NotAPart"

#: The four fab-affecting pad optionals the emitters read. They exist on the
#: board dict only when the footprint authored them, so a reader that drops one
#: silently re-defaults real copper.
OPTIONAL_PAD_FIELDS = ("corner_rratio", "raw_shape",
                       "solder_mask_margin", "solder_paste_margin")


def _minimal_board(**overrides) -> dict:
    board = {
        "version": 1, "name": "mini", "width_mm": 20, "height_mm": 20,
        "layers": ["top", "bottom"],
        "design_rules": {"clearance_mm": 0.2, "trace_width_mm": 0.3,
                         "via_diameter_mm": 0.8, "via_drill_mm": 0.4},
        "components": [],
    }
    board.update(overrides)
    return board


def _roundrect_pad() -> dict:
    return {
        "number": "1", "type": "smd", "shape": "roundrect",
        "position": {"x": -1.4, "y": 0.0},
        "size": {"width": 1.25, "height": 1.75},
        "drill": {"x": 0.0, "y": 0.0},
        "layers": ["F.Cu", "F.Mask", "F.Paste"],
        "corner_rratio": 0.2, "raw_shape": "roundrect",
        "solder_mask_margin": 0.05, "solder_paste_margin": -0.02,
    }


def _courtyard() -> list:
    # Points as {x, y} mappings — the form the panel re-encodes to, which the
    # reader must accept alongside the parser's own [x, y] pairs.
    return [{"kind": "poly", "layer": "F.CrtYd", "width": 0.05,
             "points": [{"x": -2.28, "y": -1.13}, {"x": 2.28, "y": -1.13},
                        {"x": 2.28, "y": 1.13}, {"x": -2.28, "y": 1.13}]}]


def _codes(result, severity: DiagnosticSeverity) -> set[str]:
    return {d.code for d in result.diagnostics if d.severity is severity}


def _errors(result) -> set[str]:
    return _codes(result, DiagnosticSeverity.ERROR)


# ---------------------------------------------------------------------------
# The reader IS the library, field for field.
# ---------------------------------------------------------------------------

def test_inline_geometry_is_the_library_geometry():
    """One fixture, compiled from the library and from its own resolved pads,
    must place identical copper.

    ``resolve_board`` writes each component's library geometry into the board as
    ``pads``/``graphics``; compiling THAT board takes the inline path. So the
    two runs read the same footprints through two different readers, and the
    library run is the oracle for the inline one.
    """
    source = yaml.safe_load((TESTDATA / "parity_corners.yaml").read_text(encoding="utf-8"))
    from_library = compile_board(copy.deepcopy(source))
    from_board = compile_board(resolve_board(copy.deepcopy(source)))
    assert isinstance(from_library, ResolutionSuccess)
    assert isinstance(from_board, ResolutionSuccess)

    def pads(board) -> dict:
        return {
            (comp.ref, pad.source_id): (
                pad.position, pad.size, pad.shape, pad.pad_type, pad.corner_rratio,
                pad.rotation_deg, tuple(layer.id for layer in pad.layers),
                None if pad.drill is None else (pad.drill.shape, pad.drill.size,
                                                pad.drill.plated),
                pad.solder_mask_margin, pad.solder_paste_margin, pad.raw_shape,
                pad.annulus, pad.side,
            )
            for comp in board.components for pad in comp.placed_pads
        }

    library_pads, board_pads = pads(from_library.board), pads(from_board.board)
    assert library_pads, "fixture must place pads for the comparison to mean anything"
    assert board_pads == library_pads

    # The fabricated graphic layers must match too. F.Fab and the other
    # documentation layers are NOT compared: resolve_board attaches only silk
    # and courtyard, so the board never carried the rest and K3 never emits it.
    fabricated = {"F.SilkS", "B.SilkS", "F.CrtYd", "B.CrtYd"}

    def graphics(board) -> list:
        return sorted(
            (comp.ref, graphic.layer.id, graphic.width_mm, repr(graphic.geometry))
            for comp in board.components for graphic in comp.placed_graphics
            if graphic.layer.id in fabricated)

    assert graphics(from_board.board) == graphics(from_library.board)


# ---------------------------------------------------------------------------
# FULL geometry: the library is not consulted.
# ---------------------------------------------------------------------------

def test_full_inline_geometry_compiles_without_a_library_hit():
    """The headline: an unresolvable ref plus inline pads compiles clean, the
    pins land on the YAML pad positions, and the fab optionals reach the IR."""
    board = _minimal_board(
        components=[{
            "ref": "TP1", "footprint": UNKNOWN_REF, "x_mm": 10, "y_mm": 10,
            "rotation_deg": 0, "layer": "top",
            "pins": [{"number": "1", "x_mm": -1.4, "y_mm": 0.0}],
            "pads": [_roundrect_pad()], "graphics": _courtyard(),
        }],
        nets=[{"name": "N1", "pins": ["TP1.1"]}])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert not _errors(result)

    component = result.board.components[0]
    pad = component.placed_pads[0]
    # Board placement (10, 10) + the pad's own local (-1.4, 0).
    assert pad.position == pytest.approx((8.6, 10.0))
    assert pad.size == pytest.approx((1.25, 1.75))
    assert pad.corner_rratio == pytest.approx(0.2)   # authored, not the 0.25 default
    assert pad.solder_mask_margin == pytest.approx(0.05)
    assert pad.solder_paste_margin == pytest.approx(-0.02)
    assert pad.raw_shape == "roundrect"
    assert pad.net_id is not None, "the net's pin must resolve to this pad"
    assert len(component.placed_graphics) == 1
    assert component.provenance.library_layer == "board"


def test_explicit_empty_pads_yields_a_graphics_only_component():
    """``pads: []`` means zero pads — never "fall back to the library"."""
    board = _minimal_board(components=[{
        "ref": "LOGO1", "footprint": UNKNOWN_REF, "x_mm": 10, "y_mm": 10,
        "rotation_deg": 0, "layer": "top", "pads": [],
        "graphics": [{"kind": "line", "layer": "F.SilkS", "width": 0.15,
                      "start": [0.0, 0.0], "end": [1.0, 1.0]}],
    }])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    component = result.board.components[0]
    assert component.placed_pads == ()
    assert len(component.placed_graphics) == 1


def test_inline_pads_without_graphics_are_warned_not_silent():
    """The board owns both halves once it owns either, so a component with no
    graphics really will be fabricated bare — and is told so."""
    board = _minimal_board(components=[{
        "ref": "R7", "footprint": UNKNOWN_REF, "x_mm": 10, "y_mm": 10,
        "rotation_deg": 0, "layer": "top",
        "pads": [{"number": "1", "type": "smd", "shape": "rect",
                  "position": {"x": 0.0, "y": 0.0},
                  "size": {"width": 1.0, "height": 1.0},
                  "drill": {"x": 0.0, "y": 0.0}, "layers": ["F.Cu", "F.Mask"]}],
    }])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert "component_graphics_absent" in _codes(result, DiagnosticSeverity.WARNING)


# ---------------------------------------------------------------------------
# PARTIAL geometry: nothing changes.
# ---------------------------------------------------------------------------

def test_no_inline_geometry_and_an_unknown_ref_still_fails_closed():
    """The rule the inline path must NOT weaken."""
    board = _minimal_board(components=[{
        "ref": "R9", "footprint": UNKNOWN_REF, "x_mm": 10, "y_mm": 10,
        "rotation_deg": 0, "layer": "top",
        "pins": [{"number": "1", "x_mm": -1.0, "y_mm": 0.0}],
    }])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "footprint_unresolved" in _errors(result)


def test_pins_stay_overrides_when_the_board_carries_no_pads():
    """A component with inline ``pins`` and no ``pads`` still resolves its
    footprint from the library — the partial half of the rule."""
    board = _minimal_board(components=[{
        "ref": "R1", "footprint": "Resistor_SMD:R_0805_2012Metric",
        "x_mm": 10, "y_mm": 10, "rotation_deg": 0, "layer": "top",
    }])
    assert not carries_full_geometry(board["components"][0])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    assert result.board.components[0].placed_pads, "the library supplied the pads"
    assert result.board.components[0].provenance.library_layer != "board"


#: The board dict the PANEL emits for a pins-only part — every render-detail key
#: ``pcb_component.to_board_dict`` parks in canonical Extra, and NO ``pads`` key,
#: because the part carries no lands of its own. Pin positions are the library's
#: own R_0805 pad centres, so the coincidence check has something to agree with.
def _panel_pins_only_component() -> dict:
    return {
        "ref": "U1", "footprint": "Resistor_SMD:R_0805_2012Metric",
        "x_mm": 10.0, "y_mm": 10.0, "rotation_deg": 0.0, "layer": "top",
        "pins": [{"number": "1", "x_mm": -0.9125, "y_mm": 0.0},
                 {"number": "2", "x_mm": 0.9125, "y_mm": 0.0}],
        "footprint_id": "", "width": 5.0, "height": 2.5,
        "local_bounds": {"x": -2.5, "y": -1.25, "w": 5.0, "h": 2.5},
        "has_pad_geometry": False, "graphics": [],
        "bbox_center_offset": {"x": 0.0, "y": 0.0},
        "properties": {}, "color": {"r": 0.2, "g": 0.6, "b": 0.3, "a": 1.0},
        "label_visible": True, "locked": False,
    }


def test_a_panel_pins_only_component_resolves_from_the_library():
    """The panel's own board dict for a part with no lands takes the PARTIAL
    path — the regression that broke every routing verb driven from the panel.

    The panel used to emit ``pads`` unconditionally, so a pins-only part crossed
    the wire claiming ``pads: []`` — zero lands, library not consulted — and
    every board it was on was refused with ``pin_without_pad``. Pinned from the
    panel's shape (render-detail Extra and all), not a hand-trimmed component,
    because the whole defect was in which keys that shape carries.
    """
    board = _minimal_board(components=[_panel_pins_only_component()])
    assert not carries_full_geometry(board["components"][0])
    result = compile_board(board)
    assert isinstance(result, ResolutionSuccess), _errors(result)
    component = result.board.components[0]
    assert len(component.placed_pads) == 2, "the library supplied both lands"
    assert component.provenance.library_layer != BOARD_LIBRARY_LAYER


def test_the_same_component_claiming_zero_lands_is_refused():
    """The discriminator for the test above: with ``pads: []`` added — and
    nothing else changed — the identical component is refused by name. So the
    pass above is the ABSENT key doing the work, not a tolerant compiler."""
    comp = _panel_pins_only_component()
    comp["pads"] = []
    result = compile_board(_minimal_board(components=[comp]))
    assert isinstance(result, ResolutionFailure)
    assert "pin_without_pad" in _errors(result)


# ---------------------------------------------------------------------------
# Fail-closed: unreadable inline geometry is refused, never demoted.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("bad_pad", [
    {"number": "1", "type": "smd", "position": {"x": None, "y": 0.0}},
    {"number": "1", "type": "smd", "position": {"x": 0.0, "y": float("nan")}},
    {"number": "1", "type": "smd", "position": {"x": 0.0, "y": 0.0},
     "size": {"width": -1.0, "height": 1.0}},
    {"number": "1", "type": "smd", "position": {"x": 0.0, "y": 0.0},
     "size": {"width": 1.0, "height": 1.0}, "corner_rratio": "wide"},
    # Finite but out of range: the reader accepts it (it only asks "is this a
    # number"), so this one is refused by PadDefinition's own range check —
    # a different exception type reaching the same diagnostic.
    {"number": "1", "type": "smd", "shape": "roundrect",
     "position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.0, "height": 1.0},
     "corner_rratio": 0.9},
    "not-a-mapping",
])
def test_unreadable_inline_geometry_is_refused(bad_pad):
    """A resolvable footprint ref is deliberately used: falling through to the
    library would COMPILE, so the refusal proves the reader never demotes.

    Malformed geometry is refused whether the inline reader or the geometry
    dataclass is the one that catches it.
    """
    board = _minimal_board(components=[{
        "ref": "R8", "footprint": "Resistor_SMD:R_0805_2012Metric",
        "x_mm": 10, "y_mm": 10, "rotation_deg": 0, "layer": "top",
        "pads": [bad_pad],
    }])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component_geometry" in _errors(result)


def test_footprint_from_component_reports_the_offending_field():
    with pytest.raises(InlineGeometryError) as excinfo:
        footprint_from_component(
            {"pads": [{"number": "1", "position": {"x": 0.0, "y": 0.0},
                       "size": {"width": 1.0, "height": 1.0},
                       "solder_mask_margin": "thick"}]},
            UNKNOWN_REF)
    assert "solder_mask_margin" in str(excinfo.value)


# ---------------------------------------------------------------------------
# The trigger is the KEY, so the two states cannot overlap.
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("comp,expected", [
    ({"pads": []}, True),
    ({"pads": [{"number": "1"}]}, True),
    ({}, False),
    # Present but malformed is still FULL: the component claimed geometry
    # ownership, so it gets refused rather than handed back to the library.
    ({"pads": None}, True),
    ({"pads": {}}, True),
    ({"graphics": [{"kind": "line"}]}, False),
])
def test_full_versus_partial_is_decided_by_the_pads_key(comp, expected):
    assert carries_full_geometry(comp) is expected


@pytest.mark.parametrize("bad_pads", [None, {}, {"1": {}}, "none", 0])
def test_a_pads_key_that_is_not_a_list_is_refused_not_demoted(bad_pads):
    """A resolvable ref is used deliberately: demotion would COMPILE, so the
    refusal proves ``pads: null`` never silently becomes the library's copper."""
    board = _minimal_board(components=[{
        "ref": "R7", "footprint": "Resistor_SMD:R_0805_2012Metric",
        "x_mm": 10, "y_mm": 10, "rotation_deg": 0, "layer": "top",
        "pads": bad_pads,
    }])
    result = compile_board(board)
    assert isinstance(result, ResolutionFailure)
    assert "invalid_component_geometry" in _errors(result)


def test_a_non_string_layer_entry_is_refused_by_name():
    """A dropped layer entry is a land that stops touching copper/mask/paste
    with nothing downstream able to notice."""
    with pytest.raises(InlineGeometryError) as excinfo:
        footprint_from_component({"pads": [
            {"number": "1", "type": "smd", "position": {"x": 0.0, "y": 0.0},
             "size": {"width": 1.0, "height": 1.0},
             "layers": ["F.Cu", 42]}]}, UNKNOWN_REF)
    assert "pads[0].layers[1]" in str(excinfo.value)


def test_a_non_mapping_graphic_is_marked_not_dropped():
    """The bad entry earns a marker, and the entry after it keeps its id."""
    definition = footprint_from_component({"pads": [], "graphics": [
        None,
        {"kind": "line", "layer": "F.SilkS", "width": 0.12,
         "start": [0.0, 0.0], "end": [1.0, 0.0]},
    ]}, UNKNOWN_REF)
    assert [marker.feature for marker in definition.unsupported] == \
        ["malformed_graphic"]
    assert [graphic.source_id for graphic in definition.graphics] == ["graphic:1"]


def test_drill_axes_survive_the_round_trip():
    """A through-hole land's drill is carried as ``{x, y}``; equal axes are a
    round drill and unequal an oval one."""
    definition = footprint_from_component({"pads": [
        {"number": "1", "type": "thru_hole", "shape": "circle",
         "position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.7, "height": 1.7},
         "drill": {"x": 1.02, "y": 1.02}, "layers": ["F.Cu", "B.Cu"]},
        {"number": "2", "type": "np_thru_hole", "shape": "oval",
         "position": {"x": 2.0, "y": 0.0}, "size": {"width": 2.0, "height": 1.0},
         "drill": {"x": 2.0, "y": 1.0}, "layers": ["F.Cu", "B.Cu"]},
    ]}, UNKNOWN_REF)
    round_drill, oval_drill = (pad.drill for pad in definition.pads)
    assert (round_drill.shape, round_drill.size, round_drill.plated) == \
        ("round", (1.02, 1.02), True)
    assert (oval_drill.shape, oval_drill.size, oval_drill.plated) == \
        ("oval", (2.0, 1.0), False)


def test_a_sizeless_land_stays_sizeless():
    """``{width: null, height: null}`` is "the footprint authored no size"; the
    reader must not invent one, and the fail-closed gate downstream is what
    refuses to fabricate it."""
    definition = footprint_from_component({"pads": [
        {"number": "1", "type": "smd", "position": {"x": 0.0, "y": 0.0},
         "size": {"width": None, "height": None}, "layers": ["F.Cu"]}]},
        UNKNOWN_REF)
    assert definition.pads[0].size is None
