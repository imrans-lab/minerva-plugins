"""The material probe: is the solid HERE, and how thick is it along this ray.

WHAT WOULD SHOW THIS WRONG (the oracle for the whole file)
A tray a person can measure with a rule: an open box 40 x 30 x 20 mm with 2 mm
walls, so the floor spans z 0..2 and the skin over it spans z 18..20. Every
number asserted below is read off THOSE dimensions, not off anything the code
under test computes.

The fixture is built to defeat the two lazy implementations by construction:

* BOUNDING-BOX CONTAINMENT. The floorless variant is the same tray with the
  pocket cut through the bottom face. Its bounding box is IDENTICAL to the
  tray's — same eight corners — so a box test says "material" at the floor
  point in both. That is how a floorless tray passes every reference check:
  the references it is measured against are all outside the missing floor.
* TESSELLATION PARITY. The seam fixture unions two boxes that share a face at
  z = 2. A crossing-parity count over a triangulation meets both coincident
  faces, flips twice and reads 4 mm of solid PLA as air. The walk here is
  asked to report one 4 mm slab.

This needs build123d (to evaluate the DSL) and OCP (to classify the B-Rep);
both ship in the plugin's embedded runtime bundle and neither is on a plain CI
runner, so the module skips there.
"""

from __future__ import annotations

import pytest

pytest.importorskip("build123d", reason="build123d not installed in this environment")
pytest.importorskip("OCP", reason="the OCCT bindings are not installed in this environment")

from mcad_worker import material as mat  # noqa: E402
from mcad_worker import methods  # noqa: E402
from mcad_worker.material import material  # noqa: E402

# --- the fixture, in millimetres -------------------------------------------
WALL = 2.0
BOX_X, BOX_Y, BOX_Z = 40.0, 30.0, 20.0
#: Where every probe is taken: over the middle of the floor, well clear of the
#: walls, so nothing but the floor and the skin is on the ray.
PROBE_X, PROBE_Y = 20.0, 15.0
#: The floor spans z 0..WALL and the skin z BOX_Z-WALL..BOX_Z.
FLOOR_TOP = WALL
SKIN_BOTTOM = BOX_Z - WALL
#: The ray starts this far above the box and points straight down.
RAY_Z = 50.0

TRAY = """
wall = 2
outer = cube(40, 30, 20)
inner = translate([wall, wall, wall], cube(36, 26, 16))
tray = outer - inner
"""

#: The same tray with the pocket cut THROUGH the bottom face: no floor, same
#: bounding box, same walls, same skin.
FLOORLESS = """
wall = 2
outer = cube(40, 30, 20)
inner = translate([wall, wall, 0 - 1], cube(36, 26, 18 + 1))
tray = outer - inner
"""

#: Two slabs unioned on a shared face at z = 2. The DSL's `+` FUSES them, so
#: this one is a single body with no seam left in it — measured: one solid,
#: two surface crossings. The real seam is built in OCCT below.
SEAM = """
lower = cube(40, 30, 2)
upper = translate([0, 0, 2], cube(40, 30, 2))
stack = lower + upper
"""


def _ok(reply: dict) -> dict:
    assert reply["ok"], reply.get("error")
    return reply["result"]


def _point(source: str, z: float) -> dict:
    return _ok(material({"source": source, "at_mm": [PROBE_X, PROBE_Y, z]}))


def _ray(source: str) -> dict:
    return _ok(material({
        "source": source,
        "from_mm": [PROBE_X, PROBE_Y, RAY_Z],
        "direction_mm": [0, 0, -1],
    }))


# --- the point form ---------------------------------------------------------


def test_a_point_in_the_floor_is_inside_the_material() -> None:
    answer = _point(TRAY, 1.0)
    assert answer["inside"] is True
    assert answer["state"] == "inside"
    # The binding the document evaluates to, so a reader knows WHICH body.
    assert answer["body"] == "tray"
    # 1 mm up to the floor's top face, 1 mm down to its underside.
    assert answer["nearest_surface_mm"] == pytest.approx(1.0, abs=1.0e-6)


def test_a_point_one_millimetre_above_the_floor_is_in_air() -> None:
    answer = _point(TRAY, FLOOR_TOP + 1.0)
    assert answer["inside"] is False
    assert answer["state"] == "outside"
    assert answer["body"] == ""
    assert answer["nearest_surface_mm"] == pytest.approx(1.0, abs=1.0e-6)
    assert answer["nearest_point_mm"][2] == pytest.approx(FLOOR_TOP, abs=1.0e-6)


