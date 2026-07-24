"""DEV/TEST-ONLY structured GEOMETRY diff for fabrication output sets.

This is the anti-circularity control of the fabrication-verification harness
(docket SB.2, 019f77117376). It complements — it does NOT duplicate — the two
existing guards:

  * SB.3's determinism gate proves the emitter is REPRODUCIBLE (same input ->
    same BYTES). That is not the same as CORRECT: a reproducibly-wrong exporter
    is still wrong.
  * A golden pins "known-good output", but only if some INDEPENDENT authority
    confirmed it (see provenance.py + PROVENANCE.json). A golden with no
    blessed=true provenance entry is a DRIFT PIN, never a correctness oracle.

What THIS module adds: a diff at the GEOMETRY level, not the byte level (SB.3
owns bytes). It gerbonara-parses two output sets and compares apertures/pads,
traces, arcs, regions, the board outline, drills (count + diameters + positions)
and drill-to-copper registration. It returns STRUCTURED deltas — a list naming
exactly what changed and where — not a bool, so a regression test can pin drift
and a teeth test can prove the diff detects a real perturbation.

Reuses the gerbonara-parse idioms from tests/oracle/test_gerbonara_roundtrip.py.
Depends ONLY on gerbonara (a dev/test reader — no kicad-cli, no runtime import;
nothing under pcb_worker may import this).
"""

from __future__ import annotations

import warnings
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

from gerbonara import ExcellonFile, GerberFile
from gerbonara.ipc356 import Netlist

# Coordinate/dimension rounding for canonical keys. 4 decimals of a millimetre
# is 0.1 micron — far finer than any fab tolerance, coarse enough that emitter
# float noise below fab precision never registers as a spurious delta.
_ROUND = 4

# Copper layers a plated drill must land inside (drill-to-copper registration).
_COPPER_SUFFIXES = ("F_Cu", "B_Cu")


def _r(v) -> float:
    return round(float(v), _ROUND)


# ---------------------------------------------------------------------------
# Canonical keys: every parsed graphic/drill collapses to a hashable tuple whose
# FIRST element is its category, so a Counter symmetric-difference yields the
# structured delta directly.
# ---------------------------------------------------------------------------


def _aperture_sig(ap) -> tuple:
    """Shape + rounded dimensions of an aperture / drill tool.

    Robust across gerbonara aperture classes (Circle/Rectangle/Obround/Polygon/
    ExcellonTool) by name + a fixed set of numeric attributes; unknown macro
    apertures fall back to their repr so a change still registers.
    """
    if ap is None:
        return ("none",)
    name = type(ap).__name__
    base = name.replace("Aperture", "").replace("Excellon", "").lower()
    dims: list[tuple[str, float]] = []
    for attr in ("diameter", "w", "h", "n_vertices",
                 "inner_diameter", "outer_diameter"):
        v = getattr(ap, attr, None)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            dims.append((attr, round(float(v), _ROUND)))
    hole = getattr(ap, "hole_dia", None)
    if isinstance(hole, (int, float)) and not isinstance(hole, bool) and hole:
        dims.append(("hole", round(float(hole), _ROUND)))
    if not dims:
        return (base, repr(ap))
    return (base, tuple(dims))


def _bbox_key(o) -> tuple:
    try:
        (x0, y0), (x1, y1) = o.bounding_box()
        return (_r(x0), _r(y0), _r(x1), _r(y1))
    except Exception:  # noqa: BLE001 — diagnostic tool, never crash the diff
        return (repr(o),)


def _object_key(o) -> tuple:
    """Canonical, category-tagged key for one parsed Gerber graphic object."""
    t = type(o).__name__
    if t == "Flash":
        return ("flash", (_r(o.x), _r(o.y)), _aperture_sig(o.aperture))
    if t == "Line":
        a, b = (_r(o.x1), _r(o.y1)), (_r(o.x2), _r(o.y2))
        # Endpoint order is not geometrically meaningful — sort so a reversed
        # segment is not reported as a change.
        return ("segment", tuple(sorted((a, b))), _aperture_sig(o.aperture))
    if t == "Arc":
        a, b = (_r(o.x1), _r(o.y1)), (_r(o.x2), _r(o.y2))
        cx, cy = _r(getattr(o, "cx", 0.0) or 0.0), _r(getattr(o, "cy", 0.0) or 0.0)
        ccw = bool(getattr(o, "clockwise", getattr(o, "ccw", False)))
        return ("arc", (a, b, (cx, cy), ccw), _aperture_sig(getattr(o, "aperture", None)))
    if t == "Region":
        return ("region", _bbox_key(o))
    return (t.lower(), _bbox_key(o))


