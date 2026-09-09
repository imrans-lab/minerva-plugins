"""Exact minimum distance between the evaluated solid and reference meshes.

WHAT THIS ANSWERS
"Is there 1.0 mm of air around every part?" — with numbers, not pixels. For
each reference node the caller names, the reply carries the minimum distance
to the solid and the pair of points that realises it, so an LLM iterating on
the DSL can move the wall by the amount it is short rather than by a guess.

WHY IT IS EXACT
The distance between two triangle meshes is the minimum over triangle pairs.
FCL's swept-sphere BVH (Larsen/Gottschalk/Lin/Manocha RSS trees, as shipped in
python-fcl) prunes that minimum down to a handful of pairs and evaluates those
exactly, so the answer carries no sampling error at all: the only error is the
coordinates' own float precision, ~1e-5 mm at hundred-millimetre scale. A
sampled scheme cannot make that promise — meeting a hundredth of a millimetre
by covering a shell with sample points needs millions of them.

THE ERROR BAR THAT DOES EXIST
The DSL solid is an OCCT B-Rep and the query sees only its TESSELLATION: a
curved face becomes chords that lie inside the true surface by up to the
tessellation deviation. So this module tessellates the solid ITSELF, at a
tolerance the caller states and the reply echoes, rather than measuring
whatever mesh the display happened to be showing. Every reply carries
``tessellation_tolerance_mm`` and the bound it implies. A clearance number
without its tolerance is not a measurement, and this module never emits one.

WHY THE REFERENCES ARRIVE AS A FILE
The worker never opens a mesh file: the panel owns glTF parsing, unit
conversion and posing, and hands over triangles already in world millimetres.
The panel→plugin IPC channel caps a payload at 64 KiB, which a 130k-triangle
board exceeds by two orders of magnitude, so the arrays travel as a small
binary blob the panel writes and this module reads back with numpy. The blob
is addressed by the SHA-256 of its array bytes, which is also the cache key:
a reference set that has not changed is uploaded once and named by hash on
every evaluation afterwards.

The blob layout, little-endian, written by geometry_checks.gd:

    magic    8 bytes   b"MCADMESH"
    version  uint32    1
    vertices uint32    V
    triangles uint32   F
    verts    float32[3V]  world millimetres
    indices  uint32[3F]

NO FALLBACK. If python-fcl cannot be imported the verb fails loudly, naming
the diagnosis. A sampled substitute would answer the same question with a
different, weaker guarantee under the same name — the one failure mode a
clearance check must not have.
"""

from __future__ import annotations

import hashlib
import math
import struct
from collections import OrderedDict
from typing import Any, Optional

#: Blob header. The magic exists so a truncated or foreign file is refused
#: with a name rather than parsed into nonsense triangles.
BLOB_MAGIC = b"MCADMESH"
BLOB_VERSION = 1
_HEADER = struct.Struct("<8sIII")

#: Reference BVH trees kept between calls. A board's tree costs ~0.5 s to
#: build and does not change while the document is edited, so the cache is
#: what makes the warm path milliseconds. Bounded: a document that re-poses
#: its references repeatedly must not grow the worker without limit.
#:
#: THE BOUND HAS TO HOLD A WHOLE ASSEMBLY. One entry is one reference NODE,
#: not one reference file, and a populated board is one node per component:
#: at 16 the cache could not hold a single real board, so every call after
#: the first evicted part of the set it was about to be asked for again. A
#: node's tree is a few hundred triangles, so a few hundred of them is tens
#: of megabytes at worst — the size of the board mesh the panel already
#: holds — while a bound below the assembly costs the warm path entirely.
MAX_CACHED_REFERENCES = 512

#: Tessellations of the solid kept between calls, keyed by (source, tolerance,
#: angular tolerance). Small, because the source changes on every keystroke.
MAX_CACHED_SOLIDS = 4

#: Tessellation deviation used when the caller states none. Ten microns is far
#: below the tolerances an enclosure is designed to and still tessellates a
#: shell in well under a second.
DEFAULT_TOLERANCE_MM = 0.01

