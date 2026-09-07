"""Is there material here — at this point, and along this ray?

WHAT THIS ANSWERS
Every other check measures the solid AGAINST something: interference against a
reference, clearance against a reference, a fastener against a hole. Air
violates none of them. A tray whose floor was subtracted away passed all three
on rev 4 and three floorless STLs were exported, because nothing in the check
family ever asks "is the solid actually HERE".

This does, in the two forms a person asks it in:

  at_mm=[x, y, z]          am I inside the material, and how far is the
                           nearest surface?
  from_mm + direction_mm   walking this ray, where does material start and
                           stop, and how thick is each run?

WHY THE KERNEL AND NOT A MESH
The evaluated solid is an OCCT B-Rep in this worker, and OCCT answers point
containment EXACTLY: BRepClass3d_SolidClassifier walks the faces of the solid
and returns IN, OUT or ON with no tessellation and no rays at all. Two lazier
answers are available and both are wrong in exactly the case that mattered:

  * a bounding box contains the missing floor as happily as the present one —
    the box of the tray is the same either way, so the floorless export passes;
  * a tessellation-parity count (crossings of a triangle mesh, odd = inside) is
    fooled by a COINCIDENT-FACE SEAM, where a union leaves two faces in the
    same plane: the ray meets both, the parity flips twice, and material reads
    as air. This module never counts parity — see the ray walk below.

HOW THE RAY WALK WORKS, AND WHY IT SURVIVES THAT SEAM
BRepIntCurveSurface_Inter gives the parameters along the line where it meets
the solid's faces. Those parameters are treated as CANDIDATE BOUNDARIES and
nothing more: hits closer together than HIT_MERGE_MM are one place, and each
interval between consecutive places is decided by classifying its MIDPOINT with
the same solid classifier. So a doubled hit at a coincident seam produces a
zero-length interval that changes no verdict, and a tangential graze that
touches without entering is an interval whose midpoint is outside. The parity
of the hit count is never consulted, so it can never lie.

WHAT THE MERGE CAN HIDE, AND HOW THAT IS SAID. A seam's two hits are the same
parameter to the last bit. Two hits that are NOT the same parameter but still
closer than HIT_MERGE_MM are a different thing: a wall thinner than the merge
width, whose entry and exit collapse into one place and whose material is then
never asked about. Such a merge is recorded as an UNCERTAIN BOUNDARY — the
reply lists them and marks segments_certified false — and the raw hits travel
beside the merged ones so a reader can see what was collapsed.

AN UNSOUND BODY WITHHOLDS THE WALK. A reversed or open body inverts the
classifier, so a ray that meets one has no segments: they, the total and
started_inside are null with the reason, and only the raw face hits are
reported. A ray that meets no face of an unsound body is walked against the
sound bodies alone and says which bodies it left out.

EVERY LENGTH IS A MILLIMETRE, in the solid's own frame — which is also the
panel's world frame, because the evaluated solid is never posed.
"""

from __future__ import annotations

import math
from typing import Optional

from .features import FeatureError, shape_for

#: Tolerance handed to the solid classifier, millimetres. A point this close to
#: a face is ON it rather than in or out; the classifier's own default is
#: coarser than a print tolerance, so it is stated here instead.
CLASSIFY_TOLERANCE_MM = 1.0e-7

#: Two ray hits closer together than this along the ray are ONE crossing. This
#: is what a coincident-face seam produces, and the merge is why it cannot
#: split a slab in two or erase one.
HIT_MERGE_MM = 1.0e-6

#: Two hits closer than this are the same parameter by arithmetic, not by
#: geometry: a seam's doubled hit. Anything wider that still merges is a wall
#: too thin for the merge, and is reported as uncertain rather than dropped.
HIT_NOISE_MM = 1.0e-12

#: How far along the ray the walk looks when the caller does not say.
DEFAULT_MAX_DISTANCE_MM = 10000.0

#: How far past the last hit the walk probes to see whether material runs off
#: to infinity — which a closed solid cannot do, so it is reported rather than
#: silently truncated.
TAIL_PROBE_MM = 1.0e-3


class MaterialError(Exception):
    """A material request that cannot be answered, with a reason for the user."""