# ---------------------------------------------------------------------------
# Parsed model.
# ---------------------------------------------------------------------------


@dataclass
class LayerGeometry:
    """One Gerber layer: a multiset of category-tagged graphic keys, plus the
    dedup'd set of apertures actually used on the layer."""

    objects: Counter = field(default_factory=Counter)
    apertures: Counter = field(default_factory=Counter)


@dataclass
class OutputGeometry:
    """A whole fabrication output set: Gerber layers keyed by suffix (F_Cu, ...)
    and drill files keyed by class (PTH / NPTH)."""

    layers: dict[str, LayerGeometry] = field(default_factory=dict)
    drills: dict[str, Counter] = field(default_factory=dict)


def _suffix(filename: str) -> str:
    """`board-F_Cu.gbr` -> `F_Cu`; `board-PTH.drl` -> `PTH`."""
    stem = Path(filename).stem
    return stem.rsplit("-", 1)[-1] if "-" in stem else stem


def parse_gerber_layer(text: str, filename: str = "layer.gbr") -> LayerGeometry:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        gf = GerberFile.from_string(text, filename=filename)
    lg = LayerGeometry()
    for o in gf.objects:
        lg.objects[_object_key(o)] += 1
        ap = getattr(o, "aperture", None)
        if ap is not None:
            lg.apertures[_aperture_sig(ap)] += 1
    return lg


def _drill_key(o) -> tuple:
    """Canonical, stable key for one parsed Excellon object.

    A point drill is a ``Flash`` -> ``(x, y, diameter)`` (unchanged legacy
    3-float form). A ROUTED SLOT parses as a ``Line`` (start/end + a routing
    tool) -> ``("slot", (p_lo, p_hi), width)`` where the endpoints are sorted so
    a reversed slot is not a spurious change and ``width`` is the tool diameter.
    The literal-string first element distinguishes slots from point drills for
    every downstream consumer.
    """
    t = type(o).__name__
    if t == "Line":
        a, b = (_r(o.x1), _r(o.y1)), (_r(o.x2), _r(o.y2))
        return ("slot", tuple(sorted((a, b))), round(float(o.tool.diameter), _ROUND))
    # Flash (point drill) — legacy behaviour.
    return (_r(o.x), _r(o.y), round(float(o.tool.diameter), _ROUND))


def _is_slot_key(key: tuple) -> bool:
    return bool(key) and key[0] == "slot"


def parse_drill_file(text: str, filename: str = "drill.drl") -> Counter:
    """Parse an Excellon drill file into a multiset of canonical drill keys.

    Handles point drills (``Flash``) AND routed slots (``Line``) — a slot no
    longer crashes the harness (docket 019f7772eca0). See ``_drill_key``.
    """
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        ef = ExcellonFile.from_string(text, filename=filename)
    hits: Counter = Counter()
    for o in ef.objects:
        hits[_drill_key(o)] += 1
    return hits


def parse_output_set(files: dict[str, str]) -> OutputGeometry:
    """Parse a {filename: text} output set (from build_gerbers or a golden dir)
    into the canonical geometry model."""
    out = OutputGeometry()
    for name, text in files.items():
        if name.endswith(".gbr"):
            out.layers[_suffix(name)] = parse_gerber_layer(text, name)
        elif name.endswith(".drl"):
            out.drills[_suffix(name)] = parse_drill_file(text, name)
    return out


def load_output_dir(path: str | Path) -> dict[str, str]:
    """Read a golden directory into a {filename: text} set (Gerbers + drills)."""
    p = Path(path)
    files: dict[str, str] = {}
    for f in sorted(p.iterdir()):
        if f.suffix in (".gbr", ".drl"):
            files[f.name] = f.read_text(encoding="utf-8")
    return files


# ---------------------------------------------------------------------------
# Registration (drill-to-copper): every PLATED drill hit must land on a copper
# flash (annulus/pad). Non-plated holes (NPTH) intentionally have no copper.
# ---------------------------------------------------------------------------


def _copper_flash_positions(output: OutputGeometry) -> set[tuple[float, float]]:
    pos: set[tuple[float, float]] = set()
    for suffix in _COPPER_SUFFIXES:
        lg = output.layers.get(suffix)
        if not lg:
            continue
        for key in lg.objects:
            if key[0] == "flash":
                pos.add(key[1])  # (x, y)
    return pos


