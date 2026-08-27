"""Canonical component-placement geometry for the PCB worker.

Single source of truth for the KiCad footprint-placement transform: rotate a
component-LOCAL offset by the placement angle, and translate it to the
component's board position. gerber.py, drc.py and route_bridge.py all delegate
here so there is exactly ONE rotation implementation in pcb_worker (DRY), and
no path can silently drift to a different sign.

Rotation convention (pinned by tests/test_rotation.py against a real
KiCad-authored fixture):

    KiCad applies a footprint ``(at x y rot)`` angle CLOCKWISE in the file's
    coordinate frame (Y grows downward) — i.e. negate the angle before applying
    the standard CCW rotation matrix (``math.radians(-deg)``). This is the exact
    convention the agent_router KiCad reader encodes
    (``kicad_io._transform_position`` uses ``radians(-rotation)``), which is the
    ground truth. The previous ``+deg`` (CCW) form flashed pads MIRRORED about
    the component centre versus KiCad, so a connector authored at rotation 90
    landed off its routed trace endpoints (docket 019f3ba0f455).

    0 deg is rotation-invariant and short-circuits (returns the inputs
    unchanged, exactly — no float drift), so the rotation_deg=0 gerber goldens
    are unaffected by the sign fix.

    (Boards authored in the pcb-architect dialect use the OPPOSITE sign for their
    ``rotation`` field; reconciling that is an IMPORT-layer concern — negate at
    import — not this worker's, whose rotation_deg is defined as KiCad-equivalent.)

Equivalence note (why consolidating three call sites is safe): route_bridge's
former hand-written ``radians(+deg)`` matrix ``(px·cos d + py·sin d,
−px·sin d + py·cos d)`` is algebraically IDENTICAL to the ``radians(-deg)`` form
here — expand ``cos(-d)=cos d`` and ``sin(-d)=−sin d`` and both collapse to the
same closed form. tests/test_geometry.py proves this across many angles.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Any

# The single authority for the placement-convention version.  Any change to the
# rotation sign or bottom-side mirror below MUST bump this so a downstream
# consumer (e.g. the K2 compiler's board provenance) records a detectable
# identity change rather than silently re-placing geometry under the old label.
TRANSFORM_VERSION = "kicad-flip-v1"

from .resolved_board import (
    ArcGeometry,
    CircleGeometry,
    GraphicGeometry,
    Layer,
    LineGeometry,
    PolygonGeometry,
    Side,
)


#: Single source of truth for the top/bottom side-token vocabulary (docket
#: 019fc3105828 — this table used to be hand-copied at compile_board.py's and
#: assembly_outputs.py's own ``_resolve_side`` in addition to here). Public
#: (no leading underscore) so those two modules can import and read the SAME
#: frozensets rather than re-typing the token list — one source for what a
#: "top"/"bottom" token IS, while each caller keeps its own refusal shape
#: (return None vs. raise AssemblyBoardError vs. raise ValueError) local, on
#: purpose: unifying the token set is DRY, unifying error handling is a
#: different, un-asked-for change across call sites with different failure
#: contracts.
TOP_LAYER_NAMES = frozenset({"top", "f.cu", "front"})
BOTTOM_LAYER_NAMES = frozenset({"bottom", "b.cu", "back"})


def is_top(layer: Any) -> bool:
    """Which fabricable side a copper item is on.

    FAILS CLOSED (docket 019fb5869f3f): a *named* layer outside the two
    fabricable sides raises instead of silently bucketing onto top — the old
    "not bottom, therefore top" rule put in1..in30 copper on the top
    Gerber/DRC layer, one level below the compile step's 2-layer refusal.
    An *unspecified* layer (None / empty string) still defaults to top:
    absence is the legacy shape for "the default side", not a claim about a
    layer this pipeline cannot fabricate.
    """
    if layer is None:
        return True
    name = str(layer).strip().lower()
    if not name or name in TOP_LAYER_NAMES:
        return True
    if name in BOTTOM_LAYER_NAMES:
        return False
    raise ValueError(
        f"is_top: unrecognized copper layer {layer!r} — this 2-layer pipeline "
        "fabricates only top/bottom (F.Cu/B.Cu); refusing to default it to top"
    )


def rotation_radians(deg: float) -> float:
    """A KiCad placement/land angle as RADIANS for this y-down board frame.

    The one conversion for any consumer that feeds an angle to a rotation matrix
    of its own — an oriented land rectangle, a mask aperture — rather than going
    through :func:`rotate_local_offset`. Plain ``math.radians`` turns such a
    primitive the WRONG WAY: the angle is clockwise in a frame whose Y grows
    downward (see the module docstring), so it is negated before the standard
    CCW matrix. Every multiple of 90 hides the difference under the rectangle's
    own symmetry; a 45-degree land does not.
    """
    return math.radians(-deg)


def rotate_local_offset(px: float, py: float, deg: float) -> tuple[float, float]:
    """Rotate a component-LOCAL pad offset by *deg* using KiCad's footprint-angle
    convention, so the resulting flash lands on KiCad's own absolute pad position.

    See the module docstring for the full clockwise-convention rationale (KiCad
    negates the angle; pinned by tests/test_rotation.py; docket 019f3ba0f455).

    0 deg is rotation-invariant and short-circuits, returning the inputs
    unchanged (exact, no float drift).
    """
    if deg == 0.0:
        return px, py
    r = rotation_radians(deg)
    c, s = math.cos(r), math.sin(r)
    return px * c - py * s, px * s + py * c


def place_point(cx: float, cy: float, deg: float,
                lx: float, ly: float) -> tuple[float, float]:
    """Rotate a component-LOCAL point (lx, ly) by *deg* (via ``rotate_local_offset``)
    and translate by the component's board placement (cx, cy) — the exact pad
    convention KiCad's reader (kicad_io._transform_position) applies."""
    ox, oy = rotate_local_offset(lx, ly, deg)
    return cx + ox, cy + oy