def _occt() -> dict:
    """Import the OCCT surface this module needs, or raise with a reason.

    Imported at call time exactly like features' and clearance's own imports: a
    worker that never probes material never pays for it, and a broken bundle
    says what is broken instead of raising a bare ImportError three frames down.
    """
    try:
        from OCP.BRep import BRep_Builder
        from OCP.BRepBuilderAPI import BRepBuilderAPI_MakeVertex
        from OCP.BRepCheck import BRepCheck_NoError, BRepCheck_Shell
        from OCP.BRepClass3d import BRepClass3d_SolidClassifier
        from OCP.BRepExtrema import BRepExtrema_DistShapeShape
        from OCP.BRepIntCurveSurface import BRepIntCurveSurface_Inter
        from OCP.TopAbs import (TopAbs_FACE, TopAbs_IN, TopAbs_ON, TopAbs_OUT,
                                TopAbs_SHELL, TopAbs_SOLID)
        from OCP.TopExp import TopExp_Explorer
        from OCP.TopoDS import TopoDS, TopoDS_Compound
        from OCP.gp import gp_Dir, gp_Lin, gp_Pnt
    except BaseException as exc:  # noqa: BLE001 — a broken .so raises anything
        raise MaterialError(
            "probing material needs the OCCT bindings (OCP), which this "
            "runtime bundle could not load: %s" % exc
        ) from exc
    return {
        "BRep_Builder": BRep_Builder,
        "BRepCheck_NoError": BRepCheck_NoError,
        "BRepCheck_Shell": BRepCheck_Shell,
        "BRepBuilderAPI_MakeVertex": BRepBuilderAPI_MakeVertex,
        "BRepClass3d_SolidClassifier": BRepClass3d_SolidClassifier,
        "BRepExtrema_DistShapeShape": BRepExtrema_DistShapeShape,
        "BRepIntCurveSurface_Inter": BRepIntCurveSurface_Inter,
        "TopAbs_FACE": TopAbs_FACE,
        "TopAbs_IN": TopAbs_IN,
        "TopAbs_ON": TopAbs_ON,
        "TopAbs_OUT": TopAbs_OUT,
        "TopAbs_SHELL": TopAbs_SHELL,
        "TopAbs_SOLID": TopAbs_SOLID,
        "TopExp_Explorer": TopExp_Explorer,
        "TopoDS": TopoDS,
        "TopoDS_Compound": TopoDS_Compound,
        "gp_Dir": gp_Dir,
        "gp_Lin": gp_Lin,
        "gp_Pnt": gp_Pnt,
    }


# ---------------------------------------------------------------------------
# The shape, its bodies and its skin
# ---------------------------------------------------------------------------


def _shape(source: str) -> tuple:
    """(shape_name, OCCT shape) for the source, translating only if it must.

    The evaluation the panel is showing already built this B-Rep, and the
    worker still holds it against the source digest, so a probe of the
    document on screen is a dictionary lookup. A part-scoped probe states a
    different source and translates, once.
    """
    from . import methods

    cached = methods.cached_shape(source)
    if cached is not None:
        return cached
    return shape_for(source)


def _bodies(occt: dict, shape) -> list:
    """Every solid of the evaluated shape as {classifier, orientation_ok, closed}.

    A document that unions a tray, a lid and four keycaps evaluates to a
    compound of loose solids, and "which body am I in" is the difference
    between a wall and a part sitting next to it. One classifier is built per
    body and kept: building one costs a face walk, and a ray of forty hits
    would otherwise pay for that walk forty times over.

    THE CLASSIFIER ANSWERS ABOUT THE SOLID IT IS GIVEN, NOT ABOUT MATERIAL.
    Its verdict is the face orientations' verdict, so two flaws invert it in
    silence and are measured here rather than trusted:

      * a REVERSED solid has every face normal pointing inward, and the
        classifier then reports the outside as IN and the inside as OUT —
        measured with OCP: a reversed 10 mm box says [5, 5, 5] is outside and
        [50, 50, 50] is inside. PerformInfinitePoint is the test: a point at
        infinity is OUT of any sound solid, and IN of a reversed one.
      * an OPEN SHELL bounds no volume, and the classifier reports IN for
        points far outside it — the same box missing one face says [50, 50,
        50] is inside. BRepCheck_Shell reports the shell unclosed.

    Both are exactly the answer this verb exists to catch being wrong about,
    so an unsound body is reported and its verdict withheld.
    """
    out: list = []
    explorer = occt["TopExp_Explorer"](shape, occt["TopAbs_SOLID"])
    while explorer.More():
        solid = occt["TopoDS"].Solid_s(explorer.Current())
        classifier = occt["BRepClass3d_SolidClassifier"](solid)
        classifier.PerformInfinitePoint(CLASSIFY_TOLERANCE_MM)
        out.append({
            "solid": solid,
            "classifier": classifier,
            "orientation_ok": classifier.State() == occt["TopAbs_OUT"],
            "closed": _shells_closed(occt, solid),
        })
        explorer.Next()
    for body in out:
        body["sound"] = body["orientation_ok"] and body["closed"]
    return out