def test_the_floorless_tray_has_no_material_where_its_bounding_box_does() -> None:
    """THE BOX IS FULL EITHER WAY — this is the test a box check fails."""
    solid = _point(TRAY, 1.0)
    hollow = _point(FLOORLESS, 1.0)
    assert solid["inside"] is True
    assert hollow["inside"] is False
    # Same outer envelope: a point inside the side wall is material in both, so
    # the difference above is the floor and not a different-sized box.
    assert _point(TRAY, 10.0)["inside"] is False
    assert _ok(material({"source": TRAY, "at_mm": [1.0, 15.0, 10.0]}))["inside"] is True
    assert _ok(material({"source": FLOORLESS, "at_mm": [1.0, 15.0, 10.0]}))["inside"] is True


# --- the ray form -----------------------------------------------------------


def test_a_ray_down_the_tray_reports_the_skin_then_the_floor() -> None:
    answer = _ray(TRAY)
    assert answer["count"] == 2
    skin, floor = answer["segments"]
    assert skin["thickness_mm"] == pytest.approx(WALL, abs=1.0e-6)
    assert floor["thickness_mm"] == pytest.approx(WALL, abs=1.0e-6)
    # Where they are, in world z: the skin's underside and the floor's top.
    assert skin["entry_point_mm"][2] == pytest.approx(BOX_Z, abs=1.0e-6)
    assert skin["exit_point_mm"][2] == pytest.approx(SKIN_BOTTOM, abs=1.0e-6)
    assert floor["entry_point_mm"][2] == pytest.approx(FLOOR_TOP, abs=1.0e-6)
    assert floor["exit_point_mm"][2] == pytest.approx(0.0, abs=1.0e-6)
    assert answer["total_thickness_mm"] == pytest.approx(2 * WALL, abs=1.0e-6)
    assert answer["started_inside"] is False
    assert answer["unbounded"] is False
    assert skin["contiguous_with_previous"] is False
    assert floor["contiguous_with_previous"] is False
    for segment in answer["segments"]:
        assert segment["body"] == "tray"


def test_a_ray_down_the_floorless_tray_reports_only_the_skin() -> None:
    """The oracle for the whole feature: the floor that is not there."""
    answer = _ray(FLOORLESS)
    assert answer["count"] == 1
    assert answer["segments"][0]["thickness_mm"] == pytest.approx(WALL, abs=1.0e-6)
    assert answer["segments"][0]["entry_point_mm"][2] == pytest.approx(BOX_Z, abs=1.0e-6)
    assert answer["total_thickness_mm"] == pytest.approx(WALL, abs=1.0e-6)


def test_a_ray_started_inside_the_material_says_so() -> None:
    answer = _ok(material({
        "source": TRAY,
        "from_mm": [PROBE_X, PROBE_Y, 1.0],
        "direction_mm": [0, 0, 1],
    }))
    assert answer["started_inside"] is True
    assert answer["segments"][0]["entry_mm"] == pytest.approx(0.0, abs=1.0e-9)
    # 1 mm of floor left above the start, then the skin.
    assert answer["segments"][0]["thickness_mm"] == pytest.approx(1.0, abs=1.0e-6)
    assert answer["count"] == 2


def test_a_fused_union_on_a_shared_plane_is_one_slab() -> None:
    """The DSL union removes the shared face, so this is the easy half."""
    answer = _ok(material({
        "source": SEAM,
        "from_mm": [PROBE_X, PROBE_Y, RAY_Z],
        "direction_mm": [0, 0, -1],
    }))
    assert answer["count"] == 1
    assert answer["segments"][0]["thickness_mm"] == pytest.approx(4.0, abs=1.0e-6)
    seam_point = _ok(material({"source": SEAM, "at_mm": [PROBE_X, PROBE_Y, 2.0]}))
    assert seam_point["inside"] is True


def _stacked_compound():
    """Two 2 mm boxes as SEPARATE solids sharing their face at z = 2.

    The DSL cannot express this — `+` fuses — so the compound is built in OCCT
    directly. It is the shape a parity count gets wrong: the ray meets a face
    at z = 2 TWICE (the underside of the upper solid and the top of the lower
    one), flips twice, and calls 4 mm of material air.
    """
    from OCP.BRep import BRep_Builder
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.TopoDS import TopoDS_Compound
    from OCP.gp import gp_Pnt

    lower = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), BOX_X, BOX_Y, 2.0).Shape()
    upper = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 2.0), BOX_X, BOX_Y, 2.0).Shape()
    builder = BRep_Builder()
    compound = TopoDS_Compound()
    builder.MakeCompound(compound)
    builder.Add(compound, lower)
    builder.Add(compound, upper)
    return compound


