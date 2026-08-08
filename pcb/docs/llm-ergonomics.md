# LLM Ergonomics — HITL-4 findings and fixes

Source: the first post-Epoch-UX1 owner co-working round (2026-08-06, smart-remote
board, docket question 019fd440deb9 lineage). The owner's framing: the LLM is a
co-worker driving these tools blind — every reply is its entire view of the
world. An ergonomics defect is anything that makes the reply lie by omission,
bury signal, or fail to hand the model the context a human at the canvas gets
for free.

The HITL-4 round produced one P1-class live bug (F0) and a proposal the owner
correctly called unbuildable — routed through a known-broken placement with no
automated signal firing. The root-cause analysis is at the bottom; the numbered
findings each carry their fix state.

## F0 — live path dropped task_constraints (FIXED, HITL-4)
`PCBPanel.route_board` forwarded `extra` through a pre-station-9 allow-list;
`task_constraints` never reached the worker. Corridor steering was a silent
no-op in production while both test suites were green — each side was tested
against a double of exactly the function in the middle (RouterShim client-side,
pytest fixtures worker-side).
**Fix:** forward the key (PCBPanel.gd, tagged HITL-4). **Debt:** a seam test
that drives the real `route_board` request assembly instead of a shim.

## F1 — silent "nothing to route" (FIXED: per-span outcomes)
An already-connected span (GND BAT1.2→U1.22, satisfied by existing B.Cu copper)
returned `routes_returned:0`, empty `unrouted`, empty `stuck` — byte-identical
to a dropped request. Diagnosing it cost a geometry dump, a solo re-propose and
a full trace export.
**Contract:** every span asked about appears in exactly ONE of: `candidates`,
`holds`, `unrouted`, or the new `span_outcomes` (e.g.
`{span, status:"already_connected", connected_via:[...]}`) — accounting
identity, silence impossible.

## F2 — connectivity DRC cannot say "incomplete" (FIXED: completeness)
`drc_summary` reported clean while VCC_5V (D1.1→U1.21) had ZERO copper. The
summary checks shorts (copper vs net assignment), not completeness — "this net
has no route yet" was structurally unreportable, so the owner found the missing
D1/U1 connection by eye.
**Fix:** propose/DRC replies name in-scope nets with missing/partial copper.

## F3 — assembly collisions invisible (FIXED: courtyard advisory)
D1 (SMA) and BAT1 (JST-PH) bodies overlap — the parts cannot be assembled.
No gate fired: geometric DRC is copper/drill only (gc1–gc7) and courtyard
geometry is captured but "documentation-only" (the emitter notes say so on
every reply). The collision PRE-EXISTS the routing session; the owner flagged
this exact placement last cycle. Full courtyard DRC is the deferred engine item
(docket 019fce3a6c57); the ergonomics floor is cheaper:
**Fix:** advisory courtyard/body-overlap pass (bbox-level) surfaced at
load_board and in propose DRC output — enough for a co-worker to say "these
parts collide" before proposing copper through them.

## F4 — misleading `detail_level 'sparse'` warning (FIXED)
Intent-minted hints (which NEVER carry waypoints; steering rides
task_constraints) drew "detail_level 'sparse' has no agent_router slot — it
selects the bridge path… not engine behaviour" — implying the corridor might
not steer, on exactly the hints where it does. During F0's diagnosis this was
an active red herring.
**Fix:** suppressed when a task_constraints entry applies to the hint; replaced
by the constraint-steered status that already exists.

## F5 — float drift in hint_status (FIXED)
`hint_status[].constraint_revision` surfaced as `1.0` while the candidate's own
field is int — the exact drift class Codex-1047 verdict 8 covered.
**Fix:** int-normalised in the `_attach_hint_status` lift.

## F6 — emitter_notes flood on every propose (FIXED: routed to fab surfaces)
~27 per-BOARD static capability notes (footprint fab-text omissions) repeated
verbatim on every propose, dominating the reply. They are fab/export facts, not
routing facts.
**Fix:** propose-family replies carry a one-line count summary
(`emitter_notes_summary`); the full list stays on the fab-time surfaces
(gerbers/export) where it is decision-relevant.