def _shells_closed(occt: dict, solid) -> bool:
    """Is every shell of this solid closed? An open one bounds no volume."""
    explorer = occt["TopExp_Explorer"](solid, occt["TopAbs_SHELL"])
    shells = 0
    while explorer.More():
        shells += 1
        shell = occt["TopoDS"].Shell_s(explorer.Current())
        if occt["BRepCheck_Shell"](shell).Closed() != occt["BRepCheck_NoError"]:
            return False
        explorer.Next()
    return shells > 0


def _unsound(bodies: list) -> list:
    """The indices of the bodies whose containment verdict cannot be trusted."""
    return [index for index, body in enumerate(bodies) if not body["sound"]]


def _unsound_reason(bodies: list, unsound: list) -> str:
    """Why those bodies are unsound, named one by one."""
    parts = []
    for index in unsound:
        body = bodies[index]
        faults = []
        if not body["orientation_ok"]:
            faults.append("its faces are oriented inward (a point at infinity "
                          "classifies as inside it)")
        if not body["closed"]:
            faults.append("its shell is not closed, so it bounds no volume")
        parts.append("body %d: %s" % (index, " and ".join(faults)))
    return ("containment cannot be decided on this shape — "
            + "; ".join(parts)
            + ". BRepClass3d_SolidClassifier answers from the face "
            "orientations, so on such a body it reports the outside as inside; "
            "no inside/outside verdict is given rather than an inverted one")


def _skin(occt: dict, shape):
    """A compound of every FACE of the shape — the surface, not the volume.

    BRepExtrema_DistShapeShape against a SOLID answers 0 for any point inside
    it (measured: a point 1 mm under the top face of a box reports 0.0), which
    is the wrong answer to "how far is the nearest surface" for exactly the
    points this verb exists to describe. Against the faces alone it reports the
    1.0 that is there, inside and outside alike.
    """
    builder = occt["BRep_Builder"]()
    compound = occt["TopoDS_Compound"]()
    builder.MakeCompound(compound)
    faces = 0
    explorer = occt["TopExp_Explorer"](shape, occt["TopAbs_FACE"])
    while explorer.More():
        builder.Add(compound, explorer.Current())
        faces += 1
        explorer.Next()
    if faces == 0:
        raise MaterialError("the evaluated part has no faces to measure against")
    return compound


def _classify(occt: dict, bodies: list, point, tolerance: float) -> tuple:
    """(state, body_index) for one point. state is "inside", "on" or "outside".

    A point ON a face is reported as such and is NOT counted as inside: a
    surface is where material stops, and calling the boundary material would
    make a zero-thickness floor read as a floor.

    Only the SOUND bodies answer. An unsound one reports the outside as inside,
    and a single such body would otherwise make every point on every ray read
    as material; the callers decide what its absence from the verdict means.
    """
    on_index = -1
    for index, body in enumerate(bodies):
        if not body["sound"]:
            continue
        classifier = body["classifier"]
        classifier.Perform(point, tolerance)
        state = classifier.State()
        if state == occt["TopAbs_IN"]:
            return "inside", index
        if state == occt["TopAbs_ON"] and on_index < 0:
            on_index = index
    if on_index >= 0:
        return "on", on_index
    return "outside", -1


# ---------------------------------------------------------------------------
# The two questions
# ---------------------------------------------------------------------------


def _point_answer(occt: dict, shape, bodies: list, at: tuple,
                  tolerance: float) -> dict:
    """Is the material here, and where is the nearest surface to here.

    `inside` is None — never False — when the bodies cannot be classified. A
    False there would read as "this point is air", which is the exact answer
    an inward-oriented or open body gives wrongly.
    """
    point = occt["gp_Pnt"](*at)
    unsound = _unsound(bodies)
    if unsound:
        state, body_index = "unknown", -1
    else:
        state, body_index = _classify(occt, bodies, point, tolerance)

    vertex = occt["BRepBuilderAPI_MakeVertex"](point).Vertex()
    distance = occt["BRepExtrema_DistShapeShape"](vertex, _skin(occt, shape))
    distance.Perform()
    if not distance.IsDone() or distance.NbSolution() < 1:
        raise MaterialError(
            "the distance from the probe point to the solid's surface could "
            "not be computed"
        )
    nearest = distance.PointOnShape2(1)
    out = {
        "mode": "point",
        "at_mm": list(at),
        "inside": None if unsound else state == "inside",
        "state": state,
        "body_index": body_index,
        "nearest_surface_mm": float(distance.Value()),
        "nearest_point_mm": [nearest.X(), nearest.Y(), nearest.Z()],
    }
    if unsound:
        out["reason"] = _unsound_reason(bodies, unsound)
    return out


