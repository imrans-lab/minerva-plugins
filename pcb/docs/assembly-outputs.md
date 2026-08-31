# Assembly outputs — BOM + CPL (`minerva_pcb_export_assembly`)

The emitted CSV pair for a pre-assembled order: a bill of materials (what a
house buys) and a component placement list / pick-and-place file (where it puts
each part). Both are rendered from ONE strict compilation — the same
`ResolvedBoard` the Gerbers come from — so a single order cannot carry CSVs
describing one board and Gerbers describing another. The emitter is
`worker/pcb_worker/assembly_outputs.py`; the gates it runs first are
`assembly_gates.py` and are tabulated in `board-yaml.md` under "Hard gates on
assembly export".

Which columns those files carry, which fabrication profile a board must have
compiled against, and which of the house's published rules are checked, advised
or explicitly not looked at, all come from the SELECTED SERVICE PROFILE —
`service-profiles.md`. `jlc` selects the dialect and claims no tier;
`jlcpcb-economic` selects the tier and turns on its compatibility checks.

## What each BOM column carries

The schema gives three `assembly` fields a column of their own, and each is read
with exactly one fallback to the pre-block source it supersedes:

| column | authored field | fallback when absent |
|---|---|---|
| Comment | `assembly.comment` | the component's `value` |
| Footprint | `assembly.package` | the authored `footprint` ref |
| part number (`LCSC Part #` in JLCPCB's dialect) | `assembly.house_parts[<house>]` | `assembly.mpn` |

`<house>` is the selected profile's own `house_part_id` — the id a board names
that house's catalogue number under (`jlcpcb` for the `jlc` profile). Selecting
by profile rather than by position is what keeps a board carrying two houses'
numbers from ordering against the wrong one. A grouped BOM row's identity is
these RESOLVED cells, so two components that print identically are one line
whichever field each authored it in, and a difference the file carries splits
the row.

## One compilation for the pair

`build_package` is the entry point for both files, and the
`minerva_pcb_export_assembly` tool reaches it through the worker's single
`assembly_package` call. Asking for the BOM and then the CPL is **two**
compilations: the reference-set gate inside each proves only that THAT walk
agreed with itself, so library or footprint state moving between the two calls
would return a BOM and a CPL describing different resolved boards with both gates
green. `build_bom` and `build_cpl` remain the single-artifact entry points.

## What the coordinate is

A CPL row carries the **assembly anchor** — the part's body-box centre, composed
through its rotation and side — not the `x_mm`/`y_mm` that place the footprint
origin. See "The assembly anchor" in `board-yaml.md` for the basis ladder, why
silk and the courtyard are not bases, and how an expansion whose parts do not
share the drawing's centre states one anchor per placement (`anchor_mm`).

## Coordinate frame — measured, not assumed

CPL **X is the resolved anchor's X verbatim; CPL Y is its Y negated.**

This is proven against KiCad itself rather than inferred from a Y-down/Y-up
label. The full command, the measured output table and the byte-exact seal are
in `worker/tests/test_assembly_outputs.py::test_cpl_y_matches_kicad_cli_position_file_oracle`
— the citation lives in the test because shipped worker code may not name the
dev/CI-only export tool (`worker/tests/test_kicad_cli_boundary.py`, STANDING
GUARD 2). The finding:

| field | reference exporter emits |
|---|---|
| PosX | the placed footprint **origin's X**, exactly |
| PosY | the **negation** of its Y |
| Rot | the authored `rotation_deg`, **verbatim** |

A bottom-side part's X is **unmirrored**. The reference exporter negates X for
bottom parts only under an opt-in flag, which the oracle run did not pass;
matching the tool's DEFAULT rather than its opt-in is the profile decision this
emitter makes.

`gerber.py`'s `_Geometry.to_gerber_frame` negates Y at its own harvest boundary
for the identical reason — the placement frame is Y-down, and every consumer
outside it negates. A CPL is not a Gerber layer and is not re-derived through
`_Geometry`: `assembly_outputs._walk` negates Y itself, at its own
row-construction boundary.

## Rotation convention

CPL `Rotation` is emitted **verbatim** from the component's authored
`rotation_deg`, normalized to `[0, 360)` — no sign change, no trigonometry. It
is the same number `compile_board` threads into `Placement.rotation_deg`, and
the same convention `geometry.py` documents as "KiCad-equivalent": KiCad applies
a footprint `(at x y rot)` angle CLOCKWISE in the file's Y-down frame
(`math.radians(-deg)`), matching `agent_router/kicad_io.py::_transform_position`.
`geometry.py` is the pinned single source (`tests/test_rotation.py`,
`tests/test_geometry.py`). KiCad's own position-file export dumps this stored
angle unmodified, and JLCPCB's SMT upload flow accepts a KiCad-generated
position file as-is — so the emitter's job is to reproduce that number
faithfully.

**That is already JLC's counter-clockwise-positive convention**, and not a
second decision: the angle is clockwise in a Y-DOWN frame, and negating Y (which
every row gets, above) conjugates a clockwise turn into a counter-clockwise one.
In the frame the CSV is actually written in, a part at rotation 90 has turned 90
degrees counter-clockwise from its rotation-0 pose — on BOTH sides, because the
bottom-side mirror cancels against that same Y negation. Proven on real library
geometry in `worker/tests/test_assembly_anchor.py`.

Boards authored in the pcb-architect dialect use the OPPOSITE sign for their own
`rotation` field; per `geometry.py` that is reconciled at IMPORT time, so
`rotation_deg` is already KiCad-equivalent before an emitter sees it.

## Two non-claims

**This is not a promise the part mounts right-side-up.** JLC's own internal
component-library images sometimes disagree with a footprint's 0-degree
reference — a per-part-type calibration problem, not a board-wide sign
convention, and one caught in JLC's placement-review UI. Emitting the wrong
global sign here would rotate EVERY part; not correcting a per-part calibration
quirk rotates at most a few footprint families. Different bugs, different
owners; this emitter claims only the first.

**A BOM/CPL pair is not a stencil.** Neither file says anything about
solder-paste coverage. Paste is emitted by `gerber.py` (`F_Paste`/`B_Paste`) and
is fail-closed there (`fab_capability.FABRICATION_CRITICAL_OUTPUTS`).
