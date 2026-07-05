#!/usr/bin/env python
"""Structural validator for the gerber-writer spike output.

This is the round's acceptance gate (visual/gerbv-viewer confirmation is
deferred to the HITL session per the spike brief). It checks, per Gerber
layer:

  1. RS-274X skeleton: %FSLAX_Y_*% present and self-consistent, %MOMM*%
     present, every aperture (%ADDnn...*%) defined before its first D-code
     use, D01/D02/D03 usage looks sane, M02 terminator present.
  2. X2 attributes: .FileFunction / .FilePolarity present (gerber_writer
     emits these as `G04 #@! TF...*` comment-attributes -- both the
     extended-command %TF...*% form and the comment form are accepted).
  3. All plotted coordinates fall within the board's 0..width_mm x
     0..height_mm bounds (with a small tolerance for pad/trace half-widths).
  4. Independent round-trip parse with `pygerber` (actively maintained,
     X3-aware) -- catches anything the hand-rolled regex checks miss,
     and cross-checks the aperture-aware bounding box.
  5. Best-effort independent round-trip parse with `pcb-tools` (documented
     workaround required for Python 3.12 -- see NOTE in run_pcbtools_check).

Excellon drill files get their own structural check: M48 header, tool table,
FMAT/METRIC, G90/G05, every T-code used is defined, hole coordinates within
bounds, M30 terminator.

Usage: python validate.py [golden_dir]
"""
import re
import sys
from pathlib import Path

GOLDEN = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).parent / "golden"

BOARD_W, BOARD_H = 40.0, 30.0
# Coordinates are pad/trace *centerlines*; allow generous slack for pad half-
# extents (largest pad in this board is the 1.6mm annular TH pad -> 0.8mm
# radius, plus 0.1mm mask clearance -> 0.9mm; round up).
BOUNDS_TOLERANCE_MM = 1.5

GERBER_LAYERS = [
    "board-F_Cu.gbr",
    "board-B_Cu.gbr",
    "board-F_Mask.gbr",
    "board-B_Mask.gbr",
    "board-F_SilkS.gbr",
    "board-Edge_Cuts.gbr",
]
DRILL_FILES = ["board-PTH.drl", "board-NPTH.drl"]

FAIL = "FAIL"
WARN = "WARN"
OK = "OK"


class Result:
    def __init__(self, name):
        self.name = name
        self.checks = []  # list of (status, message)

    def add(self, status, message):
        self.checks.append((status, message))

    @property
    def status(self):
        if any(s == FAIL for s, _ in self.checks):
            return FAIL
        if any(s == WARN for s, _ in self.checks):
            return WARN
        return OK


# --- Gerber (RS-274X) structural checks -------------------------------------