def _raw_hits(occt: dict, shape, origin: tuple, direction: tuple,
              max_distance: float) -> list:
    """Every parameter along the ray where it meets a face of `shape`, sorted.

    The line is infinite in both directions, so hits behind the origin are
    dropped here rather than confusing the walk.
    """
    line = occt["gp_Lin"](occt["gp_Pnt"](*origin), occt["gp_Dir"](*direction))
    walker = occt["BRepIntCurveSurface_Inter"]()
    walker.Init(shape, line, CLASSIFY_TOLERANCE_MM)
    raw: list = []
    while walker.More():
        w = float(walker.W())
        if -HIT_MERGE_MM <= w <= max_distance:
            raw.append(max(w, 0.0))
        walker.Next()
    raw.sort()
    return raw


def _hits(raw: list) -> tuple:
    """(merged, uncertain): the raw hits with runs closer than HIT_MERGE_MM
    collapsed to one place, and the places where that collapse swallowed a
    hit at a DIFFERENT parameter — a wall thinner than the merge width, whose
    material the walk can no longer ask about.
    """
    merged: list = []
    uncertain: list = []
    for w in raw:
        if merged and w - merged[-1] <= HIT_MERGE_MM:
            if w - merged[-1] > HIT_NOISE_MM and merged[-1] not in uncertain:
                uncertain.append(merged[-1])
            continue
        merged.append(w)
    return merged, uncertain


def _touched(occt: dict, bodies: list, indices: list, origin: tuple,
             direction: tuple, max_distance: float) -> list:
    """Which of the bodies at `indices` the ray meets a face of."""
    return [index for index in indices
            if _raw_hits(occt, bodies[index]["solid"], origin, direction,
                         max_distance)]


