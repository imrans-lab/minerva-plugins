"""Does OUR footprint drawing point the same way as the VENDOR's?

WHY THIS EXISTS
---------------
A pick-and-place position file states a rotation, and the assembly house
interprets that rotation against the VENDOR's canonical drawing of the part —
the orientation in the part's own datasheet/CAD model — not against our
``.kicad_mod``. Where our footprint is drawn rotated relative to the vendor's,
the emitted rotation is off by exactly that amount and the part is soldered
down rotated. Nothing in the current pipeline can see that: our copper is
self-consistent, DRC is clean, the gerbers are right, and the board comes back
with a connector facing the wrong way.

This module is the MEASUREMENT only. It answers "by how much, and how sure?"
for one (seed footprint, vendor payload) pair. Nothing here changes an export;
applying the correction to the CPL is separate work by design, because a
measurement you cannot inspect before you trust it is worse than no
measurement.

THE ANGLE CONVENTION — read this before using ``offset_deg``
------------------------------------------------------------
``offset_deg`` is the COUNTER-CLOCKWISE rotation that carries the VENDOR's
drawing onto OURS::

    our_drawing = rotate_ccw(vendor_drawing, offset_deg)

CCW-positive is the same sense KiCad and the JLC/KiCad position file use for a
component's rotation, so a part our library draws at ``offset_deg`` relative to
vendor canonical, placed TOP-SIDE at rotation ``rho``, must be told to the house
as ``rho + offset_deg``. This is a LOCAL-frame rotation, so a BOTTOM-side
placement — which mirrors the local frame before rotating it — subtracts it
instead; ``assembly_orientation.corrected_rotation`` owns both signs and derives
them. Stating the sense any other way inverts the fix on the two
packages that most need it, so it is pinned by
``tests/test_part_orientation.py`` against three pairs a human read off a board
house's 3D preview before any of these numbers were computed.

Note the file coordinates are Y-DOWN (both KiCad's ``.kicad_mod`` and EasyEDA's
canvas), so a CCW-on-screen rotation is ``(x cos + y sin, -x sin + y cos)``.

ANCHORING IS BY PAD NUMBER, NEVER BY POSITION
---------------------------------------------
Pads are matched by their NUMBER and compared like-for-like. This is
load-bearing, not tidiness. Several packages we buy — 0805 chips, an even-pin
QFN, a symmetric header — have pad FIELDS that map onto themselves under 90 or
180 degrees, so a position-only match (nearest-neighbour, Hungarian, ICP, a
shape hash) reports a perfect fit at two or four angles and cannot say which.
That is precisely the case where the defect hides: the copper is symmetric, the
PART is not. Pad numbering is the only thing in either drawing that breaks the
symmetry, so it is the anchor.

A number appearing more than once on either side (a split thermal pad, a pair of
mechanical tabs both called ``MP``) is dropped from the comparison rather than
guessed at, and reported in ``duplicate_numbers``.

TWO INDEPENDENT AXES, NOT ONE THRESHOLD
---------------------------------------
The verdict rests on two questions that a single residual threshold conflates:

1. WHICH orientation — decided by how much better the best angle fits than the
   runner-up (:data:`SEPARATION_RATIO`). A drawing rotated 180 from ours fits
   its own angle far better than any other, however crudely the lands are
   drawn.
2. WHETHER THE LANDS AGREE — decided by the absolute residual at that angle
   (:data:`LAND_TOL_MM`).

The two are reported separately (``angle_decided`` / ``lands_agree``) as well
as summarised into one ``verdict``, so a too-tight land tolerance can never
destroy a correct angle. Keeping them separate is what makes the two measured
traps come out right.
``SOT-23``/``C15127`` fits 180 with a 0.28 mm worst-pad error, because the
vendor's land sits at x = +/-1.150 mm and KiCad's IPC land at +/-0.9375 mm —
a land-SIZE difference, with the orientation never in doubt (the runner-up is
9x worse). ``SPK0641HT4H-1``/``C5159510`` fits 180 with 0.06 mm from a
pad-centre difference. A scheme with one tight absolute threshold calls both
"disagrees on geometry" and throws away the 180 that is the whole point.

Determinism: pure functions over the two parsed drawings, no clock, no
network, no filesystem beyond what the caller opens. Reported floats are
rounded to :data:`_ROUND` places so a result is byte-stable across runs.
"""