#: Angular deflection used when nothing curved binds it, radians. OCCT applies
#: BOTH deflections and the finer one wins, so a fixed angular value silently
#: becomes the real tolerance on a small curved face: a cylinder of radius 2
#: tessellated at 0.1 rad has a chord error of 2*(1-cos(0.05)) = 0.0025 mm
#: whatever linear tolerance was asked for, and 0.05 and 0.005 produce the
#: SAME mesh. The linear number would then be a promise the mesh does not
#: keep, which is the one thing this module may not do.
DEFAULT_ANGULAR_RAD = 0.1

#: The finest angular deflection this module will ask for, radians — about a
#: fifth of a degree, 1256 segments on a full turn. A huge radius with a tight
#: tolerance would otherwise ask for a mesh nobody can hold in memory; when
#: this floor binds, the reply says the chord error is bounded by the floor's
#: own sagitta instead of by the tolerance.
MIN_ANGULAR_RAD = 0.005


class ClearanceError(Exception):
    """A clearance request that cannot be answered, with a reason for the user."""


class _LRU(OrderedDict):
    """Smallest useful LRU: `take` moves an entry to the front, `put` evicts."""

    def __init__(self, capacity: int) -> None:
        super().__init__()
        self._capacity = capacity

    def take(self, key: str) -> Optional[Any]:
        if key not in self:
            return None
        self.move_to_end(key, last=False)
        return self[key]

    def put(self, key: str, value: Any) -> None:
        self[key] = value
        self.move_to_end(key, last=False)
        while len(self) > self._capacity:
            self.popitem(last=True)


_reference_trees: _LRU = _LRU(MAX_CACHED_REFERENCES)
_solid_meshes: _LRU = _LRU(MAX_CACHED_SOLIDS)
#: Curvature reports, keyed by source. Reading the curvature TRANSLATES the
#: whole DSL — on a shell of a hundred booleans that is as expensive as the
#: tessellation beside it — and the answer is a property of the source alone,
#: so a clearance that pays for it once must not pay for it twice.
_curvatures: _LRU = _LRU(MAX_CACHED_SOLIDS)


def reset_caches() -> None:
    """Drop every cached tree and tessellation. For tests and for a reload."""
    _reference_trees.clear()
    _solid_meshes.clear()
    _curvatures.clear()


# ---------------------------------------------------------------------------
# The blob
# ---------------------------------------------------------------------------

def read_blob(path: str, key: str):
    """Read a mesh blob and return (vertices (V,3) float64, faces (F,3) int64).

    The declared `key` is checked against the SHA-256 of the array bytes that
    were actually read. The check is not ceremony: the key is what the caller
    will name this geometry by for the rest of the session, so a path that has
    been rewritten under a stale key would answer every later evaluation with
    the wrong board and never say so.
    """
    import numpy as np

    try:
        with open(path, "rb") as handle:
            raw = handle.read()
    except OSError as exc:
        raise ClearanceError(f"cannot read mesh blob '{path}': {exc}") from exc

    if len(raw) < _HEADER.size:
        raise ClearanceError(f"mesh blob '{path}' is shorter than its header")
    magic, version, vertex_count, triangle_count = _HEADER.unpack_from(raw, 0)
    if magic != BLOB_MAGIC:
        raise ClearanceError(f"'{path}' is not a mesh blob (bad magic)")
    if version != BLOB_VERSION:
        raise ClearanceError(
            f"mesh blob '{path}' is version {version}; this worker reads "
            f"version {BLOB_VERSION}"
        )

    vertex_bytes = vertex_count * 3 * 4
    index_bytes = triangle_count * 3 * 4
    expected = _HEADER.size + vertex_bytes + index_bytes
    if len(raw) != expected:
        raise ClearanceError(
            f"mesh blob '{path}' declares {vertex_count} vertices and "
            f"{triangle_count} triangles ({expected} bytes) but is {len(raw)}"
        )

    body = raw[_HEADER.size:]
    # The header is hashed WITH the body, exactly as the panel hashes it: the
    # same bytes mean different geometry under different counts (three
    # vertices and six indices decode the same buffer as four vertices and
    # three, the index words becoming coordinates), so a digest over the body
    # alone would let two different meshes share one cache entry.
    digest = hashlib.sha256(raw[:_HEADER.size] + body).hexdigest()
    if key and digest != key:
        raise ClearanceError(
            f"mesh blob '{path}' hashes to {digest[:16]}… but was sent as "
            f"{key[:16]}… — the file changed under its key"
        )

    vertices = np.frombuffer(body, dtype="<f4", count=vertex_count * 3)
    faces = np.frombuffer(
        body, dtype="<u4", count=triangle_count * 3, offset=vertex_bytes
    )
    vertices = vertices.reshape((vertex_count, 3)).astype(np.float64)
    faces = faces.reshape((triangle_count, 3)).astype(np.int64)
    if triangle_count and int(faces.max()) >= vertex_count:
        raise ClearanceError(
            f"mesh blob '{path}' indexes vertex {int(faces.max())} of "
            f"{vertex_count}"
        )
    return vertices, faces


