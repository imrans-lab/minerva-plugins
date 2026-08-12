"""KiCad footprint (`.kicad_mod`) parser + seed-library lookup.

This module turns a real KiCad footprint into the geometry Minerva needs to
render or fabricate a component: its pads and modeled front/back technical
graphics. Coordinates are
returned in footprint-LOCAL space -- the board-placement transform (component
position + KiCad clockwise rotation) happens elsewhere, in the resolve round,
exactly as ``agent_router.kicad_io._transform_position`` already does for pads.

Design / reuse notes
--------------------
* ``agent_router.kicad_io`` parses whole ``.kicad_pcb`` files with regexes and
  is the reader for placed boards; it stays as-is. It is deliberately NOT
  reused here: a ``.kicad_mod`` is a different container, and -- per the round
  brief -- nested graphics (``fp_line``/``fp_circle``/``fp_arc``/``fp_poly``)
  are far safer to read with a real s-expression parser than with regexes.
  Mixing a regex pad reader with an s-expr graphics reader inside one module
  would also violate DRY, so BOTH pads and graphics are read from a single
  robust s-expr parse (productized from the validated prototype).
* No rotation helper lives here on purpose -- footprints are stored in local
  coordinates; the transform is applied by the resolve step.

Public API
----------
* ``parse_kicad_mod(path_or_text) -> dict``
* ``resolve_footprint(ref, ...) -> dict``  (seed-library lookup, sha-verified)
"""

from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
from typing import Any, Union

# Primitive geometry is layer-agnostic: once line/circle/arc/poly/rect is
# understood, dropping it merely because it is on the back, fab, courtyard, or
# paste side makes strict compilation reject ordinary library parts.  Capture
# the modeled technical-layer set; consumers still explicitly choose which
# layers they render/emit, so this is additive to the current live path.
GRAPHIC_LAYERS = frozenset({
    "F.SilkS", "B.SilkS", "F.Fab", "B.Fab", "F.CrtYd", "B.CrtYd",
    "F.Paste", "B.Paste",
})

_CAPTURED_GRAPHIC_TAGS = frozenset(
    {"fp_line", "fp_circle", "fp_arc", "fp_poly", "fp_rect"}
)
_CAPTURED_GRAPHIC_KINDS = frozenset(
    tag[len("fp_"):] for tag in _CAPTURED_GRAPHIC_TAGS
)
# Kinds scanned for capture-or-diagnostic coverage. Text/curve forms are not
# silently dropped; the FootprintDefinition adapter classifies their layer and
# whether omitting them blocks a requested output.
_FAB_GRAPHIC_TAGS = (
    "fp_line", "fp_circle", "fp_arc", "fp_poly", "fp_rect",
    "fp_text", "fp_text_box", "fp_curve",
)

# Repo layout: this file is pcb/worker/pcb_worker/footprints.py, so the seed
# library lives two levels up (pcb/library/...).
_PCB_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_LIBRARY_ROOT = _PCB_ROOT / "library" / "footprints"
DEFAULT_LOCKFILE = _PCB_ROOT / "library" / "footprints.lock.json"


# ---------------------------------------------------------------------------
# Minimal s-expression parser (productized from the validated prototype).
# ---------------------------------------------------------------------------


def _tokenize(s: str) -> list[str]:
    """Split KiCad s-expression text into tokens. Quoted strings are emitted
    with a leading ``"`` marker so callers can tell them from bare atoms; use
    :func:`_atom` to normalise."""
    out: list[str] = []
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in "()":
            out.append(c)
            i += 1
        elif c == '"':
            j = i + 1
            buf: list[str] = []
            while j < n and s[j] != '"':
                if s[j] == "\\" and j + 1 < n:
                    buf.append(s[j + 1])
                    j += 2
                else:
                    buf.append(s[j])
                    j += 1
            out.append('"' + "".join(buf))
            i = j + 1
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and s[j] not in '() \t\r\n"':
                j += 1
            out.append(s[i:j])
            i = j
    return out