def _walk(occt: dict, shape, bodies: list, origin: tuple, direction: tuple,
          max_distance: float) -> dict:
    """Every run of material along the ray, as entry/exit pairs with thickness.

    The hits are candidate boundaries; the midpoint of each interval between
    them decides whether that interval is material. Adjacent material intervals
    are then merged, so a body split into two faces at a seam reports the ONE
    slab it is rather than two touching ones.

    THE MIDPOINTS ARE CLASSIFIED AT CLASSIFY_TOLERANCE_MM, NOT THE CALLER'S.
    The caller's tolerance_mm says how close to a face counts as ON it, which
    is a question about the point form. Applied here it swallows the interval
    itself: the midpoint of a 0.3 mm wall is 0.15 mm from both faces, so a
    tolerance of 1.0 classifies it ON, the run is dropped, and the reply says
    thickness 0 with no flag — the wall reported as air by the verb that
    exists to find missing material.
    """
    def at(w: float) -> tuple:
        return (origin[0] + direction[0] * w,
                origin[1] + direction[1] * w,
                origin[2] + direction[2] * w)

    raw = _raw_hits(occt, shape, origin, direction, max_distance)
    hits, uncertain = _hits(raw)
    payload = {
        "mode": "ray",
        "from_mm": list(origin),
        "direction_mm": list(direction),
        "max_distance_mm": max_distance,
        "surface_crossings": len(hits),
        # Every face the ray met, before the merge: what the walk was given.
        "raw_hits": [{"at_mm": w, "point_mm": list(at(w))} for w in raw],
    }

    # A ray that meets an unsound body has no walk: the classifier it would
    # be decided by is inverted there, and the sound bodies alone cannot say
    # what lies between the hits it left.
    unsound = _unsound(bodies)
    touched = _touched(occt, bodies, unsound, origin, direction, max_distance)
    if touched:
        payload.update({
            "count": None,
            "segments": None,
            "total_thickness_mm": None,
            "started_inside": None,
            "unbounded": None,
            "segments_certified": False,
            "reason": ("this ray meets %s, so no segment is certified: "
                       % ", ".join("body %d" % index for index in touched))
                      + _unsound_reason(bodies, touched),
        })
        return payload

    cuts = [0.0] + [w for w in hits if w > 0.0] + [max_distance]
    runs: list = []
    for index in range(len(cuts) - 1):
        low, high = cuts[index], cuts[index + 1]
        if high - low <= 0.0:
            continue
        state, body = _classify(
            occt, bodies, occt["gp_Pnt"](*at((low + high) * 0.5)),
            CLASSIFY_TOLERANCE_MM)
        if state != "inside":
            continue
        if runs and abs(runs[-1]["exit"] - low) <= HIT_MERGE_MM \
                and runs[-1]["body_index"] == body:
            runs[-1]["exit"] = high
            continue
        runs.append({"entry": low, "exit": high, "body_index": body})

    # Material that reaches the end of the walk has not been shown to end: a
    # closed solid cannot do that, so it means the ray ran out of budget.
    unbounded = bool(runs) and runs[-1]["exit"] >= max_distance - TAIL_PROBE_MM

    segments = []
    for run in runs:
        # Two bodies stacked on a shared face are two runs with no air between
        # them. They stay two — they are two solids and a reader sizing a wall
        # needs to know that — but the flag says they are one slab of material,
        # and total_thickness_mm has already added them together.
        contiguous = bool(segments) \
            and abs(segments[-1]["exit_mm"] - run["entry"]) <= HIT_MERGE_MM
        segments.append({
            "contiguous_with_previous": contiguous,
            "entry_mm": run["entry"],
            "exit_mm": run["exit"],
            "thickness_mm": run["exit"] - run["entry"],
            "entry_point_mm": list(at(run["entry"])),
            "exit_point_mm": list(at(run["exit"])),
            "body_index": run["body_index"],
        })
    started_inside = bool(segments) and segments[0]["entry_mm"] <= 0.0
    payload.update({
        "count": len(segments),
        "segments": segments,
        "total_thickness_mm": sum(s["thickness_mm"] for s in segments),
        "started_inside": started_inside,
        "unbounded": unbounded,
        "uncertain_boundaries": {
            "count": len(uncertain),
            "parameters_mm": list(uncertain),
            "points_mm": [list(at(w)) for w in uncertain],
        },
        "segments_certified": not uncertain,
    })
    if uncertain:
        payload["reason"] = (
            "%d boundar%s merged face hits that were distinct but closer than "
            "%g mm: material thinner than that may lie there and is not in "
            "the segments — see uncertain_boundaries and raw_hits"
            % (len(uncertain), "y" if len(uncertain) == 1 else "ies",
               HIT_MERGE_MM))
    if unsound:
        payload["note"] = ("%s unsound and left out of this walk; the ray "
                           "meets no face of %s"
                           % (", ".join("body %d is" % i for i in unsound),
                              "it" if len(unsound) == 1 else "them"))
    return payload


# ---------------------------------------------------------------------------
# Parameters and the reply
# ---------------------------------------------------------------------------


def _triple(raw, name: str) -> Optional[tuple]:
    """A [x, y, z] parameter as floats, or None when it was not supplied."""
    if raw is None:
        return None
    if not isinstance(raw, (list, tuple)) or len(raw) != 3:
        raise MaterialError("%s must be three numbers [x, y, z] in millimetres" % name)
    try:
        return (float(raw[0]), float(raw[1]), float(raw[2]))
    except (TypeError, ValueError) as exc:
        raise MaterialError("%s must be three numbers: %s" % (name, exc)) from exc


def _unit(direction: tuple) -> tuple:
    length = math.sqrt(sum(c * c for c in direction))
    if length <= 0.0:
        raise MaterialError(
            "direction_mm has no length; give the way the ray points, e.g. "
            "[0, 0, -1] for straight down"
        )
    return tuple(c / length for c in direction)