## F7 — stale/thin tool descriptions (FIXED in manifest)
(a) `add_route_intent` still described the P1-A conflict rule as "dropped, with
a warning" — since Codex-1047 the constrained singletons are KEPT and steering
survives. (b) Nothing in the authoring tools tells the model to gather spatial
context first; pin positions are the only geometry the intent loop hands you.
**Fix:** description corrections + an explicit "fetch board context
(get_image / spatial_query / describe_component) before authoring corridors"
nudge on add_route_intent.

## F8 — plugin_inspect is 87KB on one line (OPEN, core Minerva)
Blew the caller's context. Needs a lean default (status/version/tool count)
with opt-in detail. Core-side; filed rather than fixed in this round.

## F9 — process finding on the model side (no code)
The agent authored corridors from pin coordinates alone: no render, no
footprint extents, and it routed inside a placement the owner had already
ruled broken. Tool ergonomics can lower the cost of context (F3, F7b) but the
co-working discipline is: placement questions settle before copper, and
geometry authored blind is geometry authored wrong.

---

## Why the HITL-4 proposal went awry (owner's item-2 question)

1. **Could the model see the board?** The capability existed (get_image,
   render_overlay, describe_component) and was not used — corridors were
   authored from pin coordinates only. Neither footprint bodies nor courtyards
   are surfaced anywhere in the intent→propose loop itself (F3, F7b).
2. **Was it a DRC failure?** No check failed — the two relevant checks did not
   exist: no courtyard/assembly overlap check (F3) and no connectivity
   completeness check (F2). Both reported "clean" boards that a human at the
   canvas would reject on sight.
3. **The short that wasn't:** the owner's first read (GND+VBAT into one D1 pad)
   resolved on inspection — the GND return crosses under D1 on B.Cu, which is
   legal. The real defects were the assembly collision (pre-existing placement,
   F3) and the unrouted VCC_5V net (F2). Neither was created by the proposal;
   both should have been NAMED by the tooling before any routing was attempted.

---

# Epoch UX2 outcomes ("real parts first", 2026-08-07/08 — docket 019fde5764b6)

The HITL-5 findings batch, all SHIPPED this epoch:

## Accepted state is invisible (owner-ruled Option A)
An applied route hint renders NOTHING — no markers, no label, unconditionally
(above supersession, selection, headless). The annotation persists as an
invisible record (refs, provenance, undo); commit-undo re-inks it because the
render mode is a pure lifecycle read. Enforced past rendering: a consumed hint
cannot be selected (host veto), picked (bend/via tools skip it), or edited
(path lock); the lifecycle reconcile runs BOTH directions (undo reopens, redo
re-closes). The core annotations dock hides consumed records behind a
"Show consumed (N)" toggle.

## The routing loop's missing verbs
- `clear_constraint:true` on reroute_route — a corridor can now be REMOVED,
  guarded and durable like every steer; the constraint_stale_candidate refusal
  finally advises a verb that exists. Revisions stay monotonic across clears
  (a stale pre-clear candidate can never pass the commit gate).
- `width_mm` on add_route_intent and reroute_route — width is part of intent;
  the three-wholesale-payload-patches workaround is gone.

## Quality as a signal, not a human catch
Every candidate record carries `bend_count`, `routed_length_mm`,
`length_ratio` — the "5+5+5 vs 2+2+5" placement smell is now a number, and the
tool descriptions say what a high value on a short hop means (move the part).
`island_deltas` reports what each route BUYS against the census ("merges 2
islands → 8 remain"; a zero-merge is reported, not hidden).

## Reply honesty polish
Placement replies disclose grid snaps (`snapped` + `requested`);
move_relative's echo now reports where the part actually landed;
`pin_groups` reaches callers as an int; the sparse-detail_level warning no
longer fires for empty-waypoints hints (nothing to "route as drawn").

## Durability + at-open visibility
- Annotation sidecars are durable-by-default: debounced auto-write on every
  mutation, teardown flush, and path-form load_board ADOPTS the file as the
  sidecar home (write-on-adopt, pending-flush-before-switch, routing-sidecar
  load mirrored) — the HITL-4 restart-loss class is closed end to end.
- `board_health` rides the LOAD reply (new pcb.board_health channel): "8 nets
  unrouted, GND in 9 islands" is known at open, before the first routing verb.
- F8 closed core-side: plugin_inspect is lean by default with include-arg
  opt-ins.