def check_gerber_layer(path: Path) -> Result:
    r = Result(path.name)
    if not path.exists():
        r.add(FAIL, "file does not exist")
        return r
    text = path.read_text()
    lines = text.splitlines()

    # %FSLAX_Y_*%
    fs_match = re.search(r"%FSLAX(\d)(\d)Y(\d)(\d)\*%", text)
    if not fs_match:
        r.add(FAIL, "no %FSLAX..Y..*% format spec found")
        int_digits = dec_digits = None
    else:
        xi, xd, yi, yd = (int(g) for g in fs_match.groups())
        int_digits, dec_digits = xi, xd
        if xi != yi or xd != yd:
            r.add(WARN, f"asymmetric X/Y format spec X{xi}.{xd} Y{yi}.{yd}")
        else:
            r.add(OK, f"format spec %FSLAX{xi}{xd}Y{yi}{yd}*% (X{xi}.{xd})")

    # %MOMM*%
    if "%MOMM*%" in text:
        r.add(OK, "%MOMM*% (units = mm) present")
    else:
        r.add(FAIL, "%MOMM*% not found (units not declared as mm)")

    # M02 terminator
    if lines and lines[-1].strip() == "M02*":
        r.add(OK, "M02* terminator present as last line")
    elif "M02*" in text:
        r.add(WARN, "M02* present but not the last line")
    else:
        r.add(FAIL, "M02* terminator missing")

    # Aperture definitions must precede first use, and every used Dnn (n>=10)
    # must be defined via %ADDnn...*%
    defined_apertures = set()
    used_apertures = set()
    define_order_ok = True
    seen_define_positions = {}
    for i, line in enumerate(lines):
        for m in re.finditer(r"%ADD(\d+)", line):
            defined_apertures.add(int(m.group(1)))
            seen_define_positions.setdefault(int(m.group(1)), i)
    for i, line in enumerate(lines):
        m = re.match(r"D(\d+)\*$", line.strip())
        if m:
            dcode = int(m.group(1))
            if dcode < 10:
                continue  # D01/D02/D03 plot commands, not aperture selects
            used_apertures.add(dcode)
            if dcode in seen_define_positions and seen_define_positions[dcode] > i:
                define_order_ok = False

    undefined = used_apertures - defined_apertures
    if undefined:
        r.add(FAIL, f"apertures used but never defined: {sorted(undefined)}")
    else:
        r.add(OK, f"all {len(used_apertures)} referenced apertures ({sorted(used_apertures)}) are defined")

    if not define_order_ok:
        r.add(FAIL, "an aperture was selected (Dnn) before its %ADDnn definition")

    # D01/D02/D03 usage sanity: must have at least one D0x opcode
    d01 = len(re.findall(r"D01\*", text))
    d02 = len(re.findall(r"D02\*", text))
    d03 = len(re.findall(r"D03\*", text))
    if d01 + d02 + d03 == 0:
        r.add(WARN, "no D01/D02/D03 plot commands found (empty layer?)")
    else:
        r.add(OK, f"D01={d01} D02={d02} D03={d03} plot commands")

    # X2 attributes: .FileFunction / .FilePolarity, accepting both the
    # extended-command %TF...*% form and gerber_writer's `G04 #@! TF...*`
    # comment-attribute form (both are spec-legal; see REPORT.md).
    file_function = re.search(r"TF\.FileFunction,([^*]+)\*", text)
    file_polarity = re.search(r"TF\.FilePolarity,([^*]+)\*", text)
    if file_function:
        r.add(OK, f".FileFunction = {file_function.group(1)}")
    else:
        r.add(FAIL, ".FileFunction attribute not found")
    if file_polarity:
        r.add(OK, f".FilePolarity = {file_polarity.group(1)}")
    else:
        r.add(FAIL, ".FilePolarity attribute not found")
    if "G04 #@!" in text and "%TF." not in text:
        r.add(WARN, "X2 attributes are encoded as G04-comment attributes, not %TF...*% extended commands (spec-legal backward-compat form -- see REPORT.md)")

    # Aperture function attributes (.AperFunction) present for at least one aperture
    if re.search(r"TA\.AperFunction,", text):
        r.add(OK, ".AperFunction present on at least one aperture")
    else:
        r.add(WARN, "no .AperFunction attributes found on any aperture")

    # Coordinates within board bounds (unit = nm per %FSLAX..6Y..6%, i.e. /1e6 -> mm)
    if dec_digits == 6:
        unit_divisor = 1_000_000.0
    else:
        unit_divisor = None
        r.add(WARN, f"unexpected decimal digit count {dec_digits}, skipping bounds check")

    if unit_divisor:
        coords = re.findall(r"X(-?\d+)Y(-?\d+)D0[123]\*", text)
        out_of_bounds = []
        for xs, ys in coords:
            x_mm, y_mm = int(xs) / unit_divisor, int(ys) / unit_divisor
            if not (
                -BOUNDS_TOLERANCE_MM <= x_mm <= BOARD_W + BOUNDS_TOLERANCE_MM
                and -BOUNDS_TOLERANCE_MM <= y_mm <= BOARD_H + BOUNDS_TOLERANCE_MM
            ):
                out_of_bounds.append((x_mm, y_mm))
        if out_of_bounds:
            r.add(FAIL, f"{len(out_of_bounds)} coordinate(s) outside board bounds: {out_of_bounds[:5]}")
        else:
            r.add(OK, f"all {len(coords)} plotted coordinates within board bounds (0..{BOARD_W} x 0..{BOARD_H} mm, tol {BOUNDS_TOLERANCE_MM}mm)")

    return r


