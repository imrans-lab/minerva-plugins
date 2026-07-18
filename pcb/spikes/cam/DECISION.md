# CAM emitter selection — spike decision (docket MNR 019f761fcfc3)

**Question:** pick the PCB plugin's native fabrication-output writer stack. Backend
decision is already made — CAM is native + plugin-owned; **KiCad stays a dev-only
oracle (kicad-cli DRC), never the product**. This spike compares two writer paths
and proves a coupon, harness-backed, to feed an owner ratification.

**Candidates**
1. **CURRENT / incumbent** — `gerber-writer==0.4.3.3` (Karel Tavernier / Ucamco,
   the format's own spec author) for the six Gerber layers + **hand-written**
   Excellon in `pcb/worker/pcb_worker/gerber.py`. Read, not modified.
2. **CANDIDATE** — `gerbonara==1.6.3` (Apache-2.0) as a **unified** Gerber +
   Excellon + IPC-356 writer. Already a dependency as our *reader* (SB.1 harness).

All findings below were produced by **actually emitting** in the worker venv
(`pcb/worker/.venv`, py3.12, both libs importable) — not from docs. Reproduce:
`python gerbonara_coupon.py` then `python compare_harness.py`.

---

## 1. Feature matrix (verified by emission)

| Feature | gerber-writer (incumbent) | gerbonara 1.6.3 | Notes |
|---|---|---|---|
| F/B copper | ✅ productionised | ✅ coupon proven | golden-identical geometry |
| Solder mask F/B | ✅ | ✅ | identical |
| Silk (line/circle/poly) | ✅ (+ legacy KiCad arc) | ✅ (Line/Region) | both fine |
| Closed board profile | ✅ | ✅ | identical Edge_Cuts |
| Profile **with cutout / inner slot** | ⚠️ outline only in gerber.py | ✅ routed slot in Excellon | see slot row |
| Arcs (G02/G03 I/J) | ✅ `add_trace_arc` | ✅ `Arc` object | both round-trip clean |
| Region / copper pour (G36/G37) | ✅ `add_region` | ✅ `Region` | coupon emits a B_Cu pour |
| SMD pad | ✅ | ✅ | identical flashes |
| **Rotated** SMD pad | ✅ `add_pad(...,angle)` | ⚠️ needs aperture macro (no `Flash` rotation) | coupon is rot=0; gate for rotated parts |
| PTH drill | ⚠️ **hand-written** Excellon | ✅ `ExcellonTool(plated=True)` | first-class in gerbonara |
| NPTH drill | ⚠️ hand-written | ✅ `plated=False` | " |
| Via drill | ⚠️ hand-written | ✅ | " |
| **Plated/non-plated SPLIT** | ⚠️ our convention (2 files) | ✅ per-tool `plated` flag **and** 2-file split | gerbonara models it at the tool |
| **Routed slot** | ❌ not emitted today | ✅ `Line`→G00/M15/G01 | gerbonara only |
| X2 **file** attrs (.TF) | ✅ but `G04 #@!` **comment** form | ✅ canonical **`%TF...*%`** extended form | gerbonara form is the one fabs literally scan for |
| X2 **aperture** attrs (.TA/.AperFunction) | ✅ (`ComponentPad`/`ViaPad`/`SMDPad`/`Conductor`) | ❌ **writer drops them** | incumbent advantage |
| X2 **net** attrs (.TO/.N) | ❌ not emitted | ❌ writer drops them | neither; use IPC-356 instead |
| **IPC-356 netlist** | ❌ none | ✅ (with a 1.6.3 bug, worked around) | gerbonara only |
| Layer/job manifest | ❌ (filenames only) | ⚠️ `LayerStack`/`layers` exists (unproven for write) | future gate, both |
| **Deterministic** (no timestamp) | ⚠️ TF.CreationDate must be regex-pinned | ✅ **no timestamp emitted at all** | gerbonara wins |
| Deterministic ordering | ✅ | ✅ (coupon byte-identical on re-emit) | both |

Model-expressibility caveat (structured future-gate, **not** an emitter defect):
today's canonical `board.yaml` has **no first-class fields** for TH-pad
drill/annulus, mounting/NPTH holes, routed slots, copper pours, or net-attribute
assignment — the spike (like the incumbent) routes these through `Extra`
passthrough or hard-codes them. Whichever writer wins, these need canonical-model
fields before the features are reachable from real boards.

---

## 2. Harness comparison (SB.1–3 oracle, not by-eye)

Ran the gerbonara coupon through `pcb/worker/tests/oracle`:

- **Round-trip parse** — all 6 Gerber layers + both drill files parse clean;
  slot detected (`slots=1`), drill sizes exact `[0.4, 0.8, 1.0]` / `[3.2]`.
- **Geometry diff vs BLESSED golden** (`spike-gerber-v1`, blessed=true) on the
  overlap layers (F/B Cu, F/B Mask, Edge_Cuts, PTH, NPTH): **the ONLY delta is
  the intentionally-added B_Cu pour region.** Every copper flash, trace, mask
  opening, edge segment and drill hit is **geometrically identical** to the
  independently-blessed golden.
- **Drill-to-copper registration: 0 violations** — every plated hole lands exactly
  on its copper annulus.
- **Determinism:** coupon re-emitted byte-identical (no timestamp to pin).
- **X2 recognition:** `%TF` file attrs survive round-trip into a structured dict;
  `.TO`/`.TA` confirmed **dropped** by gerbonara's writer.
- **IPC-356:** round-trips; nets `['GND','VCC']`, 4 test records.
- **kicad-cli DRC oracle:** binary present (9.0.7) but is **emitter-agnostic** — it
  DRCs the *canonical board* via the worker's KiCad emitter, not the CAM output,
  so it does **not** discriminate the two writer paths. (An import gap —
  `agent_router.layers` — blocks running it from this spike venv; out-of-fence,
  pre-existing, noted below.)

### gerbonara 1.6.3 writer bugs found (reliability tax — worked around, report upstream)
- `ipc356.TestRecord`: ctor field is misspelled `lefover` but `format()` reads
  `self.leftover` → `AttributeError`. Worked around by `record.leftover = ''`.
- `Netlist.write_to_bytes` / `ExcellonFile.split_by_plating`: crash on
  `import_settings=None` (`None.copy()`). Worked around by always passing explicit
  `FileSettings`.
- Mixed-plating in one Excellon file falls back to **non-standard Altium**
  `;TYPE=` comments (SyntaxWarning). Use the **2-file** PTH/NPTH split (incumbent
  convention) to avoid it.

---

## 3. License / dependency audit

| | gerber-writer 0.4.3.3 | gerbonara 1.6.3 |
|---|---|---|
| License | **Apache-2.0** | **Apache-2.0** |
| Redistribution of lib + our output | Permitted (Apache-2.0, no copyleft) | Permitted |
| Direct install deps | **NONE** (pure Python) | `click`, **`rtree`**, **`quart`** |
| Transitive weight | zero | `rtree` = native libspatialindex wheel; `quart` = async web stack (hypercorn/blinker/…) |
| Cold import cost | 0.013 s | 0.043 s — **rtree/quart NOT loaded at import** (lazy; only CLI/layer-rules pull them) |
| No-FCIB packaging | trivial (no binaries) | ⚠️ `rtree` ships a **native** lib → needs a per-platform wheel; keep it as a pinned/hashed PyPI wheel, never a committed binary |

**License/FCIB verdict:** both Apache-2.0, both redistributable, **no unlicensed
circuit-json source touched**. gerber-writer is dependency-clean. gerbonara's
runtime writer path needs none of `rtree`/`quart`, but a plain `pip install
gerbonara` pulls them — pin+hash the wheels; if the deploy image size matters,
the writer subset could be vendored/trimmed (a fork cost, not a blocker).

---

## 4. Decision — rubric-scored (durability → DRY → reliability → well-factored → readability → cost)

**RECOMMENDATION (for owner ratification): adopt `gerbonara` as the single
unified production emitter — Gerber + Excellon (incl. slots) + IPC-356 — pinned
at 1.6.3 with thin local workarounds, and treat X2 aperture/net-attribute
emission as the ONE explicit future gate to close before GA.** KiCad remains a
dev-only DRC oracle.

Why gerbonara over a split or the incumbent, by rubric order:

| Axis | gerber-writer path (Gerber + hand-Excellon; no netlist) | gerbonara unified path |
|---|---|---|
| **Durability** (1) | Spec-author lib, zero deps, 100% spec claim — very durable for *Gerber copper*. But covers only ⅓ of the stack; drill + netlist are **hand-owned forever** (a standing liability). | Broad Apache-2.0 lib, actively maintained; 1.6.3 **writer** has real bugs (less battle-tested than its reader); heavier supply chain. **≈ tie** — incumbent better on core Gerber, gerbonara better on breadth. |
| **DRY** (2) | Two Gerber-capable libs already in-tree (gerber-writer writes, gerbonara reads) + bespoke Excellon + no netlist → 3–4 code paths, 2 data shapes. | **One library reads AND writes** Gerber/Excellon/IPC-356 on one model — collapses the whole stack. **Decisive gerbonara win.** |
| **Reliability** (3) | `gerber.py` is proven against the blessed golden. | Coupon geometry is **golden-identical, registration exact, deterministic**; the residual risk is the 3 known writer bugs (all worked around / version-pinned). Slightly behind incumbent, acceptable. |
| **Well-factored** (4) | Emitter split across a library + hand-rolled Excellon string-builder. | Uniform object model (`Flash`/`Line`/`Arc`/`Region`/`ExcellonTool`) across all outputs. gerbonara. |
| **Readability** (5) | Hand-Excellon is terse but ad-hoc. | Typed objects read clearly (see coupon). gerbonara. |
| **Cost** (6) | Lightest deps. | `rtree`/`quart` install weight (lazy at runtime); pin+hash. Incumbent cheaper. |

The rubric puts **DRY second, right behind a near-tie on durability** — and DRY is
where gerbonara wins overwhelmingly: it is **already the reader**, so making it the
writer unifies reader + writer + drill + netlist on one library and one model, and
uniquely delivers first-class Excellon plating, **routed slots**, and **IPC-356** —
three things the incumbent stack hand-owns or lacks entirely. The incumbent's one
real edge (X2 `.AperFunction`) is recoverable as cheap post-write text injection or
an upstream writer patch, and is booked as a future gate, not a blocker.

**Deliberate-split fallback (documented, NOT recommended):** if the owner weights
durability/AperFunction over DRY, keep `gerber-writer` for the six Gerber layers
(retains `%TA.AperFunction`) and use `gerbonara` **only** for Excellon + IPC-356
(the two things gerber-writer cannot do at all). Ownership: gerber.py owns Gerber;
a new `excellon.py`/`ipc356.py` owns drills+netlist via gerbonara. Cost: two
Gerber-capable libs stay in-tree (worse DRY), but zero hand-written Excellon.

### Structured future-gates (feature → blocking library → canonical-model gap)
1. **X2 `.AperFunction` / `.TO` net attributes** → *gerbonara writer emits neither*
   (only `%TF`). Canonical model also has no per-pad function / net-attribute field.
   Close via post-write attribute injection or an upstream gerbonara PR + a model
   `pad_function` / net-map field.
2. **Rotated SMD/footprint pads** → *gerbonara* has no `Flash` rotation (needs a
   rotated-rectangle aperture macro). Model already carries `rotation_deg`; the gate
   is purely emitter-side (macro synthesis).
3. **Routed slots / inner cutouts & mounting holes as first-class geometry** →
   emitter-capable in gerbonara (proven), but the **canonical `board.yaml` has no
   slot / cutout / mounting-hole / pour entities** — today they ride `Extra`. Needs
   real schema fields before boards can request them.

*(Honorable mention: layer/job manifest — neither writer proved a manifest emitter;
gerbonara's `LayerStack` is a candidate but unverified for write.)*

---

## Reuse declaration
- **READ, not modified:** `pcb/worker/pcb_worker/gerber.py` (incumbent baseline —
  feature source of truth), `pcb/spikes/gerber/{generate.py,board.yaml,golden/,REPORT.md}`
  (coupon geometry + blessed golden `spike-gerber-v1`).
- **REUSED (imported, unmodified):** `pcb/worker/tests/oracle/geometry_diff.py`
  (parse + structured diff + registration), `provenance.py`, `kicad_drc.py`.
- **NEW (this spike, fence `pcb/spikes/cam/**`):** `gerbonara_coupon.py`,
  `compare_harness.py`, this `DECISION.md`, `out/` (9 emitted files).

## Out-of-fence findings (reported, not acted on)
- **SB.2 `geometry_diff.parse_drill_file`** assumes every Excellon object is a
  `Flash` (reads `o.x`); it **crashes on a routed slot** (`Line`, has `x1/y1`).
  Needs slot handling before slots can be diffed. (Fence: `pcb/worker/` runtime —
  and geometry_diff is the shared harness; left untouched.)
- **kicad-cli DRC oracle** can't be imported from the spike venv:
  `agent_router.layers` import error via `pcb_worker.kicad`. Pre-existing;
  emitter-agnostic (does not affect the writer choice).