def material(params: dict) -> dict:
    """Answer a material probe. Returns {ok, result|error}.

    params:
      source          .mcad DSL text (required).
      at_mm           [x, y, z] — the point form.
      from_mm         [x, y, z] with direction_mm — the ray form.
      direction_mm    [dx, dy, dz], normalised here; need not be a unit vector.
      max_distance_mm how far along the ray to walk. Default 10000.
      tolerance_mm    how close to a face counts as ON it, for the POINT
                      form. The ray walk classifies its interval midpoints at
                      CLASSIFY_TOLERANCE_MM whatever this says, or a coarse
                      tolerance would erase the thin wall it is measuring.

    Exactly one of at_mm and from_mm is expected; both together is a request
    with two answers and is refused rather than half-answered.
    """
    source = params.get("source")
    if not isinstance(source, str) or not source.strip():
        return _error("material requires params.source: the .mcad DSL text")

    try:
        at = _triple(params.get("at_mm"), "at_mm")
        origin = _triple(params.get("from_mm"), "from_mm")
        direction_raw = _triple(params.get("direction_mm"), "direction_mm")
        if at is None and origin is None:
            raise MaterialError(
                "material needs either at_mm=[x, y, z] (is the solid here?) or "
                "from_mm + direction_mm (where does it start and stop along "
                "this ray?)"
            )
        if at is not None and origin is not None:
            raise MaterialError(
                "material takes at_mm OR from_mm, not both: they are two "
                "different questions and one reply cannot be about both"
            )
        if origin is not None and direction_raw is None:
            raise MaterialError("the ray form needs direction_mm beside from_mm")
        try:
            max_distance = float(params.get("max_distance_mm",
                                            DEFAULT_MAX_DISTANCE_MM))
            tolerance = float(params.get("tolerance_mm", CLASSIFY_TOLERANCE_MM))
        except (TypeError, ValueError) as exc:
            raise MaterialError("material received a non-numeric parameter: %s"
                                % exc) from exc
        if max_distance <= 0.0:
            raise MaterialError("max_distance_mm must be greater than zero")
        if tolerance <= 0.0:
            raise MaterialError("tolerance_mm must be greater than zero")

        occt = _occt()
        shape_name, wrapped = _shape(source)
        bodies = _bodies(occt, wrapped)
        if not bodies:
            raise MaterialError(
                "the document evaluated to no closed solid, so there is no "
                "material to be inside of; a surface or a wire has no volume"
            )
        if at is not None:
            payload = _point_answer(occt, wrapped, bodies, at, tolerance)
        else:
            payload = _walk(occt, wrapped, bodies, origin, _unit(direction_raw),
                            max_distance)
    except (MaterialError, FeatureError) as exc:
        return _error(str(exc))

    payload["units"] = "mm"
    payload["shape_name"] = shape_name
    payload["body_count"] = len(bodies)
    # What each body's containment verdict is worth. A reader that only sees
    # `inside` cannot tell a sound answer from an inverted one; these two
    # flags are the evidence behind every verdict in this reply.
    payload["bodies"] = [{"index": index,
                          "orientation_ok": bool(body["orientation_ok"]),
                          "closed": bool(body["closed"])}
                         for index, body in enumerate(bodies)]
    unsound = _unsound(bodies)
    if unsound:
        payload["unsound_bodies"] = unsound
        if payload["mode"] == "point":
            payload.setdefault("reason", _unsound_reason(bodies, unsound))
    # The body a run or a point is IN, named. It is deliberately not called
    # `part`: the panel's verb layer calls the binding it probed `part` (which
    # shape the question was about), and this says which solid of it the answer
    # landed in — "" for a probe that landed in air. A compound's solids have
    # no names of their own, so they are numbered under the binding's.
    if payload["mode"] == "point":
        payload["body"] = _body_name(shape_name, int(payload["body_index"]),
                                     len(bodies))
    else:
        for segment in payload["segments"] or []:
            segment["body"] = _body_name(shape_name,
                                         int(segment["body_index"]),
                                         len(bodies))
    payload["bound"] = (
        "containment is BRepClass3d_SolidClassifier on the B-Rep itself — no "
        "tessellation, no rays, no bounding box; the ray's boundaries are "
        "face intersections and every interval between them is decided by "
        "classifying its midpoint, so a coincident-face seam cannot flip a "
        "parity that is never counted; two bodies sharing a face are two "
        "segments with contiguous_with_previous set and their thicknesses "
        "already summed into total_thickness_mm; segments_certified is false "
        "when a merge swallowed distinct hits (uncertain_boundaries) or the "
        "ray met an unsound body, and raw_hits are the face hits before any "
        "merge"
    )
    return {"ok": True, "result": payload}


def _body_name(shape_name: str, body_index: int, body_count: int) -> str:
    """What to call the body a probe landed IN. "" for a probe in air."""
    if body_index < 0:
        return ""
    if body_count == 1:
        return shape_name
    return "%s[%d]" % (shape_name, body_index)


def _error(message: str) -> dict:
    return {"ok": False, "error": {"kind": "internal", "message": message}}
