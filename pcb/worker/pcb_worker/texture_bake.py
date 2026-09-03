"""PER-SIDE TEXTURE BAKE: one raster of the board as it will actually look.

Every other picture this worker makes is per-layer and vector — the fab preview
emits one SVG per Gerber, and a person wanting to know what the built board
looks like has to composite it in their head. This bakes the composite: bare
laminate, copper under the mask, the mask itself, the plating showing through
the mask openings, and silk on top, in THE COLOURS THAT WERE ORDERED.

WHAT IT DRAWS, AND WHY THAT SOURCE
----------------------------------
:func:`gerber.harvest_geometry` — the same harvest ``build_gerbers_ir`` writes
the fabrication files from, in the same frame, with the mask clearance already
applied. So the picture and the shipped Gerbers cannot disagree about the same
board: they are two renderings of one geometry, not two derivations of one
design. (``drc_geometric`` also builds copper, and is the wrong source: it
builds a deliberate SUPERSET for checking, so a picture from it would show
copper the board does not have.)

Not drawn, deliberately:

  * SOLDER PASTE. The stencil is a tool, not part of the board; no built board
    has paste apertures on it.
  * INNER COPPER. Neither face shows it, and a picture that leaked inner layers
    onto a face would be a picture of a board nobody can build.
  * ANY SILK RULE. Whether silk lands on a pad or is too thin is GC9's job
    (``drc_silk_placement``), in vector, once. A second opinion here could only
    disagree with the first.

ROUND HOLES ONLY, AND THE MESH DISAGREES. The harvest's ``holes`` bucket is
``(x, y, DIAMETER, plated)`` — round, always — and the harvest RAISES on a board
hole whose feature is not round ("the round-only fabrication path cannot drill").
The 3D substrate does not: :mod:`board_drills` models every opening as a capsule
and :mod:`substrate_mesh` cuts slots and ovals faithfully. Nothing compiled today
can produce one (``compile_board._check_pad_capabilities`` refuses a non-round
drill), so the two agree in practice — but the FIRST board that gets a slot will
mesh correctly and raise HERE. Punching a real slot needs the true drill shape,
which means reading ``board_drills`` rather than the harvest's round bucket.

COMPOSITE ORDER (fab order, bottom to top)
------------------------------------------
1. bare substrate, clipped to the board outline minus its cutouts
2. copper, on the substrate
3. the solder-mask film, translucent, everywhere the board has mask — which is
   everywhere except the openings. One alpha composite gives BOTH the "copper
   showing through as lighter regions" and the "mask colour over bare laminate"
   effects, because they are the same film over two different undersides.
4. the surface finish, in the mask openings, where there is copper to plate
5. silk
6. finally the drilled holes are punched out of the alpha, because a hole is
   the absence of board and nothing is printed inside one.

RESOLUTION, AND WHAT THE DEFAULT BUYS
--------------------------------------
Caller's choice in pixels per millimetre, defaulting to
:data:`texture_frame.DEFAULT_SCALE_PX_PER_MM` (20). MEASURED at that default:
the thinnest silkscreen any shipped profile admits is JLCPCB's published
0.15 mm minimum line width, which lands at 3 px, and the 1.0 mm designator text
this worker draws is 20 px tall with 0.15 mm strokes. Three pixels is thin, and
it is legible here only because the bake antialiases — the masks are drawn at
:data:`SUPERSAMPLE` times the final resolution and box-filtered down, so a 3 px
stroke arrives as a solid 3 px stroke with soft edges rather than as the
stair-stepped dashes a direct 1:1 rasterisation of a hairline produces. Below
about 12 px/mm that floor drops under 2 px and silk starts to break up; a caller
who needs to READ the legend should ask for 40.

The long side is capped at :data:`texture_frame.MAX_TEXTURE_PX`; see that
module for the cap's rationale and for the registration convention — pixel
origin, axis directions and the bottom-side mirror — which lives there rather
than here precisely because more than one task depends on it.
"""

from __future__ import annotations

import io
from dataclasses import dataclass

from PIL import Image, ImageChops, ImageDraw

