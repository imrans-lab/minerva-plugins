"""EVERY PLACED PART IN THE SCENE, put there by the position file's own transform
— and a placeholder standing where a part has no model.

THE PROPERTY THIS MODULE EXISTS TO HOLD
---------------------------------------
The render must not be able to disagree with the CPL. So a part is NOT placed
by re-reading its authored ``x_mm``/``y_mm``/``rotation_deg``: it is placed by
the :class:`resolved_board.PhysicalPlacement` the CPL row was built from,
through a :class:`geometry.PlacementTransform` rebuilt from that placement's
``origin``/``rotation_deg``/``side`` — the same three numbers
``assembly_anchor`` composed the CPL's anchor with. Before anything is placed,
that transform is made to RE-DERIVE the anchor and the result is compared with
the anchor the row carries (:func:`_check_anchor`). The two sides of that check
are the SAME expression, so it cannot catch an error in the transform algebra
itself — that is what the suite's landmark literals are for. What it catches is
this module holding the WRONG INPUTS: a drawing that is not the one the row was
measured on, or an emission walked from a different board than the one passed
in. Either way it REFUSES rather than draw. A placement that moves in the file
therefore moves here by construction, not by agreement.

The rotation reaches the CPL as a NUMBER (``assembly_orientation``: placed
angle plus or minus the ledger offset, by side) and reaches the scene as POINTS
(the ledger offset turns the vendor model in the local frame, then the same
transform turns and mirrors it as it does the copper). Those two spellings get
the same treatment as the translation: before a model is turned,
:func:`_check_rotation` asks the EMITTED ROW what offset it applied — its
rotation less the placement's, signed by side — and REFUSES unless it is the
offset about to be used. So the file's own rotation decision governs the
picture, rather than a second decision that happens to match today.

THE CHAIN, link by link, and who owns each:

    footprint ORIGIN, never the body-box anchor    PhysicalPlacement.origin
    vendor model -> vendor canvas                  part_seat (measured)
    vendor canvas -> our footprint-local frame     ledger offset + part_orientation.datum_offset
    local -> board (rotation, bottom mirror)       geometry.PlacementTransform
    height above the face, by side                 here; mesh_frame for the axis map

WHAT A PART BECOMES
-------------------
``vendor_model``  the fetched OBJ, seated, in its own materials.
``placeholder``   a prism standing where the part stands: its COURTYARD where
                  the footprint draws one, else its land box, else a nominal
                  square on the origin — each recorded, because the three are
                  not equally trustworthy. Height is :data:`PLACEHOLDER_HEIGHT_MM`
                  and is recorded as NOMINAL: nothing on a board states a part's
                  height but its model, so a part without one has no height to
                  claim, and the per-side tallest-part report leaves it out by
                  name rather than counting a made-up number.

ORIENTATION: VERIFIED OR NOT, AND THE MARK
------------------------------------------
A part is ``verified`` only when the ledger states an applicable offset for
its pair AND the CPL did not refuse the row. Everything else — no row, a
declared no-reference, an undecided or mismatched measurement, a part bought
under no catalogue number — is ``unverified``: it is placed at its RAW rotation
with NO ledger offset, and if a vendor model is shown at all it stands under a
MARKER (:data:`UNVERIFIED_MARKER_MATERIAL`, a post rising clear of the part) so
nobody can read a guessed orientation as a measured one. The reason is carried
on the part and in the report. A placeholder prism is already unmistakably not a
part, so it carries the reason but no post.

THE REPORT
----------
One :class:`PartPlacementReport`: every part, every fallback with its reason,
every unverified orientation with its reason, the tallest MEASURED part per
side (enclosure clearance), the parts whose height is unknown, and the
advisories — a vendor package extent that disagrees with our fab body, a model
lying crosswise to our pads, a vendor ``c_origin`` that disagrees with the
vendor's own outline, and a measured pair whose drawing no longer shares a pad
number with the vendor's, which costs the SEATING DATUM and not the angle. Each advisory that is blind on a square part says so where
it is produced; see :mod:`part_seat`.

NOT HERE: writing any file, collision, enclosure fit. :mod:`part_seat` owns the
vendor-frame measurements; this module does not restate them.
"""

