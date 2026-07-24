# Fabrication output — Gerber + Excellon (`pcb_gerbers`)

Docket: minerva `019eb47ddebc` · DCR `019dc140`. Built on the validation spike
`019eb480415a` (see `pcb/spikes/gerber/REPORT.md` for the library evaluation —
its verdict is the foundation this builds on, not re-litigated here).

`pcb_gerbers` (worker method `gerbers`, `pcb_worker/gerber.py`) compiles a
canonical board (the same `board-yaml` contract `pcb_validate` / `pcb_generate`
consume) into manufacturer-ready fabrication files, in **pure Python — no KiCad
binary**. Gerber layers come from the pinned `gerber-writer` library (0.4.3.3,
authored by Karel Tavernier / Ucamco, a principal author of the Gerber spec
itself); the Excellon drill files are emitted by this module directly, because
`gerber-writer` has zero drill support.

## Output

`{files: {name: content}, written: [{path, bytes_written}]}` — the exact return
convention as `pcb_generate`. `out_dir` optionally also writes to disk.

| File (`<base>` = `name` arg or board name) | Layer / content |
|---|---|
| `<base>-F_Cu.gbr` | Top copper: SMD pads, TH-pad annuli, via annuli, top traces |
| `<base>-B_Cu.gbr` | Bottom copper: TH/via annuli, bottom traces |
| `<base>-F_Mask.gbr` | Top solder-mask openings (pad + clearance) |
| `<base>-B_Mask.gbr` | Bottom solder-mask openings |
| `<base>-F_SilkS.gbr` | Top silkscreen (resolved footprint silk graphics only; no output when the footprint carries none — K4) |
| `<base>-Edge_Cuts.gbr` | Board outline rectangle from origin + width/height |
| `<base>-PTH.drl` | Plated through-holes (Excellon) — only if the board has any |
| `<base>-NPTH.drl` | Non-plated holes (Excellon) — only if the board has any |

## Decisions

### Coordinate format — NOT pinned to 4.6

`gerber-writer` self-declares `%FSLAX_Y_*%` per layer from that layer's actual
coordinate extent: 3 integer digits for any board under ~1000 mm, so a 40×30 mm
board emits `%FSLAX36Y36*%` (3 integer + 6 fractional). This is fully
RS-274X-legal — the format is self-describing and any consumer **must read the
`%FS` line, not assume 4.6**. We deliberately do NOT override it. Consequence:
byte-goldens are only portable at a fixed board size + library version (a board
crossing 1000 mm would shift to `%FSLAX46Y46*%`). The test suite reads and
checks the declared `%FS` for self-consistency rather than hard-requiring 4.6.

### X2 attributes — comment form

`gerber-writer` emits X2 attributes as backward-compatible `G04 #@! TF...*` /
`TA...*` comment-attributes, not `%TF...*%` / `%TA...*%` extended commands. Both
are spec-legal; the comment form exists so pre-X2 tooling ignores the line while
X2-aware tooling still extracts it (`pygerber` parses it into a structured
attribute dict — verified in the round-trip tests). **Interop note:** a fab
intake that scans only for literal `%TF.` could under-attribute this output even
though it is spec-compliant. Not a defect; flag it when choosing a fab house.
Copper apertures carry `.AperFunction` (`SMDPad,CuDef` / `ComponentPad` /
`ViaPad` / `Conductor`); mask/silk apertures deliberately omit it this round
(the acceptance gate only requires `.FileFunction` / `.FilePolarity`).

### Excellon ownership + PTH/NPTH split

`gerber-writer` has no Excellon support at all, so this module owns drill
generation. Excellon has no first-class per-hole plated flag; the traditional,
widely-accepted convention is **two separate files**. The split source:

- **PTH** (plated): through-hole pads (`pin.drill_mm` set, `plated` not false)
  and vias.
- **NPTH** (non-plated): any pad/hole flagged `plated: false`, plus board-level
  mounting holes (`mounting_holes` / `npth_holes`).

Each file: `M48` header, `;`-comments, `FMAT,2`, `METRIC`, a tool table keyed by
ascending drill diameter (deterministic), a G90/G05 body of `X..Y..` hits grouped
per tool, `M30`. Metric, absolute, 3.3 decimal coordinates.

### Silk limitations

`F_SilkS` emits the component's **real resolved silkscreen primitives** (lines,
arcs, polygons from the resolved footprint's `F.SilkS` graphics) when the footprint
carries them; a component **without** resolved silk graphics contributes **no silk
output** — K4 retired the procedural courtyard-box placeholder, matching the KiCad
emitter, which never drew one (faithful-or-nothing). Silkscreen **text** (vectorised
refdes/value glyphs) is still not rendered — `gerber-writer` has no glyph
primitive — so real silk-text correctness is tracked separately (silk-text
`019f77fd6d69`; coverage audit `019f77fd9c6c`).