from . import gerber
from .ir_projection import cutout_point_loops, outline_frame
from .resolved_board import ResolvedBoard, Side
from .texture_appearance import Appearance, appearance_for
from .texture_frame import DEFAULT_SCALE_PX_PER_MM, MAX_TEXTURE_PX, TextureFrame
from .texture_shapes import Point, aperture_outline, arc_points, circle_points

#: Linear oversampling factor for the coverage masks. 2 is where antialiasing
#: stops being the limiting factor on a 3 px silk stroke; 4 costs four times the
#: working memory for a difference nobody can see at these feature sizes.
SUPERSAMPLE = 2

#: Working-raster budget, in pixels of one oversampled mask. Five masks are live
#: at once, so this bounds the bake at roughly 160 MB of 8-bit coverage for the
#: largest board the cap admits. A board that would exceed it is drawn at 1:1
#: instead of oversampled — a big board at high resolution has pixels to spare
#: for its silk anyway, which is exactly the case where antialiasing matters
#: least.
WORK_PIXEL_BUDGET = 32_000_000


@dataclass(frozen=True)
class BakedSide:
    """One side's finished raster plus everything needed to place it.

    ``image`` is RGBA and TRANSPARENT outside the board: past the outline, inside
    a cutout, and inside every drilled hole. That is what lets it be laid over a
    slab (or over a canvas) without painting a rectangle where the board is not.
    """

    side: str
    frame: TextureFrame
    image: Image.Image
    appearance: Appearance
    notes: tuple[str, ...] = ()

    def to_png_bytes(self) -> bytes:
        buffer = io.BytesIO()
        self.image.save(buffer, format="PNG")
        return buffer.getvalue()


class _Ink:
    """One 8-bit coverage mask, drawn oversampled and resolved down at the end.

    Every drawing method takes MILLIMETRES and is explicit about which frame
    they are in — ``*_gerber`` for harvest geometry, ``*_board`` for the outline
    and its cutouts. Mapping is the frame's job (:class:`TextureFrame`), so no
    method here carries a sign, a mirror or an angle conversion of its own.
    """

    def __init__(self, frame: TextureFrame, supersample: int) -> None:
        self.frame = frame
        self.ss = supersample
        self.px_per_mm = frame.scale_px_per_mm * supersample
        self.image = Image.new("L", (frame.width_px * supersample,
                                     frame.height_px * supersample), 0)
        self.draw = ImageDraw.Draw(self.image)

    def map_gerber(self, points) -> list[tuple[float, float]]:
        return [self._scale(self.frame.gerber_to_pixel(x, y)) for (x, y) in points]

    def map_board(self, points) -> list[tuple[float, float]]:
        return [self._scale(self.frame.board_to_pixel(x, y)) for (x, y) in points]

    def _scale(self, pixel: tuple[float, float]) -> tuple[float, float]:
        return (pixel[0] * self.ss, pixel[1] * self.ss)

    def polygon(self, pixels, value: int = 255) -> None:
        if len(pixels) >= 3:
            self.draw.polygon(pixels, fill=value)

    def fill_all(self, value: int = 255) -> None:
        self.draw.rectangle([0, 0, self.image.width - 1, self.image.height - 1], fill=value)

    def disc_gerber(self, cx: float, cy: float, radius_mm: float, value: int = 255) -> None:
        """A filled circle. Rotation-free and mirror-free, so it needs no outline."""
        if radius_mm <= 0:
            return
        px, py = self._scale(self.frame.gerber_to_pixel(cx, cy))
        r = radius_mm * self.px_per_mm
        self.draw.ellipse([px - r, py - r, px + r, py + r], fill=value)

    def stroke_gerber(self, points: list[Point], width_mm: float, value: int = 255) -> None:
        """A ROUND-CAPPED, round-joined stroke — what a Gerber trace aperture is.

        The caps and joins are discs at the vertices rather than a mitre, which
        is both what the aperture does and what keeps a polyline from growing
        spikes at sharp corners.
        """
        if not points:
            return
        pixels = self.map_gerber(points)
        width = max(1.0, width_mm * self.px_per_mm)
        if len(pixels) >= 2:
            self.draw.line(pixels, fill=value, width=max(1, int(round(width))))
        radius = width / 2.0
        for (px, py) in pixels:
            self.draw.ellipse([px - radius, py - radius, px + radius, py + radius], fill=value)

    def resolved(self) -> Image.Image:
        """The mask at final resolution, box-filtered so coverage antialiases."""
        if self.ss == 1:
            return self.image
        return self.image.resize((self.frame.width_px, self.frame.height_px),
                                 Image.Resampling.BOX)


