"""DEV/TEST-ONLY pcbnew ZONE_FILLER oracle — an INDEPENDENT judge for pour fill.

WHY THIS EXISTS. Zone fill is the one piece of CAM geometry that cannot be
graded against our own rules. The filler carves the pour by inflating foreign
copper by a clearance and subtracting it; a clearance check over that output
asks the filler whether it obeyed itself, and the answer is always yes. Docket
hint ``019faf103eee`` names the same trap from the other side: a KiCad export of
OUR board is not an oracle for anything we authored into it.

The escape is to make KiCad DO THE FILLING. We author an outline plus rules —
never a fill polygon — hand it to ``pcbnew.ZONE_FILLER``, and read back the
polygon KiCad computed from geometry it derived itself. That is an independent
judge: a different codebase, a different algorithm, run on the same inputs.

WHAT IT RETURNS (measured against KiCad 9.0.9, 2026-08-02):
  * INTEGER NANOMETRE coordinates. KiCad's filler is exact integer arithmetic,
    which happens to be the same domain the worker's filler and the emitted
    Gerber (``%FSLAX36Y36``, 6 decimals = nm) both live in. No float tolerance
    is needed to compare.
  * FRACTURED contours: a pour with a void comes back as ONE self-touching
    "keyhole" outline (``OutlineCount()==1``, ``HoleCount(0)==0``), not as an
    outline plus a hole. This is not an implementation detail to work around —
    it is the same representation ``gerber_writer.DataLayer.add_region`` forces
    on us, since that API has no hole support at all.

BOUNDARY (STANDING GUARD 2, ``tests/test_kicad_cli_boundary.py``). This module
lives under ``tests/`` and reaches KiCad's Python bindings. KiCad is a DEV/CI
tool: there is none on the deploy target. ``pcbnew`` must NEVER be importable
from ``pcb_worker`` runtime — the boundary lint greps for it.

WHY A SUBPROCESS. The worker venv is built with
``include-system-site-packages = false``, so ``import pcbnew`` is not reachable
from the test interpreter at all. KiCad installs its bindings into the system
python's ``dist-packages``. Shelling out to the system interpreter is the same
shape ``kicad_drc.py`` already uses for ``kicad-cli`` — and it keeps KiCad's
several-hundred-megabyte native library out of the test process.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

NM_PER_MM = 1_000_000

# The system interpreter KiCad installs `pcbnew` against. NOT the worker venv
# (see the module docstring): the venv cannot see system site-packages.
SYSTEM_PYTHON = "/usr/bin/python3"

# Runs INSIDE the system interpreter. Kept as a literal string rather than a
# checked-in .py so there is exactly one file to read and no chance of the
# harness and its payload drifting apart. Reads a JSON request on argv, writes a
# JSON response on stdout.
_PROBE = r'''
import json, sys, os, tempfile
sys.path.insert(0, "/usr/lib/python3/dist-packages")
import pcbnew

req = json.loads(sys.argv[1])
path = os.path.join(tempfile.mkdtemp(), "oracle.kicad_pcb")
with open(path, "w") as fh:
    fh.write(req["pcb"])

board = pcbnew.LoadBoard(path)
zones = board.Zones()
filler = pcbnew.ZONE_FILLER(board)
ok = filler.Fill(zones)

out = {"filled": bool(ok), "version": pcbnew.GetBuildVersion(), "zones": []}
for zone in zones:
    layer = zone.GetLayer()
    polys = zone.GetFilledPolysList(layer)
    contours = []
    for i in range(polys.OutlineCount()):
        outline = polys.Outline(i)
        contours.append({
            "points": [[outline.CPoint(j).x, outline.CPoint(j).y]
                       for j in range(outline.PointCount())],
            "holes": polys.HoleCount(i),
        })
    out["zones"].append({
        "net": zone.GetNetname(),
        "layer": board.GetLayerName(layer),
        "is_rule_area": bool(zone.GetIsRuleArea()),
        # Area() is in nm^2 (integer domain squared) and is SIGNED per contour,
        # so a fractured keyhole's slit contributes zero and the net value is the
        # real copper area.
        "area_nm2": int(polys.Area()),
        "contours": contours,
    })
print(json.dumps(out))
'''


class OracleUnavailable(RuntimeError):
    """The pcbnew oracle could not be reached on this machine."""


@dataclass(frozen=True)
class OracleZone:
    """One zone as KiCad filled it."""

    net: str
    layer: str
    is_rule_area: bool
    area_nm2: int
    # Each contour is a tuple of integer-nm (x, y). A pour with voids arrives as
    # ONE fractured keyhole contour (see module docstring), so `holes` is
    # normally 0 — it is carried anyway so a future KiCad that stops fracturing
    # is a loud surprise rather than a silent area mismatch.
    contours: tuple[tuple[tuple[int, int], ...], ...]
    holes: tuple[int, ...]

    @property
    def area_mm2(self) -> float:
        return self.area_nm2 / (NM_PER_MM * NM_PER_MM)


@dataclass(frozen=True)
class OracleResult:
    filled: bool
    kicad_version: str
    zones: tuple[OracleZone, ...]


def pcbnew_available() -> bool:
    """True when the system interpreter can import ``pcbnew``.

    Cheap and side-effect-free, so tests can ``pytest.skip`` cleanly on a CI box
    with no KiCad rather than fail. NEVER swallow a failure of the fill ITSELF
    this way — that is a real result, and :func:`fill_zones` raises for it.
    """
    if not Path(SYSTEM_PYTHON).exists() and shutil.which(SYSTEM_PYTHON) is None:
        return False
    try:
        proc = subprocess.run(
            [SYSTEM_PYTHON, "-c",
             "import sys; sys.path.insert(0, '/usr/lib/python3/dist-packages'); "
             "import pcbnew; print(pcbnew.GetBuildVersion())"],
            capture_output=True, text=True, timeout=60.0)
    except (OSError, subprocess.SubprocessError):
        return False
    return proc.returncode == 0


def fill_zones(pcb_text: str, timeout: float = 120.0) -> OracleResult:
    """Fill every zone in a ``.kicad_pcb`` source string with pcbnew's filler.

    ``pcb_text`` must author the zone as an OUTLINE plus rules. If it carries a
    ``filled_polygon``, the oracle is no longer independent — it is reading our
    own answer back — so this refuses one outright rather than quietly producing
    a meaningless agreement.
    """
    if "filled_polygon" in pcb_text:
        raise ValueError(
            "zone_fill_oracle: the board source carries a (filled_polygon ...) — "
            "the oracle would be grading our own fill against itself. Author the "
            "zone OUTLINE and its rules only; KiCad must do the filling.")
    if not pcbnew_available():
        raise OracleUnavailable(
            f"{SYSTEM_PYTHON} cannot import pcbnew (KiCad not installed, or its "
            "python bindings are absent)")

    with tempfile.TemporaryDirectory():
        proc = subprocess.run(
            [SYSTEM_PYTHON, "-c", _PROBE, json.dumps({"pcb": pcb_text})],
            capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(
            f"zone_fill_oracle: pcbnew probe failed (rc={proc.returncode}):\n"
            f"{proc.stderr.strip()}")
    try:
        raw = json.loads(proc.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError) as exc:
        raise RuntimeError(
            f"zone_fill_oracle: unparseable probe output: {exc}\n"
            f"stdout={proc.stdout!r} stderr={proc.stderr!r}") from exc

    zones = tuple(
        OracleZone(
            net=z["net"],
            layer=z["layer"],
            is_rule_area=z["is_rule_area"],
            area_nm2=z["area_nm2"],
            contours=tuple(tuple((int(p[0]), int(p[1])) for p in c["points"])
                           for c in z["contours"]),
            holes=tuple(c["holes"] for c in z["contours"]),
        )
        for z in raw["zones"]
    )
    return OracleResult(filled=raw["filled"], kicad_version=raw["version"], zones=zones)