def _parse(tokens: list[str]) -> Any:
    """Build a nested list tree from tokens (the top-level ``(module ...)`` or
    ``(footprint ...)`` node)."""
    it = iter(tokens)

    def rd(tok: str) -> Any:
        if tok == "(":
            lst: list[Any] = []
            while True:
                t = next(it)
                if t == ")":
                    return lst
                lst.append(rd(t))
        return tok

    return rd(next(it))


def _atom(x: Any) -> Any:
    """Strip the tokenizer's quote marker from a string atom."""
    if isinstance(x, str) and x.startswith('"'):
        return x[1:]
    return x


def _num(x: Any) -> Union[float, None]:
    try:
        return float(_atom(x))
    except (TypeError, ValueError):
        return None


def _find_all(node: Any, tag: str):
    """Yield every sub-list whose head atom equals *tag* (recursive)."""
    if isinstance(node, list):
        if node and node[0] == tag:
            yield node
        for c in node:
            yield from _find_all(c, tag)


def _kv(node: Any, tag: str) -> Union[list, None]:
    """Return the first direct child list of *node* headed by *tag*."""
    for c in node:
        if isinstance(c, list) and c and c[0] == tag:
            return c
    return None


# ---------------------------------------------------------------------------
# Pad + graphic extraction.
# ---------------------------------------------------------------------------


