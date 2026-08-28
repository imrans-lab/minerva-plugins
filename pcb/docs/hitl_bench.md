# The HITL bench

`worker/tests/testdata/hitl_bench.yaml` is a **bench**, not a coupon. It is a
60 x 286 mm synthetic board laid out as a **table**: one scenario per row, fixed
12 mm pitch, a board-level silk label in the left 10 mm of every row, and **no
net shared between rows**. Point at a row, run one tool, compare what came back
with the answer written beside it in the YAML.

It is never ordered. The JLC coupon is the fabrication test; this is the
behaviour test.

## How to read it

* Row *n*'s centre line is `y = 8 + 12*(n-1)` — R1 at y=8, R23 at y=272.
* Cell **A** sits around x=22, cell **B** around x=46. A one-cell row uses A.
* **Never more than two tests in a row.**
* Modes: **P** the geometry is here and the human only reads what the tools
  say; **I** the human performs a gesture against pre-placed geometry;
  **blend** one cell of each.
* Every net is named `R<n>_<letter>`, so a ratsnest, a DRC finding or a census
  row names its own row out loud.
* Footprint refs the seed library does not stock are named `Bench_*` (never
  colon-shaped — a colon ref used to strip inline pads on the wire path). Their
  `pads:` lists are the whole geometry authority, so the board compiles, DRCs
  and fabricates, but **strict `minerva_pcb_resolve` refuses them by contract**.
  Use `drc` / `board_health`, never `resolve`, to prove this board healthy.

**Row numbers are stable; row subjects are not.** A row keeps its slot for the
life of the bench, but a question that has been answered is retired and the slot
re-used. The silk label is the authority on what a row is about — read the
board, not an old results sheet.

## Whole-board baseline

Measured through the worker's own entry points on the current file.

| Surface | Answer |
| --- | --- |
| `validate` | 0 errors, 1 warning — R9 B's 0.05 mm probe is under `design_rules.trace_width_mm` (deliberate) |
| entities | 48 components, 29 nets, 18 traces, 5 vias, 5 zones, 23 board graphics |
| `compile` (V1_FAB_OUTPUTS) | `ResolutionSuccess`; `zone_filled` x4, `footprint_from_board` x8, `ordinal_ids` x1, plus library noise (`feature_omitted` x9, `captured_geometry_not_emitted` x40) |
| `drc` connectivity | `dangling_endpoint` 5, `wrong_net_pad` 0, `crossing` 0, `layer_change_no_via` 0, `indeterminate` none |
| — dangling at | R1_B (40.475, 4.75); R5_A (22.9, 56.0) and (27.1, 56.0); R22_A (22.0, 260.0); R23_B (46.0, 274.0) |
| — partial | R1_B 2, R3_G 2, R5_A 3, R16_A 3, R21_B 2, R23_B 2 |
| — missing copper | R4_A, R15_A |
| `drc_geometric` | exactly ONE finding: `gc1_trace_width` on R9 B's probe |
| `zone_fill` | Z3 (bottom) 1 region 104.0000 mm²; Z13 (top) 112.0000; Z21A (bottom) 70.0000; Z21B (bottom) 70.0000 |
| `board_health` / `check_bom` / `gerbers` / `fab_preview` / `generate` | ok |
| strict `resolve` | FAILS by contract: `footprint ref 'Bench_RotLand_1P' is not in the seed library lockfile` |

## The rows

