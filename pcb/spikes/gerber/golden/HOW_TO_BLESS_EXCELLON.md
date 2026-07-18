# How to bless the Excellon/slots/IPC-356 golden (`cam-excellon-ipc356-v1`)

**Read this before setting `blessed: true` for `cam-excellon-ipc356-v1` in
`PROVENANCE.json`.** (Sibling of `HOW_TO_BLESS.md`, which blesses the Gerber
copper golden `spike-gerber-v1`. Same human-in-the-loop protocol, drill/slot/
netlist edition.)

The geometry-diff harness can tell when an emitter *drifts* from this golden, but
drift-detection is worthless if the golden itself is wrong. This golden becomes a
**correctness reference** only after an **independent** authority — you, using
tooling that did NOT produce the golden — confirms it is actually correct. The
implementer may NOT self-certify.

## Why this is a CANDIDATE, and what your bless does / does NOT prove

This golden is emitted by the **ratified gerbonara coupon** (`emit_golden.py` ->
`gerbonara_coupon.build()`). The future Stage-5 **production** emitter
(docket 019f761fefae) will ALSO be gerbonara-based, but a **different code path**
(pcb_worker consuming the ResolvedBoard IR). Consequences:

- The golden catches **integration / driving divergence** — the production path
  feeding gerbonara the wrong params/geometry from the IR.
- The golden does **NOT** catch **gerbonara library bugs** (both paths share the
  library). Those are tracked in **019f7773257** and can only be caught by *your*
  independent viewer check here.

So your bless is exactly the independent gerbv/netlist review that the shared
library can't self-check. **There is no production Excellon/slots/IPC-356 emitter
yet**, so there is nothing to compare the golden against today — the
correctness-oracle test skips-with-reason until BOTH (a) you bless it AND (b) that
Stage-5 consumer exists.

## Files to inspect

The three files in `pcb/spikes/cam/golden/`:

| Artifact              | File                |
|-----------------------|---------------------|
| Plated drills + slot  | `board-PTH.drl`     |
| Non-plated drill      | `board-NPTH.drl`    |
| IPC-356 netlist       | `board.ipc356`      |

(Copper/mask/silk/edge overlay for drill-to-pad *registration* is the same coupon
geometry already blessed as `spike-gerber-v1` in `../gerber/golden/` — load those
`.gbr` alongside if you want to eyeball hole-in-pad centring.)

## Option A — Independent drill viewer (do at least this)

Load the drill files in an **independent** viewer — **gerbv**
(`gerbv board-PTH.drl board-NPTH.drl`) or a fab online viewer (JLCPCB / OSHPark;
zip and upload). Optionally add the `spike-gerber-v1` copper `.gbr` for the
registration overlay.

### STATED INTENT — confirm every hole and the slot against this exact spec

`board-PTH.drl` (plated) must contain exactly:

1. **Ø0.8 mm** plated round hole at **(30.0, 15.0)** — the U1 through-hole test
   point. Lands concentric inside U1's Ø1.6 copper annulus.
2. **Ø0.4 mm** plated round hole at **(20.0, 10.0)** — the via. Lands concentric
   inside the Ø0.8 via copper.
3. **Routed SLOT, Ø1.0 mm** tool, a straight horizontal cut from **(34.0, 5.0)**
   to **(38.0, 5.0)** — i.e. a 4.0 mm-long, 1.0 mm-wide rounded-end slot. In the
   file this is Excellon **route mode**: `G00 X034 Y005` (rapid to start),
   `M15` (tool down), `G01 X038 Y005` (route to end). Confirm the viewer draws a
   SLOT, not two separate point holes.

`board-NPTH.drl` (non-plated) must contain exactly:

4. **Ø3.2 mm** non-plated (bare) hole at **(5.0, 5.0)** — the mounting hole. It
   must appear ONLY in the drill layer, with no copper/mask ring.

Confirm: hole **diameters** match, **positions** match, the **slot shape/width**
matches, and NPTH is bare. If anything differs, **DO NOT bless** — reconcile the
coupon spec first.

### Flag the open Excellon-header bug during this check

While loading the drills, confirm they load **cleanly despite open bug
019f7720928d** — the `G05` / route-mode header lines are emitted after the
`M48 ... %` header-end and some parsers warn. If gerbv reads the holes and slot
correctly, note it as cosmetic (as it was for `spike-gerber-v1`) but keep the bug
tracked. If a viewer **rejects or mis-reads** a drill file, DO NOT bless — fix the
drill-header bug first.

## Option B — Eyeball the IPC-356 records

Open `board.ipc356` in a text editor (IPC-D-356A is line-oriented and
human-readable). Confirm the four `3x7`/`3x2` test records against STATED INTENT:

| Ref.Pin | Net | Type         | Location (mm)     | Plating / access        |
|---------|-----|--------------|-------------------|-------------------------|
| U1.1    | VCC | through-hole | (30.000, 15.000)  | Ø0.8 **plated**, access both (`D0800PA00`) |
| R1.2    | VCC | SMD pad      | (10.950, 10.000)  | top only (`A01`)        |
| R1.1    | GND | SMD pad      | (9.050, 10.000)   | top only (`A01`)        |
| C1.1    | GND | SMD pad      | (9.050, 20.000)   | top only (`A01`)        |

Confirm: each **net name** (VCC / GND) is on the intended pads; the through-hole
record carries the **Ø0.8 drill + `P` plated** flag; SMD records carry **no**
drill and access layer `A01`; the X/Y coordinates match the pad locations above
(IPC-356 uses `X+030000` = 30.000 mm at 3-decimal implied). A fab's netlist tester
uses exactly these records, so a wrong net or location here is a real defect.

## Option C — kicad-cli cross-export (optional corroboration)

If you have `kicad-cli`, exporting the same coupon board's drills/IPC-356 through
KiCad and eyeballing that the hole table + net list agree is independent
corroboration (a different toolchain). It is NOT a substitute for Option A/B — it
checks the KiCad round-trip, not these emitted bytes.

## Flip the switch

Once you have confirmed Option A **and** Option B (Option C optional), edit
`PROVENANCE.json`, entry `cam-excellon-ipc356-v1`:

```json
"blessed": true,
"method": "gerbv 2.10.0 drills+slot visual + IPC-356 record review (+ kicad-cli cross-export)",
"date":   "YYYY-MM-DD",
"by":     "your-name",
```

Even after you bless it, the **correctness-oracle** test stays skipped until the
Stage-5 production emitter (019f761fefae) exists to compare against — that is
correct and honest, not a gap. **Do NOT bless `emitter-snapshot-v1`.**