@dataclass(frozen=True)
class PlacementTransform:
    """Place footprint-local geometry on either board side.

    KiCad's bottom-side footprint operation mirrors the local Y axis before
    applying the footprint rotation.  The same reflection swaps explicit
    front/back technical layers and negates local feature orientation.  Layer
    wildcards (for example ``*.Cu`` and ``*.Mask``) deliberately survive.

    The convention is pinned by ``k1_bottom_oracle.kicad_pcb``, generated by
    pcbnew 9.0.9 from an asymmetric top-side footprint and evaluated after a
    native ``FOOTPRINT.Flip`` operation.
    """

    position: tuple[float, float]
    rotation_deg: float
    side: Side

    def __post_init__(self) -> None:
        if (not isinstance(self.position, tuple) or len(self.position) != 2
                or any(isinstance(v, bool) or not isinstance(v, (int, float))
                       or not math.isfinite(v) for v in self.position)):
            raise ValueError("PlacementTransform.position must be a finite tuple")
        if (isinstance(self.rotation_deg, bool)
                or not isinstance(self.rotation_deg, (int, float))
                or not math.isfinite(self.rotation_deg)):
            raise ValueError("PlacementTransform.rotation_deg must be finite")
        if not isinstance(self.side, Side):
            raise TypeError("PlacementTransform.side must be a Side")

    def point(self, local: tuple[float, float]) -> tuple[float, float]:
        """Transform one immutable footprint-local point to board coordinates."""
        if (not isinstance(local, tuple) or len(local) != 2
                or any(isinstance(v, bool) or not isinstance(v, (int, float))
                       or not math.isfinite(v) for v in local)):
            raise ValueError("local point must be a finite tuple")
        lx, ly = local
        if self.side is Side.BOTTOM:
            ly = -ly
        return place_point(
            self.position[0], self.position[1], self.rotation_deg, lx, ly,
        )

    def angle(self, local_degrees: float) -> float:
        """Transform a local feature orientation to KiCad board orientation."""
        if (isinstance(local_degrees, bool)
                or not isinstance(local_degrees, (int, float))
                or not math.isfinite(local_degrees)):
            raise ValueError("local angle must be finite")
        combined = (self.rotation_deg + local_degrees
                    if self.side is Side.TOP
                    else self.rotation_deg - local_degrees)
        return combined % 360.0

    def layer(self, local: Layer) -> Layer:
        return local if self.side is Side.TOP else local.flipped()

    def layers(self, local: tuple[Layer, ...]) -> tuple[Layer, ...]:
        return tuple(self.layer(layer) for layer in local)

    def graphic(self, local: GraphicGeometry) -> GraphicGeometry:
        """Transform every supported graphic primitive without special cases."""
        if isinstance(local, LineGeometry):
            return LineGeometry(self.point(local.a), self.point(local.b))
        if isinstance(local, CircleGeometry):
            return CircleGeometry(self.point(local.center), local.radius_mm)
        if isinstance(local, ArcGeometry):
            return ArcGeometry(
                self.point(local.start), self.point(local.mid), self.point(local.end),
            )
        if isinstance(local, PolygonGeometry):
            return PolygonGeometry(tuple(self.point(point) for point in local.points))
        raise TypeError(f"unsupported graphic geometry {type(local)!r}")


def _placement_num(value: Any) -> float:
    """One placement field of a board dict as a float; unreadable reads as 0.0.

    The tolerant reading the loose-dict consumers have always applied to an
    absent or junk coordinate — they must still produce a board to look at.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    return float(value)


def component_transform(comp: dict) -> PlacementTransform:
    """The board placement of one canonical-board COMPONENT dict.

    THE placement rule for the loose-dict readers (connectivity DRC), built from
    the same three authored facts ``compile_board._place_component`` reads —
    ``x_mm``/``y_mm``, ``rotation_deg`` and ``layer`` — and returning the same
    :class:`PlacementTransform` it builds. Rotation and the BOTTOM-side mirror
    therefore cannot be applied on the compiled path and skipped on the raw one,
    which is exactly how a bottom-mounted part's pads came to be checked at the
    position its top-side twin would occupy.

    An unrecognized ``layer`` raises through :func:`is_top`: a component on a
    layer this pipeline cannot fabricate has no side to be placed on.
    """
    return PlacementTransform(
        position=(_placement_num(comp.get("x_mm")),
                  _placement_num(comp.get("y_mm"))),
        rotation_deg=_placement_num(comp.get("rotation_deg")),
        side=Side.TOP if is_top(comp.get("layer")) else Side.BOTTOM,
    )
