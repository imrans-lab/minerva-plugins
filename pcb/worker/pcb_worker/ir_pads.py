"""Neutral IR pad projection — the ONE owner of what a placed pad IS.

Two facts live here because two independent consumers need them, and a second
interpretation of either is a SAFETY defect rather than a style problem:

  * the footprint ``source_id`` -> HUMAN pad-number correlation (a
    :class:`PlacedPad` carries only ``"pad:1:0"``; the human ``"1"`` lives on the
    footprint pad), and
  * the copper LAND SHAPE of a placed pad, resolved through the neutral land
    owner (:func:`pad_source.placed_pad_to_geom` + :func:`pad_source.th_land`) —
    the same owner the CAM emitters shape fabricated copper with.

Consumers: geometric copper DRC (:mod:`drc_geometric`, which owns these two
facts' first implementation) and canonical routing (:mod:`route_bridge`, Round E
019f783860c8). CHECKED copper, ROUTED keepouts and FABRICATED copper are
therefore shaped by one code path and cannot drift apart.

FAIL-SAFE DIRECTION (inherited from :mod:`drc_geom_primitives` — do NOT invert)
------------------------------------------------------------------------------
Every shape returned here is EXACT or a SUPERSET of the real copper. A DRC
consumer may therefore raise a false violation; a routing consumer may
over-block. Neither may ever UNDER-state copper: an under-stated land lets a
router lay a trace through real copper, which is the fail-closed-ruling violation
Round E exists to remove.

Anything this module cannot model faithfully raises :class:`UnsupportedGeometry`
— never a nominal/guessed size. Callers turn that into their own fail-closed
reply (DRC: the indeterminate union; routing: zero routes + diagnostics).
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any, Iterator

from .drc_geom_primitives import Capsule, OrientedRect
from .geometry import rotation_radians
from .pad_source import placed_pad_to_geom, th_land
from .resolved_board import LayerRole, ResolvedBoard

# The IR pad_type literal for a bare mechanical (non-plated) through hole. Shared
# with pad_source's classification rather than re-spelled per consumer.
NPTH_PAD_TYPE = "np_thru_hole"


class UnsupportedGeometry(Exception):
    """Raised when a projection meets geometry it cannot model faithfully.

    Caught by :func:`drc_geometric.run_geometric_drc` (-> the INDETERMINATE
    union) and by the routing bridge (-> zero routes + diagnostics). One
    exception type across IR consumers, so a new fail-closed reason is honoured
    by every caller the moment it is raised.
    """


@dataclass(frozen=True)
class LandDisc:
    """The copper land of a drilled pad, as the annular check needs it."""

    kind: str                      # round|rect
    dia_mm: float | None = None    # round land diameter
    w_mm: float | None = None      # rect land width
    h_mm: float | None = None      # rect land height

    def min_reach(self) -> float:
        """Smallest copper reach from the land centre to its boundary — the nearest
        edge. For a round land, the radius; for a rectangle, half its MINOR side
        (a roundrect's mid-edge is unaffected by its corners, so this stays exact
        for the nearest edge, and conservative elsewhere)."""
        if self.kind == "round":
            return (self.dia_mm or 0.0) / 2.0
        return min(self.w_mm or 0.0, self.h_mm or 0.0) / 2.0


@dataclass(frozen=True)
class IRPad:
    """One placed pad plus the correlations every consumer re-derives otherwise."""

    component: Any                 # ResolvedComponent
    pad: Any                       # PlacedPad
    source_number: str             # pad.source_id — what PadGeom messages name
    number: str                    # DISPLAY token: human number, else source_id
    human_number: str | None       # AUTHORED identity; None when the pad has none
    net_name: str | None
    is_drilled: bool
    is_npth: bool

    @property
    def ref(self) -> str:
        return self.component.ref

    @property
    def carries_copper(self) -> bool:
        """Whether this placed KiCad pad primitive actually participates in copper.

        ``pad_type == smd`` is not sufficient: KiCad represents split stencil
        apertures as unnumbered SMD pad nodes on F.Paste/B.Paste only.  Copper is
        therefore a layer-participation fact, not a pad-type inference.
        """
        if self.is_npth:
            # KiCad commonly writes NPTH pads on ``*.Cu`` to make the hole span
            # the stack; the pad type still means there is no plated land/ring.
            return False
        return any(layer.role is LayerRole.COPPER for layer in self.pad.layers)

    @property
    def is_addressable(self) -> bool:
        """True when this pad can be NAMED by a user or a net ref.

        Nets are spelled "U1.2", hints reference "U1.2", the panel labels "U1.2" —
        all of it keyed on the AUTHORED pad number. A pad without one cannot be a
        routed endpoint, but it can still be perfectly good copper or a bare
        mechanical hole (019f97eb6adf): KiCad legitimately leaves NPTH mechanical
        pads unnumbered, and PadDefinition permits number="". Consumers that need
        an addressable endpoint check this; consumers that only need GEOMETRY
        (hole primitives, keepouts, copper checks) must not.
        """
        return self.human_number is not None


def pad_number_map(definition) -> dict[str, str]:
    """Footprint pad ``source_id`` -> human pad number, for one footprint."""
    return {fpad.source_id: fpad.number for fpad in definition.pads}


def iter_ir_pads(rb: ResolvedBoard) -> Iterator[IRPad]:
    """Every placed pad on the board, with its human number and net name.

    The single owner of the source_id/number correlation and the NPTH
    classification — consumers branch on :attr:`IRPad.carries_copper` rather than
    re-spelling the pad-type literal.
    """
    net_names = {net.id: net.name for net in rb.nets}
    for comp in rb.components:
        numbers = pad_number_map(rb.footprint_for(comp))
        for pad in comp.placed_pads:
            source_number = pad.source_id
            # NEUTRAL, PERMISSIVE (019f97eb6adf). An empty authored number is
            # preserved as `human_number=None` rather than rejected here: this
            # iterator serves geometry consumers too, and an unnumbered NPTH
            # mechanical pad is fully modelable copper-free geometry. Endpoint
            # ADDRESSABILITY is a routing concern and is enforced there, on
            # `is_addressable` — baking "every pad is an endpoint" into the shared
            # iterator would make geometric DRC indeterminate for a hole it models
            # exactly. `number` stays a display token so findings can still name
            # something stable.
            human_number = numbers.get(source_number) or None
            yield IRPad(
                component=comp,
                pad=pad,
                source_number=source_number,
                number=human_number or source_number,
                human_number=human_number,
                net_name=net_names.get(pad.net_id),
                is_drilled=pad.drill is not None,
                is_npth=pad.pad_type == NPTH_PAD_TYPE,
            )


def pad_land(pad, number: str, ref: str) -> tuple[LandDisc, Any]:
    """The copper LAND of a through-hole pad — resolved through the NEUTRAL OWNER
    (``placed_pad_to_geom`` + ``th_land``), NOT reinterpreted here. This is the DRY
    call site mandated by Codex #3: the CAM emitters shape the exact same land, so
    fabricated, checked and ROUTED copper cannot drift.

    Returns ``(LandDisc, shape)`` where ``shape`` is the exact/superset geometry
    primitive. Raises :class:`UnsupportedGeometry` for a land the owner cannot
    classify into a modelable family — fail-closed rather than guess."""
    geom = placed_pad_to_geom(pad, number)
    shaped, shape_token, w, h, _rr = th_land(geom)
    # The land turns the way the PLACEMENT does: this frame's Y grows
    # downward, so the angle is negated before any rotation matrix
    # (geometry.rotation_radians). A 45-degree pad checked with the raw
    # radians() lands mirrored about the pad centre versus its own copper.
    angle = rotation_radians(pad.rotation_deg)
    if not shaped:
        # Round annulus: the neutral owner exposes the land DIAMETER as PadGeom.annulus.
        dia = geom.annulus
        if dia is None or not math.isfinite(dia) or dia <= 0:
            raise UnsupportedGeometry(
                f"pad {ref}.{number}: through-hole land has no usable round-annulus "
                f"diameter from the neutral owner (annulus={dia!r})")
        land = LandDisc(kind="round", dia_mm=float(dia))
        shape = Capsule.disc(pad.position[0], pad.position[1], float(dia) / 2.0)
        return land, shape
    # Shaped land (oblong / authored-cornered rect / roundrect). rect + roundrect
    # are modeled by the bounding oriented rectangle (superset of copper);
    # anything else the owner would have failed upstream.
    if shape_token not in ("rect", "roundrect", "oval"):
        raise UnsupportedGeometry(
            f"pad {ref}.{number}: through-hole land shape {shape_token!r} has no "
            f"modelable copper primitive")
    land = LandDisc(kind="rect", w_mm=float(w), h_mm=float(h))
    shape = OrientedRect(pad.position[0], pad.position[1],
                         float(w) / 2.0, float(h) / 2.0, angle)
    return land, shape


def smd_shape(pad, number: str, ref: str) -> Any:
    """The copper land of a surface-mount pad, through the same neutral owner."""
    geom = placed_pad_to_geom(pad, number)
    w, h = geom.width, geom.height
    if w is None or h is None:
        # A sizeless SMD pad should never reach the IR (compiler fail-closes), but
        # be defensive rather than emit copper we cannot model.
        raise UnsupportedGeometry(
            f"pad {ref}.{number}: SMD pad has no copper size in the IR")
    angle = rotation_radians(pad.rotation_deg)  # y-down convention, as in pad_land
    if geom.shape == "circle":
        return Capsule.disc(pad.position[0], pad.position[1], float(w) / 2.0)
    return OrientedRect(pad.position[0], pad.position[1],
                        float(w) / 2.0, float(h) / 2.0, angle)


def pad_copper_shape(ir_pad: IRPad) -> Any:
    """The copper primitive of a copper-bearing pad, drilled or not.

    Raises :class:`UnsupportedGeometry` for an NPTH pad: a bare mechanical hole
    has NO land, so asking for its copper is a caller bug, and inventing an
    answer would put phantom copper on the board. Callers gate on
    :attr:`IRPad.carries_copper`.
    """
    if ir_pad.is_npth:
        raise UnsupportedGeometry(
            f"pad {ir_pad.ref}.{ir_pad.number}: NPTH pads carry no copper land")
    if ir_pad.is_drilled:
        return pad_land(ir_pad.pad, ir_pad.source_number, ir_pad.ref)[1]
    return smd_shape(ir_pad.pad, ir_pad.source_number, ir_pad.ref)
