"""KiCad footprint (`.kicad_mod`) parser + seed-library lookup.

This module turns a real KiCad footprint into the geometry Minerva needs to
render a component as more than a bare pad-cluster: its PADS *and* its
silkscreen (``F.SilkS``) + courtyard (``F.CrtYd``) graphics. Coordinates are
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

# Graphics layers we CAPTURE as real geometry. Silkscreen is the visible body
# outline / pin-1 markers; courtyard is the keep-out boundary. Fab-affecting
# primitives on OTHER layers (F.Fab, F.Mask, B.SilkS, ...) are NOT modeled --
# but they are no longer silently dropped: ``_uncaptured_graphics`` surfaces an
# attributed marker for each so a downstream compiler can fail closed on data
# the parser could not represent (K1: lossless-or-flagging).
GRAPHIC_LAYERS = frozenset({"F.SilkS", "F.CrtYd"})

# fp_* geometry tags scanned when surfacing uncaptured fab graphics.
_FAB_GRAPHIC_TAGS = ("fp_line", "fp_circle", "fp_arc", "fp_poly")

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
        radius = math.hypot(_num(en[1]) - cx, _num(en[2]) - cy)
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

    return graphics


def _uncaptured_graphics(root: Any) -> list[dict]:
    """Surface (never silently filter) fab-affecting graphic primitives that
    fall OUTSIDE the captured ``GRAPHIC_LAYERS``.

    ``_parse_graphics`` keeps F.SilkS/F.CrtYd exactly as before; this reuses the
    SAME ``_find_all`` + ``_graphic_layer`` helpers to enumerate fp_line/circle/
    arc/poly on every OTHER layer (F.Fab, F.Mask, B.SilkS, ...) and returns one
    attributed marker per (layer, kind), so a downstream compiler sees the
    data-loss instead of it being dropped. No coordinates are captured -- these
    layers are not modeled -- only that geometry EXISTS there is reported.
    """
    counts: dict = {}
    order: list = []
    for tag in _FAB_GRAPHIC_TAGS:
        kind = tag[len("fp_"):]  # line / circle / arc / poly
        for g in _find_all(root, tag):
            layer = _graphic_layer(g)
            if layer in GRAPHIC_LAYERS:
                continue  # captured verbatim by _parse_graphics
            key = (layer, kind)
            if key not in counts:
                counts[key] = 0
                order.append(key)
            counts[key] += 1

    markers: list[dict] = []
    for (layer, kind) in order:
        n = counts[(layer, kind)]
        markers.append({
            "feature": "uncaptured_graphic",
            "layer": layer,
            "kind": kind,
            "count": n,
            "detail": (
                f"{n} fp_{kind} on layer {layer!r} not captured "
                f"(outside {sorted(GRAPHIC_LAYERS)})"
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
          "graphics": [{layer, kind, ...coords, width}],  # F.SilkS + F.CrtYd
        }

    The eight pad keys above and the ``graphics`` list are byte-identical to
    prior behavior. K1 (lossless-or-flagging) ADDS, only when the source carries
    them: per-pad ``rotation`` / ``roundrect_rratio`` / ``drill_shape`` +
    ``drill_size`` / ``solder_mask_margin`` / ``solder_paste_margin`` and a pad
    ``unsupported`` list (custom primitives); plus a top-level ``unsupported``
    list of attributed markers for fab graphics on layers we do not capture.

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
    # K1 ADDITIVE: surface fab geometry on layers we do not capture as an
    # attributed marker list (NEW top-level key, added only when non-empty so
    # footprints with only silk/courtyard graphics stay byte-identical).
    uncaptured = _uncaptured_graphics(root)
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
) -> dict:
    """Resolve a footprint ``ref`` (``"LibNick:Name"``) to a parsed footprint.

    Looks the ref up in the seed-library lockfile, verifies the on-disk file's
    sha256 against the pin, then parses it. No network access -- on-demand
    fetch of un-vendored footprints is a deferred item.
    """
    root = Path(library_root) if library_root else DEFAULT_LIBRARY_ROOT
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