# ---------------------------------------------------------------------------
# The trees
# ---------------------------------------------------------------------------

def _require_fcl():
    """Import python-fcl or raise with the diagnosis, never a bare ImportError.

    A compiled extension's ImportError names the module, not the thing that is
    actually missing; `_backend_diagnosis` turns "DLL load failed" into the
    name of the DLL and the fix.
    """
    try:
        import fcl  # type: ignore[import]
    except BaseException as exc:  # noqa: BLE001 — a broken .so raises anything
        from .dispatcher import _backend_diagnosis
        raise ClearanceError(
            "clearance needs the python-fcl geometry backend, which this "
            "runtime bundle could not load — " + _backend_diagnosis("fcl", exc)
        ) from exc
    return fcl


def _build_tree(vertices, faces):
    """A swept-sphere BVH over one mesh, ready for distance queries."""
    fcl = _require_fcl()
    model = fcl.BVHModel()
    model.beginModel(len(vertices), len(faces))
    model.addSubModel(vertices, faces)
    model.endModel()
    return model


def _entry_for(key: str, path: Optional[str]) -> tuple[tuple, bool]:
    """The cache entry for `key`, building it from `path` on a miss.

    The entry is (tree, triangle count, world bounds, (vertices, faces)) and
    `cached` says whether this call paid for a build. The arrays and bounds
    ride with the tree because a containment probe walks the triangles the
    BVH was built from, a built BVH exposes no bounds, and re-reading the
    blob for either would undo the point of caching. A caller holds the
    whole entry for the length of its request: the LRU may evict the key
    while later targets of the same request are built.
    """
    entry = _reference_trees.take(key)
    if entry is not None:
        return entry, True
    if not path:
        raise KeyError(key)
    vertices, faces = read_blob(path, key)
    entry = (_build_tree(vertices, faces), len(faces), _bounds_of(vertices),
             (vertices, faces))
    _reference_trees.put(key, entry)
    return entry, False


def _tree_for(key: str, path: Optional[str]) -> tuple[Any, int, bool]:
    """(tree, triangle count, cached) for `key` — see _entry_for."""
    entry, cached = _entry_for(key, path)
    return entry[0], entry[1], cached


def _bounds_of(vertices) -> Optional[tuple[list, list]]:
    """(min, max) corners of a vertex array in world mm, or None if empty."""
    if len(vertices) == 0:
        return None
    import numpy as np

    array = np.asarray(vertices, dtype=float)
    return ([float(v) for v in array.min(axis=0)],
            [float(v) for v in array.max(axis=0)])


def arrays_for(key: str):
    """The cached mesh's (vertices, faces), or None if it is not known."""
    entry = _reference_trees.get(key)
    if entry is None or len(entry) < 4:
        return None
    return entry[3]


def bounds_for(key: str) -> Optional[tuple[list, list]]:
    """The cached mesh's world bounding box, or None if it is not known.

    Reads the LRU without disturbing anything the caller has not already
    built: a key with no entry, or an entry stored before bounds were kept,
    answers None rather than reading the blob again.
    """
    entry = _reference_trees.get(key)
    if entry is None or len(entry) < 3:
        return None
    return entry[2]


# ---------------------------------------------------------------------------
# The solid
# ---------------------------------------------------------------------------

