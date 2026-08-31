"""WHERE an assembly house puts its nozzle — the resolved anchor of every
physical placement.

A component's ``x_mm``/``y_mm`` place the FOOTPRINT ORIGIN, the datum the
``.kicad_mod`` states its pad offsets against, and where that datum sits on the
part is a property of the footprint. Measured over ``pcb/library/footprints``
(39 footprints): 14 put their origin on pin 1, and 18 resolve an anchor
somewhere other than their origin — so emitting the placement position as a
pick-and-place coordinate is wrong by up to half a package, and by 30.85 mm on
the DevKit socket set. The house is told where to CENTRE the part.

THE ANCHOR IS THE BODY BOX CENTRE, exactly: the centre of the axis-aligned
bounding box of the part's body, in footprint-local millimetres, put through the
component's own placement transform. Deliberately NOT an area centroid — a
nozzle centres on the extent of what it picks up, and every basis is a box.

AN EXPANSION CHILD MAY STATE ITS OWN ANCHOR, and needs to whenever the drawing
spreads several parts across itself. A child carries NO geometry — the parent's
footprint draws all of it — so with nothing authored every child inherits the
one anchor measured off the parent's whole body. Right when the drawing is the
part; wrong for the DevKit socket set, whose two 1x22 rows have their own
centres at (-11.43, 26.67) and (+11.43, 26.67) while the parent's fab box
centres at (0, 30.8485), between the rows and on neither — and wrong QUIETLY,
because two anchors the correct distance apart clear the spacing gate.
``assembly.placements[].anchor_mm`` is that answer, stated in the placement's
own local frame and composed through the same child transform a measured anchor
is. It records the basis :data:`resolved_board.ANCHOR_BASIS_AUTHORED`, so a
reader is never told a figure a person wrote down was measured off a drawing.

THE BASIS LADDER (:data:`resolved_board.ANCHOR_BASES` names the three MEASURED
outcomes):

1. ``fab_outline`` — the fab-layer body outline, which is KiCad's own assembly
   drawing, drawn for exactly this audience.
2. ``lands`` — every pad's box, for a footprint that draws no fab outline. The
   two bases agree on every seed footprint carrying both, except where lands are
   measurably wrong: a JST horizontal header's lands are its surface-mount tabs,
   0.6 mm off the connector body the fab layer draws.
3. ``footprint_origin`` — the honest fallback, RECORDED rather than inferred, for
   a footprint with neither a fab outline nor a sized land (silk-only furniture:
   a logo, a revision legend).

SILK IS NOT A BASIS: it is drawn deliberately asymmetric — a cathode bar, a
pin-1 dot, a polarity chevron — so its box is off the part it draws (measured
here, ``D_SMA``'s silk box centre sits 3.05 mm from its fab box centre,
``SOT-23``'s 0.39 mm). THE COURTYARD IS NOT A BASIS EITHER: it is a keep-out
envelope drawn larger than the part, by different margins on different edges
(``PinSocket_1x07`` 0.025 mm off its fab centre, the DevKit socket set 3.08 mm).

TRANSFORM COMPOSITION. Every placement is composed with ONE object, the same
:class:`geometry.PlacementTransform` the compiler places copper with, so an
anchor cannot drift from the pads it belongs to::

    anchor_board = T(component).point(anchor_local)

A synthetic expansion nests a second transform inside the first. An authored
``offset_mm`` is stated in the PARENT's local frame, before the parent's
rotation and side, so the child's origin is ``T(parent).point(offset)`` and its
angle is ``T(parent).angle(child_rotation)`` — which on the BOTTOM side
SUBTRACTS the child's rotation rather than adding it, because a reflection
conjugates a rotation into its inverse (``M·R(r) = R(-r)·M``). Building the child
as its own ``PlacementTransform`` from those two numbers is algebraically
identical to composing in the parent's local frame, and is the form the CPL, the
BOM's quantities and a preview all read.

THE EMITTED FRAME IS SOMEONE ELSE'S JOB. Everything here is in the board's
Y-DOWN millimetre frame; ``assembly_outputs`` negates Y at its own row boundary
(see ``docs/assembly-outputs.md``). That negation is also what makes a verbatim
``rotation_deg`` read as JLCPCB's counter-clockwise-positive convention, so the
equivalence is a property of the pair and is proven where the pair meets, in
``tests/test_assembly_anchor.py``.
"""