def _parse_pad(p: list) -> dict:
    """Parse a ``(pad NUMBER TYPE SHAPE ...)`` node into a dict.

    The EIGHT original keys (number, type, shape, x_mm, y_mm, size, drill,
    layers) keep their exact historical values/shape so existing consumers
    (``resolve._pads_from_parsed``, ``footprint_def.from_kicad_parsed``, the
    coincidence golden) are byte-identical.

    K1 (lossless-or-flagging) ADDITIVELY surfaces fab-affecting fields that were
    previously dropped -- each is added under a NEW key and ONLY when the source
    carries it, so a pad with none of them is byte-identical to before:

    * ``rotation``            -- the pad's own ``(at x y ROT)`` 3rd value.
    * ``roundrect_rratio``    -- ``(roundrect_rratio N)`` corner ratio.
    * ``drill_shape``/``drill_size`` -- an oval/slot ``(drill oval X Y)`` hole's
      shape token + BOTH dimensions (the legacy ``drill`` keeps the 1st numeric).
    * ``solder_mask_margin`` / ``solder_paste_margin`` -- per-pad overrides.
    * ``unsupported``         -- attributed markers for pad geometry we do NOT
      model (e.g. a custom pad's ``(primitives ...)``): flagged, never dropped.
    """
    number = _atom(p[1]) if len(p) > 1 else ""
    pad_type = _atom(p[2]) if len(p) > 2 else None
    shape = _atom(p[3]) if len(p) > 3 else None

    at = _kv(p, "at")
    x = _num(at[1]) if at and len(at) > 1 else None
    y = _num(at[2]) if at and len(at) > 2 else None

    size_node = _kv(p, "size")
    size = None
    if size_node and len(size_node) >= 3:
        size = [_num(size_node[1]), _num(size_node[2])]

    # (drill 0.8) or (drill oval 0.8 0.8) -> first numeric.
    drill = None
    drill_node = _kv(p, "drill")
    if drill_node:
        for tok in drill_node[1:]:
            v = _num(tok)
            if v is not None:
                drill = v
                break

    layers_node = _kv(p, "layers")
    layers = [_atom(t) for t in layers_node[1:]] if layers_node else []

    pad = {
        "number": number,
        "type": pad_type,
        "shape": shape,
        "x_mm": x,
        "y_mm": y,
        "size": size,
        "drill": drill,
        "layers": layers,
    }

    # --- K1 ADDITIVE: surface previously-dropped fab-affecting fields ---------
    # All reuse the SAME _kv/_atom/_num helpers as the extraction above.

    # Local pad rotation: the 3rd value of the pad's own (at x y ROT).
    if at is not None and len(at) > 3:
        rot = _num(at[3])
        if rot is not None:
            pad["rotation"] = rot

    # Roundrect corner ratio.
    rr = _kv(p, "roundrect_rratio")
    if rr is not None and len(rr) > 1:
        v = _num(rr[1])
        if v is not None:
            pad["roundrect_rratio"] = v

    # Oval/slot drill: a shape token (e.g. "oval") and/or a 2nd dimension. The
    # legacy ``drill`` above already holds the 1st numeric; only surface the
    # extra (shape + full size) when this is NOT a plain round hole.
    if drill_node is not None:
        drill_shape = None
        drill_dims: list = []
        for tok in drill_node[1:]:
            v = _num(tok)
            if v is not None:
                drill_dims.append(v)
            elif drill_shape is None:
                a = _atom(tok)
                if isinstance(a, str):
                    drill_shape = a
        if drill_shape is not None or len(drill_dims) > 1:
            pad["drill_shape"] = drill_shape or "oval"
            pad["drill_size"] = drill_dims

    # Solder mask / paste margin overrides.
    for _margin in ("solder_mask_margin", "solder_paste_margin"):
        node = _kv(p, _margin)
        if node is not None and len(node) > 1:
            v = _num(node[1])
            if v is not None:
                pad[_margin] = v

    # Solder-paste margin RATIO (proportional to pad size) -- distinct from the
    # absolute solder_paste_margin parsed above, and NOT modeled here: the
    # correct per-shape geometry (bug 019fb0155d93) has to be measured against
    # KiCad, which this refusal-only unit is forbidden from doing. Left
    # unflagged, the value is silently dropped and the pad falls back to
    # ``margin == 0.0``, which paste_aperture() returns byte-identical to the
    # copper land (pcb_worker/pad_source.py paste_aperture, measured against
    # KiCad 10.0.5) -- the wrong aperture for any footprint that authored a
    # nonzero ratio, cut into a physical stencil with no diagnostic at all.
    # Flag it as PASTE-domain unsupported instead, so judge()/is_blocking
    # (compile_board.py) fails the board closed now that "paste" is a
    # fabrication-critical output (fab_capability.FABRICATION_CRITICAL_OUTPUTS).
    #
    # Attributed ONLY to a side the pad actually declares paste on (an exact
    # "F.Paste"/"B.Paste" layer, or the "*.Paste" wildcard covering both):
    # pad_source.has_paste() gates the emitter on that same per-side
    # declaration, so a ratio on a pad with no paste layer is never read by
    # anything downstream, and refusing the board over it would be a false
    # alarm rather than a real fabrication risk.
    # A ratio of EXACTLY 0.0 is not a defect and must not be refused: a zero
    # proportional margin means the aperture equals the copper land, which is
    # precisely what paste_aperture() already emits for margin == 0.0. Refusing
    # it would reject a board that fabricates correctly -- the same false-alarm
    # mistake the per-side gate above exists to avoid. (Malformed values are a
    # separate gap: _num returns None for a missing or non-numeric token and we
    # drop it here, matching how solder_paste_margin already behaves. Filed, not
    # fixed, on 019fb0155d93.)
    ratio_node = _kv(p, "solder_paste_margin_ratio")
    if ratio_node is not None and len(ratio_node) > 1:
        ratio_value = _num(ratio_node[1])
        if ratio_value is not None and ratio_value != 0.0:
            _paste_sides = []
            if any(_l in ("F.Paste", "*.Paste") for _l in layers):
                _paste_sides.append("F.Paste")
            if any(_l in ("B.Paste", "*.Paste") for _l in layers):
                _paste_sides.append("B.Paste")
            for _side in _paste_sides:
                pad.setdefault("unsupported", []).append({
                    "feature": "solder_paste_margin_ratio",
                    "layer": _side,
                    "detail": (
                        f"pad {_atom(number)!r} declares "
                        f"solder_paste_margin_ratio={ratio_value!r} on {_side} "
                        f"AS DECLARED (a bottom-side placement mirrors this to "
                        f"the opposite paste layer at resolve time); this "
                        f"proportional stencil margin is not modeled, so "
                        f"without this refusal the paste aperture would be "
                        f"taken from the pad's absolute margin -- 0.0 unless "
                        f"one is also authored -- instead of the "
                        f"ratio-adjusted size the footprint asked for"
                    ),
                })

    # Pad geometry we do NOT model (custom pad primitives): flag, never drop.
    prim = _kv(p, "primitives")
    if prim is not None:
        pad.setdefault("unsupported", []).append({
            "feature": "custom_primitives",
            "detail": (
                f"pad {_atom(number)!r} carries (primitives ...) custom "
                f"geometry not modeled by the parser"
            ),
        })

    # Other fab-affecting pad tokens we do not yet model: flag (never silently
    # drop) so a downstream compiler can fail closed instead of the geometry
    # vanishing. `offset` (nested in the drill node) shifts copper relative to
    # the hole; chamfer/clearance/zone_connect alter copper/mask.
    if drill_node is not None and _kv(drill_node, "offset") is not None:
        pad.setdefault("unsupported", []).append({
            "feature": "pad_drill_offset",
            "detail": f"pad {_atom(number)!r} drill carries (offset ...) not modeled by the parser",
        })
    for _feat, _toks in (
        ("chamfer", ("chamfer", "chamfer_ratio")),
        ("local_clearance", ("clearance",)),
        ("zone_connect", ("zone_connect",)),
    ):
        _present = [t for t in _toks if _kv(p, t) is not None]
        if _present:
            pad.setdefault("unsupported", []).append({
                "feature": _feat,
                "detail": (
                    f"pad {_atom(number)!r} carries ({'/'.join(_present)} ...) "
                    f"not modeled by the parser"
                ),
            })

    return pad