from __future__ import annotations

import math

from dataclasses import dataclass
from typing import Mapping, Sequence, Union

from . import assembly_anchor
from . import mesh_frame
from . import orientation_ledger as ol
from . import part_orientation as po
from . import part_seat
from .assembly_orientation import SIDE_TOP, default_ledger
from .footprint_def import FootprintDefinition
from .footprints import FootprintLookupError, resolve_footprint_layered
from .geometry import PlacementTransform
from .mesh_frame import Vec3
from .part_models import Absence, REASON_NO_PART_NUMBER
from .refdes_anchor import (LocalExtent, courtyard_extent_from_definition,
                            fab_extent_from_definition,
                            land_extent_from_definition)
from .resolved_board import ANCHOR_BASIS_AUTHORED, Side
from .wavefront_obj import Material

KIND_MODEL = "vendor_model"
KIND_PLACEHOLDER = "placeholder"

ORIENTATION_VERIFIED = "verified"
ORIENTATION_UNVERIFIED = "unverified"

#: A placeholder's height. Deliberately a slab, not a guess at the part.
PLACEHOLDER_HEIGHT_MM = 1.0
HEIGHT_BASIS_MODEL = "model"
HEIGHT_BASIS_NOMINAL = "nominal"

#: Which box a placeholder stands on. Recorded per part.
PRISM_BASIS_COURTYARD = "courtyard"
PRISM_BASIS_LANDS = "lands"
PRISM_BASIS_ORIGIN = "footprint_origin"
#: The square a footprint with no courtyard and no sized land gets — silk-only
#: furniture that somehow carries an order row.
ORIGIN_PRISM_HALF_MM = 0.5

#: Material names a file writer colours by, with the colour each should get.
#: Obviously synthetic on purpose: nothing on a real board is magenta or that
#: orange, so a placeholder or a marker can never pass for a part.
PLACEHOLDER_MATERIAL = "minerva_placeholder"
PLACEHOLDER_RGB = (1.0, 0.0, 1.0)
UNVERIFIED_MARKER_MATERIAL = "minerva_unverified_orientation"
UNVERIFIED_MARKER_RGB = (1.0, 0.38, 0.0)
#: The marker post: this much across, and this far above the part it marks.
MARKER_SIDE_MM = 0.5
MARKER_CLEARANCE_MM = 2.0

#: Tolerance for the anchor re-derivation. Same float arithmetic on the same
#: inputs, so this is round-off headroom, not a licence.
ANCHOR_TOL_MM = 1e-6

#: Tolerance for the rotation re-derivation, in degrees. Same reasoning as
#: :data:`ANCHOR_TOL_MM`.
ROTATION_TOL_DEG = 1e-6

ADVISORY_EXTENT = "vendor_extent_disagrees_with_fab_body"
ADVISORY_CROSSWISE = "model_crosswise_to_pads"
ADVISORY_SQUARE = "square_part_swap_undetectable"
ADVISORY_UNVERIFIED_MODEL = "model_shown_at_unverified_orientation"
ADVISORY_NO_SHARED_PADS = "verified_pair_shares_no_pad_number_with_vendor_drawing"


class PartPlacementError(ValueError):
    """This module could not prove it holds the CPL's transform, and stopped."""


@dataclass(frozen=True)
class SceneMesh:
    """Triangles in SCENE millimetres (:mod:`mesh_frame`), with the materials
    that colour them. ``triangle_materials`` runs parallel to ``triangles``."""

    positions: tuple[Vec3, ...]
    triangles: tuple[tuple[int, int, int], ...]
    triangle_materials: tuple[Union[str, None], ...]
    materials: Mapping[str, Material]


@dataclass(frozen=True)
class PlacedPart:
    ref: str
    side: str
    kind: str
    orientation: str
    #: Why the orientation is unverified, or why a placeholder stands here.
    reason: Union[str, None]
    house_part: Union[str, None]
    footprint_ref: str
    mesh: SceneMesh
    height_mm: float
    height_basis: str
    #: Distance from the seated model's footprint centre to the CPL anchor, in
    #: board millimetres. A cross-check, not a placement input: a large value
    #: says the vendor's model does not sit where our fab drawing says the body
    #: is, which is worth a look on either side. None for a placeholder.
    anchor_delta_mm: Union[float, None]
    #: The CPL row's own anchor, in board millimetres. Carried so a file writer
    #: can seat this part's node ON the position file's number instead of
    #: baking the location into vertices and leaving a reader nothing to
    #: compare against the CPL.
    anchor_mm: tuple[float, float]
    marker: Union[SceneMesh, None] = None
    prism_basis: Union[str, None] = None
    notes: tuple[str, ...] = ()