from __future__ import annotations

from .assembly_spec import AssemblyPlacementSpec
from .geometry import PlacementTransform
from .refdes_anchor import fab_extent_from_definition, land_extent_from_definition
from .resolved_board import (
    ANCHOR_BASIS_AUTHORED,
    ANCHOR_BASIS_FAB,
    ANCHOR_BASIS_LANDS,
    ANCHOR_BASIS_ORIGIN,
    PhysicalPlacement,
    Placement,
)


def _specs(component_ref: str, assembly) -> tuple[AssemblyPlacementSpec, ...]:
    """The authored expansion, or the single implicit placement an unexpanded
    component resolves to.

    Stated as a spec rather than branched around, so both paths run the SAME
    composition: a zero offset and a zero rotation compose to the component's
    own position and angle EXACTLY (``rotate_local_offset`` short-circuits on 0,
    and the zero offset's rotated components are exactly 0.0 at any angle), so
    there is no float drift to move a coordinate that should not move.
    """
    authored = getattr(assembly, "placements", ()) if assembly is not None else ()
    if authored:
        return authored
    return (AssemblyPlacementSpec(ref=component_ref, offset_mm=None, rotation_deg=0.0),)


def footprint_anchor(footprint) -> tuple[tuple[float, float], str]:
    """The footprint-LOCAL body-box centre and the BASIS it was measured from.

    ``footprint`` is a built ``footprint_def.FootprintDefinition``. See the
    module docstring for why the ladder is fab, then lands, then the origin.
    """
    for basis, extent in (
        (ANCHOR_BASIS_FAB, fab_extent_from_definition(footprint)),
        (ANCHOR_BASIS_LANDS, land_extent_from_definition(footprint)),
    ):
        if extent is not None:
            return (extent.center_x, extent.center_y), basis
    return (0.0, 0.0), ANCHOR_BASIS_ORIGIN


def physical_placements(component_ref: str, placement: Placement, assembly,
                        footprint) -> tuple[PhysicalPlacement, ...]:
    """Every part this component resolves to, anchored and composed.

    One entry under the component's own ref for an ordinary component; one per
    authored ``assembly.placements`` entry for a synthetic expansion, each
    carrying the authored ref and the offset composed against this component's
    rotation and side.

    The footprint is measured ONCE, outside the loop, because it is the parent's
    drawing and every child that did not author an ``anchor_mm`` shares it.
    """
    measured_local, measured_basis = footprint_anchor(footprint)
    parent = PlacementTransform(position=placement.position,
                                rotation_deg=placement.rotation_deg,
                                side=placement.side)
    placements: list[PhysicalPlacement] = []
    for spec in _specs(component_ref, assembly):
        origin = parent.point(spec.offset_mm or (0.0, 0.0))
        rotation = parent.angle(spec.rotation_deg)
        child = PlacementTransform(position=origin, rotation_deg=rotation,
                                   side=placement.side)
        # AUTHORED WINS, tested against None rather than truthiness: an anchor
        # of (0, 0) says "this part's centre IS its own origin", which is a
        # different statement from not having answered.
        authored = spec.anchor_mm is not None
        anchor_local = spec.anchor_mm if authored else measured_local
        placements.append(PhysicalPlacement(
            ref=spec.ref,
            origin=origin,
            # The authored anchor rides the CHILD's transform, exactly as a
            # measured one does — so it is written in the untransformed local
            # frame a datasheet states, and is turned and mirrored by the same
            # object that places the copper.
            anchor=child.point(anchor_local),
            rotation_deg=rotation,
            side=placement.side,
            anchor_basis=ANCHOR_BASIS_AUTHORED if authored else measured_basis,
        ))
    return tuple(placements)