def _flash(ink: _Ink, x: float, y: float, shape: str, w: float, h: float,
           rratio: float | None, angle: float) -> None:
    """One flashed aperture — copper land or mask opening, one code path.

    The emitter flashes copper and mask through a single ``_shape_aperture``
    branch for exactly this reason: a mask window that did not match the shape of
    the land under it would be a lie about the same pad on two layers.
    """
    outline = aperture_outline(shape, w, h, rratio, angle, x, y, ink.px_per_mm)
    if outline is None:
        ink.disc_gerber(x, y, w / 2.0)
    else:
        ink.polygon(ink.map_gerber(outline))


def _draw_copper(ink: _Ink, g, top: bool) -> None:
    """Every copper feature that shows on one face.

    Through-hole lands — round annuli and oblong ``th_shaped`` ones alike — are
    on BOTH faces, which is what a plated through-hole is, so neither is filtered
    by side. Pour rings arrive already fractured into self-touching keyhole
    contours by ``zone_fill``; filling them with the even-odd scanline rule
    preserves the voids for the same reason ``add_region`` can carry them.
    """
    for (x, y, w, h, angle, is_top, shape, rratio) in g.smd_pads:
        if bool(is_top) == top:
            _flash(ink, x, y, shape, w, h, rratio, angle)
    for (x, y, diameter, _function) in g.th_annuli:
        ink.disc_gerber(x, y, diameter / 2.0)
    for (x, y, shape, w, h, rratio, angle) in g.th_shaped:
        _flash(ink, x, y, shape, w, h, rratio, angle)
    for (x1, y1, x2, y2, width) in (g.traces_top if top else g.traces_bot):
        ink.stroke_gerber([(x1, y1), (x2, y2)], width)
    for ring in (g.zone_fill_top if top else g.zone_fill_bot):
        ink.polygon(ink.map_gerber(ring))


def _draw_silk(ink: _Ink, g, top: bool) -> None:
    lines = g.silk_lines if top else g.silk_lines_bot
    circles = g.silk_circles if top else g.silk_circles_bot
    polys = g.silk_polys if top else g.silk_polys_bot
    arcs = g.silk_arcs if top else g.silk_arcs_bot

    for (x1, y1, x2, y2, width) in lines:
        ink.stroke_gerber([(x1, y1), (x2, y2)], width)
    for (cx, cy, radius, width) in circles:
        ink.stroke_gerber(circle_points(cx, cy, radius, ink.px_per_mm), width)
    for (points, width, closed) in polys:
        path = list(points)
        if closed and len(path) > 2 and path[0] != path[-1]:
            path.append(path[0])
        ink.stroke_gerber(path, width)
    for (start, end, center, orientation, width) in arcs:
        ink.stroke_gerber(arc_points(start, end, center, orientation, ink.px_per_mm), width)


def _supersample_for(frame: TextureFrame) -> int:
    if frame.width_px * frame.height_px * SUPERSAMPLE ** 2 > WORK_PIXEL_BUDGET:
        return 1
    return SUPERSAMPLE