def _sagitta_mm(angle_rad: float, radius_mm: float) -> float:
    """How far a chord subtending `angle_rad` sits inside a circle of `r`."""
    if radius_mm <= 0.0 or angle_rad <= 0.0:
        return 0.0
    return radius_mm * (1.0 - math.cos(angle_rad * 0.5))


def _angular_for(tolerance_mm: float, radius_mm: float) -> float:
    """The angular deflection that holds a chord within `tolerance_mm`.

    A chord subtending theta on a circle of radius r sits r*(1 - cos(theta/2))
    inside it, so theta = 2*acos(1 - tol/r) is the largest step that keeps the
    sagitta inside the tolerance. Below MIN_ANGULAR_RAD the answer is the
    floor, and the caller is told what that costs.
    """
    if radius_mm <= 0.0:
        return DEFAULT_ANGULAR_RAD
    ratio = 1.0 - (tolerance_mm / radius_mm)
    if ratio <= -1.0:
        # A tolerance wider than the diameter: no angular limit is needed.
        return DEFAULT_ANGULAR_RAD
    angle = 2.0 * math.acos(min(1.0, ratio))
    return max(MIN_ANGULAR_RAD, angle)


def _chord_clause(angular_rad: float, effective_mm: float,
                  tolerance_mm: float) -> str:
    """The tail of the tessellation `how` when the chords sit wider than asked.

    Two things it has to get right, because a caller reads this beside the
    numbers it subtracts. The angle it names is the one actually STEPPED: the
    reply's angular_deflection_deg is degrees of that same angle, and naming
    the module's floor where the floor did not bind leaves the reader with a
    degree figure and a radian figure that are not the same angle. And the
    comparison word matches the numbers AS PRINTED: `effective_mm` is the max
    of the request and a sagitta derived from it, which on the face the angle
    was chosen for lands a float step above the request — "more than the
    0.010000 mm asked for" beside an identical 0.010000 is a contradiction,
    not a measurement.
    """
    printed_effective = "%.6f" % effective_mm
    printed_request = "%.6f" % tolerance_mm
    relation = "equal to" if printed_effective == printed_request else "more than"
    step = ("this module's finest angular step (%.6f rad)" % angular_rad
            if angular_rad <= MIN_ANGULAR_RAD
            else "an angular step of %.6f rad" % angular_rad)
    return (" and held at %s, which on that radius is %s mm of chord error — "
            "%s the %s mm asked for"
            % (step, printed_effective, relation, printed_request))


def _curvature(source: str, tolerance_mm: float, selection: str = "", configuration: str = "") -> tuple:
    """(widest binding radius or None, every curved face measured, sampled?).

    The widest, because the sagitta of a fixed angle grows with the radius:
    an angle chosen for a 2 mm bore leaves a 200 mm barrel a millimetre from
    its own surface. Hold the chord error on the widest face and every
    tighter one is inside it.

    Read by the module that already reads B-Rep surfaces: analytically off a
    cylinder, sphere, cone or torus, and by sampling the surface's own
    principal curvatures on anything else — the B-spline flanks a loft or a
    sweep produces, which have a curvature but no radius field to read. The
    tolerance goes in because a face too small for its curvature to deviate
    that far does not bind any angular step, and a near-flat spline patch
    whose sampled curvature is noise must not drag the mesh finer.

    The second value is False only when a face could not be measured at all —
    OCCT would not adapt it, or the B-Rep could not be read: the radius is
    then at best a partial answer, and no bound derived from it covers the
    faces it did not see. The third says whether any radius came from
    sampling, so the reply can name where its bound came from.
    """
    key = hashlib.sha256(
        ("%r\n%r\n%r\n" % (tolerance_mm, selection, configuration)).encode("utf-8") + source.encode("utf-8")
    ).hexdigest()
    cached = _curvatures.take(key)
    if cached is not None:
        return cached
    try:
        from .features import FeatureError, curvature_report
    except ImportError:
        return None, False, False
    try:
        report = curvature_report(source, tolerance_mm=tolerance_mm, selection=selection, configuration=configuration)
    except FeatureError:
        answer = (None, False, False)
    except BaseException:  # noqa: BLE001 — a broken OCCT raises anything
        answer = (None, False, False)
    else:
        answer = (report["largest_radius_mm"],
                  int(report["unrecognised_faces"]) == 0,
                  int(report.get("sampled_faces", 0)) > 0)
    _curvatures.put(key, answer)
    return answer


