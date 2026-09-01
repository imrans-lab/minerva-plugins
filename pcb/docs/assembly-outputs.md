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

These two CSVs are two of the seven artifacts in a complete order package —
`order-package.md` covers the archive allowlist, the digest projection, the
readiness states and the atomic write.

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
`_Geometry`: `assembly_outputs.cpl_frame_point` negates Y, and `_walk` calls it
at its own row-construction boundary.

### Two functions carry this convention out of the module

`cpl_frame_point(point)` is the board-to-emitted frame map; `cpl_cells(row,
profile)` is a row's emitted TEXT — designator, X, Y, layer token, rotation, in
the profile's column order. The CSV renderer is written in terms of both, and so
is the local assembly preview (`assembly_preview.py`, `order-package.md`). That
is deliberate and it is the whole reason the two exist as named functions: the
picture a person checks before paying prints the SAME STRINGS the file carries,
rather than a second formatting of the same float that agrees until somebody
changes a rounding rule. Anything else that has to place a board feature beside
an emitted coordinate goes through these; a second spelling of the negation is a
sign error waiting to disagree with the file a house was sent.

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

## The part-orientation correction

Everything above describes where the part GOES. It says nothing about which way
the part is TURNED relative to the vendor's own drawing of it — and that is the
number the machine actually interprets. A pick-and-place house reads the
position file's rotation against the VENDOR's canonical orientation, so where
our footprint is drawn turned relative to the vendor's, the part is assembled
turned: a connector's signal leads onto its mounting-tab lands, an IC a quarter
turn out with every pin function moved. Nothing upstream sees it — our copper is
self-consistent, DRC is clean, the gerbers are right — and where the pad field
is rotationally symmetric it is invisible in a 3D preview too.

`part_orientation.py` measures that offset for one (our footprint, vendor part)
pair; `pcb/library/part_orientation.json` stores it, keyed on
`(footprint ref, house, catalogue number)`; and `assembly_orientation.py`
applies it to the emitted row:

```
emitted rotation = (placed rotation + measured offset) mod 360
```

**It is an ADDITION.** `offset_deg` is the rotation carrying the VENDOR's
drawing onto OURS, so our copper on the board is the vendor's drawing turned by
`placed + offset`, and the file has to say so for the machine to land the part
on it. Watch this sign: it is INVISIBLE on any part whose offset is 0 or 180
(`R + 180` and `R - 180` are the same number modulo 360), and nine of the eleven
pairs measured so far are exactly that. Only a 90 or a 270 can falsify it, which
is why `worker/tests/test_assembly_orientation.py` is built around the two
measured 270s and refuses to go green if either is ever re-measured flat.

The correction is a SEPARATE step from the frame map above, run by
`assembly_outputs.emit` over the rows `_walk` finished. Two different facts, two
different steps.

**A catalogue part nobody measured REFUSES the emission**, by name
(`assembly_orientation_unknown`), naming the component and the pair. Treating
"we do not know" as "no rotation needed" is exactly what shipped turned parts,
and a measured zero and an absent row are deliberately different things. A pair
whose measurement could not settle the angle refuses too
(`assembly_orientation_undecided`). A pair with `no_reference` — a mounting
hole, a fiducial, a part whose vendor ships no usable drawing — does NOT refuse:
there is nothing to correct against, and the placed rotation is emitted
verbatim.

The join reads the HOUSE catalogue number the selected profile names
(`assembly.house_parts[<house>]`), never `assembly.mpn`: the ledger is keyed on
the pair, and a manufacturer's number is not a house's. A part identified only
by `mpn` is therefore not corrected and not gated — a stated gap, not an
oversight.

## Two non-claims

**This is not a promise the part mounts right-side-up.** JLC's own internal
component-library images sometimes disagree with a footprint's 0-degree
reference. That per-part-type disagreement is what the part-orientation
correction above now measures and applies — but only for a pair somebody has
measured, and only against the drawing in the vendor payload we captured. A
supplier that redraws the package, or a part we buy on a footprint whose pair
was never measured, is still outside the claim; the second of those refuses the
emission rather than guessing.

**A BOM/CPL pair is not a stencil.** Neither file says anything about
solder-paste coverage. Paste is emitted by `gerber.py` (`F_Paste`/`B_Paste`) and
is fail-closed there (`fab_capability.FABRICATION_CRITICAL_OUTPUTS`).