from __future__ import annotations

import math

from dataclasses import dataclass
from typing import Any, Iterable, Mapping, Sequence, Union

#: EasyEDA/LCSC package drawings are in units of 10 mil. NOT taken on trust:
#: ``test_part_orientation.py`` re-derives this from three known pitches in the
#: committed payloads (JST PH 2.00 mm, JST XH 2.50 mm, VQFN 0.50 mm), so a
#: vendor unit change shows up as a failing pitch, not as silently wrong angles.
VENDOR_UNIT_MM = 0.254

#: The four orientations a part can be placed at. Nothing between them is
#: physically orderable, so a continuous best-fit angle would only invite a
#: reader to believe a 3.7-degree answer.
CANDIDATE_ANGLES = (0, 90, 180, 270)

#: How many times worse the runner-up must be for the best angle to be the
#: ANSWER rather than a coin toss. Measured over the nineteen committed pairs the
#: weakest true separation is 8.9x (SOT-23, 1.778 / 0.200); the tightest thing
#: this must still reject is a genuine tie at 1.0x. 4.0 sits in that gap.
SEPARATION_RATIO = 4.0

#: ...AND the runner-up must be at least this many mm worse in absolute terms.
#: The ratio test alone declares a perfectly symmetric pair (best 0.0, runner-up
#: 0.0) DECIDED, because ``0 >= 0 * 4`` — which is the exact case the whole
#: pad-number anchor exists to catch. This floor is what makes a tie read as a
#: tie instead of as whichever angle float noise sorted first.
SEPARATION_FLOOR_MM = 0.05

#: Residual (RMS, mm) above which the two drawings are not the same land
#: pattern, whatever angle fits best. THIS IS A NARROW GAP and the number was
#: measured, not chosen: the largest LEGITIMATE residual over the committed
#: pairs is 0.200 mm (SOT-23's vendor land at +/-1.150 mm against KiCad's IPC
#: land at +/-0.9375 mm), and the smallest WRONG-PART residual measured is
#: 0.400 mm (our 1206 fuse footprint against the 0805 capacitor C49678, whose
#: 2.0 mm pitch is 0.8 mm tighter). 0.30 sits between them with 0.10 mm on each
#: side, pinned from both directions by the headroom test rather than nudged
#: until the suite went green.
LAND_TOL_MM = 0.30

#: How close either population may come to :data:`LAND_TOL_MM` before the
#: threshold has stopped separating them and a human must re-measure.
LAND_HEADROOM_MM = 0.05

_ROUND = 6

# Verdicts. Strings, not an enum, because these cross the worker's JSON
# boundary into Go and a name is more legible in a report than an ordinal.
VERDICT_ALIGNED = "aligned"
VERDICT_ROTATED = "rotated"
VERDICT_GEOMETRY_MISMATCH = "geometry_mismatch"
VERDICT_AMBIGUOUS = "ambiguous"
VERDICT_INSUFFICIENT_OVERLAP = "insufficient_overlap"
VERDICT_NO_REFERENCE = "no_reference"

VERDICTS = (
    VERDICT_ALIGNED,
    VERDICT_ROTATED,
    VERDICT_GEOMETRY_MISMATCH,
    VERDICT_AMBIGUOUS,
    VERDICT_INSUFFICIENT_OVERLAP,
    VERDICT_NO_REFERENCE,
)

#: Verdicts for which ``offset_deg`` is a number a consumer may act on.
DECIDED_VERDICTS = (VERDICT_ALIGNED, VERDICT_ROTATED)


# ---------------------------------------------------------------------------
# Pad sets — one shape for both sides of the comparison
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class PadField:
    """A drawing reduced to what orientation depends on: numbered pad centres.

    ``centres`` maps a pad number (as written, a string — ``"MP"`` and ``"17"``
    are both real) to its centre in millimetres in the drawing's OWN frame.
    ``duplicate_numbers`` are the numbers seen more than once and therefore
    excluded; ``source`` names where the field came from, for the report.
    """

    source: str
    centres: Mapping[str, tuple[float, float]]
    duplicate_numbers: tuple[str, ...]

    @property
    def numbers(self) -> tuple[str, ...]:
        return tuple(sorted(self.centres))