def test_a_coincident_face_seam_between_two_bodies_is_not_a_gap() -> None:
    """The doubled face is ONE crossing and the material either side is solid.

    Two bodies stay two runs — they are two solids, and a reader sizing a wall
    has to know that — but they are marked contiguous and their thicknesses are
    already summed, so the answer to "how much material is on this ray" is the
    4 mm that is there.
    """
    occt = mat._occt()
    compound = _stacked_compound()
    bodies = mat._bodies(occt, compound)
    assert len(bodies) == 2

    answer = mat._walk(occt, compound, bodies, (PROBE_X, PROBE_Y, RAY_Z),
                       (0.0, 0.0, -1.0), 100.0)
    # Three places, not four: the two coincident faces at z = 2 are one.
    assert answer["surface_crossings"] == 3
    assert answer["count"] == 2
    assert answer["total_thickness_mm"] == pytest.approx(4.0, abs=1.0e-6)
    assert [seg["thickness_mm"] for seg in answer["segments"]] == pytest.approx(
        [2.0, 2.0], abs=1.0e-6)
    assert answer["segments"][0]["contiguous_with_previous"] is False
    assert answer["segments"][1]["contiguous_with_previous"] is True
    assert answer["segments"][0]["body_index"] != answer["segments"][1]["body_index"]

    # And the seam plane itself is material, in one of the two bodies.
    state, body = mat._classify(occt, bodies,
                                occt["gp_Pnt"](PROBE_X, PROBE_Y, 2.0),
                                mat.CLASSIFY_TOLERANCE_MM)
    assert (state, body) != ("outside", -1)


def test_the_direction_need_not_be_a_unit_vector() -> None:
    """Thicknesses are distances, so a long direction must not scale them."""
    answer = _ok(material({
        "source": TRAY,
        "from_mm": [PROBE_X, PROBE_Y, RAY_Z],
        "direction_mm": [0, 0, -10],
    }))
    assert [s["thickness_mm"] for s in answer["segments"]] == pytest.approx(
        [WALL, WALL], abs=1.0e-6)


def test_the_probe_reuses_the_shape_the_last_evaluation_built() -> None:
    """The same answer whether the B-Rep was cached or translated again.

    The worker keeps the last evaluation's shape against the source digest, and
    a probe of the document on screen takes it instead of re-running every
    boolean. A cache handing back the WRONG shape is the failure that matters,
    so the two paths are compared on the same source.
    """
    methods.reset_caches()
    fresh = _ray(TRAY)
    assert methods.cached_shape(TRAY) is None

    evaluated = methods.handle_request(
        {"id": 1, "method": "evaluate", "params": {"source": TRAY}})
    assert evaluated["ok"], evaluated.get("error")
    assert methods.cached_shape(TRAY) is not None

    reused = _ray(TRAY)
    assert [s["thickness_mm"] for s in reused["segments"]] == pytest.approx(
        [s["thickness_mm"] for s in fresh["segments"]], abs=1.0e-9)
    # An edited buffer must never be answered from the shape before the edit.
    assert methods.cached_shape(FLOORLESS) is None
    assert _ray(FLOORLESS)["count"] == 1


# --- what it refuses --------------------------------------------------------


@pytest.mark.parametrize("params, phrase", [
    ({}, "at_mm"),
    ({"at_mm": [0, 0, 0], "from_mm": [0, 0, 1]}, "not both"),
    ({"from_mm": [0, 0, 1]}, "direction_mm"),
    ({"from_mm": [0, 0, 1], "direction_mm": [0, 0, 0]}, "no length"),
    ({"at_mm": [0, 0]}, "three numbers"),
])
def test_a_probe_that_cannot_be_answered_says_what_to_send(params: dict,
                                                           phrase: str) -> None:
    reply = material(dict(params, source=TRAY))
    assert reply["ok"] is False
    assert phrase in reply["error"]["message"]


def test_a_document_with_no_solid_is_refused_rather_than_called_empty() -> None:
    reply = material({"source": "x = 1\n", "at_mm": [0, 0, 0]})
    assert reply["ok"] is False
    assert "no 3D part" in reply["error"]["message"] \
        or "no closed solid" in reply["error"]["message"]


# --- the classifier's own soundness -----------------------------------------