### Bottom-side components

Bottom-side (`layer: "B.Cu"`) footprints ARE mirrored: the ResolvedBoard IR bakes
the bottom-side mirror into each board-absolute `PlacedPad`, so an asymmetric
bottom-side footprint emits correctly on B_Cu / B_Mask / B_Paste. (The original
loose-dict gerber spike did **not** mirror — that limitation was superseded by the
fabrication-complete footprint resolution; this note is retained only to mark the
change.)

### Determinism

The only volatile bytes `gerber-writer` emits are the `TF.CreationDate`
timestamp; `build_gerbers` pins it (and the Excellon `CREATED_BY` stamp) to a
fixed sentinel (`1970-01-01T00:00:00`, SOURCE_DATE_EPOCH-style) so output is
byte-reproducible for golden comparison. Pass `creation_date=...` for a real
dated artifact.

### Pad/mask geometry

Pad copper geometry is **resolved from the locked library footprint** (the
fabrication-complete `FootprintDefinition` → `ResolvedBoard` IR); the emitter
consumes that geometry and FAILS CLOSED on a sizeless SMD pad rather than
inventing a placeholder land (pad bug 019f7736b236). The original spike's
documented placeholders (1.0 × 0.6 mm SMD, `drill × 2` TH annulus) have been
removed. Solder-mask clearance defaults to 0.1 mm/side, overridable via
`solder_mask_clearance_mm` in `design_rules` or a per-pad `solder_mask_margin`;
a pin may still override `pad_width_mm` / `pad_height_mm` / `annulus_diameter_mm`.

## Contract fields formalized this round

The spike surfaced two schema gaps (docket comment 508); both are now
first-class in the Go contract (`pcb/internal/board/board.go`) and documented in
`docs/board-yaml.md`, replacing the spike's Extra passthrough:

- `Pin.drill_mm` / `Pin.annulus_diameter_mm` / `Pin.plated` — through-hole pad
  geometry. A pin with `drill_mm > 0` is a TH pad (plated unless
  `plated: false`).
- `Board.mounting_holes` (`[]Hole`) — board-level mechanical holes with
  `x_mm` / `y_mm` / `diameter_mm` / `plated` (default non-plated).

Producers may pre-split plating with the `npth_holes` / `pth_holes` INPUT aliases;
the codec normalizes them into the canonical `mounting_holes` collection (`plated`
set from the alias key) at parse, so they round-trip as `mounting_holes` and get
the same v2 id-minting + structural validation (finding `019f8b7fb07e` c689).

## Fab-correctness HITL gate (debt #5 — extended to production output)

Structural validation + two independent parser round-trips are the automated
acceptance gate; they are **not** a substitute for a viewer check. Before any
board's Gerbers are treated as fab-final, a human must open all six layers plus
both drill files in `gerbv` or KiCad GerbView and confirm (extends the spike's
checklist to the production `pcb_gerbers` output):

1. **Zero parser warnings** in the viewer for every layer.
2. **Visual match to intent:** SMD pads show their resolved copper land, with silk
   only where the footprint carries real graphics (no courtyard boxes — K4); TH pads
   show their resolved copper land (a round annulus, or an authored square / roundrect
   land — D1) with a drilled hole on both copper layers; traces land exactly on
   pads/vias; the outline is a clean closed rectangle; mask openings are centered
   on their pads with visible clearance; NPTH holes get a **drill-size mask
   opening** (no copper ring) on both sides, matching KiCad's `np_thru_hole` (E3).
3. **Drill-to-copper alignment:** every PTH hole lands inside its copper annulus
   with no annular-ring violations.

No `gerbv` / GerbView is available in this environment, so this gate remains open
debt (#5) and must be closed per-board by a human before fabrication.

## Testing

`pcb/worker/tests/test_gerbers.py` lifts the spike's `validate.py` structural
checks into pytest assertions and runs them over the PRODUCTION compiler for two
boards (the spike board + a hand-authored drill-split fixture,
`tests/testdata/gerber_boards/drilltest.yaml`): every Gerber layer passes the
RS-274X/X2 structural checks + a `pygerber` round-trip parse; every Excellon file
passes header/tool-table/split checks; and all outputs byte-match the goldens in
`tests/testdata/gerber_golden/` (regenerate via that dir's `regenerate.py`).
`pygerber` is a **test-only** dependency; `gerber-writer` is a runtime dependency
(pinned in `pyproject.toml`).