@dataclass(frozen=True)
class PartPlacementReport:
    parts: tuple[PlacedPart, ...]
    #: Physical refs the order leaves out (not populated), so a reader can tell
    #: "not drawn because unbought" from "not drawn because something failed".
    excluded: tuple[str, ...]
    fallbacks: tuple[dict, ...]
    unverified: tuple[dict, ...]
    #: ``{"side", "ref", "height_mm"}`` for each side that has a MEASURED part.
    tallest: tuple[dict, ...]
    unknown_height_refs: tuple[str, ...]
    advisories: tuple[dict, ...]
    board_thickness_mm: float

    def as_dict(self) -> dict:
        """Everything but the geometry, for a sidecar or a worker reply."""
        return {
            "parts": [{
                "ref": p.ref, "side": p.side, "kind": p.kind,
                "orientation": p.orientation, "reason": p.reason,
                "house_part": p.house_part, "footprint": p.footprint_ref,
                "height_mm": round(p.height_mm, 4), "height_basis": p.height_basis,
                "anchor_delta_mm": (None if p.anchor_delta_mm is None
                                    else round(p.anchor_delta_mm, 4)),
                "anchor_mm": {"x": round(p.anchor_mm[0], 4),
                              "y": round(p.anchor_mm[1], 4)},
                "prism_basis": p.prism_basis, "marked": p.marker is not None,
                "notes": list(p.notes),
            } for p in self.parts],
            "excluded": list(self.excluded),
            "fallbacks": list(self.fallbacks),
            "unverified": list(self.unverified),
            "tallest": list(self.tallest),
            "unknown_height_refs": list(self.unknown_height_refs),
            "advisories": list(self.advisories),
            "board_thickness_mm": self.board_thickness_mm,
        }


# ---------------------------------------------------------------------------
# The chain's last two links: local -> board -> scene
# ---------------------------------------------------------------------------


def _transform_of(physical) -> PlacementTransform:
    """The CPL's transform, rebuilt from the three numbers it was composed with."""
    return PlacementTransform(position=physical.origin,
                              rotation_deg=physical.rotation_deg,
                              side=physical.side)


def _check_anchor(physical, footprint: Union[FootprintDefinition, None],
                  transform: PlacementTransform) -> Union[str, None]:
    """Make the rebuilt transform RE-DERIVE the CPL anchor, or refuse.

    An authored anchor cannot be re-derived from the drawing (its local value is
    the author's, not the footprint's) and a child whose own drawing could not
    be resolved has nothing to measure, so both are skipped WITH A NOTE rather
    than silently — the note is the reader's warning that the cross-check did
    not run for this part.
    """
    if physical.anchor_basis == ANCHOR_BASIS_AUTHORED:
        return "anchor cross-check skipped: the anchor is authored, not measured"
    if footprint is None:
        return "anchor cross-check skipped: the part's own drawing was not resolved"
    local, basis = assembly_anchor.footprint_anchor(footprint)
    if basis != physical.anchor_basis:
        raise PartPlacementError(
            f"{physical.ref}: the CPL anchor was measured on basis "
            f"{physical.anchor_basis!r} but this drawing measures on {basis!r}; "
            f"this module is not holding the drawing the CPL row came from")
    derived = transform.point(local)
    if math.dist(derived, physical.anchor) > ANCHOR_TOL_MM:
        raise PartPlacementError(
            f"{physical.ref}: the rebuilt placement transform puts the anchor at "
            f"{derived}, the CPL row carries {physical.anchor}; refusing to place "
            f"a part by a transform that is not the position file's")
    return None


