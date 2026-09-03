"""EVERY OPENING DRILLED THROUGH THE BOARD, in its TRUE shape, board frame.

The 3D substrate needs to know what is not there. That question is already
answered three times in this worker and none of the three answers is usable
here, which is why this module exists rather than a call:

* ``gerber.harvest_geometry`` — the ink the fab receives. Its ``holes`` bucket is
  ``(x, y, DIAMETER, plated)``: round, always. The IR-native harvest REFUSES a
  non-round board hole outright (``gerber.py``: "the round-only fabrication path
  cannot drill"), and a pad's drill is reduced to a scalar by taking its X axis
  (``pad_source._from_resolved``). Cutting from that bucket would make an oval
  slot come out round, which is exactly what this task must not do.
* ``drc_geometric`` — capsules, and it models Round/Oval/Slot faithfully, but it
  is deliberately SUPERSET-biased where it is unsure: an oblong PAD drill is
  over-approximated as a disc of the MAJOR axis, because a checker must never
  under-state a hazard. A mesh built from a superset would cut away board that
  is really there.
* ``texture_bake`` — punches the harvest's round discs out of the image alpha.

So: read the IR, and model each opening as a CAPSULE CORE (a polyline swept by a
radius). One primitive covers all three hole features and both pad-drill shapes,
and it is the shape ``pyclipper``'s round-joined offset produces exactly — no
hand-rolled circle tessellation anywhere in the path.

WHAT IS INCLUDED, AND THE EVIDENCE FOR IT
-----------------------------------------
Board holes (mounting / NPTH / PTH), through-hole PAD drills, and VIAS: all of
them, cut for real. Vias were expected to be PAINTED instead, on the argument
that forty tiny cylinders buy nothing at a sane viewing distance. Measured, that
argument does not survive: :mod:`texture_bake` already punches every via out of
the texture's ALPHA (it iterates the whole ``g.holes`` bucket), so a via that the
mesh does not cut is a fully transparent pinprick in a solid slab — a hole you
can see through with no barrel wall behind it, which is worse than either
honest answer. Painting vias properly would mean changing what the BAKE draws,
which belongs to that module and that task. The cost of cutting them IS real
and was measured rather than guessed: on smart-remote-v2 rev B, cutting its 42
vias (0.4 and 0.6 mm drills) takes the substrate from 5,272 to 7,816 triangles —
a third of the mesh for 2,544 triangles, which is a large proportion of a very
small number. If the owner would rather have them painted, the change is in two
places at once (here, and the bake's alpha punch), never in this one alone.

ROTATION IS NOT RE-DERIVED HERE. An oval hole's major axis goes through
``geometry.rotate_local_offset``, the worker's ONE rotation, for the reason
``drc_geometric`` spells out at length: the angle is clockwise in a Y-down frame
and must be negated first, and every multiple of 90 degrees hides the difference
under the oval's own symmetry, so only an off-axis slot ever exposes a hand-
rolled matrix as wrong.

NOTHING TODAY CAN DELIVER A NON-ROUND OPENING — verified, not assumed:
``compile_board._check_pad_capabilities`` refuses any drill outside the v1 round
subset AND any round-shaped drill whose axes disagree, and no compile path
constructs an ``OvalHole`` or a ``SlotHole`` at all. The oval and slot branches
below are therefore unreachable from a compiled board today. They are written
anyway, and tested against a hand-built IR, because the IR carries the types and
the first board that gets a slot must not discover that the renderer rounds it
off.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum

from .geometry import rotate_local_offset
from .resolved_board import (
    OvalHole,
    ResolvedBoard,
    RoundHole,
    SlotHole,
)

Point = tuple[float, float]


class DrillOrigin(str, Enum):
    """Which kind of entity asked for the hole. Carried so a consumer can
    report what it cut, and so a future "leave the vias alone" policy has
    something to select on without re-deriving the geometry."""

    BOARD_HOLE = "board_hole"      # mounting / NPTH / PTH board-level holes
    PAD = "pad"                    # a through-hole pad's drill
    VIA = "via"


@dataclass(frozen=True)
class DrillOpening:
    """One opening as a capsule: ``core`` swept by ``radius_mm``.

    A single-point ``core`` is a plain round bore — the degenerate capsule.
    Two points are an oval or an oblong pad drill; more are a routed slot.
    Coordinates are BOARD-frame millimetres (X right, Y down), the frame the
    IR itself is in, so nothing here converts anything.
    """

    id: str
    origin: DrillOrigin
    core: tuple[Point, ...]
    radius_mm: float
    plated: bool

    @property
    def is_round(self) -> bool:
        return len(self.core) == 1


def drill_openings(board: ResolvedBoard) -> tuple[DrillOpening, ...]:
    """Every drilled opening in ``board``, board-level holes first.

    Order is board holes, then pad drills in component order, then vias — the
    order the IR carries them in, so two runs over one board produce byte-equal
    output.
    """
    out: list[DrillOpening] = []
    for hole in board.holes:
        out.append(_from_feature(hole.id, hole.feature, hole.plated))
    for component in board.components:
        for pad in component.placed_pads:
            opening = _from_pad_drill(component.ref, pad)
            if opening is not None:
                out.append(opening)
    for via in board.vias:
        out.append(DrillOpening(id=via.id, origin=DrillOrigin.VIA,
                                core=(via.position,), radius_mm=via.drill_mm / 2.0,
                                plated=True))
    return tuple(out)


def _from_feature(hole_id: str, feature, plated: bool) -> DrillOpening:
    """A board-level hole feature as a capsule."""
    if isinstance(feature, RoundHole):
        return DrillOpening(id=hole_id, origin=DrillOrigin.BOARD_HOLE,
                            core=(feature.position,),
                            radius_mm=feature.diameter_mm / 2.0, plated=plated)
    if isinstance(feature, OvalHole):
        core = _oval_core(feature.position, feature.width_mm, feature.height_mm,
                          feature.rotation_deg)
        return DrillOpening(id=hole_id, origin=DrillOrigin.BOARD_HOLE, core=core,
                            radius_mm=min(feature.width_mm, feature.height_mm) / 2.0,
                            plated=plated)
    if isinstance(feature, SlotHole):
        return DrillOpening(id=hole_id, origin=DrillOrigin.BOARD_HOLE,
                            core=tuple(feature.path),
                            radius_mm=feature.width_mm / 2.0, plated=plated)
    raise TypeError(
        f"hole {hole_id!r}: unsupported hole feature {type(feature).__name__}; "
        f"refusing to guess a shape for it rather than cutting the wrong opening")


def _from_pad_drill(ref: str, pad) -> DrillOpening | None:
    """A through-hole pad's drill, or ``None`` for an SMD land."""
    drill = pad.drill
    if drill is None:
        return None
    dx, dy = float(drill.size[0]), float(drill.size[1])
    if dx <= 0.0 or dy <= 0.0:
        return None
    identifier = f"{ref}:{pad.id}"
    if dx == dy:
        return DrillOpening(id=identifier, origin=DrillOrigin.PAD,
                            core=(pad.position,), radius_mm=dx / 2.0,
                            plated=bool(drill.plated))
    # OBLONG pad drill. The DrillDefinition carries no angle of its own, so the
    # major axis follows the PAD's rotation — the same assumption drc_geometric
    # makes; unlike that one, this keeps the true stadium instead of widening it
    # to a disc of the major axis, because cutting a superset would remove board
    # that is really there.
    return DrillOpening(id=identifier, origin=DrillOrigin.PAD,
                        core=_oval_core(pad.position, dx, dy, pad.rotation_deg),
                        radius_mm=min(dx, dy) / 2.0, plated=bool(drill.plated))


def _oval_core(position: Point, width_mm: float, height_mm: float,
               rotation_deg: float) -> tuple[Point, Point]:
    """The two ends of an oval's core segment, in the board frame.

    The core is the major axis shortened by the minor diameter, so sweeping it
    by the minor radius reproduces the oval exactly. Local axis is X when the
    oval is wider than it is tall, otherwise Y — the convention
    ``drc_geometric._hole_capsules`` states and both must keep.
    """
    minor = min(width_mm, height_mm)
    half = (max(width_mm, height_mm) - minor) / 2.0
    dx, dy = rotate_local_offset(*((half, 0.0) if width_mm >= height_mm
                                   else (0.0, half)), rotation_deg)
    cx, cy = position
    return ((cx - dx, cy - dy), (cx + dx, cy + dy))