def _reversed_box():
    """A 10 mm box with every face normal pointing inward.

    BRepClass3d_SolidClassifier reads the face orientations, so on this shape
    it reports [5, 5, 5] as OUTSIDE and [50, 50, 50] as INSIDE — the answer
    inverted, with nothing in the numbers to say so.
    """
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.gp import gp_Pnt

    return BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10.0, 10.0, 10.0).Shape().Reversed()


def _open_shell_solid():
    """A solid made from five of the box's six faces: it bounds no volume.

    The classifier reports IN for points far outside it, so "is there material
    at [50, 50, 50]" answers yes on a shape that has no inside.
    """
    from OCP.BRep import BRep_Builder
    from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeSolid
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.TopAbs import TopAbs_FACE
    from OCP.TopExp import TopExp_Explorer
    from OCP.TopoDS import TopoDS_Shell
    from OCP.gp import gp_Pnt

    box = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10.0, 10.0, 10.0).Shape()
    builder = BRep_Builder()
    shell = TopoDS_Shell()
    builder.MakeShell(shell)
    kept = 0
    explorer = TopExp_Explorer(box, TopAbs_FACE)
    while explorer.More():
        if kept < 5:
            builder.Add(shell, explorer.Current())
        kept += 1
        explorer.Next()
    return BRepBuilderAPI_MakeSolid(shell).Solid()


@pytest.mark.parametrize("shape_of, orientation_ok, closed", [
    (_reversed_box, False, True),
    (_open_shell_solid, True, False),
])
def test_a_body_the_classifier_cannot_be_trusted_on_answers_null(
        shape_of, orientation_ok: bool, closed: bool) -> None:
    """inside is None with a reason, never the inverted True/False.

    THE ORACLE. Without the guard the reversed box answers inside=False at
    [5, 5, 5] (a point 5 mm deep in solid material) and inside=True at
    [50, 50, 50] (a point 40 mm outside it), and the open shell answers
    inside=True at [50, 50, 50]. Each of those is a confident wrong answer to
    the one question this verb exists to answer, so the verdict is withheld
    and the flags say which fault withheld it.
    """
    occt = mat._occt()
    shape = shape_of()
    bodies = mat._bodies(occt, shape)
    assert len(bodies) == 1
    assert bodies[0]["orientation_ok"] is orientation_ok
    assert bodies[0]["closed"] is closed

    for at in [(5.0, 5.0, 5.0), (50.0, 50.0, 50.0)]:
        answer = mat._point_answer(occt, shape, bodies, at,
                                   mat.CLASSIFY_TOLERANCE_MM)
        assert answer["inside"] is None
        assert answer["state"] == "unknown"
        assert answer["reason"]


def test_a_sound_box_reports_both_flags_true_and_still_answers() -> None:
    """The control: the guard must not withhold anything on a good solid."""
    from OCP.BRepPrimAPI import BRepPrimAPI_MakeBox
    from OCP.gp import gp_Pnt

    occt = mat._occt()
    box = BRepPrimAPI_MakeBox(gp_Pnt(0, 0, 0), 10.0, 10.0, 10.0).Shape()
    bodies = mat._bodies(occt, box)
    assert (bodies[0]["orientation_ok"], bodies[0]["closed"]) == (True, True)
    assert mat._point_answer(occt, box, bodies, (5.0, 5.0, 5.0),
                             mat.CLASSIFY_TOLERANCE_MM)["inside"] is True
    assert mat._point_answer(occt, box, bodies, (50.0, 50.0, 50.0),
                             mat.CLASSIFY_TOLERANCE_MM)["inside"] is False


def test_a_thin_wall_survives_a_coarse_tolerance() -> None:
    """A 0.3 mm wall asked with tolerance_mm=1.0 is still 0.3 mm of material.

    THE ORACLE. tolerance_mm is the band in which a point counts as ON a face.
    Applied to the walk's interval midpoints it swallows the interval: the
    midpoint of a 0.3 mm wall is 0.15 mm from both faces, classifies ON at a
    tolerance of 1.0, the run is dropped, and the reply reads count 0,
    total_thickness_mm 0 — a missing wall, reported by the verb that exists to
    find missing walls. The walk classifies at CLASSIFY_TOLERANCE_MM instead,
    and the caller's tolerance governs the point form alone.
    """
    answer = _ok(material({
        "source": "wall = cube(10, 10, 0.3)",
        "from_mm": [5.0, 5.0, -5.0],
        "direction_mm": [0, 0, 1],
        "tolerance_mm": 1.0,
    }))
    assert answer["count"] == 1
    assert answer["total_thickness_mm"] == pytest.approx(0.3, abs=1.0e-6)