def _collect(source: str,
             items: Iterable[tuple[str, float, float]]) -> PadField:
    """Build a :class:`PadField`, dropping any number that appears twice."""
    seen: dict[str, tuple[float, float]] = {}
    dupes: set[str] = set()
    for number, x_mm, y_mm in items:
        key = str(number).strip()
        if not key:
            continue
        if key in seen:
            dupes.add(key)
            continue
        seen[key] = (float(x_mm), float(y_mm))
    for key in dupes:
        seen.pop(key, None)
    return PadField(source=source, centres=seen,
                    duplicate_numbers=tuple(sorted(dupes)))


def our_pad_field(parsed: Mapping[str, Any],
                  source: Union[str, None] = None) -> PadField:
    """The pad field of one of OUR footprints, from ``parse_kicad_mod`` output.

    Takes the parsed dict rather than a path so the caller keeps ownership of
    library resolution (and its sha pin) — this module never reads the library.
    """
    name = source or str(parsed.get("name") or "")
    return _collect(name, ((p.get("number"), p.get("x_mm"), p.get("y_mm"))
                           for p in parsed.get("pads") or ()))


# ---------------------------------------------------------------------------
# The vendor side — EasyEDA/LCSC package payloads
# ---------------------------------------------------------------------------

# A vendor shape record is a "~"-separated line. For PAD the fields we need
# are, by index: 1 shape, 2 centre x, 3 centre y, 6 layer id, 8 pad number.
# Later fields (outline points, rotation, element id, hole geometry) carry the
# land's SIZE and are deliberately unread here: this module measures where the
# numbered pads are, not how big they are, and reading size would tempt a
# future reader to fold a land-size difference back into the angle.
_PAD_X = 2
_PAD_Y = 3
_PAD_NUMBER = 8
_PAD_MIN_FIELDS = 9


@dataclass(frozen=True)
class VendorFootprint:
    """A vendor package drawing: its identity plus its numbered pad centres.

    ``pads`` are in millimetres relative to the drawing ORIGIN that
    ``dataStr.head.x``/``.y`` states, so a payload re-fetched onto a different
    canvas position parses to the same numbers.
    """

    lcsc: str
    package: str
    pads: PadField


def parse_vendor_payload(payload: Mapping[str, Any],
                         lcsc: Union[str, None] = None,
                         ) -> Union[VendorFootprint, None]:
    """Read a cached LCSC/EasyEDA component payload into a vendor drawing.

    Returns ``None`` — never raises, never guesses — when the payload carries
    no usable package drawing: a failed lookup, a part with no footprint, a
    truncated cache entry. "We have no vendor reference for this part" is a
    real and common answer, and the caller renders it as
    :data:`VERDICT_NO_REFERENCE` rather than as an error.
    """
    result = payload.get("result") if isinstance(payload, Mapping) else None
    if not isinstance(result, Mapping):
        return None
    detail = result.get("packageDetail")
    if not isinstance(detail, Mapping):
        return None
    data = detail.get("dataStr")
    if not isinstance(data, Mapping):
        return None
    head = data.get("head")
    shapes = data.get("shape")
    if not isinstance(head, Mapping) or not isinstance(shapes, Sequence):
        return None
    try:
        origin_x = float(head["x"])
        origin_y = float(head["y"])
    except (KeyError, TypeError, ValueError):
        return None

    def _pads():
        for record in shapes:
            if not isinstance(record, str) or not record.startswith("PAD~"):
                continue
            fields = record.split("~")
            if len(fields) <= _PAD_MIN_FIELDS:
                continue
            try:
                x = (float(fields[_PAD_X]) - origin_x) * VENDOR_UNIT_MM
                y = (float(fields[_PAD_Y]) - origin_y) * VENDOR_UNIT_MM
            except ValueError:
                continue
            yield fields[_PAD_NUMBER], x, y

    number = lcsc or str((result.get("lcsc") or {}).get("number") or "")
    package = str(detail.get("title") or "")
    field = _collect(number or package, _pads())
    if not field.centres:
        return None
    return VendorFootprint(lcsc=number, package=package, pads=field)