def _stroke_width(g: list) -> Union[float, None]:
    """Line width across KiCad revisions.

    KiCad 6/legacy: ``(fp_line ... (width 0.12))``.
    KiCad 7/8:      ``(fp_line ... (stroke (width 0.12) (type solid)))``.
    """
    w = _kv(g, "width")
    if w and len(w) > 1:
        return _num(w[1])
    st = _kv(g, "stroke")
    if st:
        sw = _kv(st, "width")
        if sw and len(sw) > 1:
            return _num(sw[1])
    return None


def _graphic_layer(g: list) -> Union[str, None]:
    lyr = _kv(g, "layer")
    if lyr and len(lyr) > 1:
        return _atom(lyr[1])
    return None


def _parse_graphics(root: Any) -> list[dict]:
    """Extract fp_line/fp_circle/fp_arc/fp_poly on the wanted layers, in local
    coords. Only ``GRAPHIC_LAYERS`` are kept."""
    graphics: list[dict] = []

    for g in _find_all(root, "fp_line"):
        layer = _graphic_layer(g)
        if layer not in GRAPHIC_LAYERS:
            continue
        st, en = _kv(g, "start"), _kv(g, "end")
        if not (st and en):
            continue
        graphics.append({
            "layer": layer, "kind": "line",
            "start": [_num(st[1]), _num(st[2])],
            "end": [_num(en[1]), _num(en[2])],
            "width": _stroke_width(g),
        })

    for g in _find_all(root, "fp_circle"):
        layer = _graphic_layer(g)
        if layer not in GRAPHIC_LAYERS:
            continue
        ct, en = _kv(g, "center"), _kv(g, "end")
        if not (ct and en):
            continue
        cx, cy = _num(ct[1]), _num(ct[2])
        ex, ey = _num(en[1]), _num(en[2])
        if None in (cx, cy, ex, ey):
            continue
        radius = math.hypot(ex - cx, ey - cy)
        graphics.append({
            "layer": layer, "kind": "circle",
            "center": [cx, cy], "radius": radius,
            "width": _stroke_width(g),
        })

    for g in _find_all(root, "fp_arc"):
        layer = _graphic_layer(g)
        if layer not in GRAPHIC_LAYERS:
            continue
        st, en, mid = _kv(g, "start"), _kv(g, "end"), _kv(g, "mid")
        if not (st and en):
            continue
        pts = [[_num(st[1]), _num(st[2])]]
        if mid:  # KiCad 7/8 three-point arc
            pts.append([_num(mid[1]), _num(mid[2])])
        pts.append([_num(en[1]), _num(en[2])])
        entry = {
            "layer": layer, "kind": "arc",
            "points": pts, "width": _stroke_width(g),
        }
        ang = _kv(g, "angle")  # KiCad 6 start/end/angle form
        if ang and len(ang) > 1:
            entry["angle"] = _num(ang[1])
        graphics.append(entry)

    for g in _find_all(root, "fp_poly"):
        layer = _graphic_layer(g)
        if layer not in GRAPHIC_LAYERS:
            continue
        pts_node = _kv(g, "pts")
        if not pts_node:
            continue
        pts = [[_num(xy[1]), _num(xy[2])]
               for xy in pts_node if isinstance(xy, list) and xy and xy[0] == "xy"]
        graphics.append({
            "layer": layer, "kind": "poly",
            "points": pts, "width": _stroke_width(g),
        })

    # Rectangles normalize to the one downstream polygon form. KiCad stores
    # opposing corners; preserve a deterministic clockwise local-point order.
    for g in _find_all(root, "fp_rect"):
        layer = _graphic_layer(g)
        if layer not in GRAPHIC_LAYERS:
            continue
        st, en = _kv(g, "start"), _kv(g, "end")
        if not (st and en):
            continue
        x1, y1 = _num(st[1]), _num(st[2])
        x2, y2 = _num(en[1]), _num(en[2])
        graphics.append({
            "layer": layer,
            "kind": "poly",
            "source_kind": "rect",
            "points": [[x1, y1], [x2, y1], [x2, y2], [x1, y2]],
            "width": _stroke_width(g),
        })

    return graphics