def registration_violations(output: OutputGeometry) -> list[tuple]:
    """Plated drill hits with NO coincident copper flash: (class, x, y, dia).

    Positions from the emitter align exactly (a plated hole is drilled at its
    pad centre), so an exact rounded-coordinate match is the correct test.
    """
    copper = _copper_flash_positions(output)
    bad: list[tuple] = []
    for cls, hits in output.drills.items():
        if cls.upper() != "PTH":  # only plated holes require copper
            continue
        for key in hits:
            if _is_slot_key(key):
                continue  # routed slots are cutouts, not annulus-backed holes
            (x, y, dia) = key
            if (x, y) not in copper:
                bad.append((cls, x, y, dia))
    return sorted(bad)


# ---------------------------------------------------------------------------
# Structured delta + diff.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Delta:
    """One structured geometry difference.

    change: 'added'   -> present in CURRENT but not GOLDEN
            'removed' -> present in GOLDEN but not CURRENT
            'registration' -> a plated drill lacking copper (in one set only)
    """

    category: str   # flash | segment | arc | region | aperture | drill | slot | netlist | registration
    layer: str      # layer suffix, drill class, or '*'
    change: str
    detail: str

    def __str__(self) -> str:
        return f"[{self.change:10s}] {self.layer:9s} {self.category:12s} {self.detail}"


@dataclass
class GeometryDiff:
    deltas: list[Delta] = field(default_factory=list)

    @property
    def is_empty(self) -> bool:
        return not self.deltas

    def categories(self) -> set[str]:
        return {d.category for d in self.deltas}

    def layers_changed(self) -> set[str]:
        return {d.layer for d in self.deltas}

    def excluding_layers(self, *names: str) -> "GeometryDiff":
        """A copy of this diff with all deltas on the named layers dropped.

        Used to scope a correctness assertion to the layers a golden genuinely
        pins. A synthetic golden can be a trusted oracle for the fabrication-
        critical geometry it was blessed against (copper/mask/drill/edge) while
        NOT being a meaningful oracle for a cosmetic legend layer (F.SilkS),
        which carries only real footprint silk graphics (K4: the procedural
        courtyard-box placeholder is retired). Excluding such a layer is NOT
        hiding a defect: silk correctness is earned separately, against real
        footprints that carry real silk graphics (see the silk-text/coverage-
        audit follow-ups), not by pinning to a synthetic golden.
        """
        drop = set(names)
        return GeometryDiff([d for d in self.deltas if d.layer not in drop])

    def describe(self) -> str:
        if not self.deltas:
            return "GeometryDiff: (empty — geometry identical)"
        head = f"GeometryDiff: {len(self.deltas)} delta(s)"
        return "\n".join([head, *(f"  {d}" for d in self.deltas)])


def _describe_key(key: tuple) -> str:
    cat = key[0]
    if cat == "flash":
        return f"pad/flash at {key[1]} aperture {key[2]}"
    if cat == "segment":
        return f"trace {key[1][0]}->{key[1][1]} width {key[2]}"
    if cat == "arc":
        return f"arc {key[1]} aperture {key[2]}"
    if cat == "region":
        return f"region bbox {key[1]}"
    return f"{cat} {key[1:]}"


def _describe_drill_key(key: tuple) -> str:
    """Human-readable label for a point-drill OR routed-slot drill key."""
    if _is_slot_key(key):
        (p_lo, p_hi), width = key[1], key[2]
        return f"routed slot Ø{width}mm {p_lo}->{p_hi}"
    return f"drill Ø{key[2]}mm at ({key[0]}, {key[1]})"


def _diff_counter(deltas: list[Delta], layer: str, current: Counter,
                  golden: Counter, describe, category_of) -> None:
    """Multiset symmetric difference -> added/removed deltas."""
    for key, n in (current - golden).items():
        for _ in range(n):
            deltas.append(Delta(category_of(key), layer, "added", describe(key)))
    for key, n in (golden - current).items():
        for _ in range(n):
            deltas.append(Delta(category_of(key), layer, "removed", describe(key)))


