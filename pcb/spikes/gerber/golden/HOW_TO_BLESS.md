# How to bless the spike golden (`spike-gerber-v1`)

**Read this before setting `blessed: true` in `PROVENANCE.json`.**

The geometry-diff harness (`tests/oracle/geometry_diff.py`) can tell when the
emitter *drifts* from a golden, but drift-detection is worthless if the golden
itself is wrong. A golden becomes a **correctness oracle** only after an
**independent** authority — a human, using tooling that did NOT produce the
golden — confirms it is actually correct. That confirmation is what this
document asks you to perform ONCE. The harness will not treat `spike-gerber-v1`
as a correctness oracle until you do (`correctness_oracle_status` returns
"not blessed" and the correctness test skips-with-reason).

The implementer may NOT self-certify — this is a human-in-the-loop gate.

## Files to inspect

All eight files in `pcb/spikes/gerber/golden/`:

| Layer / drill        | File                    |
|----------------------|-------------------------|
| Top copper           | `board-F_Cu.gbr`        |
| Bottom copper        | `board-B_Cu.gbr`        |
| Top solder mask      | `board-F_Mask.gbr`      |
| Bottom solder mask   | `board-B_Mask.gbr`      |
| Top silkscreen       | `board-F_SilkS.gbr`     |
| Board outline        | `board-Edge_Cuts.gbr`   |
| Plated drills        | `board-PTH.drl`         |
| Non-plated drills    | `board-NPTH.drl`        |

## Option A — Independent Gerber viewer (do at least this)

Load ALL eight files together in an **independent** viewer — one of:

- **gerbv** (`gerbv board-F_Cu.gbr board-B_Cu.gbr board-F_Mask.gbr board-B_Mask.gbr board-F_SilkS.gbr board-Edge_Cuts.gbr board-PTH.drl board-NPTH.drl`), or
- an **online fab viewer**: JLCPCB Gerber Viewer (<https://jlcpcb.com/gerber-viewer>)
  or OSHPark's upload preview (<https://oshpark.com>) — zip the eight files and upload.

Overlay all layers and visually confirm, per the spike REPORT.md HITL checklist:

1. **Zero parser warnings** in the viewer for any layer or drill file. In
   particular, confirm the drill files still load cleanly despite open bug
   **019f7720928d** (the Excellon `G90` / `G05` lines are emitted AFTER the
   `M48 ... %` header-end; some parsers warn). If the viewer rejects or
   mis-reads a drill file, DO NOT bless — file/fix the drill-header bug first.
2. **Layer registration**: solder-mask openings are centred on their copper
   pads with visible clearance; the F.SilkS courtyards sit over the right
   components.
3. **Pad / drill alignment**: both PTH holes (U1 test point Ø0.8, via Ø0.4)
   land inside their copper annuli on F.Cu/B.Cu with no annular-ring
   violation; the NPTH Ø3.2 mounting hole appears ONLY in the drill layer with
   no copper/mask ring.
4. **Board outline**: a clean, closed 40 mm x 30 mm rectangle, no gaps.
5. **Pad geometry sanity**: the SMD pads are the intended size for R_0805 /
   C_0805 (this golden uses 1.2 x 1.3 mm). Note that the current
   `pcb_worker.gerber` emitter produces 1.0 x 0.6 mm placeholder pads instead —
   decide which is correct and reconcile (`board.yaml` pad geometry vs emitter
   defaults) as part of blessing.

## Option B — kicad-cli DRC on the round-tripped board (recommended in addition)

The dev-only oracle already round-trips the board through KiCad and runs DRC:

```
cd pcb/worker
.venv/bin/python -m pytest tests/oracle/test_kicad_drc_oracle.py -q   # needs kicad-cli on PATH
```

A clean DRC on the spike board is corroborating (independent-of-gerber-writer)
evidence. It is not a substitute for the visual Gerber check in Option A, because
it verifies the KiCad round-trip, not the emitted Gerber bytes.

## Flip the switch

Once you have visually confirmed Option A (and ideally Option B), edit
`PROVENANCE.json`, entry `spike-gerber-v1`:

```json
"blessed": true,
"method": "gerbv 2.10.0 visual overlay + kicad-cli 9.0.7 pcb drc (clean)",
"date":   "YYYY-MM-DD",
"by":     "your-name",
```

The next test run will then use `spike-gerber-v1` as a correctness oracle
instead of skipping. **Do NOT bless `emitter-snapshot-v1`** — it is a circular
drift-pin and must stay `blessed: false`.
