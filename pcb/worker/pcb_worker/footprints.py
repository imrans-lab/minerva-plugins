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

# Graphics layers we extract. Silkscreen is the visible body outline / pin-1
# markers; courtyard is the keep-out boundary. Everything else (F.Fab,
# Cmts.User, F.Mask, ...) is intentionally dropped.
GRAPHIC_LAYERS = frozenset({"F.SilkS", "F.CrtYd"})

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

    Position/size/drill/layers come from nested lists; a pad's own ``at``
    rotation (3rd value) is ignored -- it does not move the pad centre.
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

    return {
        "number": number,
        "type": pad_type,
        "shape": shape,
        "x_mm": x,
        "y_mm": y,
        "size": size,
        "drill": drill,
        "layers": layers,
    }


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


def parse_kicad_mod(path_or_text: Union[str, Path]) -> dict:
    """Parse a ``.kicad_mod`` footprint.

    Accepts a :class:`pathlib.Path`, a filesystem path string, or the raw
    file text. Returns::

        {
          "name": str,
          "pads": [{number, type, shape, x_mm, y_mm, size:[w,h], drill, layers}],
          "graphics": [{layer, kind, ...coords, width}],  # F.SilkS + F.CrtYd
        }

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
    return {"name": name, "pads": pads, "graphics": graphics}


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