def _check_rotation(row, physical, offset: Union[int, None]) -> None:
    """Make the OFFSET this module is about to turn the model by be the one the
    emitted row actually applied, or refuse.

    The anchor check does this for the translation; without this the rotation
    is TWO DERIVATIONS. ``assembly_orientation`` decides an offset and folds it
    into the row's number; :func:`_orientation` re-reads the ledger and decides
    again in points. They agree only because both ask the same functions the
    same way, so a change to either — closing the mpn gap, a second refusal
    state — diverges silently, and a render that disagrees with the position
    file is the whole failure this module exists to prevent.

    So the row is asked what it applied: its rotation less the placement's,
    signed the way ``corrected_rotation`` composed it (top ADDS a local-frame
    offset, bottom SUBTRACTS it). That number is a fact about the emitted file,
    not a re-run of the decision, so it catches a divergence whichever side
    caused it — including an emission corrected with a different ledger than
    the one this module was handed.

    Run BEFORE the shared-pad downgrade below, which knowingly draws a verified
    pair at its raw angle and says so with a marker, an advisory and a report
    line. That divergence is announced; this one would not be.
    """
    delta = float(row.rotation_deg) - float(physical.rotation_deg)
    applied = (delta if row.side == SIDE_TOP else -delta) % 360.0
    ours = float(offset or 0) % 360.0
    gap = abs(applied - ours) % 360.0
    if min(gap, 360.0 - gap) > ROTATION_TOL_DEG:
        raise PartPlacementError(
            f"{row.ref}: the CPL row states rotation {row.rotation_deg} over a "
            f"placement of {physical.rotation_deg} on the {row.side} side, which "
            f"is an applied offset of {applied}, but this module is about to turn "
            f"the vendor model by {ours}; refusing to draw a part at an "
            f"orientation the position file does not state")


def _face_height(side: Side, thickness_mm: float, h: float) -> float:
    """Scene height of a point ``h`` mm off the seating face of ``side``. A
    bottom-side part grows DOWN from the underside — with the transform's
    local-Y mirror that is a proper rotation of the part, never a reflection."""
    if side is Side.TOP:
        return mesh_frame.top_y_mm(thickness_mm) + h
    return mesh_frame.BOARD_BOTTOM_Y_MM - h


def _to_scene(points: Sequence[Vec3], transform: PlacementTransform,
              side: Side, thickness_mm: float) -> tuple[Vec3, ...]:
    out = []
    for lx, ly, h in points:
        bx, by = transform.point((lx, ly))
        out.append(mesh_frame.scene_point(bx, by, _face_height(side, thickness_mm, h)))
    return tuple(out)


def _box(extent: LocalExtent, h0: float, h1: float, transform: PlacementTransform,
         side: Side, thickness_mm: float, material: str, rgb) -> SceneMesh:
    """An axis-aligned local box, through the chain, wound OUTWARD on every face.

    Winding is fixed by measurement rather than by hand-ordering the corners,
    because the chain reflects on the bottom side and a hand-wound box would be
    inside out there."""
    corners = [(x, y, h) for h in (h0, h1)
               for y in (extent.min_y, extent.max_y)
               for x in (extent.min_x, extent.max_x)]
    positions = _to_scene(corners, transform, side, thickness_mm)
    centre = tuple(sum(p[i] for p in positions) / 8.0 for i in range(3))
    # Indices: bit0 = x, bit1 = y, bit2 = h.
    faces = ((0, 1, 3, 2), (4, 6, 7, 5), (0, 4, 5, 1), (2, 3, 7, 6), (0, 2, 6, 4), (1, 5, 7, 3))
    triangles = []
    for a, b, c, d in faces:
        for tri in ((a, b, c), (a, c, d)):
            p, q, r = (positions[i] for i in tri)
            normal = _cross(_sub(q, p), _sub(r, p))
            outward = _sub(_mid(p, q, r), centre)
            triangles.append(tri if _dot(normal, outward) >= 0 else (tri[0], tri[2], tri[1]))
    return SceneMesh(positions=positions, triangles=tuple(triangles),
                     triangle_materials=(material,) * len(triangles),
                     materials={material: Material(name=material, diffuse=tuple(rgb))})


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _mid(p, q, r):
    return ((p[0] + q[0] + r[0]) / 3.0, (p[1] + q[1] + r[1]) / 3.0, (p[2] + q[2] + r[2]) / 3.0)