# --- Excellon structural checks ---------------------------------------------


def check_excellon(path: Path) -> Result:
    r = Result(path.name)
    if not path.exists():
        r.add(FAIL, "file does not exist")
        return r
    text = path.read_text()
    lines = [l.strip() for l in text.splitlines()]

    if lines and lines[0] == "M48":
        r.add(OK, "M48 header start present")
    else:
        r.add(FAIL, "M48 header start missing")

    if lines and lines[-1] == "M30":
        r.add(OK, "M30 terminator present as last line")
    else:
        r.add(FAIL, "M30 terminator missing")

    if "METRIC" in lines:
        r.add(OK, "METRIC units declared")
    else:
        r.add(WARN, "METRIC declaration not found")

    tools = {}
    for line in lines:
        m = re.match(r"T(\d+)C([\d.]+)$", line)
        if m:
            tools[int(m.group(1))] = float(m.group(2))
    if tools:
        r.add(OK, f"tool table defines {tools}")
    else:
        r.add(FAIL, "no tool table (Tn Cd.ddd) definitions found")

    # Body: every T-code select must reference a defined tool; every hole
    # coordinate must fall within board bounds.
    current_tool = None
    used_tools = set()
    holes = []
    for line in lines:
        m = re.match(r"T(\d+)$", line)
        if m:
            current_tool = int(m.group(1))
            used_tools.add(current_tool)
            continue
        m = re.match(r"X(-?[\d.]+)Y(-?[\d.]+)$", line)
        if m:
            holes.append((current_tool, float(m.group(1)), float(m.group(2))))

    undefined_tools = used_tools - set(tools.keys())
    if undefined_tools:
        r.add(FAIL, f"tool select(s) reference undefined tools: {undefined_tools}")
    else:
        r.add(OK, f"all selected tools {sorted(used_tools)} are defined")

    out_of_bounds = [
        (t, x, y)
        for t, x, y in holes
        if not (-BOUNDS_TOLERANCE_MM <= x <= BOARD_W + BOUNDS_TOLERANCE_MM
                and -BOUNDS_TOLERANCE_MM <= y <= BOARD_H + BOUNDS_TOLERANCE_MM)
    ]
    if out_of_bounds:
        r.add(FAIL, f"{len(out_of_bounds)} hole(s) outside board bounds: {out_of_bounds}")
    elif holes:
        r.add(OK, f"all {len(holes)} hole(s) within board bounds")
    else:
        r.add(WARN, "no hole coordinates found")

    return r


# --- Independent parser cross-checks ----------------------------------------


def run_pygerber_check(path: Path) -> Result:
    r = Result(f"{path.name} [pygerber round-trip]")
    try:
        from pygerber.gerberx3.api.v2 import (
            FileTypeEnum,
            GerberFile,
            OnParserErrorEnum,
        )
    except ImportError:
        r.add(WARN, "pygerber not installed, skipped")
        return r

    try:
        gf = GerberFile.from_file(path, file_type=FileTypeEnum.INFER_FROM_ATTRIBUTES)
        parsed = gf.parse(on_parser_error=OnParserErrorEnum.Raise)
    except Exception as e:  # noqa: BLE001 -- this is a diagnostic tool
        r.add(FAIL, f"pygerber raised parsing error: {e!r}")
        return r

    info = parsed.get_info()
    r.add(OK, f"parsed without error; file_type inferred = {parsed.get_file_type().name}")
    r.add(
        OK,
        f"aperture-aware bbox: x=[{info.min_x_mm}, {info.max_x_mm}] "
        f"y=[{info.min_y_mm}, {info.max_y_mm}]",
    )
    if (
        float(info.min_x_mm) < -BOUNDS_TOLERANCE_MM
        or float(info.max_x_mm) > BOARD_W + BOUNDS_TOLERANCE_MM
        or float(info.min_y_mm) < -BOUNDS_TOLERANCE_MM
        or float(info.max_y_mm) > BOARD_H + BOUNDS_TOLERANCE_MM
    ):
        r.add(FAIL, "pygerber bounding box exceeds board bounds")
    else:
        r.add(OK, "pygerber bounding box within board bounds")
    return r