def diff_geometry(current: OutputGeometry, golden: OutputGeometry) -> GeometryDiff:
    """Structured GEOMETRY diff of two parsed output sets (current vs golden).

    Compares, per layer: graphic objects (pads/flashes, traces, arcs, regions,
    board outline) and the dedup'd aperture set; across the set: drills (count +
    diameter + position, per PTH/NPTH class) and drill-to-copper registration.
    """
    deltas: list[Delta] = []

    # --- Per-layer graphics + apertures. ---
    for suffix in sorted(set(current.layers) | set(golden.layers)):
        c = current.layers.get(suffix, LayerGeometry())
        g = golden.layers.get(suffix, LayerGeometry())
        _diff_counter(deltas, suffix, c.objects, g.objects,
                      _describe_key, lambda k: k[0])
        _diff_counter(deltas, suffix, c.apertures, g.apertures,
                      lambda k: f"aperture {k}", lambda k: "aperture")

    # --- Drills (per class) — point drills AND routed slots. ---
    for cls in sorted(set(current.drills) | set(golden.drills)):
        c = current.drills.get(cls, Counter())
        g = golden.drills.get(cls, Counter())
        _diff_counter(
            deltas, cls, c, g,
            _describe_drill_key,
            lambda k: "slot" if _is_slot_key(k) else "drill",
        )

    # --- Registration (only differences between the two sets). ---
    cur_bad = set(registration_violations(current))
    gold_bad = set(registration_violations(golden))
    for (cls, x, y, dia) in sorted(cur_bad - gold_bad):
        deltas.append(Delta("registration", cls, "added",
                            f"plated drill Ø{dia}mm at ({x}, {y}) has NO copper annulus"))
    for (cls, x, y, dia) in sorted(gold_bad - cur_bad):
        deltas.append(Delta("registration", cls, "removed",
                            f"plated drill Ø{dia}mm at ({x}, {y}) had NO copper annulus in golden"))

    return GeometryDiff(deltas)


def diff_output_sets(current_files: dict[str, str],
                     golden_files: dict[str, str]) -> GeometryDiff:
    """Convenience: parse both {filename: text} sets and diff their geometry."""
    return diff_geometry(parse_output_set(current_files),
                         parse_output_set(golden_files))


# ---------------------------------------------------------------------------
# IPC-356 (IPC-D-356A) netlist diff — the electrical companion to the geometry
# diff. Each test record collapses to a canonical, category-tagged key so the
# same Counter symmetric-difference yields added/removed Deltas; a CHANGED
# record surfaces as a removed(old)+added(new) pair, exactly as a moved pad does
# in the geometry diff.
# ---------------------------------------------------------------------------


def _netlist_record_key(rec) -> tuple:
    """Canonical key for one IPC-356 TestRecord: net + pad/location + plating.

    Includes ref-des and pad-type for identity; ``pin_num`` is deliberately
    excluded — gerbonara 1.6.3 does not round-trip it (reads back as None).
    """
    net = getattr(rec, "net_name", None)
    ref = getattr(rec, "ref_des", None)
    x, y = getattr(rec, "x", None), getattr(rec, "y", None)
    loc = (_r(x) if x is not None else None, _r(y) if y is not None else None)
    pt = getattr(rec, "pad_type", None)
    pad_type = getattr(pt, "name", None) or (repr(pt) if pt is not None else None)
    plated = getattr(rec, "is_plated", None)
    hole = getattr(rec, "hole_dia", None)
    hole = _r(hole) if isinstance(hole, (int, float)) and not isinstance(hole, bool) else None
    return ("netlist", net, ref, loc, pad_type, plated, hole)


def parse_ipc356_file(text: str, filename: str = "board.ipc356") -> Counter:
    """Parse an IPC-356 netlist into a multiset of canonical record keys.

    Thin gerbonara 1.6.3 read-bug workaround: ``Netlist.from_string`` calls
    ``Path(filename)`` unconditionally, so ``filename=None`` raises TypeError —
    we always pass an explicit filename. The ``lefover``/``leftover`` typo and
    the ``None.copy()`` crash are WRITE-path bugs and do not bite reading.
    """
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        nl = Netlist.from_string(text, filename=filename)
    hits: Counter = Counter()
    for rec in nl.objects:
        hits[_netlist_record_key(rec)] += 1
    return hits


def _describe_netlist_key(key: tuple) -> str:
    _, net, ref, loc, pad_type, plated, hole = key
    plate = "plated" if plated else ("nonplated" if plated is not None else "?plating")
    hole_s = f" Ø{hole}mm" if hole is not None else ""
    return f"net {net!r} {ref} {pad_type} at {loc} [{plate}]{hole_s}"


def diff_netlists(current: Counter, golden: Counter) -> GeometryDiff:
    """Structured diff of two parsed IPC-356 record multisets (current vs golden).

    Returns a ``GeometryDiff`` of ``category='netlist'`` Deltas — 'added' present
    only in current, 'removed' present only in golden. A changed record is a
    removed+added pair (same idiom as a moved pad in the geometry diff).
    """
    deltas: list[Delta] = []
    _diff_counter(deltas, "ipc356", current, golden,
                  _describe_netlist_key, lambda k: "netlist")
    return GeometryDiff(deltas)


def diff_ipc356_files(current_text: str, golden_text: str,
                      current_name: str = "board.ipc356",
                      golden_name: str = "board.ipc356") -> GeometryDiff:
    """Convenience: parse two IPC-356 texts and diff their netlist records."""
    return diff_netlists(parse_ipc356_file(current_text, current_name),
                         parse_ipc356_file(golden_text, golden_name))