def _prism_extent(footprint: Union[FootprintDefinition, None]) -> tuple[LocalExtent, str]:
    """The box a placeholder stands on, and which drawing supplied it."""
    if footprint is not None:
        courtyard = courtyard_extent_from_definition(footprint)
        if courtyard is not None and courtyard.width > 0 and courtyard.height > 0:
            return courtyard, PRISM_BASIS_COURTYARD
        lands = land_extent_from_definition(footprint)
        if lands is not None and lands.width > 0 and lands.height > 0:
            return lands, PRISM_BASIS_LANDS
    r = ORIGIN_PRISM_HALF_MM
    return LocalExtent(-r, -r, r, r), PRISM_BASIS_ORIGIN


# ---------------------------------------------------------------------------
# Per-part decisions
# ---------------------------------------------------------------------------


def _resolve_drawing(board, component, physical) -> Union[FootprintDefinition, None]:
    """The drawing THIS PART is described by: the child's own when it named one
    (resolved through the library, as the compiler did), else the component's."""
    if physical.footprint_ref is None:
        return board.footprint_for(component)
    try:
        return FootprintDefinition.from_kicad_parsed(
            resolve_footprint_layered(physical.footprint_ref).parsed)
    except FootprintLookupError:
        return None


def _orientation(row, house: str, ledger: ol.OrientationLedger,
                 refused: Mapping[str, str]) -> tuple[Union[int, None], Union[str, None]]:
    """``(offset to apply, reason it is unverified)`` — exactly one is None.

    Reads the same ledger key the CPL correction read, and defers to the CPL's
    own refusals: a row the position file refused to state a rotation for is
    not one this module gets to orient either.
    """
    if row.ref in refused:
        return None, f"the position file refused this row ({refused[row.ref]})"
    if not row.house_part:
        return None, "not bought as a catalogue part: nothing to measure against"
    record = ledger.lookup(row.footprint_ref, house, row.house_part)
    state = ol.state_of(record)
    if state == ol.STATE_UNKNOWN:
        return None, (f"never measured: no ledger row for "
                      f"({row.footprint_ref}, {house}, {row.house_part})")
    if state == ol.STATE_NO_REFERENCE:
        return None, "no vendor drawing to measure against (ledger: no_reference)"
    if ol.applies_offset(record.offset_deg is not None, record.lands_agree):
        return int(record.offset_deg), None
    return None, f"measured but undecided or mismatched (verdict {record.verdict!r})"


def _vendor(client, house_part: Union[str, None]):
    """Facts and model for one catalogue number, both possibly an Absence."""
    if not house_part:
        absence = Absence(house_part or "", REASON_NO_PART_NUMBER,
                          "the placement carries no catalogue number")
        return absence, absence
    facts = client.facts(house_part)
    if facts.absent:
        return facts, facts
    return facts, client.model(facts)


# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------