# ---------------------------------------------------------------------------
# The measurement
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class OrientationMeasurement:
    """What we can say about one (our footprint, vendor part) pair.

    ``offset_deg`` is the CCW rotation from the vendor's drawing to ours (see
    the module docstring) and is stated IF AND ONLY IF ``angle_decided`` — which
    includes a ``geometry_mismatch`` and excludes everything else, so it is a
    narrower claim than :data:`DECIDED_VERDICTS`. ``residual_mm`` is the RMS
    per-pad distance after
    the best rigid fit; ``max_pad_error_mm`` is the worst single pad, which is
    the figure to quote when explaining a nonzero residual to a human.
    ``residuals_by_angle`` carries all four so a reader can see the separation
    the verdict rests on rather than being asked to trust it.

    THE TWO AXES ARE READABLE SEPARATELY. ``angle_decided`` is axis 1 alone:
    when it is true ``offset_deg`` is the answer, INCLUDING under a
    ``geometry_mismatch`` verdict — a part drawn 180 out is still drawn 180 out
    when the land sizes also disagree. ``lands_agree`` is axis 2. A consumer
    that only needs the rotation reads ``angle_decided``; one that wants to be
    sure it is even holding the right part reads both. Collapsing them into the
    verdict string alone would make a wrong land tolerance destroy a correct
    angle, and the land gap here is narrow (see :data:`LAND_TOL_MM`).
    """

    verdict: str
    offset_deg: Union[int, None]
    residual_mm: Union[float, None]
    max_pad_error_mm: Union[float, None]
    runner_up_deg: Union[int, None]
    runner_up_mm: Union[float, None]
    residuals_by_angle: tuple[tuple[int, float], ...]
    matched_pads: tuple[str, ...]
    ours_only: tuple[str, ...]
    vendor_only: tuple[str, ...]
    duplicate_numbers: tuple[str, ...]
    datum_offset_mm: Union[tuple[float, float], None]
    angle_decided: bool
    lands_agree: Union[bool, None]
    detail: str

    @property
    def decided(self) -> bool:
        """Both axes clean: the angle is known AND the lands are the same."""
        return self.verdict in DECIDED_VERDICTS

    def as_dict(self) -> dict:
        """JSON-ready form, for a report or an MCP result."""
        return {
            "verdict": self.verdict,
            "offset_deg": self.offset_deg,
            "residual_mm": self.residual_mm,
            "max_pad_error_mm": self.max_pad_error_mm,
            "runner_up_deg": self.runner_up_deg,
            "runner_up_mm": self.runner_up_mm,
            "residuals_by_angle": {str(a): r for a, r in self.residuals_by_angle},
            "matched_pads": list(self.matched_pads),
            "ours_only": list(self.ours_only),
            "vendor_only": list(self.vendor_only),
            "duplicate_numbers": list(self.duplicate_numbers),
            "datum_offset_mm": (list(self.datum_offset_mm)
                                if self.datum_offset_mm else None),
            "angle_decided": self.angle_decided,
            "lands_agree": self.lands_agree,
            "detail": self.detail,
        }


def _rotate_ccw(point: tuple[float, float], degrees: int) -> tuple[float, float]:
    """Rotate counter-clockwise ON SCREEN in a Y-DOWN frame.

    Both container formats put +Y downward, so the familiar
    ``(x cos - y sin, x sin + y cos)`` turns clockwise there. Getting this
    backwards is invisible at 0 and 180 and inverts the answer at 90 and 270 —
    which is why the sense is pinned by the human-confirmed pairs in the tests.
    """
    radians = math.radians(degrees)
    cos, sin = math.cos(radians), math.sin(radians)
    x, y = point
    return (x * cos + y * sin, -x * sin + y * cos)


def _centroid(points: Sequence[tuple[float, float]]) -> tuple[float, float]:
    n = len(points)
    return (sum(p[0] for p in points) / n, sum(p[1] for p in points) / n)


