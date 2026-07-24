# PCB design-rule checking (two surfaces)

The worker exposes **two distinct DRC surfaces**. They answer different
questions and must not be confused: a pass on one is not a pass on the other.

| | `drc` (`_drc`) | `drc_geometric` (`_drc_geometric`) |
|---|---|---|
| MCP tool | `minerva_pcb_pcb_drc` | `minerva_pcb_pcb_drc_geometric` |
| What it reads | pad **centers** + trace **centerlines** | real **copper + hole geometry** (the ResolvedBoard IR) |
| Question | is the net **topology/connectivity** sane? | is the **copper geometrically** legal? |
| Kernel | `pcb_worker.drc` (`run_drc`) | `pcb_worker.drc_geometric` (`run_geometric_drc`) |
| Reply shape | legacy `{ok, result:{findings, counts}}` | the geometric **result union** (see below), verbatim |

## `drc` — connectivity / topology (legacy, NOT geometric)

`_drc` runs the centerline checker over a best-effort-resolved board. It reasons
about pad centers and trace centerlines only, so it **cannot verify a clearance,
a trace width, or an annular ring**. Its findings are connectivity faults:
`wrong_net_pad` (endpoint on a different-net pad → short), `crossing` (two
different-net traces intersect), `dangling_endpoint` (a leaf endpoint reaching no
pad/via → open), `layer_change_no_via` (missing via). **A zero-finding `drc`
result is a topology pass, not a proof the copper is geometrically clean.**

## `drc_geometric` — geometric copper DRC (IR-based, fail-closed)

`_drc_geometric` parses the board, compiles it to the **ResolvedBoard IR**
(`compile_board.compile_board`), and runs the pure geometric kernel
(`run_geometric_drc`) over real copper/hole shapes. Checks:

- **GC1** min trace width
- **GC2** copper-to-copper clearance (same canonical layer, same-net exempt)
- **GC3** drill / finished-hole minimums
- **GC4** annular ring
- **GC5** copper-to-edge inset
- **GC6** hole-to-hole spacing

### Result union (returned verbatim — not the `{ok, result}` wrapper)

- **Determinate** (compile succeeded):
  `{ok:true, scope:"geometric", verifies_geometry:true,
  verdict:"clean"|"violations", findings:[…], counts:{…}, warnings:[…],
  board_id, source_digest, rule_profile}`.
- **Indeterminate** (compile failed, or the kernel met geometry it cannot
  model — a non-rectangular outline, a copper zone/pour, …):
  `{ok:false, scope:"geometric", verifies_geometry:false,
  verdict:"indeterminate", error:{kind, message, diagnostics}}` — carrying **no**
  `clean`/`findings`/zero-counts a caller could mistake for a pass. `kind` is
  `unresolved_geometry` when the board parsed but would not compile/resolve
  (unknown footprint, sizeless pad), or `unsupported_geometry` when the kernel
  met geometry it does not model (non-rectangular outline, copper zone), or
  `internal` on an unexpected fault.

A board that will not **parse** at all returns the structured `{ok:false,
error:{kind:"parse"}}` reply instead (no `verdict`), mirroring
`generate`/`gerbers`.

### Safety invariant — never a false `clean`

The kernel is **fail-safe** (every modeled shape is exact or a superset of the
real copper, so a computed margin never exceeds the true margin) and
**fail-closed** (un-modelable geometry → indeterminate, never a silent skip).
`ok:true` means *the check ran to a verdict*, not *the board passed*.

### Corroborated against kicad-cli

The IR-native verdict is cross-checked against the external `kicad-cli pcb drc`
(KiCad 9.0.x) in `tests/oracle/test_kicad_drc_geometric_oracle.py`: a known
clearance short and a clean board are each rendered through the production IR
path (`kicad.generate_ir`) and confirmed to agree with kicad-cli over the
**intersection** of categories both engines implement (clearance, track width,
annular ring, hole-to-hole, copper-to-edge). This is a *corroboration* — the
kicad board is still a projection of our own IR — not a proof of full geometric
coverage.