def _composite(frame: TextureFrame, appearance: Appearance, board: Image.Image,
               copper: Image.Image, openings: Image.Image, silk: Image.Image,
               holes: Image.Image) -> Image.Image:
    """The five coverage masks and the ordered colours, in fab order."""
    size = (frame.width_px, frame.height_px)
    box = (0, 0, frame.width_px, frame.height_px)
    image = Image.new("RGBA", size, (0, 0, 0, 0))

    image.paste(appearance.substrate + (255,), box, board)
    image.paste(appearance.copper + (255,), box, ImageChops.multiply(copper, board))

    # The mask film: present over the whole board EXCEPT the openings, and
    # translucent, so one composite tints copper and laminate differently
    # without either being drawn twice.
    film = Image.new("RGBA", size, appearance.mask + (0,))
    coverage = ImageChops.subtract(board, openings)
    film.putalpha(coverage.point(lambda v: int(v * appearance.mask_alpha)))
    image = Image.alpha_composite(image, film)

    # Plating shows where an opening exposes copper. An opening over bare
    # laminate — a mask window wider than its land, which is the normal case for
    # a generous mask margin — correctly shows laminate, not plating.
    plating = ImageChops.multiply(ImageChops.multiply(openings, copper), board)
    image.paste(appearance.finish + (255,), box, plating)

    image.paste(appearance.silk + (255,), box, ImageChops.multiply(silk, board))

    # Holes last: a bore is board that is not there, so it takes the alpha away
    # from everything already painted over it, including its own annulus.
    image.putalpha(ImageChops.subtract(image.getchannel("A"), holes))
    return image


def bake_side(board: ResolvedBoard, side, *,
              scale_px_per_mm: float = DEFAULT_SCALE_PX_PER_MM,
              max_px: int = MAX_TEXTURE_PX,
              geometry=None) -> BakedSide:
    """Bake one face of ``board``.

    ``geometry`` lets a caller baking both faces harvest once
    (:func:`bake_board` does); left ``None`` this harvests for itself.
    """
    name = getattr(side, "value", side)
    if name not in ("top", "bottom"):
        raise ValueError(f"bake_side: side must be 'top' or 'bottom', got {name!r}")
    top = name == "top"

    g = gerber.harvest_geometry(board) if geometry is None else geometry
    origin_x, origin_y, width_mm, height_mm = outline_frame(board.outline)
    frame = TextureFrame.for_board((origin_x, origin_y), (width_mm, height_mm), name,
                                   scale_px_per_mm=scale_px_per_mm, max_px=max_px)
    appearance = appearance_for(board.fabrication)
    supersample = _supersample_for(frame)

    board_ink = _Ink(frame, supersample)
    board_ink.fill_all()
    for (_cutout_id, loop) in cutout_point_loops(board.outline):
        # Cutouts are the ONE input in board-frame millimetres: the outline does
        # not pass through the harvest, exactly as in _build_gerber_layers.
        board_ink.polygon(board_ink.map_board(loop), value=0)

    copper_ink = _Ink(frame, supersample)
    _draw_copper(copper_ink, g, top)

    opening_ink = _Ink(frame, supersample)
    for (x, y, shape, w, h, rratio, angle) in (g.mask_top if top else g.mask_bot):
        _flash(opening_ink, x, y, shape, w, h, rratio, angle)

    silk_ink = _Ink(frame, supersample)
    _draw_silk(silk_ink, g, top)

    hole_ink = _Ink(frame, supersample)
    for (x, y, diameter, _plated) in g.holes:
        hole_ink.disc_gerber(x, y, diameter / 2.0)

    image = _composite(frame, appearance, board_ink.resolved(), copper_ink.resolved(),
                       opening_ink.resolved(), silk_ink.resolved(), hole_ink.resolved())

    notes = list(appearance.notes)
    if frame.clamped:
        notes.append(
            f"requested {frame.requested_scale_px_per_mm:g} px/mm would exceed the "
            f"{max_px} px cap on the long side; baked at "
            f"{frame.scale_px_per_mm:g} px/mm instead")

    return BakedSide(side=name, frame=frame, image=image, appearance=appearance,
                     notes=tuple(notes))


def bake_board(board: ResolvedBoard, *,
               scale_px_per_mm: float = DEFAULT_SCALE_PX_PER_MM,
               max_px: int = MAX_TEXTURE_PX) -> dict[str, BakedSide]:
    """Both faces, from ONE harvest, keyed ``"top"`` / ``"bottom"``."""
    geometry = gerber.harvest_geometry(board)
    return {side.value: bake_side(board, side, scale_px_per_mm=scale_px_per_mm,
                                  max_px=max_px, geometry=geometry)
            for side in (Side.TOP, Side.BOTTOM)}