def _fit(ours: Sequence[tuple[float, float]],
         vendor: Sequence[tuple[float, float]],
         degrees: int) -> tuple[float, float]:
    """RMS and worst-pad distance for one candidate angle.

    Translation is removed by centroid alignment, which for a fixed rotation IS
    the least-squares-optimal translation — so the residual reported is the
    smallest achievable at that angle, and a datum difference between the two
    drawings never masquerades as a rotation.
    """
    ours_c = _centroid(ours)
    vendor_rotated = [_rotate_ccw(p, degrees) for p in vendor]
    vendor_c = _centroid(vendor_rotated)
    total = 0.0
    worst = 0.0
    for (ax, ay), (bx, by) in zip(ours, vendor_rotated):
        dx = (ax - ours_c[0]) - (bx - vendor_c[0])
        dy = (ay - ours_c[1]) - (by - vendor_c[1])
        squared = dx * dx + dy * dy
        total += squared
        worst = max(worst, math.sqrt(squared))
    return math.sqrt(total / len(ours)), worst


def _empty(verdict: str, detail: str, *, ours: Union[PadField, None] = None,
           vendor: Union[PadField, None] = None) -> OrientationMeasurement:
    ours_numbers = set(ours.numbers) if ours else set()
    vendor_numbers = set(vendor.numbers) if vendor else set()
    dupes = set(ours.duplicate_numbers if ours else ())
    dupes |= set(vendor.duplicate_numbers if vendor else ())
    return OrientationMeasurement(
        verdict=verdict, offset_deg=None, residual_mm=None,
        max_pad_error_mm=None, runner_up_deg=None, runner_up_mm=None,
        residuals_by_angle=(),
        matched_pads=tuple(sorted(ours_numbers & vendor_numbers)),
        ours_only=tuple(sorted(ours_numbers - vendor_numbers)),
        vendor_only=tuple(sorted(vendor_numbers - ours_numbers)),
        duplicate_numbers=tuple(sorted(dupes)),
        datum_offset_mm=None, angle_decided=False, lands_agree=None,
        detail=detail,
    )