def _bbox_radius(vertices) -> float:
    """A radius from the mesh's own bounding box: half its LARGEST extent.

    The stand-in when a curved face's radius could not be read. It is a GUESS
    about curvature nobody measured — a shallow spline patch can be far
    flatter than its box is wide — so a tolerance derived from it is reported
    as unbounded rather than as a promise.
    """
    if len(vertices) == 0:
        return 0.0
    extents = vertices.max(axis=0) - vertices.min(axis=0)
    widest = float(max(float(value) for value in extents))
    return widest * 0.5


UNRECOGNISED_CURVATURE = ("a curved face OCCT would not let this reader "
                          "evaluate at all, or a B-Rep that could not be read")

#: Named in the `how` when the widest radius was sampled off the surface
#: rather than read off it, because the two are not the same kind of fact.
SAMPLED_CLAUSE = (", whose curvature was sampled across the face rather than "
                  "read off an analytic surface: a parametric grid whose "
                  "widest sample is then bisected onto the flattest point "
                  "beside it, so the radius is that point's and not the "
                  "nearest grid node's. The bisection only ever approaches "
                  "that point from below, so the radius is corrected for the "
                  "search's residual step; that correction is the width of "
                  "the search's own uncertainty rather than a proof, and "
                  "curvature inside a cell the grid steps over entirely is "
                  "still unseen — so the tolerance is NOT guaranteed on this "
                  "solid and the distances are advisory")

#: Why the bar is not a bound, per source, in the words the panel quotes.
UNBOUNDED_BECAUSE = {
    "sampled": ("spline faces in the solid whose curvature was sampled on a "
                "grid and not read: a curvature between two samples is unseen"),
    "guessed": "unrecognised curved faces in the solid",
    "stated": "an angular step the caller stated over curvature that was "
              "not read",
}