def _fp_text_type(g: list) -> Union[str, None]:
    """The fp_text TYPE token (``reference`` / ``value`` / ``user``) — the 2nd
    element of ``(fp_text TYPE "content" (at ...) ...)``."""
    return _atom(g[1]) if len(g) > 1 else None


def _fp_text_hidden(g: list) -> bool:
    """True if the fp_text node is authored hidden. Covers both forms seen in
    the wild: KiCad 6's bare ``hide`` atom as a direct child of the fp_text
    node, and KiCad 7/8's ``(effects ... (hide yes))``. A bare ``(hide)`` with
    no value counts as hidden; an explicit ``(hide no)`` does not."""
    for c in g:
        if isinstance(c, str) and c == "hide":
            return True
    effects = _kv(g, "effects")
    if effects:
        h = _kv(effects, "hide")
        if h:
            if len(h) <= 1:
                return True
            return _atom(h[1]) not in ("no", False, "false")
    return False


def _is_captured_reference_fp_text(g: list) -> bool:
    """True for the ONE fp_text node 019f77fd6d69's fix captures: the
    footprint's own visible REFERENCE designator field on F.SilkS with a
    usable ``(at x y)``. Never ``value``/``user`` text (those stay
    unrendered — docs/gerbers.md), never B.SilkS/F.Fab (frozen
    fab_capability.py boundary — this module never widens what the emitter
    claims to fabricate, only WHERE on F.SilkS the already-shipped stroke
    designator gets drawn). Shared by :func:`_parse_reference_text` (which
    captures it) and :func:`_uncaptured_graphics` (which must stop calling it
    omitted once it is)."""
    if _fp_text_type(g) != "reference":
        return False
    if _graphic_layer(g) != "F.SilkS":
        return False
    # A HIDDEN reference is CAPTURED, not dropped (bug 019ff2a6ce1b, owner
    # ruling 2026-08-12: hide means hidden). Dropping it here had two wrong
    # consequences at once: the authored anchor vanished, so the designator
    # synthesized at the DEFAULT anchor anyway — hide moved the text instead
    # of removing it — and the node was warned as an uncaptured graphic.
    # Visibility rides the parsed dict as its own field; suppression happens
    # at the one glyph owner (silk_source.refdes_strokes), never here.
    at = _kv(g, "at")
    if not at or len(at) < 3:
        return False
    return _num(at[1]) is not None and _num(at[2]) is not None


