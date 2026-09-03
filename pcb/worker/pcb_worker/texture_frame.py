"""THE REGISTRATION CONVENTION for per-side board rasters — pixel origin, axis
directions, and the bottom-side mirror, defined ONCE.

This module is deliberately free of any imaging dependency. It is the piece the
texture bake (:mod:`texture_bake`), the 3D slab that wraps the bake, and the
viewer that places a texture over a board all read, and if any of them re-derived
the mapping the three would eventually disagree — producing a board that looks
perfectly fine and is BACKWARDS. Getting a mirror wrong is not a visible bug; it
is a correct-looking wrong answer, which is why the convention is a module rather
than a comment.

THREE FRAMES, and the two conversions between them
--------------------------------------------------
BOARD frame (mm)
    KiCad's file frame, which this worker uses everywhere a board document is
    read: X grows RIGHT, **Y grows DOWN**. Board outlines, component placements
    and cutouts are all in it.

GERBER frame (mm)
    RS-274X coordinates: X right, **Y UP**. The fabrication harvest
    (:func:`gerber.harvest_geometry`) is expressed in it, because
    ``_Geometry.to_gerber_frame`` converts once at the end of the harvest. The
    only difference from the board frame is the sign of Y — see
    :meth:`TextureFrame.gerber_to_pixel`, which is the ONE place in the raster
    path that crosses this boundary.

TEXTURE PIXEL frame (px)
    Column ``u`` grows RIGHT, row ``v`` grows **DOWN** from row 0 at the top —
    the ordinary image convention, and also glTF's: a glTF UV origin is the
    TOP-LEFT of the image with ``v`` increasing downward. So ``uv`` here is
    ``(px / width, py / height)`` with no flip, and a task that wraps this
    texture onto a slab must not insert one.

    Pixel (0, 0) is the TOP-LEFT corner of the board's bounding rectangle:

      * TOP side — that corner is board ``(min_x, min_y)``. Board +X is image
        +u and board +Y is image +v, so the image reads exactly like the board
        seen from ABOVE in a Y-down canvas (which is what the editor draws).
      * BOTTOM side — that corner is board ``(max_x, min_y)``. Board +X is image
        **-u**; Y is unchanged. This is the board seen from BELOW, i.e. flipped
        about its vertical axis the way a person turns a board over on a bench,
        and the same handedness a fab's bottom-side view has.

    The mirror is on X, NEVER on Y. Mirroring Y instead produces an image that
    is equally "flipped" to a casual eye and wrong by 180 degrees.

ANGLES AND CHIRALITY NEED NO SEPARATE RULE. Every consumer here maps POINTS
through :meth:`gerber_to_pixel`; rotations and arc sweeps are then correct on
both sides for free, because a mirror reverses handedness exactly once and it
does so inside the point mapping. Converting an angle by hand ANYWHERE in the
raster path is a bug, not an optimisation.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

#: Default resolution. At 20 px/mm the narrowest silkscreen any shipped profile
#: admits (0.15 mm, JLCPCB's published minimum line width) is 3 px wide and the
#: 1.0 mm designator text this worker draws is 20 px tall — thin, but legible,
#: and the bake antialiases so a 3 px stroke reads as a stroke rather than as a
#: dotted line. Below roughly 12 px/mm that silk floor drops under 2 px and
#: starts to break up.
DEFAULT_SCALE_PX_PER_MM = 20.0

#: Hard ceiling on the LONG side of one baked image, in pixels.
#:
#: 8192 is the largest 2D texture dimension guaranteed by every GPU class the 3D
#: export can plausibly be opened on (desktop GL, GL ES 3.x, WebGL 2 all require
#: at least 8192), so a texture at the cap still renders instead of being
#: silently downsampled or dropped by the viewer. It also bounds the arithmetic:
#: one side at the cap is at most 8192 x 8192 x 4 bytes of RGBA.
#:
#: The cap CLAMPS THE SCALE rather than refusing the bake — see
#: :meth:`TextureFrame.for_board`. A picture is not a fabrication artifact, so
#: producing it at a lower, RECORDED resolution is a better answer than
#: producing nothing; and because every measurement in the frame derives from
#: ``scale_px_per_mm``, registration stays exact at the clamped scale. What must
#: never happen is the clamp being invisible, so the frame keeps the requested
#: scale beside the effective one and :attr:`TextureFrame.clamped` says so.
MAX_TEXTURE_PX = 8192


def _dim_px(extent_mm: float, scale: float, cap: int) -> int:
    """Pixel extent for a millimetre extent: ceil, never zero, never over cap.

    Ceil rather than round so the image can never crop the board it is a picture
    of; the rounding guard absorbs the float noise that makes ``8192.0000001``
    out of an exactly-capped edge.
    """
    return max(1, min(cap, math.ceil(round(extent_mm * scale, 6))))


@dataclass(frozen=True)
class TextureFrame:
    """The mapping between one side's board millimetres and its texture pixels.

    ``origin_mm`` / ``size_mm`` are the BOARD-frame bounding rectangle of the
    outline — the same ``(origin_x, origin_y, width, height)`` the fabrication
    path frames Edge.Cuts with (``ir_projection.outline_frame``) — so the
    texture covers exactly the board's extent and nothing else.
    """

    side: str                                   # "top" | "bottom"
    origin_mm: tuple[float, float]              # board-frame (min_x, min_y)
    size_mm: tuple[float, float]                # (width_mm, height_mm)
    scale_px_per_mm: float                      # EFFECTIVE scale, post-clamp
    requested_scale_px_per_mm: float
    width_px: int
    height_px: int

    @classmethod
    def for_board(cls, origin_mm: tuple[float, float], size_mm: tuple[float, float],
                  side, scale_px_per_mm: float = DEFAULT_SCALE_PX_PER_MM,
                  max_px: int = MAX_TEXTURE_PX) -> "TextureFrame":
        """Build a frame, clamping the scale so the long side fits ``max_px``."""
        name = getattr(side, "value", side)
        if name not in ("top", "bottom"):
            raise ValueError(f"TextureFrame side must be 'top' or 'bottom', got {name!r}")
        width_mm, height_mm = float(size_mm[0]), float(size_mm[1])
        if not (width_mm > 0 and height_mm > 0):
            raise ValueError(
                f"TextureFrame needs a positive board extent, got {width_mm} x {height_mm} mm")
        requested = float(scale_px_per_mm)
        if not requested > 0:
            raise ValueError(f"scale_px_per_mm must be positive, got {requested}")

        long_mm = max(width_mm, height_mm)
        effective = min(requested, max_px / long_mm)
        return cls(
            side=name,
            origin_mm=(float(origin_mm[0]), float(origin_mm[1])),
            size_mm=(width_mm, height_mm),
            scale_px_per_mm=effective,
            requested_scale_px_per_mm=requested,
            width_px=_dim_px(width_mm, effective, max_px),
            height_px=_dim_px(height_mm, effective, max_px),
        )

    @property
    def mirrored(self) -> bool:
        """True when board +X runs toward DECREASING pixel columns (bottom side)."""
        return self.side == "bottom"

    @property
    def clamped(self) -> bool:
        """True when the requested scale did not fit :data:`MAX_TEXTURE_PX`."""
        return self.scale_px_per_mm < self.requested_scale_px_per_mm

    def board_to_pixel(self, x_mm: float, y_mm: float) -> tuple[float, float]:
        """BOARD-frame millimetres -> texture pixels (float, sub-pixel exact).

        The bottom side mirrors X about the board's own extent, so the two sides'
        images are registered to the SAME physical board: a feature at board
        ``x`` sits at ``(x - min_x) * s`` from the left on top and the same
        distance from the RIGHT on the bottom.
        """
        ox, oy = self.origin_mm
        s = self.scale_px_per_mm
        py = (y_mm - oy) * s
        if self.mirrored:
            return ((self.size_mm[0] - (x_mm - ox)) * s, py)
        return ((x_mm - ox) * s, py)

    def gerber_to_pixel(self, x_mm: float, y_mm: float) -> tuple[float, float]:
        """GERBER-frame millimetres -> texture pixels.

        THE ONE FRAME BOUNDARY of the raster path, mirroring
        ``gerber._Geometry.to_gerber_frame`` in the opposite direction: the
        harvest negated Y on the way into Gerber space, so reading it back into
        board space negates Y again. Every primitive the bake draws goes through
        here, so no drawing routine carries a sign of its own.
        """
        return self.board_to_pixel(x_mm, -y_mm)

    def pixel_to_board(self, px: float, py: float) -> tuple[float, float]:
        """Texture pixels -> BOARD-frame millimetres (exact inverse)."""
        ox, oy = self.origin_mm
        s = self.scale_px_per_mm
        y_mm = py / s + oy
        if self.mirrored:
            return (ox + self.size_mm[0] - px / s, y_mm)
        return (px / s + ox, y_mm)

    def uv(self, x_mm: float, y_mm: float) -> tuple[float, float]:
        """BOARD-frame millimetres -> glTF UV, origin TOP-LEFT, ``v`` downward.

        No flip: glTF's UV origin already is the image's top-left, and this
        module's pixel rows already run downward. A consumer that adds
        ``1 - v`` here is compensating for a flip that does not exist.
        """
        px, py = self.board_to_pixel(x_mm, y_mm)
        return (px / self.width_px, py / self.height_px)

    def as_dict(self) -> dict:
        """The frame as plain JSON-able data, for a worker reply or a sidecar."""
        return {
            "side": self.side,
            "origin_mm": {"x": self.origin_mm[0], "y": self.origin_mm[1]},
            "size_mm": {"width": self.size_mm[0], "height": self.size_mm[1]},
            "scale_px_per_mm": self.scale_px_per_mm,
            "requested_scale_px_per_mm": self.requested_scale_px_per_mm,
            "clamped": self.clamped,
            "width_px": self.width_px,
            "height_px": self.height_px,
            "mirrored_x": self.mirrored,
            "pixel_origin": "top-left; +u right, +v down; glTF UV = (u/width, v/height)",
        }
