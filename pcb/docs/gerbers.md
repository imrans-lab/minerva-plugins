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
| `<base>-F_SilkS.gbr` | Top silkscreen (courtyard-box placeholder per component) |
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

`gerber-writer` has no glyph/text primitive, so `F_SilkS` currently renders a
**courtyard-box outline placeholder** around each top-side component's pad
extent — NOT the reference-designator text. Real silkscreen text (vectorised
glyphs for refdes/value/pin-1 markers) is deferred to a later child.

### Bottom-side component limitation

Pad harvesting rotates footprints but does **not mirror** them for bottom-side
(`layer: "B.Cu"`) components — an asymmetric bottom-side footprint would emit
its pads unmirrored on B_Cu/B_Mask. Pad and mask stay self-consistent and
drill positions are unaffected, so boards with only symmetric bottom parts
(or none) are correct. Mirroring lands with the real footprint-geometry work;
until then treat asymmetric bottom-side parts as unsupported (review note,
gerber round).

### Determinism

The only volatile bytes `gerber-writer` emits are the `TF.CreationDate`
timestamp; `build_gerbers` pins it (and the Excellon `CREATED_BY` stamp) to a
fixed sentinel (`1970-01-01T00:00:00`, SOURCE_DATE_EPOCH-style) so output is
byte-reproducible for golden comparison. Pass `creation_date=...` for a real
dated artifact.

### Pad/mask geometry defaults

The canonical schema carries no per-pad copper geometry yet, so SMD pad size
(1.0 × 0.6 mm), TH annulus (`drill × 2` when unspecified) and solder-mask
clearance (0.1 mm/side) are **documented placeholders**, each overridable via the
schema's Extra passthrough (`pad_width_mm` / `pad_height_mm` /
`annulus_diameter_mm` on a pin; `solder_mask_clearance_mm` in `design_rules`).

## Contract fields formalized this round

The spike surfaced two schema gaps (docket comment 508); both are now
first-class in the Go contract (`pcb/internal/board/board.go`) and documented in
`docs/board-yaml.md`, replacing the spike's Extra passthrough:

- `Pin.drill_mm` / `Pin.annulus_diameter_mm` / `Pin.plated` — through-hole pad
  geometry. A pin with `drill_mm > 0` is a TH pad (plated unless
  `plated: false`).
- `Board.mounting_holes` (`[]Hole`) — board-level mechanical holes with
  `x_mm` / `y_mm` / `diameter_mm` / `plated` (default non-plated).

The worker reads these tolerantly and additionally accepts `npth_holes` /
`pth_holes` aliases via Extra for producers that pre-split the two lists.

## Fab-correctness HITL gate (debt #5 — extended to production output)

Structural validation + two independent parser round-trips are the automated
acceptance gate; they are **not** a substitute for a viewer check. Before any
board's Gerbers are treated as fab-final, a human must open all six layers plus
both drill files in `gerbv` or KiCad GerbView and confirm (extends the spike's
checklist to the production `pcb_gerbers` output):

1. **Zero parser warnings** in the viewer for every layer.
2. **Visual match to intent:** SMD pads under their silk courtyards; TH pads show
   a round copper pad with a drilled hole on both copper layers; traces land
   exactly on pads/vias; the outline is a clean closed rectangle; mask openings
   are centered on their pads with visible clearance; NPTH holes appear only in
   the drill layer (no copper/mask ring).
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