def _parse_reference_text(root: Any) -> Union[dict, None]:
    """Extract the footprint's authored REFERENCE fp_text placement (local
    position, KiCad clockwise text rotation, font cap-height size), so the
    emitter can draw the synthesized designator stroke text where the
    footprint's author actually put it instead of always using a fixed
    default offset (019f77fd6d69). Returns ``None`` when the footprint has no
    qualifying reference text (see :func:`_is_captured_reference_fp_text`) —
    callers then keep the pre-existing default placement, unchanged."""
    for g in _find_all(root, "fp_text"):
        if not _is_captured_reference_fp_text(g):
            continue
        at = _kv(g, "at")
        x, y = _num(at[1]), _num(at[2])
        rot = _num(at[3]) if len(at) > 3 else 0.0
        hidden = _fp_text_hidden(g)
        size_mm = 1.0
        effects = _kv(g, "effects")
        if effects:
            font = _kv(effects, "font")
            if font:
                sz = _kv(font, "size")
                if sz and len(sz) > 2:
                    a = _num(sz[1])
                    b = _num(sz[2])
                    # KiCad authors (size <a> <b>) where the two values are
                    # height/width. Every seed font is SQUARE, so the scalar is
                    # unambiguous when a == b. A non-square font would make the
                    # index choice load-bearing (and stroke_font.render only
                    # takes one cap-height scalar) — rather than bet on the
                    # order, refuse the capture: return None so the fp_text
                    # falls into the uncaptured-graphic marker (the documented
                    # degrade path) instead of silently mis-scaling.
                    if a is None or b is None or a <= 0 or b <= 0:
                        return None
                    if a != b:
                        return None
                    size_mm = a
        return {"x_mm": x, "y_mm": y, "rotation_deg": rot or 0.0,
                "size_mm": size_mm, "hidden": hidden}
    return None


def _uncaptured_graphics(root: Any, captured: list[dict]) -> list[dict]:
    """Surface every graphic that the modeled kind/layer matrix cannot hold.

    This includes supported primitives on unmodeled layers and unmodeled kinds
    (such as text) on otherwise modeled layers. One attributed marker per
    ``(layer, kind)`` makes the omission visible to capability policy.
    """
    # Count successful capture by SOURCE kind (rect normalizes to poly). This
    # makes a malformed known primitive visible too: if parsing could not emit
    # it, its source count remains after subtraction and becomes a marker.
    captured_counts: dict = {}
    for graphic in captured:
        key = (graphic.get("layer"), graphic.get("source_kind") or graphic.get("kind"))
        captured_counts[key] = captured_counts.get(key, 0) + 1

    counts: dict = {}
    order: list = []
    for tag in _FAB_GRAPHIC_TAGS:
        kind = tag[len("fp_"):]  # line / circle / arc / poly
        for g in _find_all(root, tag):
            # 019f77fd6d69: the footprint's own visible reference-designator
            # fp_text on F.SilkS is now captured (see
            # _is_captured_reference_fp_text) — it must stop being counted as
            # an omission. Every OTHER fp_text (value/user, hidden, missing
            # (at ...), or on any other layer) still counts exactly as before.
            if tag == "fp_text" and _is_captured_reference_fp_text(g):
                continue
            layer = _graphic_layer(g)
            key = (layer, kind)
            if (tag in _CAPTURED_GRAPHIC_TAGS and layer in GRAPHIC_LAYERS
                    and captured_counts.get(key, 0) > 0):
                captured_counts[key] -= 1
                continue
            if key not in counts:
                counts[key] = 0
                order.append(key)
            counts[key] += 1

    markers: list[dict] = []
    for (layer, kind) in order:
        n = counts[(layer, kind)]
        if layer not in GRAPHIC_LAYERS:
            reason = "outside the modeled layer set"
        elif kind in _CAPTURED_GRAPHIC_KINDS:
            reason = "malformed or unsupported source form"
        else:
            reason = "unsupported graphic kind"
        markers.append({
            "feature": "uncaptured_graphic",
            "layer": layer,
            "kind": kind,
            "count": n,
            "detail": (
                f"{n} fp_{kind} on layer {layer!r} not captured: {reason}"
            ),
        })
    return markers