def place_parts(board, emission, *, client,
                ledger: Union[ol.OrientationLedger, None] = None) -> PartPlacementReport:
    """Every CPL row of ``emission`` as a placed part in the scene.

    ``emission`` is the :class:`assembly_outputs.AssemblyEmission` the position
    file is rendered from — the rows, the profile, the refusals — so this
    module never walks the board for placement facts of its own. ``client``
    answers ``facts(part)`` and ``model(facts)`` as
    :class:`part_models.VendorPartClient` does. ``ledger`` defaults to the
    shipped one, and MUST be the ledger the emission was corrected with.
    """
    book = default_ledger() if ledger is None else ledger
    house = emission.profile.house_part_id
    thickness = float(board.fabrication.thickness_mm)
    refused = {r.component: r.code for r in emission.orientation_refusals}
    index = {}
    excluded = set()
    for component in board.components:
        for physical in component.physical_placements:
            index[physical.ref] = (component, physical)
            if component.assembly is not None and not component.assembly.populate:
                excluded.add(physical.ref)

    parts: list[PlacedPart] = []
    fallbacks: list[dict] = []
    unverified: list[dict] = []
    advisories: list[dict] = []
    tallest: dict[str, tuple[str, float]] = {}
    unknown_height: list[str] = []

    for row in emission.cpl:
        try:
            component, physical = index[row.ref]
        except KeyError:
            raise PartPlacementError(
                f"CPL row {row.ref!r} names a part the compiled board does not "
                f"place; the emission and the board are not the same board")
        footprint = _resolve_drawing(board, component, physical)
        transform = _transform_of(physical)
        notes: list[str] = []
        skipped = _check_anchor(physical, footprint, transform)
        if skipped:
            notes.append(skipped)

        offset, why = _orientation(row, house, book, refused)
        _check_rotation(row, physical, offset)
        orientation = ORIENTATION_VERIFIED if why is None else ORIENTATION_UNVERIFIED
        if why is not None:
            unverified.append({"ref": row.ref, "reason": why})

        facts, model = _vendor(client, row.house_part)
        if model.absent:
            extent, basis = _prism_extent(footprint)
            fallbacks.append({"ref": row.ref, "reason": model.reason,
                              "detail": model.detail, "prism_basis": basis})
            unknown_height.append(row.ref)
            parts.append(PlacedPart(
                ref=row.ref, side=row.side, kind=KIND_PLACEHOLDER,
                orientation=orientation, reason=why or model.detail,
                house_part=row.house_part, footprint_ref=row.footprint_ref,
                mesh=_box(extent, 0.0, PLACEHOLDER_HEIGHT_MM, transform, physical.side,
                          thickness, PLACEHOLDER_MATERIAL, PLACEHOLDER_RGB),
                height_mm=PLACEHOLDER_HEIGHT_MM, height_basis=HEIGHT_BASIS_NOMINAL,
                anchor_delta_mm=None, anchor_mm=tuple(physical.anchor),
                prism_basis=basis, notes=tuple(notes)))
            continue

        # The translation half of the vendor-to-ours map, from the two pad
        # fields, by the measurement's own rule. At an unverified 0 it is still
        # the honest thing to do: the model's pads go over ours, and the post
        # says the angle is a guess.
        datum = None
        if footprint is not None:
            datum = po.datum_offset(
                po.pad_field_from_definition(footprint),
                po.pad_field_from_vendor_pads(facts.part, facts.pads),
                offset or 0)
        if datum is None and offset is not None:
            # A VERIFIED pair had at least two shared pad numbers when it was
            # measured, so none now means this drawing is not the one the ledger
            # measured (renumbered pads leave the fab box, and so the anchor
            # check, untouched).
            #
            # THE TWO UNKNOWNS ARE NOT THE SAME UNKNOWN, and only one of them is
            # real here. The DATUM is lost, so part_seat centres the model on
            # our footprint origin. The ANGLE is not: the ledger states it and
            # THE POSITION FILE APPLIED IT, so dropping it would draw the part
            # at an angle the file does not state — the one failure this module
            # exists to prevent, and marking it does not make it acceptable. So
            # the offset is applied, _check_rotation above holds it equal to the
            # row's, and the report says THE SEATING is approximate rather than
            # calling a known orientation a guess.
            detail = ("verified in the ledger, but this drawing shares no pad "
                      "number with the vendor's — it is not the drawing that was "
                      "measured. The ledger offset IS applied (it is the angle "
                      "the position file states), but no datum could be computed, "
                      "so the model is centred on our footprint origin rather "
                      "than laid on its pads — re-measure the pair")
            notes.append(detail)
            advisories.append({"code": ADVISORY_NO_SHARED_PADS, "ref": row.ref,
                               "detail": detail})
        elif datum is None:
            notes.append("no pad number shared with the vendor drawing; the "
                         "model was centred on our footprint origin")
        seated = part_seat.seat_model(facts.model, model.mesh, facts.part,
                                      offset_deg=offset or 0, datum=datum)
        notes.extend(seated.notes)
        mesh = SceneMesh(
            positions=_to_scene(seated.points, transform, physical.side, thickness),
            triangles=seated.triangles,
            triangle_materials=seated.triangle_materials,
            materials=seated.materials)
        anchor_delta = math.dist(transform.point(seated.centre), physical.anchor)

        marker = None
        if why is not None:
            cx, cy = seated.centre
            r = MARKER_SIDE_MM / 2.0
            marker = _box(LocalExtent(cx - r, cy - r, cx + r, cy + r), 0.0,
                          seated.height_mm + MARKER_CLEARANCE_MM, transform,
                          physical.side, thickness, UNVERIFIED_MARKER_MATERIAL,
                          UNVERIFIED_MARKER_RGB)
            advisories.append({"code": ADVISORY_UNVERIFIED_MODEL, "ref": row.ref,
                               "detail": f"the vendor model is drawn at an UNVERIFIED "
                                         f"0 degree offset and marked: {why}"})

        advisories.extend(_advisories(row.ref, footprint, facts.model, seated, offset))

        side_best = tallest.get(row.side)
        if side_best is None or seated.height_mm > side_best[1]:
            tallest[row.side] = (row.ref, seated.height_mm)
        parts.append(PlacedPart(
            ref=row.ref, side=row.side, kind=KIND_MODEL, orientation=orientation,
            reason=why, house_part=row.house_part, footprint_ref=row.footprint_ref,
            mesh=mesh, height_mm=seated.height_mm, height_basis=HEIGHT_BASIS_MODEL,
            anchor_delta_mm=anchor_delta, anchor_mm=tuple(physical.anchor),
            marker=marker, notes=tuple(notes)))

    return PartPlacementReport(
        parts=tuple(parts),
        excluded=tuple(sorted(excluded)),
        fallbacks=tuple(fallbacks),
        unverified=tuple(unverified),
        tallest=tuple({"side": side, "ref": ref, "height_mm": round(h, 4)}
                      for side, (ref, h) in sorted(tallest.items())),
        unknown_height_refs=tuple(unknown_height),
        advisories=tuple(advisories),
        board_thickness_mm=thickness,
    )


