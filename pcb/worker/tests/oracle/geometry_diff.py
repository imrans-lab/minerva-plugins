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


def parse_drill_file(text: str, filename: str = "drill.drl") -> Counter:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        ef = ExcellonFile.from_string(text, filename=filename)
    hits: Counter = Counter()
    for o in ef.objects:
        hits[(_r(o.x), _r(o.y), round(float(o.tool.diameter), _ROUND))] += 1
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
        for (x, y, dia) in hits:
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

    category: str   # flash | segment | arc | region | aperture | drill | registration
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

    # --- Drills (per class). ---
    for cls in sorted(set(current.drills) | set(golden.drills)):
        c = current.drills.get(cls, Counter())
        g = golden.drills.get(cls, Counter())
        _diff_counter(
            deltas, cls, c, g,
            lambda k: f"drill Ø{k[2]}mm at ({k[0]}, {k[1]})",
            lambda k: "drill",
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