def parse_kicad_mod(path_or_text: Union[str, Path]) -> dict:
    """Parse a ``.kicad_mod`` footprint.

    Accepts a :class:`pathlib.Path`, a filesystem path string, or the raw
    file text. Returns::

        {
          "name": str,
          "pads": [{number, type, shape, x_mm, y_mm, size:[w,h], drill, layers}],
          "graphics": [{layer, kind, ...coords, width}],
          "reference_text": {x_mm, y_mm, rotation_deg, size_mm},  # optional
        }

    ``reference_text`` (019f77fd6d69) is present only when the footprint has a
    visible, well-formed ``reference`` fp_text on F.SilkS — see
    ``_parse_reference_text``. Its absence changes nothing: the emitter falls
    back to the pre-existing default designator placement.

    The eight original pad keys above stay byte-identical. K1
    (lossless-or-flagging) adds, only when the source carries them: per-pad
    ``rotation`` / ``roundrect_rratio`` / ``drill_shape`` +
    ``drill_size`` / ``solder_mask_margin`` / ``solder_paste_margin`` and a pad
    ``unsupported`` list (custom primitives, drill offset, chamfer, local
    clearance, zone connect, and a nonzero ``solder_paste_margin_ratio``); plus a
    top-level ``unsupported`` list of attributed markers for graphics outside the
    modeled kind/layer, and for FOOTPRINT-level ``solder_paste_margin_ratio`` /
    ``solder_paste_ratio``
    matrix.

    All coordinates are footprint-LOCAL (no board transform applied).
    """
    if isinstance(path_or_text, Path):
        text = path_or_text.read_text(encoding="utf-8")
    else:
        s = path_or_text
        if "\n" in s or s.lstrip().startswith("("):
            text = s
        else:
            text = Path(s).read_text(encoding="utf-8")

    root = _parse(_tokenize(text))
    # root[0] is 'module' (KiCad 5/6) or 'footprint' (KiCad 6+); root[1] is name.
    name = _atom(root[1]) if len(root) > 1 else ""
    pads = [_parse_pad(p) for p in _find_all(root, "pad")]
    graphics = _parse_graphics(root)
    result = {"name": name, "pads": pads, "graphics": graphics}
    # 019f77fd6d69 ADDITIVE: the footprint's own reference-designator fp_text
    # placement, when it qualifies (see _parse_reference_text) — a NEW
    # top-level key, added only when present, so a footprint with none (or an
    # unqualifying one) stays byte-identical to before this fix.
    reference_text = _parse_reference_text(root)
    if reference_text is not None:
        result["reference_text"] = reference_text
    # K1 ADDITIVE: surface fab geometry on layers we do not capture as an
    # attributed marker list (NEW top-level key, added only when non-empty so
    # footprints with only silk/courtyard graphics stay byte-identical).
    uncaptured = _uncaptured_graphics(root, graphics)

    # FOOTPRINT-LEVEL paste-ratio overrides. KiCad carries these on the
    # footprint container, NOT the pad (gerbonara's KiCad model puts
    # solder_paste_margin_ratio and solder_paste_ratio on Footprint, not Pad),
    # and they apply to EVERY pad in the footprint. _parse_pad only reads direct
    # children of a pad node, so without this they were silently dropped at a
    # BROADER scope than the per-pad hole 019fb0155d93 describes.
    #
    # Attributed to F.Paste so the marker lands in FeatureDomain.PASTE and
    # therefore blocks: a footprint-level marker with no "layer" key falls to
    # _raw_marker's else-branch with pad_layers=(), where _layer_domain(None)
    # returns DOCUMENTATION -- which is NOT fatal. The explicit layer is what
    # makes this fail closed rather than warn.
    #
    # Unlike the per-pad case this does NOT gate on a declared paste layer: the
    # override applies footprint-wide, so the pads it would affect are not
    # knowable from the container node alone. A ratio of exactly 0.0 is skipped
    # for the same reason as the per-pad path -- it means "aperture equals the
    # copper land", which is what we already emit.
    for _fp_ratio_key in ("solder_paste_margin_ratio", "solder_paste_ratio"):
        _node = _kv(root, _fp_ratio_key)
        if _node is None or len(_node) <= 1:
            continue
        _val = _num(_node[1])
        if _val is None or _val == 0.0:
            continue
        uncaptured = list(uncaptured) + [{
            "feature": _fp_ratio_key,
            "layer": "F.Paste",
            "detail": (
                f"footprint {name!r} declares {_fp_ratio_key}={_val!r} at "
                f"FOOTPRINT level, which applies to every pad it contains; "
                f"this proportional stencil margin is not modeled, so without "
                f"this refusal every paste aperture in the footprint would be "
                f"cut from the copper land instead of the ratio-adjusted size"
            ),
        }]

    if uncaptured:
        result["unsupported"] = uncaptured
    return result