def _prepare_solid(source: str, tolerance_mm: float,
                   angular_param: Optional[float] = None, selection: str = "", configuration: str = ""):
    """Tessellate the solid so the CHORD error really is within the tolerance.

    Returns (vertices, faces, angular_rad, how, effective_mm, bounded). OCCT
    applies the linear and the angular deflection together and the finer one
    wins, so the angular one is derived from the linear one and the curvature
    it has to hold — which is what makes `tessellation_tolerance_mm` a bound
    rather than a label. A caller that states its own angular_tolerance is
    obeyed and told so.

    `effective_mm` is the tolerance the mesh ACTUALLY keeps. It is the
    requested one except where MIN_ANGULAR_RAD binds: a very wide face with a
    very tight tolerance would ask for a mesh nobody can hold, and the floor
    that prevents it also means the chords sit further out than the caller
    asked. The reply then states what it really got rather than what it was
    asked for — an error bar the mesh does not keep is worse than a coarse
    one, because a caller subtracts it and believes the result.

    `bounded` is True only when every curved face carries an ANALYTIC radius
    (or there is none): a cylinder, sphere, cone or torus, whose sagitta at
    the chosen angle is arithmetic. A face with no analytic radius — the
    B-spline flank of a loft — has its curvature SAMPLED on a grid and
    refined, which chooses a good angle but proves nothing about the cell
    the grid stepped over; the mesh is cut at that angle and the reply is
    NOT bounded, with `source` saying "sampled" so the caller can tell that
    estimate from a bounding-box guess. A face that could not be measured at
    all leaves the angle chosen from the bounding box, a guess about the
    curvature; `effective_mm` is then what that guess implies.

    The seventh value is where the bar came from: "stated", "analytic",
    "none" (nothing curved binds), "sampled" or "guessed".
    """
    measured, known, sampled = _curvature(source, tolerance_mm, selection, configuration)
    certain = known and not sampled

    if angular_param is not None:
        vertices, faces = _solid_arrays(source, tolerance_mm, angular_param, selection, configuration)
        radius = measured if known else max(measured or 0.0,
                                            _bbox_radius(vertices))
        effective = max(tolerance_mm, _sagitta_mm(angular_param, radius or 0.0))
        return (vertices, faces, angular_param, "stated by the caller",
                effective, certain, "stated")

    if known and measured is not None:
        angular = _angular_for(tolerance_mm, measured)
        vertices, faces = _solid_arrays(source, tolerance_mm, angular, selection, configuration)
        effective = max(tolerance_mm, _sagitta_mm(angular, measured))
        how = "derived from the widest curved face (radius %.4f mm)" % measured
        if sampled:
            how += SAMPLED_CLAUSE
        if effective > tolerance_mm:
            how += _chord_clause(angular, effective, tolerance_mm)
        return (vertices, faces, angular, how, effective, certain,
                "sampled" if sampled else "analytic")

    if known:
        # Nothing curved enough to bind: either no curved face at all, or only
        # faces too small for the curvature they carry to deviate by the
        # tolerance however they are cut. Every chord is inside it at any angle.
        vertices, faces = _solid_arrays(source, tolerance_mm, DEFAULT_ANGULAR_RAD, selection, configuration)
        how = "the default: no curved face was found to bind it"
        if sampled:
            how = ("the default: every curved face was measured, by sampling "
                   "where there was no analytic radius to read, and none is "
                   "curved enough across its own extent to deviate by the "
                   "tolerance" + SAMPLED_CLAUSE)
        return (vertices, faces, DEFAULT_ANGULAR_RAD, how, tolerance_mm,
                certain, "sampled" if sampled else "none")

    # A curved face whose radius could not be read. Tessellate once at the
    # default and take the bounding box as the radius — wider than any face
    # this reader measured, but only a guess about the one it could not — and
    # rebuild only when that guess asks for a finer angle than the default.
    vertices, faces = _solid_arrays(source, tolerance_mm, DEFAULT_ANGULAR_RAD, selection, configuration)
    radius = max(measured or 0.0, _bbox_radius(vertices))
    guess = _angular_for(tolerance_mm, radius)
    if guess < DEFAULT_ANGULAR_RAD:
        vertices, faces = _solid_arrays(source, tolerance_mm, guess, selection, configuration)
    else:
        guess = DEFAULT_ANGULAR_RAD
    return (vertices, faces, guess,
            "guessed from the mesh's own bounding box (radius %.4f mm), "
            "because the B-Rep carries %s" % (radius, UNRECOGNISED_CURVATURE),
            max(tolerance_mm, _sagitta_mm(guess, radius)), False, "guessed")


def _solid_arrays(source: str, tolerance: float, angular_tolerance: float,
                  selection: str = "", configuration: str = ""):
    """Tessellate the DSL source at `tolerance` and return (vertices, faces).

    Reuse compiled geometry through the shared evaluated document. Its render
    cache includes both tessellation tolerances, selection and configuration;
    measurement precision therefore cannot inherit a coarser display mesh.
    """
    import numpy as np

    # A digest, not hash(): two sources that collide in a 64-bit hash would
    # hand back each other's tessellation with no signal at all, and a wrong
    # number from a measurement verb is the one failure this module must not
    # have. SHA-256 of a few kilobytes of DSL is free beside OCCT.
    cache_key = hashlib.sha256(
        ("%r\n%r\n%r\n%r\n" % (tolerance, angular_tolerance, selection, configuration)).encode("utf-8")
        + source.encode("utf-8")
    ).hexdigest()
    cached = _solid_meshes.take(cache_key)
    if cached is not None:
        return cached

    from .methods import _evaluate
    reply = _evaluate({"source": source, "tolerance": tolerance,
        "angular_tolerance": angular_tolerance, "selection": selection, "configuration": configuration})
    if not reply["ok"]:
        raise ClearanceError("the DSL did not evaluate: " + reply["error"]["message"])
    raw_vertices = reply["result"]["mesh"].get("vertices") or []
    raw_faces = reply["result"]["mesh"].get("faces") or []
    if not raw_vertices or not raw_faces:
        raise ClearanceError(
            "the evaluation produced no solid geometry to measure"
        )
    arrays = (
        np.asarray(raw_vertices, dtype=np.float64).reshape((-1, 3)),
        np.asarray(raw_faces, dtype=np.int64)[:, :3].reshape((-1, 3)),
    )
    _solid_meshes.put(cache_key, arrays)
    return arrays