def measure_orientation(ours: PadField,
                        vendor: Union[VendorFootprint, PadField, None],
                        ) -> OrientationMeasurement:
    """Compare two pad fields and report the rotation between them.

    Pure: same two fields in, same measurement out, every time.
    """
    if vendor is None:
        return _empty(VERDICT_NO_REFERENCE,
                      "no vendor package drawing for this part", ours=ours)
    vendor_field = vendor.pads if isinstance(vendor, VendorFootprint) else vendor
    if not vendor_field.centres:
        return _empty(VERDICT_NO_REFERENCE,
                      "vendor package drawing carries no pads",
                      ours=ours, vendor=vendor_field)

    shared = sorted(set(ours.centres) & set(vendor_field.centres))
    if len(shared) < 2:
        return _empty(
            VERDICT_INSUFFICIENT_OVERLAP,
            "%d pad number(s) shared between the drawings; two non-coincident "
            "pads are the minimum that can fix an orientation" % len(shared),
            ours=ours, vendor=vendor_field)

    ours_points = [ours.centres[n] for n in shared]
    vendor_points = [vendor_field.centres[n] for n in shared]

    # A pad field collapsed to a point (every shared pad at the same place)
    # fits every angle equally; say so rather than returning whichever angle
    # float noise happened to favour.
    ours_c = _centroid(ours_points)
    spread = max(math.dist(p, ours_c) for p in ours_points)
    if spread <= 1e-9:
        return _empty(VERDICT_INSUFFICIENT_OVERLAP,
                      "the shared pads are coincident, so no angle is "
                      "distinguishable", ours=ours, vendor=vendor_field)

    fits = {angle: _fit(ours_points, vendor_points, angle)
            for angle in CANDIDATE_ANGLES}
    ranked = sorted(CANDIDATE_ANGLES, key=lambda a: (fits[a][0], a))
    best, runner_up = ranked[0], ranked[1]
    best_rms, best_max = fits[best]
    runner_rms = fits[runner_up][0]

    # AXIS 1 — is the angle decided? The runner-up must be worse by BOTH a
    # ratio and an absolute margin; see SEPARATION_FLOOR_MM for why the ratio
    # alone is not enough.
    decided = (runner_rms - best_rms > SEPARATION_FLOOR_MM
               and runner_rms >= best_rms * SEPARATION_RATIO)

    residuals = tuple((a, round(fits[a][0], _ROUND)) for a in CANDIDATE_ANGLES)
    # Where the VENDOR's drawing origin lands in OUR footprint's local frame
    # once the two pad fields are laid on top of each other. Free to compute
    # and worth reporting: it is the datum difference, which is a separate
    # defect from a rotation and would otherwise be invisible (the fit removes
    # it by construction).
    vendor_rotated = [_rotate_ccw(p, best) for p in vendor_points]
    vendor_c = _centroid(vendor_rotated)
    datum = (round(ours_c[0] - vendor_c[0], _ROUND),
             round(ours_c[1] - vendor_c[1], _ROUND))

    # OFFSET ONLY WHERE THE ANGLE WAS DECIDED. `best` is the best-FITTING
    # angle whether or not anything separates it from its runner-up, so putting
    # it in the common fields unconditionally would hand an undecided
    # measurement a numeric offset beside `angle_decided=False` — a guess
    # wearing a number, which is exactly what this dataclass promises not to
    # carry. The diagnostics (`residuals_by_angle`, the runner-up, the
    # residuals) still report `best` so a reader can see WHY it did not settle.
    common = dict(
        offset_deg=best if decided else None,
        residual_mm=round(best_rms, _ROUND),
        max_pad_error_mm=round(best_max, _ROUND),
        runner_up_deg=runner_up,
        runner_up_mm=round(runner_rms, _ROUND),
        residuals_by_angle=residuals,
        matched_pads=tuple(shared),
        ours_only=tuple(sorted(set(ours.centres) - set(vendor_field.centres))),
        vendor_only=tuple(sorted(set(vendor_field.centres) - set(ours.centres))),
        duplicate_numbers=tuple(sorted(set(ours.duplicate_numbers)
                                       | set(vendor_field.duplicate_numbers))),
        datum_offset_mm=datum,
        angle_decided=decided,
        lands_agree=(best_rms <= LAND_TOL_MM) if decided else None,
    )

    if not decided:
        return OrientationMeasurement(
            verdict=VERDICT_AMBIGUOUS,
            detail=("%d deg fits at %.3f mm but %d deg fits at %.3f mm — the "
                    "pad field is symmetric enough that the numbering does not "
                    "settle it" % (best, best_rms, runner_up, runner_rms)),
            **common)

    # AXIS 2 — at the decided angle, are these the same land pattern at all?
    if best_rms > LAND_TOL_MM:
        return OrientationMeasurement(
            verdict=VERDICT_GEOMETRY_MISMATCH,
            detail=("the angle is settled at %d deg (next-best %d deg at "
                    "%.3f mm), but the %d shared pads still sit %.3f mm RMS "
                    "apart (worst %.3f mm) — these are not the same land "
                    "pattern, so check the part number before trusting the "
                    "pairing"
                    % (best, runner_up, runner_rms, len(shared), best_rms,
                       best_max)),
            **common)

    if best == 0:
        return OrientationMeasurement(
            verdict=VERDICT_ALIGNED,
            detail=("our drawing matches the vendor's orientation; %d shared "
                    "pads agree to %.3f mm RMS (worst %.3f mm)"
                    % (len(shared), best_rms, best_max)),
            **common)

    return OrientationMeasurement(
        verdict=VERDICT_ROTATED,
        detail=("our drawing is the vendor's rotated %d deg counter-clockwise; "
                "%d shared pads agree to %.3f mm RMS (worst %.3f mm) at that "
                "angle, next-best %d deg at %.3f mm"
                % (best, len(shared), best_rms, best_max, runner_up,
                   runner_rms)),
        **common)


def measure_footprint_against_part(parsed_footprint: Mapping[str, Any],
                                   vendor_payload: Union[Mapping[str, Any], None],
                                   lcsc: Union[str, None] = None,
                                   ) -> OrientationMeasurement:
    """Convenience: parsed ``.kicad_mod`` + cached vendor payload -> verdict.

    ``vendor_payload`` may be ``None`` (nothing cached for this part), which is
    the :data:`VERDICT_NO_REFERENCE` path rather than an error.
    """
    ours = our_pad_field(parsed_footprint)
    vendor = (parse_vendor_payload(vendor_payload, lcsc=lcsc)
              if vendor_payload is not None else None)
    return measure_orientation(ours, vendor)