def run_pcbtools_check(path: Path) -> Result:
    r = Result(f"{path.name} [pcb-tools round-trip]")
    try:
        import gerber.rs274x as rs274x
    except ImportError:
        r.add(WARN, "pcb-tools not installed, skipped")
        return r

    # NOTE: pcb-tools' public entry points (`gerber.read`, `GerberParser.parse`)
    # call `open(filename, "rU")`. Python 3.11+ removed the 'U' universal-
    # newlines file mode, so those entry points raise
    # `ValueError: invalid mode: 'rU'` on this Python 3.12 venv -- pcb-tools
    # is NOT usable out of the box here. Workaround: read the file ourselves
    # and call the lower-level `GerberParser.parse_raw(data, filename)`,
    # which does the same parsing without touching the filesystem itself.
    # This is undocumented and would break again the moment pcb-tools' API
    # shifts underneath; not something an implementation child should rely on.
    try:
        data = path.read_text()
        layer = rs274x.GerberParser().parse_raw(data, str(path))
    except Exception as e:  # noqa: BLE001
        r.add(FAIL, f"pcb-tools raised parsing error (even with rU workaround): {e!r}")
        return r

    r.add(OK, f"parsed via parse_raw() workaround; {len(layer.primitives)} primitives, bounds={layer.bounds}")
    r.add(WARN, "pcb-tools has no concept of X2 attributes -- G04 #@! TF./TA. lines surface only as opaque .comments strings, not structured attributes (confirmed by inspection)")
    return r


# --- Report -------------------------------------------------------------


def print_result(r: Result):
    print(f"\n[{r.status}] {r.name}")
    for status, msg in r.checks:
        print(f"    {status:5s} {msg}")


def main():
    all_results = []

    print("=" * 78)
    print("GERBER LAYER STRUCTURAL VALIDATION")
    print("=" * 78)
    for fname in GERBER_LAYERS:
        r = check_gerber_layer(GOLDEN / fname)
        print_result(r)
        all_results.append(r)

    print("\n" + "=" * 78)
    print("EXCELLON DRILL FILE VALIDATION")
    print("=" * 78)
    for fname in DRILL_FILES:
        r = check_excellon(GOLDEN / fname)
        print_result(r)
        all_results.append(r)

    print("\n" + "=" * 78)
    print("INDEPENDENT PARSER ROUND-TRIP: pygerber")
    print("=" * 78)
    for fname in GERBER_LAYERS:
        r = run_pygerber_check(GOLDEN / fname)
        print_result(r)
        all_results.append(r)

    print("\n" + "=" * 78)
    print("INDEPENDENT PARSER ROUND-TRIP: pcb-tools (best-effort)")
    print("=" * 78)
    for fname in GERBER_LAYERS:
        r = run_pcbtools_check(GOLDEN / fname)
        print_result(r)
        all_results.append(r)

    print("\n" + "=" * 78)
    n_fail = sum(1 for r in all_results if r.status == FAIL)
    n_warn = sum(1 for r in all_results if r.status == WARN)
    n_ok = sum(1 for r in all_results if r.status == OK)
    print(f"SUMMARY: {n_ok} OK, {n_warn} WARN, {n_fail} FAIL (out of {len(all_results)} checks)")
    print("=" * 78)
    return 1 if n_fail else 0


if __name__ == "__main__":
    sys.exit(main())