def _advisories(ref: str, footprint: Union[FootprintDefinition, None], reference,
                seated: part_seat.SeatedModel, offset: Union[int, None]) -> list[dict]:
    """The two geometry cross-checks for one seated model, and ONE statement of
    blindness where the part is square — said here, where a reader of the
    report will see it, not only in a module header. Only a VERIFIED offset
    can indict the ledger: at a guessed 0 the crosswise check would be
    indicting the guess."""
    out: list[dict] = []
    package = part_seat.package_extent_local(reference, offset or 0)
    if package is None:
        return out
    if part_seat.elongation(*package) is None:
        out.append({"code": ADVISORY_SQUARE, "ref": ref,
                    "detail": f"vendor package {package[0]:.2f} x {package[1]:.2f} mm is "
                              f"square: a length/width swap in our footprint and a "
                              f"quarter-turn ledger error are both INVISIBLE to the "
                              f"extent and crosswise checks on this part"})
        return out

    fab = fab_extent_from_definition(footprint)
    verdict = part_seat.extent_disagreement(
        package, (fab.width, fab.height) if fab is not None else None)
    if verdict == "disagrees":
        out.append({"code": ADVISORY_EXTENT, "ref": ref,
                    "detail": f"vendor package {package[0]:.2f} x {package[1]:.2f} mm "
                              f"fits our fab body {fab.width:.2f} x {fab.height:.2f} mm "
                              f"better turned a quarter — check the footprint for a "
                              f"length/width swap"})

    lands = land_extent_from_definition(footprint)
    if offset is not None and lands is not None:
        verdict = part_seat.crosswise(seated.extent, (lands.width, lands.height))
        if verdict == "crosswise":
            out.append({"code": ADVISORY_CROSSWISE, "ref": ref,
                        "detail": f"the seated vendor model is elongated across our "
                                  f"pad field ({seated.extent[0]:.2f} x "
                                  f"{seated.extent[1]:.2f} mm over lands "
                                  f"{lands.width:.2f} x {lands.height:.2f} mm): the "
                                  f"ledger offset of {offset} for this pair, or the "
                                  f"vendor's model rotation, is a quarter turn wrong"})
        elif verdict == part_seat.INDETERMINATE:
            out.append({"code": ADVISORY_SQUARE, "ref": ref,
                        "detail": f"our land box {lands.width:.2f} x {lands.height:.2f} mm "
                                  f"is square: the crosswise check cannot see a "
                                  f"quarter-turn ledger error on this part"})
    return out