| Row | Label | Mode | Cell A | Cell B |
| --- | --- | --- | --- | --- |
| R1 | trace end | P | 1.0 mm run ending 0.354 mm off a 1.3x4.5 pad centre → joined, dangling 0 | the same run 1.0 mm short → dangling at (40.475, 4.75), R1_B partial 2 |
| R2 | through pad | P | run driven THROUGH a same-net land → R2_A complete, 1 group | 0.25 mm stub on a QFN exposed pad, fed by a via-in-pad → complete, dangling 0 |
| R3 | pad pour | I | pour is on **B.Cu**. Draw from TP3A on the BOTTOM layer and single-click inside it: the run ENDS there, R3_G leaves `partial`, no dangling. Start state R3_G partial 2 | *falsifier:* the same draw on the TOP layer — no copper up there, so the click is a waypoint and the end stays free |
| R4 | npth route | I | propose TP4A.1→TP4B.1 on R4_A: SUCCEEDS, one candidate at 0.25 mm `board_rules`, and the warnings name `R4_N`/`MH4.1` excluded plus "fewer than two routable pads". Used to refuse the whole board | — |
| R5 | npth via | P | R5_A partial, 3 groups: the M3 hole is drilled and never plated, so the top↔bottom join is still owed; 2 deliberate dangling ends | via V5 fed on top only → `layers_touched ["top"]`, dangling 0 |
| R6 | swap move | I | P, click TP6A, shift-click TP6B, Swap nets → ONE Undo restores both | "Move net to…" from TP6C; `export_yaml` agrees with the panel |
| R7 | pin select | blend | `free_pins` on the 2x3 socket, side "west" → pins 1,2,3; `exclude_roles ["strapping"]` → 2,3 | `select` lights J7.2/J7.3; `get_selection` returns pad rows carrying their roles |
| R8 | rotation deg | P | R_0805 at rot 90 → pin 1 SOUTH at (22.0, 92.95) | the same at rot 270 → pin 1 NORTH at (46.0, 91.05) |
| R9 | rotated land | blend | **I** — draw onto U9A's 2.0x0.6 land that carries its OWN rotation 90; the end at (22.0, 104.8) is 0.2 mm inside it, dangling 0 | **P, inspect only** — pre-routed. A 0.05 mm probe ends 0.0757 mm inside a roundrect's rounded corner: dangling 0. The 0.076 mm margin is not a gesture a hand can aim |
| R10 | silk text | blend | `add_silk_text` on F.SilkS reads normally | the same on B.SilkS reads MIRRORED in fab preview; Delete + one Undo |
| R11 | board art | I | `add_graphic` rect + circle on F.CrtYd, drawn, selectable, deletable | `get_selection` names the graphic by its own id |
| R12 | inline pads | P | a ref in NO library compiles anyway from its own `pads:` — `footprint_from_board`, DRC determinate | `pads: []` over a ref that DOES resolve → zero pads, graphics only, no BOM/CPL line |
| R13 | no fill | I | ships FILLABLE (112.0000 mm²). Add BOTH `thermal_gap_mm` and `thermal_bridge_width_mm` to Z13 → the compile is refused naming the zone, and R3_G turns `indeterminate` with reason `zone_copper`. Remove both to clear | — |
| R14 | id reload | blend | note the via id, `export_yaml` → `load_board` → `delete_traces` with the OLD id still resolves | hand-corrupt the sidecar's id claim → warning on restore, copper untouched |
| R15 | route hint | blend | a bottom waypoint past a top keepout → EXACTLY ONE via, 0.8/0.4 from `design_rules` | `propose_via for_hint` lists it under the hint; a bare `propose_via` shows unowned |
| R16 | width source | P | route TP16C→TP16D on a net that already carries 0.4 mm copper → candidate 0.40, source `net_copper`, not the 0.25 mm design rule | — |
| R17 | view fit | I | narrow docked panel, `fit:true` → the whole 60 x 286 visible | Home centres on the board |
| R18 | fab preview | I | renders over the 64 KiB IPC cap (snapshot-by-reference) | contrast readable |
| R19 | status timer | I | two refused clicks <2 s apart → the second message keeps its full 2 s | a held lead survives a transient message |
| R20 | annot dock | I | 3 long annotations at ~554 px: opens ≈1/3, cannot drag past 50%, re-clamps on resize | every control reachable, no horizontal scroll at 1200 px, chevron closes |
| R21 | via credit | P | a via on a run's **interior** (its exact midpoint) straps the probe pair to the back pour → R21_A COMPLETE, 1 group, dangling 0. *Falsifier:* delete that via → 2 groups | the same via moved 1.0 mm off the centreline — copper reaches 0.65 mm, 0.35 mm of laminate is left → R21_B partial 2 groups, dangling 0. *Falsifier:* put it back on the line → 1 group |
| R22 | add by ref | I | add `Connector_PinHeader_2.54mm:PinHeader_1x02_P2.54mm_Vertical` at (22.0, 260.0) BY REF, connect pin 1 to R22_A: geometry block reads fabricable/`library`/pad_count 2, the shipped stub's dangling finding is GONE, R22_A complete, no new geometric finding | add a generic `HEADER` at (46.0, 260.0): geometry block reads NOT fabricable / `sketch` with the note, canvas badge, status lead names it, and every pour stops filling with the refusal naming the part. **Undo it** — while it stands, R3's and R21's answers go dark |
| R23 | part on back | P | a `layer: bottom` part's land authored at local (0, −2.0) lands on **B.Cu at (22.0, 274.0)** — mirrored SOUTH — and a BOTTOM run ends on it: R23_A complete, 1 group. *Falsifier:* read it as F.Cu at (22.0, 270.0) and the end dangles | the SAME land approached by a TOP run: dangling at (46.0, 274.0), R23_B partial 2 groups. Copper on the other side of the laminate joins nothing |

## Two things the file deliberately does not do

1. **No unfillable pour is shipped.** A pour the filler refuses raises
   `ZoneFillError`, which fails the WHOLE compile — and `zone_copper.pour_nodes`
   then reports EVERY pour as indeterminate, not just the bad one. So R13 ships
   fillable and its fault is the *gesture*. R22 B is the same shape of hazard
   from the other direction: an unfabricable part refuses the compile, so it is
   a gesture to be undone, never a shipped state.
2. **Unresolvable footprint refs are deliberate**, and the strict `resolve`
   surface refuses them. The board LOAD path (`resolve_best_effort`) is
   tolerant, so the panel opens the board normally.

## Where the oracle lives

Twice, on purpose, so the GUI walk and the MCP walk read the same answer:

* the comment block above each row's components in `hitl_bench.yaml`;
* docket hint `pcb` / `hitl-bench`, which carries the per-row expectations and
  the measured whole-board baseline.

Neither records tracker ids or dates. The docket item holds those.

Load a **copy** for a walk (`~/pcb-hitl/hitl_bench.yaml`) so routing sidecars
never land in the repo.