# ---------------------------------------------------------------------------
# Seed-library lookup (sha256-verified, offline).
# ---------------------------------------------------------------------------


def sha256_file(path: Path) -> str:
    """SHA-256 of *path*'s bytes (hex)."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_lockfile(lockfile: Union[str, Path, None] = None) -> dict:
    """Load the footprint lockfile: ``{ref: {path, sha256}}``."""
    lf = Path(lockfile) if lockfile else DEFAULT_LOCKFILE
    return json.loads(lf.read_text(encoding="utf-8"))


class FootprintLookupError(Exception):
    """Raised when a ref is unknown or its file fails sha verification."""


def resolve_footprint(
    ref: str,
    library_root: Union[str, Path, None] = None,
    lockfile: Union[str, Path, None] = None,
    lock: Union[dict, None] = None,
) -> dict:
    """Resolve a footprint ``ref`` (``"LibNick:Name"``) to a parsed footprint.

    Looks the ref up in the seed-library lockfile, verifies the on-disk file's
    sha256 against the pin, then parses it. No network access -- on-demand
    fetch of un-vendored footprints is a deferred item.

    A caller that already holds a validated lock snapshot (e.g. the K2 compiler,
    which loads it once) may pass it as ``lock`` to avoid a per-call reload and
    the two-authority/TOCTOU risk that creates (K2 review 623 R7).
    """
    root = Path(library_root) if library_root else DEFAULT_LIBRARY_ROOT
    if lock is None:
        lock = load_lockfile(lockfile)

    entry = lock.get(ref)
    if entry is None:
        raise FootprintLookupError(
            f"footprint ref {ref!r} is not in the seed library lockfile"
        )

    fp_path = root / entry["path"]
    if not fp_path.exists():
        raise FootprintLookupError(f"footprint file missing: {fp_path}")

    actual = sha256_file(fp_path)
    if actual != entry["sha256"]:
        raise FootprintLookupError(
            f"sha256 mismatch for {ref!r}: lock={entry['sha256']} disk={actual}"
        )

    return parse_kicad_mod(fp_path)
