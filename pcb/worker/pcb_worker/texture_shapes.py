"""Flat geometry for the board raster: apertures and arcs as point lists.

Pure millimetre arithmetic in the GERBER frame, with no imaging dependency and
no knowledge of pixels beyond a resolution hint used to pick a tessellation fine
enough that nobody can see it. :mod:`texture_bake` maps the points this module
returns through :class:`texture_frame.TextureFrame` and hands them to the
rasteriser.

WHY NOT REUSE ``drc_geom_primitives``. That module's shapes are deliberately
CONSERVATIVE — a roundrect is modelled by its bounding rectangle, because a
copper DRC must never under-state copper. Drawing from a superset would paint
corners the board does not have. These are FAITHFUL outlines instead: they trace
what the aperture actually flashes, matching ``gerber._shape_aperture``'s
mapping of the same four shape tokens.

ONE DELIBERATE DIVERGENCE FROM THE EMITTER, and it is not a discrepancy: the
emitter applies ``gerber._obround_rotation_swap``, transposing width and height
for a fully-rounded land, to work around gerber-writer dropping the rotation of
such an aperture. That swap exists so the EMITTED file describes the rotated
land correctly. Nothing here drops a rotation, so applying the swap too would
rotate the drawn land 90 degrees away from the copper the Gerber carries.
"""

from __future__ import annotations

import math

Point = tuple[float, float]

#: Corner/arc tessellation target, in pixels of sagitta. A quarter pixel is
#: below what the bake's own antialiasing can express, so the curve is smooth.
_SAGITTA_PX = 0.25

#: Bounds on the segment count: enough that a tiny arc is still round, few
#: enough that a large one cannot blow up the point list.
_MIN_SEGMENTS = 6
_MAX_SEGMENTS = 720


def arc_segment_count(radius_mm: float, sweep_rad: float, px_per_mm: float) -> int:
    """Segments needed to draw an arc so its flat-chord error stays sub-pixel.

    Sagitta of a chord subtending ``theta`` on radius ``r`` is
    ``r * (1 - cos(theta/2))``, i.e. about ``r * theta**2 / 8``. Solving that for
    the pixel budget gives the step below.
    """
    sweep = abs(sweep_rad)
    if radius_mm <= 0 or sweep == 0:
        return _MIN_SEGMENTS
    tolerance_mm = _SAGITTA_PX / max(px_per_mm, 1e-9)
    step = math.sqrt(max(8.0 * tolerance_mm / radius_mm, 1e-12))
    return int(min(_MAX_SEGMENTS, max(_MIN_SEGMENTS, math.ceil(sweep / step))))


def _rotate(points: list[Point], cx: float, cy: float, angle_deg: float) -> list[Point]:
    """Place LOCAL offsets at ``(cx, cy)``, rotated by an absolute gerber angle.

    The angle is a gerber-frame rotation (Y-up, counter-clockwise positive) —
    the same absolute value the emitter hands ``layer.add_pad``. Mirroring for
    the bottom side happens later, in the point mapping, never here.
    """
    rad = math.radians(angle_deg)
    ca, sa = math.cos(rad), math.sin(rad)
    return [(cx + px * ca - py * sa, cy + px * sa + py * ca) for (px, py) in points]


def _rounded_corner(cx: float, cy: float, radius: float,
                    start_deg: float, px_per_mm: float) -> list[Point]:
    """One 90-degree corner arc, counter-clockwise from ``start_deg``."""
    n = arc_segment_count(radius, math.pi / 2.0, px_per_mm)
    out: list[Point] = []
    for i in range(n + 1):
        a = math.radians(start_deg) + (math.pi / 2.0) * (i / n)
        out.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return out


def aperture_outline(shape: str, w: float, h: float, rratio: float | None,
                     angle_deg: float, cx: float, cy: float,
                     px_per_mm: float) -> list[Point] | None:
    """The outline of one flashed aperture, in gerber-frame millimetres.

    Returns ``None`` for a plain circle — a disc has no meaningful polygon and
    the rasteriser draws it as an ellipse, which is both exact and cheap. Every
    other shape comes back as a closed point ring.

    The shape vocabulary and the radius rules are ``gerber._shape_aperture``'s:
    ``circle`` (w is the diameter), ``oval`` (fully rounded on the short axis),
    ``roundrect`` (radius = ``rratio * min(w, h)``, degenerating to a rectangle
    at zero), and ``rect`` — which is also the fallback for any token this
    worker does not know, exactly as the emitter falls back.
    """
    if shape == "circle":
        return None

    half_w, half_h = w / 2.0, h / 2.0
    radius = 0.0
    if shape == "oval":
        radius = min(w, h) / 2.0
    elif shape == "roundrect" and rratio:
        radius = max(0.0, float(rratio) * min(w, h))
    radius = min(radius, half_w, half_h)

    if radius <= 0.0:
        local = [(-half_w, -half_h), (half_w, -half_h), (half_w, half_h), (-half_w, half_h)]
        return _rotate(local, cx, cy, angle_deg)

    ix, iy = half_w - radius, half_h - radius
    local: list[Point] = []
    local += _rounded_corner(ix, -iy, radius, -90.0, px_per_mm)     # bottom-right
    local += _rounded_corner(ix, iy, radius, 0.0, px_per_mm)        # top-right
    local += _rounded_corner(-ix, iy, radius, 90.0, px_per_mm)      # top-left
    local += _rounded_corner(-ix, -iy, radius, 180.0, px_per_mm)    # bottom-left
    return _rotate(local, cx, cy, angle_deg)


def arc_points(start: Point, end: Point, center: Point, orientation: str,
               px_per_mm: float) -> list[Point]:
    """A silk arc as a polyline, in gerber-frame millimetres.

    ``orientation`` is gerber-writer's: ``'+'`` is counter-clockwise (it emits
    G03), ``'-'`` clockwise (G02). ``start == end`` with a real radius is that
    library's documented FULL-circle form, which this reproduces as a complete
    sweep rather than as a zero-length arc.
    """
    cx, cy = center
    r0 = math.hypot(start[0] - cx, start[1] - cy)
    r1 = math.hypot(end[0] - cx, end[1] - cy)
    radius = (r0 + r1) / 2.0
    if radius <= 0:
        return [start, end]

    a0 = math.atan2(start[1] - cy, start[0] - cx)
    a1 = math.atan2(end[1] - cy, end[0] - cx)
    ccw = orientation != "-"
    sweep = (a1 - a0) if ccw else (a0 - a1)
    sweep %= 2.0 * math.pi
    if sweep <= 1e-12:
        sweep = 2.0 * math.pi                     # full circle (start == end)
    if not ccw:
        sweep = -sweep

    n = arc_segment_count(radius, sweep, px_per_mm)
    return [(cx + radius * math.cos(a0 + sweep * (i / n)),
             cy + radius * math.sin(a0 + sweep * (i / n)))
            for i in range(n + 1)]


def circle_points(cx: float, cy: float, radius: float, px_per_mm: float) -> list[Point]:
    """A full circle as a closed polyline, in gerber-frame millimetres."""
    n = arc_segment_count(radius, 2.0 * math.pi, px_per_mm)
    return [(cx + radius * math.cos(2.0 * math.pi * i / n),
             cy + radius * math.sin(2.0 * math.pi * i / n))
            for i in range(n + 1)]