# ---------------------------------------------------------------------------
# The query
# ---------------------------------------------------------------------------

def _distance(fcl, solid_tree, reference_tree) -> tuple[float, list, list]:
    """Minimum distance and the pair of points realising it, world mm.

    Both trees are already in world millimetres, so both objects carry the
    identity transform and the nearest points come back in that same frame
    with nothing to undo.
    """
    request = fcl.DistanceRequest(enable_nearest_points=True)
    result = fcl.DistanceResult()
    value = fcl.distance(
        fcl.CollisionObject(solid_tree, fcl.Transform()),
        fcl.CollisionObject(reference_tree, fcl.Transform()),
        request,
        result,
    )
    points = list(result.nearest_points or [])
    # Overlapping meshes have no separation and FCL reports 0; the nearest
    # points it returns then describe a contact inside the overlap rather
    # than a gap, so they are dropped and the pair is flagged instead.
    if value <= 0.0:
        return 0.0, [], []
    solid_point = [float(v) for v in points[0]] if len(points) > 0 else []
    reference_point = [float(v) for v in points[1]] if len(points) > 1 else []
    return float(value), solid_point, reference_point


def clearance(params: dict) -> dict:
    """Answer a clearance request. Returns a worker {ok, result|error} dict.

    params:
      source                   .mcad DSL text; the solid is tessellated here.
      required_mm              the clearance being asked for.
      tolerance_mm             tessellation deviation for the measurement.
      angular_tolerance        radians; optional. Omit it and the module
                               derives the angular deflection from
                               tolerance_mm and the solid's own tightest
                               curvature, which is what makes the linear
                               number a real bound.
      targets                  [{reference, node, key, path?}] — one entry per
                               reference node, already scoped by the panel.

    A target whose key is not cached and carries no path is not an error: the
    reply comes back with `missing_keys` and the caller uploads those blobs
    and asks again. That is what keeps the steady state free of megabytes.
    """
    source = params.get("source")
    if not isinstance(source, str) or not source.strip():
        return _error("clearance requires params.source: the .mcad DSL text")
    targets = params.get("targets")
    if not isinstance(targets, list) or not targets:
        return _error("clearance requires params.targets: at least one "
                      "reference node to measure against")

    try:
        required_mm = float(params.get("required_mm", 0.0))
        tolerance_mm = float(params.get("tolerance_mm", DEFAULT_TOLERANCE_MM))
        stated_angular = params.get("angular_tolerance")
        angular = None if stated_angular is None else float(stated_angular)
    except (TypeError, ValueError) as exc:
        return _error(f"clearance received a non-numeric parameter: {exc}")
    if tolerance_mm <= 0.0:
        return _error("clearance tolerance_mm must be greater than zero")

    try:
        fcl = _require_fcl()

        # Trees first, and the solid's tessellation after them: a request that
        # is only missing an upload is answered without paying OCCT for a
        # tessellation whose result would be thrown away.
        prepared = []
        missing = []
        for entry in targets:
            if not isinstance(entry, dict):
                continue
            key = str(entry.get("key", ""))
            if not key:
                return _error("every clearance target needs a key")
            try:
                tree, triangles, cached = _tree_for(key, entry.get("path"))
            except KeyError:
                if key not in missing:
                    missing.append(key)
                continue
            prepared.append((entry, tree, triangles, cached))
        if missing:
            return {
                "ok": True,
                "result": {
                    "checked": False,
                    "units": "mm",
                    "reason": "the worker's blob cache holds no geometry for "
                              "%d of the targets (a first sighting, or an "
                              "eviction); send those targets again with their "
                              "path and it will read them. Nothing has been "
                              "found unreadable." % len(missing),
                    "missing_keys": missing,
                    "pairs": [],
                },
            }

        (solid_vertices, solid_faces, angular_rad, angular_how,
            effective_mm, bounded, tolerance_source) = _prepare_solid(
                source, tolerance_mm, angular, params.get("selection", ""), params.get("configuration", ""))
        solid_tree = _build_tree(solid_vertices, solid_faces)

        pairs = []
        hits = 0
        for entry, tree, triangles, cached in prepared:
            hits += 1 if cached else 0
            min_mm, solid_point, reference_point = _distance(fcl, solid_tree, tree)
            pair = {
                "reference": str(entry.get("reference", "")),
                "node": str(entry.get("node", "")),
                "key": str(entry.get("key", "")),
                "min_mm": min_mm,
                # Graded on the bound, not on the chord distance: the true
                # surface can sit effective_mm outside the chords, so a gap
                # that only meets the requirement before that is subtracted
                # is one the geometry does not promise. The same number the
                # reply publishes as tessellation_tolerance_mm is the one
                # taken off here, so the verdict and the bar agree.
                "bound_mm": max(0.0, min_mm - effective_mm),
                "pass": min_mm > 0.0 and min_mm - effective_mm >= required_mm,
                "triangles": int(triangles),
                "cached": bool(cached),
            }
            if min_mm <= 0.0:
                # A distance says only that there is no air here at all;
                # minerva_cad_check_interference is what names the crossings.
                pair["interference"] = True
                pair["note"] = ("the meshes touch or overlap — "
                                "minerva_cad_check_interference names where")
            else:
                pair["solid_point_mm"] = solid_point
                pair["reference_point_mm"] = reference_point
            pairs.append(pair)
        pairs.sort(key=lambda p: (p["min_mm"], p["reference"], p["node"]))
    except ClearanceError as exc:
        return _error(str(exc))

    return {
        "ok": True,
        "result": {
            "checked": True,
            "units": "mm",
            "pass": all(p["pass"] for p in pairs),
            "required_mm": required_mm,
            # WHAT THE MESH KEEPS, not what was asked for: where the
            # angular floor binds, the chords sit further out than the
            # request and a caller subtracting the request would believe a
            # number the geometry does not support.
            "tessellation_tolerance_mm": effective_mm,
            "requested_tolerance_mm": tolerance_mm,
            # OCCT applies both deflections and the finer one wins, so the
            # angular one is part of the promise the linear one makes.
            "angular_deflection_deg": math.degrees(angular_rad),
            "angular_deflection_source": angular_how,
            # A bound is a promise; where the curvature is unknown the number
            # is what a guess implies, and the text says so in the same words
            # the panel looks for before it trusts the row.
            "tolerance_bounded": bounded,
            # Where the bar came from — analytic radii are arithmetic, a
            # sampled radius is an estimate, a bounding box is a guess — so a
            # reader can tell a loft from a face the kernel would not read.
            "tolerance_source": tolerance_source,
            "tolerance_unbounded_because": (
                "" if bounded else UNBOUNDED_BECAUSE.get(
                    tolerance_source, UNBOUNDED_BECAUSE["guessed"])),
            "bound": (("the solid is measured as a mesh tessellated to within "
                       "%g mm of its true surface (chords stepped by at most "
                       "%.3f degrees, %s), so the true clearance is at least "
                       "min_mm - %g mm, reported as bound_mm; a pair passes "
                       "only when that bound meets required_mm"
                       % (effective_mm, math.degrees(angular_rad), angular_how,
                          effective_mm)) if bounded else
                      ("the solid is measured as a mesh tessellated at a "
                       "requested %g mm; its chord error is ESTIMATED at %g mm "
                       "(chords stepped by at most %.3f degrees, %s) and that "
                       "estimate is not guaranteed for %s, so no error bar "
                       "bounds min_mm here; each pair is graded on min_mm "
                       "minus the estimate, which is the best available and "
                       "still not a promise"
                       % (tolerance_mm, effective_mm,
                          math.degrees(angular_rad), angular_how,
                          UNBOUNDED_BECAUSE.get(tolerance_source,
                                                UNBOUNDED_BECAUSE["guessed"])))),
            "solid_triangles": int(len(solid_faces)),
            "cache": {
                "hits": hits,
                "misses": len(pairs) - hits,
                "entries": len(_reference_trees),
            },
            "engine": "python-fcl swept-sphere BVH, exact triangle-pair minimum",
            "pairs": pairs,
        },
    }


def _error(message: str) -> dict:
    return {"ok": False, "error": {"kind": "internal", "message": message}}
