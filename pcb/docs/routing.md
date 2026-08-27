# Canonical routing (IR-based, fail-closed)

Sibling of `docs/drc.md`. Since Round E1 (docket 019f783860c8) the canonical
`route` path **consumes the compiled ResolvedBoard IR or it does not route**.

## Why it fails closed

The owner-ratified Step-4 ruling puts routing in the fail-closed bucket:

> canvas DEGRADES (pins-as-dots + unresolved badge); ROUTING/DRC/CAM FAIL CLOSED.
> No approximated copper.

Before E1 the router was handed the RAW board and `route_bridge._pad_size_for`
returned a nominal `1.0 x 1.0` land for any pad with no authored geometry. That
land is smaller than most real packages, so the router computed keepouts around
copper the board does not have and could propose a trace straight through the
real package land. Accepted, that proposal becomes fabricated copper — precisely
what the ruling forbids. There is no honest size to invent, so the nominal
fallback is gone and every dimension now comes from the IR.

## The path

`_route` (canonical input) → `board_model.load_board` → **strict compile**
(`_compile_or_fail`, `requested_outputs=V1_ROUTING_OUTPUTS`) →
`route_bridge.resolved_board_to_router` → `agent_router`.

**Routing capability profile.** Routing compiles against `("copper", "drill",
"rules")`, not the full fabrication set: a solder-**mask** capability loss cannot
make a route unsafe and must not disable routing, while any dropped copper, drill
or rule stays fatal. It is a strict subset of `FABRICATION_CRITICAL_OUTPUTS`, so a
board that will not compile for routing will not compile for fabrication either.

## Run scope — which nets a call actually routes (docket `019f80a80123`)

**The rule, in one table.** It is a property of `route_hints`, nothing else.

| `params.route_hints` | What gets routed |
|---|---|
| absent, or `[]` | **the whole board** — every net with >= 2 pads |
| non-empty | **only the nets the selected hints resolve to** |

Both answers are defensible; picking one silently is not, which is why this
table exists. The reasoning:

- **No hints ⇒ whole board.** `route(board)` with nothing else has always meant
  "autoroute this board". It is `agent_router/cli.py`'s contract and every
  unhinted caller's, and there is no selection to narrow it with. This is the
  one use of the method that was never ambiguous, so it is left alone.
- **Hints ⇒ scoped.** Before this, `selection` / `hint_ids` scoped only which
  hint *annotations* were consumed. The engine went on auto-routing every net
  with >= 2 pads, so two hints on the smart-remote board came back with
  **sixteen proposals, one per net** — each tagged `proposal_for` the two hints
  that never asked for them.
- **An empty scope is honoured, not widened.** Non-empty `route_hints` of which
  *none* resolves to a net (all malformed, or a `selection` that matches no
  hint) routes **nothing**, and says so in `warnings`. Falling back to the whole
  board there would reinstate the exact surprise above at the worst possible
  moment — when the worker has just failed to understand the request. Every
  individual reason is already in `warnings` from `route_bridge._net_for_hint`;
  the added line names the consequence, which no per-hint warning can.

**"Implicates" means the nets the hints actually resolved to** — taken verbatim
from the translation that is about to be handed to the engine
(`HintTranslation.nets_by_hint`, plus the net of any as-drawn hint), never
re-derived afterwards. Concretely, per hint: an explicit `net_names[0]` **if the
board has that net**, else the net of the first resolvable `source_pins` entry,
else the first resolvable `dest_pins` entry; a `bus` hint implicates every one of
its `net_names` **that the board actually carries** (the ones dropped with a
warning are not in scope and are not attributed). Recording it during the same
pass that resolves it is deliberate: a second resolution pass could disagree with
the first, and that gap is how an attribution that lies gets built.

Scope is a function of the **hints**, never of what copper is already on the
board. A commit and its undo change the copper census; they never change which
nets a hinted run touches.

### Excluding a net from routing never excludes its copper from the grid

This is the invariant to protect when touching any of this. A net left out of the
run is still a **wall** the nets in the run must path around — its pads, its
holes and its accepted copper are all obstacles exactly as before.

It holds by construction, not by care: `only_nets` is consulted at **one** place,
`agent_router/router.py::_scoped_nets`, applied to the ordered net list the
automatic loop walks — and *every* grid marking (`grid.mark_pad` over
`board.pads`, `_mark_existing_copper`, `grid.mark_obstacle`) has already happened
by then. `existing_traces` is the whole board's accepted copper whatever the
scope is.

`only_nets=None` means "no scope given" and routes everything, which is what
every pre-scope caller (the CLI, the tests) still gets. An **empty set** is a
real answer meaning "scoped, and nothing was in scope". Conflating the two would
reinstate the bug, so the code tests `is None`, never truthiness.

Authored input — buses, chains, internal bridges — is **not** filtered by
`only_nets`, on the standing rule that authored input is admitted or rejected,
never reinterpreted (the same reason the T7 group contraction is not applied to
bridges and chains). Callers must therefore include any authored net in the
scope; `_route` does, via `_authored_hint_nets`, so the scope is a superset of
what the engine will touch by construction rather than by an argument about which
hint kinds the bridge can currently emit.

### Attribution: `hint_ids` per route

Each returned route carries **`hint_ids`** — the hints that asked for *that net*,
not the run's whole selection. Absent-key contract, like `drc` and
`drc_geometric`: an unhinted whole-board run carries no `hint_ids` at all, because
an empty list would read as "no hint wanted this route" when the truth is that no
hint was asked. As-drawn routes are attributed from the `hint_id` the
materializer already stamped on them. `selected_hint_ids` is unchanged and still
means what it always meant — *these hints fed the run* — which is exactly why it
is not what attribution uses.

Two hints that genuinely both name one net both appear on that net's route.
Truthful is not the same as "exactly one id".

**Consumed by the panel** (docket `019f9c3a136c`). `proposal_for` is read
straight off the worker's per-route `hint_ids` and is no longer re-derived:
`panel_tools._route_hint_ids` forwards the list verbatim, and the old
`_source_hint_ids_for_net` — which matched on `net_names` alone and fell back to
**every selected hint** when nothing matched — is deleted, along with the
fallback. A route with no attributed hints gets an empty `proposal_for`, whether
the worker omitted the `hint_ids` key entirely (no hints were supplied) or sent
it as `[]` (hints were supplied, none named this net). Those two states mean
different things and only the OUTPUT collapses.

This mattered because `minerva_pcb_proposal_accept` (S5, C4b, DCR
`019f7095c395`: RETIRED — replaced by `minerva_pcb_workspace_commit`, which
reads the same attribution as `consumed_hint_ids` and closes each hint's
lifecycle open→applied rather than deleting it) used to delete exactly the
hints named in `proposal_for`. Under the fallback, a hint that named its net
through `source_pins` rather than `net_names` never matched, so every
proposal claimed every hint — and accepting one proposal could silently
delete a hint the user never got an answer to. The same attribution
discipline (worker `hint_ids` verbatim, no net-name fallback) still governs
`consumed_hint_ids` on the current path.

**No longer re-derived on the production path** (docket `019fa109766f`, owner
ruling comment 869 — Shape A). `ingest_record` now passes the record's
correctly-attributed `source_hint_ids` into `_create_candidate_for_route` as
`explicit_hint_ids`, and that branch resolves hint ids, endpoints and width by
id — no net-names match, no blanket fallback.

The seam matters: both ingest paths funnel into `_create_candidate_for_route`,
so changing the shared helper's *default* would have silently fixed the bulk
path too, which the ruling declined. The branch point is therefore the
caller-supplied parameter. `ingest_routing_result` passes nothing, falls through
to `_hints_matching_net`, and behaves exactly as before — it has no production
caller and no per-route `hint_ids` stamp to read, so fixing it would have cost a
fixture rewrite for no current benefit. It was NOT deleted: no current caller is
not dead code.

The fix also covered two siblings the docket item never mentioned:
`_endpoints_for_net` and `_width_for_net` used the *same* net-names-only match,
so a pins-only hint got empty endpoints and the 0.25 mm default width, not
merely wrong attribution. Extraction is now shared by both paths; the two
*matching* strategies are deliberately kept distinct.

Pinned by `pcb/worker/tests/test_route_scope.py`, which drives `route()` for
every one of these claims — including the docket's own repro (six routable nets,
two hints, two proposals) and a grid probe proving an excluded net's copper is
still blocking.

## What comes from the IR

Position, rotation, side/mirror, copper-layer participation, net ownership, size,
shape and drill — all of it. Pad copper is shaped by
`ir_pads.pad_copper_shape`, the **same neutral owner** the CAM emitters fabricate
from and geometric DRC checks (`pad_source.placed_pad_to_geom` + `th_land`), so
routed keepouts, checked copper and fabricated copper cannot drift apart.

**Conservative envelopes.** `agent_router`'s `RoutingGrid.mark_pad` marks an
unrotated rectangle and **discards** the rotation argument it accepts. Handing it
a truthful `w/h` for a rotated elongated land would therefore under-block along
the rotated axes. It is handed the land's axis-aligned **bounding box** instead —
a strict superset of the real copper. Same invariant as the DRC kernel, restated
for keepouts:

> the modeled keepout must be a SUPERSET of the fabricated copper. Over-blocking
> is legal; under-blocking never is.

**Inflation composes with that superset, it does not replace it** (Round E2).
`RoutingGrid.keepout_margin` = `clearance + trace_width / 2`, and it is the
single owner of the term — **all three** markers go through it (`mark_pad`,
`mark_obstacle`, `mark_trace`), for the same reason `_pos_to_cell` is the single
owner of the world↔cell transform. A margin honoured in one marker and forgotten
in another is an under-block. Growing a box that already contains the rotated
copper still contains it, so the two over-blocks stack.

The half-width term is not decoration: the grid marks **centerline**-addressed
cells (the pathfinder tests one cell per step), so a trace centered exactly
`clearance` away from a pad still lays half its copper inside the clearance ring.
The same arithmetic applies to an already-routed trace, which is why `mark_trace`
now takes the **true copper width** and inflates it here rather than being handed
a pre-inflated `trace_width + 2 * clearance` by the engine: that literal reserved
a half-extent of `w/2 + clearance`, short by the newcomer's own `w/2`. The
correct half-extent — marked copper's half-width, the gap, the newcomer's
half-width — is exactly `w/2 + keepout_margin`.

Each marker writes two concentric regions: the copper itself
(`obstacle_type="pad"` / `"trace"`), and the ring around it as that copper's
reservation (`"pad_clearance"` / `"trace_clearance"`), under three rules that all
say the same thing:

| the ring meets | what happens | why |
|---|---|---|
| free space | claimed for the marker's net | a net owes no clearance to itself, so it may approach its own copper; everyone else is blocked |
| **copper** (pad or trace) | left alone | pads are marked in board order and traces as each net is routed; overwriting B's land with A's net would let A route straight through real copper |
| another **ring** of a different net | `net=None` — nobody passes | first-writer-wins would let that one net route within `clearance` of the other owner |

The precedence is **not** symmetric, and the asymmetry is deliberate: a ring never
overwrites copper, but a **copper** mark does overwrite a contested `net=None`
ring cell unconditionally. That is a weakening, and it is bounded — it is
reachable only where that net's own copper physically sits (plus at most the one
cell `_cell_range` over-claims, whose reasoning is recorded at that method). A
cell occupied by a net's real land is not a place any router could have kept that
net out of, so re-typing it as copper describes the board rather than relaxing a
rule. Under-blocking that mattered would need a ring to lose to something that is
*not* copper, which cannot happen.

An obstacle (hole) belongs to **no** net and clears any net it lands on:
`can_route_through` lets a net cross its own cells, so an inherited net would be a
licence to route through a mounting hole.

**Effective width and clearance (Round E2).** The run routes at the **board's**
rules, not the engine's. `agent_router.Board` has no slot for either — they are
per-run engine options, not board geometry — so `pcb_worker.methods.
_effective_routing_rules` resolves them and passes both to `route_board` /
`route_board_with_hints` explicitly. Precedence, highest first:

| # | source | trace width | clearance | scope |
|---|---|---|---|---|
| 1 | explicit caller option | `options.trace_width` | `options.clearance` | whole run |
| 2 | hint-authored width | widest `width_mm` among selected hints | — (a route hint has no clearance field) | whole run |
| 3 | **per-net rules**, whichever is **wider**: the net's class minimum, or the width its **existing copper** establishes | `max(net_class.min_trace_width_mm, widest existing trace on that net)` | `net_class.min_clearance_mm` | width: **that net's own copper only**. clearance: **board-wide** — see "Keepout margin" below, this is not a symmetric pair |
| 4 | the compiled board's design rules | `design_rules.defaults.trace_width_mm` | `design_rules.minimums.min_clearance_mm` | whole run (fallback) |
| 5 | the engine's own signature default | `route_board`'s `trace_width` | `route_board`'s `clearance` | whole run (fallback) |

Steps 1 and 2 are unchanged in meaning; E2 inserted (what is now) step 4 ahead
of what used to be the sole fallback, and this round inserted step 3 ahead of
*that*. Step 5 is still read from `route_board`'s **signature**
(`_engine_default_mm`) rather than re-spelled as a literal, for the same reason
the candidate overlay reads it there: a duplicated default that drifted would
under- or over-state a keepout as easily as a candidate width.

**Why step 3 sits exactly there.** Steps 1 and 2 fix a value for the **whole
run** — every net routes at it, uniformly, because that is what "the caller
asked for a 0.6mm run" or "the widest selected hint wants 0.5mm" means. A
per-net class rule must never be read as overriding that: it is scoped to
*one net*, so if it outranked steps 1/2 it would silently reinterpret what an
explicit run-wide request meant for every net that happens to carry a class —
exactly the reinterpretation the "admitted or rejected, never reinterpreted"
rule (below) forbids. So `pcb_worker.methods._route` captures, before the hint
merge, whether the CALLER set `trace_width`/`clearance` explicitly, and again
whether the hint merge added one; step 3 is applied **per net** only for a
dimension neither of those already fixed. It still outranks the board's own
blanket rule (step 4, now the fallback): a class exists precisely to make one
group of nets (say, power) wider than the board's default, and a board-wide
number can't do that.

**An explicit option — or an explicit class rule — is admitted or rejected, never
reinterpreted.** Absent means "the caller/class said nothing", so the next step
applies; *present but inadmissible* fails closed naming the value. Quietly
substituting the board's rule for what the caller (or the net's own class) asked
for is the same dishonesty as quietly routing at the engine's default. The two
dimensions differ only in their **predicate**: `clearance: 0` is admissible
(asking for no clearance is a coherent request, and `positive_mm` would have
silently discarded it), while `trace_width: 0` is not — zero-width copper is not
copper, and routing at it while the overlay checked at something else is the
false-clean shape. `NetClass.min_trace_width_mm: 0` is exactly this case: the
dataclass itself allows `0` (non-negative), but routing refuses it as a width —
see "Per-net-class minima" below.

The chain is a sequence of explicit `is None` tests, not an `or` chain: `or`
treats `0.0` as absent, so a step legitimately yielding zero would fall through
while still passing an `is None` guard — the run and the overlay would then
disagree about the width. Every step, step 5 included, goes through the same
admission predicate.

If nothing in the chain yields a usable number the route **fails closed**
(`unsupported_geometry`, zero routes). There is no invented default: step 4's
`min_clearance_mm` is the same field `ir_connectivity` publishes and
`drc_geometric` reads as its global floor, so a run that FALLS THROUGH to step 4
cannot reserve less space than DRC will demand.

**An explicit option can produce copper DRC will flag, and that is correct.**
That guarantee is about step 4, and it does not extend up the chain. Steps 1–3
can each hand the engine a number below what `drc_geometric` requires:

- An explicit `options.clearance` or `options.trace_width_mm`, or a
  hint-authored width, is admitted on its own terms — the whole point of the
  chain is that a caller who states a number gets that number rather than a
  silent promotion to the board's rule.
- The class step is skipped entirely for a dimension steps 1/2 already fixed:
  `methods._route` strips class widths from `net_overrides` when
  `caller_set_width or hint_set_width` and class clearances when
  `caller_set_clearance`, before `_widen_for_net_classes` ever runs. So
  `options.clearance: 0.1` routes a board whose class demands `0.5` at `0.1`,
  while `_effective_min_clearance` still demands `0.5` on that net's pairs.

Geometric DRC has no precedence chain — a class minimum is a RULE, not a
preference — so it reports the violation. That is the honest outcome and the
reason the surfaces are kept separate: routing does what it was asked, DRC says
what the result costs. (Before per-net-class minima landed in `drc_geometric`
this could not be observed at all, because the interim guard made any net-classed
board `indeterminate`.) A caller who wants the class floor respected should not
pass the option.

## Per-net-class minima

**Authored on the board.** A board states its classes under
`design_rules.net_classes`, each entry naming its `members` — see
[`board-yaml.md`](board-yaml.md), "Net classes", for the authored schema and its
fail-closed diagnostics. The compile is three steps in two functions:
`compile_board._build_net_classes` parses the block into
`ResolvedDesignRules.net_classes` and returns the members lists **inverted** as
a net-name -> class-id map; `compile_board` itself then checks every mapped name
against the net index (`net_class_unknown_member`); and
`compile_board._finalize_nets` is what actually assigns
`ResolvedNet.net_class_id` from that map.

That inversion, not the class tuple, is what makes a class bite: both consumers
(`methods._net_class_overrides` here, `drc_geometric._net_class_minima` on the
DRC side) read **referenced** classes only, so a populated `net_classes` whose
members never reach a net constrains no copper. An unreferenced class is legal
and does exactly nothing.

Class states an authored board cannot express — principally a
`min_trace_width_mm` of `0`, which the authoring layer refuses but the IR admits
— are still reachable by building a `ResolvedBoard` with `dataclasses.replace`
(how `drc_geometric`'s floors are tested) or by monkeypatching the compile step
(`tests/test_route_rules.py`'s `net_classed_compile` fixture). Those helpers
exercise the consumers' fail-closed guards; the authoring path is covered
end-to-end by
`test_an_authored_net_class_routes_that_nets_own_copper_at_the_class_width`.

Two entry points **refuse** a class-carrying board rather than route or emit it
as if it carried none: `agent_router` (the standalone CLI — it has no compiler
and no per-net step, so the same board would come out at the blanket rules) and
`pcb_worker.kicad._ir_board_dict` (the `.kicad_pcb` has no per-class channel, so
the KiCad DRC oracle would check a board the Python kernel checks at stricter
floors).

The board-wide keepout widening below (see "Keepout margin") is the permanent
design, not a "for now" stopgap — it is a legitimate, conservative answer on its
own merits: a ring sized to one net's own requirement cannot also satisfy a
stricter class net that approaches that copper later.

**Which fields.** `pcb_worker.methods._net_class_overrides` reads
`NetClass.min_trace_width_mm` / `.min_clearance_mm` — the SAME two fields
`drc_geometric._net_class_minima` reads to build GC1's and GC2's effective
floors, so the width a net is routed at and the width it is checked against come
from one rule. It
deliberately does **not** read the plain `NetClass.trace_width_mm` (a nominal
default, mirroring `RoutingDefaults.trace_width_mm` — a different concept from
a *minimum*): the task is "route at the class's minima", and the `min_`-prefixed
pair is the minima.

**Per-dimension, not per-class.** A class naming nothing for a dimension (that
field is `None`) contributes nothing for THAT dimension — the net falls through
to step 4/5 exactly as if it carried no class. A class naming an unrelated field
only (e.g. `via_diameter_mm`) contributes nothing to either dimension. A class
that DOES name a dimension is admitted-or-rejected through the same predicates
as an explicit caller option (`positive_mm` for width, non-negative for
clearance) — see the box above.

**An explicit caller clearance defeats a class minimum, board-wide, silently
from the class's point of view.** This is a direct consequence of "steps 1/2
outrank step 3" (the "Why step 3 sits exactly there" box) applied to a
dimension whose margin is board-wide: if the caller passes `options.clearance`
explicitly, `_route` drops the clearance component out of every net's
`net_overrides` BEFORE `_widen_for_net_classes` ever runs (see
`methods._route`, the `caller_set_clearance` guard), so the widening step
never sees the class's `min_clearance_mm` at all — not "widened then
overridden", genuinely never consulted. A board with a "power" class
authoring `min_clearance_mm: 0.5` and a caller passing `options.clearance:
0.1` routes the WHOLE BOARD, including the power net, at 0.1mm — the class's
own requirement stops applying, board-wide, for as long as that option is set.
The reply is honest about it (`clearance_mm.source` reports `"caller_option"`,
never `"net_class"`, on every route — see `test_an_explicit_run_wide_
clearance_is_never_widened_by_a_net_class`), but a reader who authored a class
minimum and separately passes a run-wide clearance option needs to know THIS,
not just that the reply happens to say `caller_option`: it is not a smaller
number than expected, it is the class minimum not applying at all. This is the
same "admitted or rejected, never reinterpreted" policy the explicit-option box
above states for width/clearance individually — restated here because a class
minimum silently losing to a run-wide option is easy to miss the SCOPE of
(one net) if a reader has not connected it to the board-wide margin.

**Keepout margin: board-wide worst case, not per-net.** A per-net margin was
the first cut of this round, and it was wrong: `RoutingGrid.keepout_margin`
(`clearance + trace_width / 2`) sizes a RING that is a static reservation,
written once, by whichever net's copper it protects. Sizing that ring to ONLY
that net's own class cannot also satisfy a STRICTER class net that comes along
later and approaches the SAME copper — the ring it finds there is smaller than
its own requirement demands. That is an under-block, and routing.md's
invariant is unconditional: **the modeled keepout must be a SUPERSET of the
fabricated copper. Over-blocking is legal; under-blocking never is.** There is
no net-class carve-out for that sentence.

The exact `max(class_A, class_B)` fix — track which specific rule each ring
reflects, and compare against the QUERYING net's own rule at
`can_route_through` time — needs per-cell metadata and a query-time lookup,
which does not fit this round's shape (the grid's occupancy model is "one
owner, one static reservation" throughout, not "who is asking"). But the
invariant does not require the exact fix, only a CONSERVATIVE one: size the
grid's OWN `clearance`/`trace_width` — which `keepout_margin` reads for
**every** marking on the board, pad or trace, classed net or not — to the
**widest** value any class present on the board demands, never narrower than
the run's own baseline. `pcb_worker.methods._widen_for_net_classes` computes
it; `agent_router.router.route_board`/`route_board_with_hints` take it as
`keepout_clearance`/`keepout_trace_width`, separate from the (still genuinely
per-net) copper width. This is the SAME move this campaign has used at
every other point it met an under-block it could not model exactly: the
axis-aligned pad envelope for a rotated land, the containing disc for an oval
hole, the conservative obstacle for unnumbered copper. All of them trade
"maybe over-blocks a little" for "never under-blocks", because that is the one
direction the invariant allows.

One consequence worth being explicit about: because the margin is board-wide,
**every** net's keepout reflects the strictest class present, even a net that
carries no class of its own — an unclassed net's own copper is protected (and
protects others) out to the SAME distance as the strictest classed net on the
board, not its own narrower baseline. Concretely: on a board with SIG in a
"power" class (0.6mm width / 0.5mm clearance) and OTHER carrying no class
(0.35mm / 0.3mm board defaults), a foreign net is kept `0.6/2 + 0.5 = 0.8mm`
from OTHER's own pads too, not merely `0.35/2 + 0.3 = 0.475mm` — pinned by
`test_a_strict_class_elsewhere_widens_the_keepout_around_an_unclassed_nets_own_copper`.
COPPER WIDTH stays exactly per-net regardless (OTHER's own trace is still
drawn at 0.35mm) — only the shared RESERVATION widens.

### The net's own established width (bug `01a02bc4f800`)

**A net that already carries copper has already had its width decided.** Before
this, a span proposed onto such a net took the board's blanket default: measured
on smart-remote v2, routes proposed onto VIN committed at **0.25mm** while every
pre-existing VIN trace on that board is **0.8mm**. Nothing objected — geometric
DRC's GC1 checks a *minimum* width, never whether a width suits the current — so
a 2A input path fabricated at a quarter of its own copper's width, and every
report called it clean. The second-order harm is the worse one: each undersized
span looks identical to a correct one in every tool output.

So step 3 reads the copper as well as the class. `pcb_worker.methods._route`
asks `route_bridge.established_net_widths` for `net name -> widest existing
trace`, over the SAME `ExistingSegment` list the grid is about to mark (accepted
copper plus any pinned candidate — `existing_copper_with_pinned`), so the width a
net adopts and the copper the run routes around are one observation rather than
two that can drift. The reply names it: `effective_routing_rules.trace_width_mm.
source` is `"net_copper"` on such a route, distinct from `"net_class"` and from
`"board_rules"`.

**Combined by `max`, not by precedence.** A class minimum and the net's own
copper are both per-net and both *floors*: routing below the class minimum
proposes copper the board's own DRC will flag (GC1 enforces it whatever routing
decided), and routing below the established width is the defect above. So the net
routes at whichever is wider, and the provenance names the one that decided it; a
tie keeps `"net_class"`, since nothing was widened by the copper.

**A net with no copper inherits nothing** — it is simply absent from the map and
falls through to step 4, the board's own default, which is the honest answer for
a fresh net. That is also why raising `design_rules.trace_width_mm` is not a fix
for this bug and never was: it would make the power span right and every
thin-signal span wrong. The width has to come from the NET.

**Steps 1/2 still outrank it**, exactly as they outrank a class minimum and for
the same reason: `options.trace_width` or a hint-authored width fixes the value
for the WHOLE RUN, and reinterpreting that per net would silently override a
stated decision. A caller who states `0.6` gets `0.6` on a 0.8mm net, reported as
`caller_option` — a stated number, not the silent board default this bug is
about.

**Mixed widths: widest wins.** A net whose copper is not uniform has no single
obvious answer, and the rule is deterministic: the widest existing trace on that
net. Widest can only over-size, and over-sized copper either fits or fails
LOUDLY (an unrouted pair with a reason); under-sized copper on a power net is a
defect every gate calls clean — the same asymmetry the keepout margin follows.
"Nearest segment" would make the result depend on which end a span starts from,
and still under-sizes whenever the near segment is the thin one; refusing would
make an ordinary tapered net (0.8mm trunk, 0.4mm branches) unroutable with
nothing for the human to fix. It is also the rule the bus path already applies to
the same question (`pcb/ui/panel_tools.gd::bus_net_width`).

**Copper whose width cannot be read fails closed** (`unsupported_geometry`,
naming the net) rather than being skipped: skipping would let the original defect
back in through the one net whose copper could not be measured. Vias are not read
— an annulus diameter is not a trace width.

**Keepout margin.** Established widths join class minima in the board-wide
worst case (`keepout_trace_width` is `max(run baseline, every per-net width)`),
because the grid's margin uses the NEWCOMER's half-width: a net adopting 0.8mm
against a grid reserved for 0.25mm would be an under-block introduced by this
fix itself. The cost is the one named below — a board carrying wide power copper
reserves more around everything, and a dense board may report unrouted pairs it
previously routed. That is the loud direction, and it is the direction the
invariant requires.

**Bus routing now honours net-class width too.** `agent_router.router.
route_bus` (hint-driven bus/parallel-corridor routing) first cut of this round
laid every net in a bus at the run's baseline copper width unconditionally,
ignoring `net_widths` entirely — a real defect (Codex must-fix), not a scoped
exception: `_attach_effective_routing_rules` stamps a bus-routed net-classed
net's reply with `{"source": "net_class", "value": <class width>}` regardless
of what actually got drawn, so the un-threaded case made the reply LIE about
copper that did not exist at that width — a lying provenance field, worse than
none, and via `ir_candidates.build_overlay` (which reads a segment's own
`width_mm` first) a **false clean** in the candidate overlay too: the proposal
would be checked at the class width while the routed copper was the baseline.
Fixed by threading `net_widths` into `route_bus`'s own per-net loop exactly
like the standard loop — each bus net now draws at its own class-or-baseline
width, the SAME `_net_width` lookup the two other loops use. Only the bus's
parallel-spacing **offset** (`bus_hint.spacing`) stays shared across the whole
bus; that is a layout choice, independent of any one net's width. Pinned by
`test_bus_routing_honours_net_class_width_not_just_the_bus_baseline`, driven
directly through `route_bus` (mirroring `TestBusRouting.test_route_bus_
creates_parallel_traces` in `tests/agent_router/test_router.py`), which probes
that a classed bus net's copper actually reaches its class width while an
unclassed bus-mate's does not. The board-wide keepout widening (above) always
applied to bus nets' pads and to every other net's copper regardless of this
bug — only a bus net's own drawn copper was ever wrong.

**Reply provenance.** Every route now carries `effective_routing_rules`:

```json
"routes": [{
  "net": "VCC",
  "segments": [{"start": [...], "end": [...], "layer": "F.Cu", "width_mm": 0.6}],
  "effective_routing_rules": {
    "trace_width_mm": {"value": 0.6, "source": "net_class"},
    "clearance_mm": {"value": 0.5, "source": "net_class"}
  }
}, {
  "net": "OTHER",
  "segments": [{"start": [...], "end": [...], "layer": "F.Cu", "width_mm": 0.35}],
  "effective_routing_rules": {
    "trace_width_mm": {"value": 0.35, "source": "board_rules"},
    "clearance_mm": {"value": 0.5, "source": "net_class"}
  }
}],
"effective_routing_rules": {
  "trace_width_mm": {"value": 0.35, "source": "board_rules"},
  "clearance_mm": {"value": 0.5, "source": "net_class"}
}
```

`source` is one of `caller_option` / `hint` / `net_class` / `board_rules` /
`engine_default` — never left for a consumer to infer from whether an override
happens to exist. This is the same honesty `drc_geometric`'s three-way verdict
enum already enforces (`ok` means "the check ran", never "the board passed";
here, a concrete `source` is always present, never omitted as "could not
determine which one"). Note the asymmetry that falls out of the margin being
board-wide: `OTHER`'s own `trace_width_mm` is unaffected (its copper is still
drawn at the board's baseline), but its `clearance_mm` reports the SAME
class-widened value as `VCC`'s — because that is the true, currently-enforced
margin around OTHER's copper too, not a per-net number a consumer could
mistake for something narrower. `pcb_worker.methods._attach_effective_
routing_rules` is the single place that stamps both the top-level baseline and
every route's own block, from the exact `net_widths` map and `keepout_
clearance` value also handed to the engine (`kw["net_widths"]`, `kw["keepout_
clearance"]`) — one value, two consumers (the grid and the reply), so they
cannot disagree.

**The candidate overlay follows, for width.** The same stamping writes each
segment's `width_mm`, and `ir_candidates.build_overlay` already reads a
segment's own `width_mm` **before** any caller-supplied default — that
precedence pre-dates this round (docket `019f952b99f2`) and needed no code
change here, only a producer that finally uses it: before this round, no
segment the worker serialized ever carried its own `width_mm`, so every
candidate fell through to the run's single `default_width_mm`. A net-classed
net is therefore now checked at the width it actually got, not the run's
baseline — the false-clean the whole overlay surface exists to prevent (see
"Where candidate dimensions come from" below). Clearance has no equivalent
per-candidate concept in the overlay: it is not a property a candidate carries,
it is a property of the PAIR, and geometric DRC derives it there
(`_effective_min_clearance`) from the overlay board's own net classes.

**`drc_geometric` now applies the same two minima.** Geometric DRC once carried a
fail-closed guard (docket `019f958b45b9`) that returned `indeterminate` for ANY
net-classed board, because it read only the global `ManufacturingConstraints`
floors and a stricter class would otherwise have false-cleaned. That guard is
gone, replaced by the real thing: `_net_class_minima` feeds GC1's
`_effective_min_trace_width` and GC2's `_effective_min_clearance`, so a
net-classed proposal now gets a REAL `drc_geometric.verdict` measured against the
class's own floors. The two surfaces read the same two fields off the same class
rather than one of them opting out.

**They still are not the same rule, and the difference is precedence.** Routing's
class step is step 3 of a chain: `methods._route` drops the class WIDTH override
when `caller_set_width or hint_set_width`, and the class CLEARANCE override when
`caller_set_clearance`, because an explicit caller option and a hint-authored
width outrank a class by design (see "Precedence" above). Geometric DRC has no
such chain — a class minimum is a RULE, and `_effective_min_trace_width` /
`_effective_min_clearance` apply it unconditionally. So "routing routes at the
class value and DRC checks that value" holds only when steps 1 and 2 said
nothing. When they did, routing honours the caller and DRC still holds the copper
to the class floor, and the two can legitimately disagree — see "An explicit
option can produce copper DRC will flag" under "Precedence".

Both surfaces **fail closed** on a class minimum that cannot be sourced, in both
dimensions and through the same predicate for each field: `positive_mm` for
`min_trace_width_mm`, `nonnegative_mm` for `min_clearance_mm`. `0.0` is admitted
for clearance and refused for width, on both sides — that single value is the
whole of the asymmetry, and it is about the predicates, not about whether the
dimension can fail closed at all.

**Endpoint identity vs geometry.** A pad becomes a routable **endpoint** only if it
carries an authored pad number — nets are spelled `U1.2`, hints reference `U1.2`,
the panel labels `U1.2`, so a pad without one cannot be addressed by anything.
That requirement belongs to routing alone, not to the shared IR iteration: KiCad
legitimately leaves NPTH mechanical pads unnumbered, and such a pad is ordinary,
exactly-modelable geometry (docket `019f97eb6adf`). So `ir_pads.iter_ir_pads`
stays permissive and reports missing identity honestly (`human_number is None`),
and each consumer decides:

| pad | routing | connectivity | geometric DRC |
|---|---|---|---|
| numbered copper | routable endpoint | electrical pad | copper |
| **unnumbered** copper, no net | conservative **obstacle** | excluded | copper |
| unnumbered copper **on a net** | **fails closed** | fails closed | copper |
| NPTH (numbered or not) | obstacle | excluded | hole primitive |

Unnumbered copper degrades to a keepout rather than failing the board: it still
has to block, but nothing could route *to* it. A **netted** unnumbered pad is a
contradiction — the netlist claims a connection to something unaddressable — so
that one fails closed rather than silently dropping the connection. NPTH is
excluded from the connectivity census deliberately: `drc._check_dangling` credits
an endpoint near *any* pad as copper-connected, so carrying a mechanical hole
there would report a route as connected to a drill. The same reasoning excludes
unaddressable copper; the short *it* could cause is a copper question, which
geometric DRC's GC2 models exactly over the same IR.

**Hole semantics.** An NPTH pad is an **obstacle, never a routable pad** (no land,
so it is not a connectable endpoint). A PTH pad keeps out its copper **land**, not
its drill. A plated board hole blocks its **annulus**; an unplated one its drill.
Oval and slot holes are blocked by the disc that **contains** them — the grid's
only obstacle primitive is a disc (`Obstacle.polygon` is declared but read
nowhere), so a containing disc is the honest conservative representation.

## Existing copper (docket `019f70ebc9ed`)

Until this landed, a board that carried **any** accepted trace or via was not
routable at all: `route_bridge._reject_unroutable_board` raised on
`rb.traces or rb.vias`. The reasoning was sound — the grid was handed pads and
holes only, so accepted copper was invisible and a fresh proposal could be laid
straight across it, which is approximated copper by another name. The
CONSEQUENCE was not: accepting one proposal ended the incremental workflow the
plugin exists to support.

The grid now sees it. `route_bridge.resolved_board_existing_copper` projects
`rb.traces`/`rb.vias` beside `resolved_board_to_router`, and
`pcb_worker.methods._route` passes both to `route_board` /
`route_board_with_hints` as `existing_traces` / `existing_vias`. It rides as a
run option rather than as a field on `agent_router.Board` for the same reason
the width/clearance pair does — that class is also what `Board.from_kicad`
builds. Dimensions are the copper's **own** authored `width_mm` / `diameter_mm`:
this copper already physically exists, so there is nothing to resolve and
nothing to invent. Only the keepout **margin** around it belongs to the run.

**Other-net copper is an obstacle; same-net copper is already-connected.** Those
are two different jobs, and conflating them is the failure this feature is prone
to in both directions — an obstacle reading would lock a net out of its own
copper; an ignore-it reading would re-propose a trace the board already carries.

| the copper is | what the grid does | what the router may do |
|---|---|---|
| another net's | marked as **that** net's copper + ring | blocked, exactly as by a pad |
| this net's | marked as **this** net's copper + ring | path **to** it and **along** it (`can_route_through` passes a net through its own cells) |
| this net's, joining two of its pads | as above, **plus** those pads are merged before the spanning tree | propose only what is still missing |

There is **no second inflation path**. Existing copper goes through
`RoutingGrid.mark_trace` and the new `mark_via`, which consult the same
`keepout_margin` every other marker does. An earlier round shipped a
hand-inflated parallel path and had to undo it: a margin spelled twice is a
margin that drifts, and the direction it drifts in is not bounded.

**Vias span layers, and that is the whole point of modeling them.**
`RoutingGrid.mark_via` marks the annulus as the via's net on **every** layer it
spans, plus the ring. It is deliberately not `mark_obstacle` — the grid's other
disc marker — because an obstacle belongs to no net and clears any net it lands
on, so an accepted via modeled that way would keep its own net out of its own
copper. `"via"` had been reserved in the cell taxonomy since Round E2 for
exactly this; `"via_clearance"` joins `_CLEARANCE_TYPES` beside it, because a
ring type missing from that set is one two rival rings can never downgrade to
`net=None`.

**Marking order is pads -> existing copper -> obstacles.** After pads, because
accepted copper sits on top of the census. Before obstacles, because losing a few
cells of accepted copper to a hole only over-blocks.

That ordering is a **preference, not the safety property**. A hole is an absolute
veto that belongs to no net, and `_mark_copper_cell` refuses to re-net a `"hole"`
cell outright — whoever asks, in whatever order. Order alone would not do: both
markers are public, and the engine's own routed traces are marked *after* the
obstacles, where `_cell_range`'s one-cell over-claim can reach a hole cell no
route ever entered. Re-netting one would license routing through a mounting hole,
because `can_route_through` lets a net cross its own cells.

**A copper mark never steals another owner's copper** (`RoutingGrid._mark_copper_cell`,
the single owner of that rule). Before this item every copper mark came from the
engine — a pad from the board census, or a trace the pathfinder had just been
*permitted* to lay — so an unconditional overwrite was unreachable. Importing the
board's own accepted copper marks geometry the grid never approved: an accepted
trace overlapping a foreign (or unconnected, `net=None`) pad, i.e. a board that is
already shorted, would hand that pad's land to the trace's net — and
`can_route_through` lets a net cross its own cells. Describing the board more
completely would have *licensed* routing through real copper. Re-marking a net's
own copper still writes through, as does the bounded copper-over-contested-ring
weakening recorded at `_cell_range`.

### Already-connected: the error directions are not symmetric

`router._preconnected_groups` decides which of a net's pads accepted copper
already joins; `_build_spanning_tree` then spans the **groups**, not the pads, so
a partly-routed net is finished rather than re-routed from scratch. A net whose
pads are wholly joined yields zero connections and no proposal at all.

Everything about how that is computed follows from one asymmetry:

* **over**-counting (claiming a connection the copper does not make) makes the
  router skip a connection the net needs, and the reply then reports a net as
  routed while it is open — a silent false clean, the worst outcome available;
* **under**-counting makes the router propose a connection that already exists —
  redundant same-net copper: wasteful, visible in the proposal, electrically
  harmless.

**The tolerance is capped in millimetres, not in cells.** `grid_resolution` is a
**caller option** (`methods._route` passes `options.grid_resolution` straight
through), so a tolerance of "one cell" is a tolerance the caller can inflate. At
the 0.1mm default the quantisation term is far below any real trace width and can
only under-count; at 0.5mm, two same-net stubs with a genuine 0.4mm air gap merge
into one group, the router skips a connection the net needs, and the reply calls
an **open** net routed. A caller's choice of grid must not be able to reverse the
safe direction, so `router._coincidence_tolerance` takes the **smaller** of the
quantisation term and the narrowest copper involved — a segment's half-width, a
via's radius. Copper of width `w` ending at a point covers a disc of radius `w/2`
about it, so two pieces that really touch are within `(w1 + w2) / 2`; the single
narrowest half-extent is strictly tighter than that. Both terms shrink the
tolerance and neither can grow it.

Subject to that cap, every rule demands **coincidence**, never proximity or
containment. A segment endpoint lands on a pad only within tolerance of the pad's
**centre** — not
"inside the pad's extent", because the extent the engine holds is the
axis-aligned *superset* of a possibly-rotated land, the right shape for a keepout
and the wrong one for connectivity. The centre is exact, and it is where copper
actually terminates: routes are pathfound pad-centre to pad-centre and acceptance
writes those coordinates back. Two segments join at shared endpoints only — a
**T-junction is missed on purpose**, because catching it needs a point-on-segment
tolerance that grows with trace width, and being wrong there over-counts. A via
joins whatever coincides with it on a layer it spans, which is what makes a
two-sided net continuous.

The contraction applies to the **automatic** spanning tree only. Bridge
assignments and chains are pad pairs the **user** authored, and this document's
standing rule for authored input is "admitted or rejected, never reinterpreted";
dropping one because the board looks already-connected would silently
reinterpret an explicit instruction.

### What still fails closed, and why that residue is right

Narrowing a fail-closed reason is correct; deleting it while a sub-case is still
unmodelable is not. Accepted copper that reaches a layer the 2-layer grid does
not carry — an inner-layer trace, or a blind/buried **via span** — is refused,
because half a via's copper modeled and half of it invisible is worse than not
routing the board. The v1 compiler cannot author either today (`_build_vias`
validates every span against `[top, bottom]`, and `ResolvedBoard.__post_init__`
checks `layer_stack.is_legal_via_span` a second time), so these are
defence-in-depth in the same sense `_pad_copper_layer`'s guard is — kept because
the failure they guard is *silent invisible copper*, and unreachable-today is not
the same as unreachable.

One case is skipped rather than refused: a caller passing `single_layer=True`
over a 2-layer board drops the B.Cu copper. That is safe **there and only
there** — with no B.Cu in the grid nothing routes on B.Cu, and no via can be
proposed (`allow_via = allow_vias and not single_layer`), so there is nothing
that could cross the copper being skipped.

## Path simplification stays inside the corridor (docket `019f9bd5f2f2`)

A* proves clearance **per cell it steps through**: every neighbour it expands is
asked `can_route_through` before it is entered — and, since round C2d
(`019f9d594f83`), a *diagonal* step is asked twice more, once for each of the two
cells orthogonally adjacent to the step, so the corner the chord would cut is
proved routable too, not just the destination cell. What it returns is
therefore a legal detour, one grid cell at a time (and, for diagonal steps, one
corner at a time). Simplification runs *after* that, to turn that cell-by-cell
polyline into a handful of segments — and it used to be purely geometric, which
meant nothing re-checked the copper it was about to emit.

The rule was "drop a point whose perpendicular distance from the run is under
0.1mm", with the distance measured against the **last kept point**. On a detour
the error accumulates monotonically along the curve: each successive point looks
nearly collinear with the one ever-growing chord, so a path that had correctly
hugged an obstacle was emitted as a single chord straight **across** it. The
search was never wrong; simplification made its answer illegal. Observed on
`tests/test_route_drc.py`'s crossing-wall fixture: 18 consecutive probe points
along the emitted segment were blocked by the routing grid, `find_path` returned
that segment anyway, and the proposal carried `gc2_copper_clearance` violations
of −0.20 to −0.64mm. It became common only once boards with accepted copper
became routable at all (`019f70ebc9ed`), because those are the boards that
produce detours.

**The invariant now enforced:** a point may be dropped only if the straight run
that replaces it is itself routable for that net. `_segment_clear` is the single
owner of that question, sampled at the same 0.1mm resolution `_try_direct_path`
and `_l_segments_clear` already used, so a chord an emitted route contains is
asked exactly what A* was asked about every cell. `_segment_clear` is now the
**only** chord check in the module — `_try_direct_path`, `_check_l_path` and
`_l_segments_clear` all route through it, so "single owner" is a fact rather
than a label. The one remaining `can_route_through` call outside it is A*'s own
per-cell test.

The **diagonal** branch (`_simplify_path`) is where the defect was. The
**orthogonal** branch (`_simplify_orthogonal`) also calls the check, but there it
is a **defensive guard on an invariant, not a bug fix, and no engine input
exercises it**: under `prefer_orthogonal` A* is cardinal, so interior points are
cell centres one axis apart and a same-direction merge is exact. The two ends
look dangerous — the exact start/end replace the first/last cell centre — and are
not: the start lies inside its own cell, so `|dx|` to that centre is at most
`resolution / 2`, while a vertical move to the next row's centre gives `|dy|` of
at least `resolution / 2`, so the `|dx| > |dy|` test cannot misclassify a row
change. Deleting that one check leaves the whole suite green, which is expected;
the honest test for a guard is that it fires when its premise is violated, and
that is what `test_the_orthogonal_guard_fires_when_the_cell_centre_invariant_is_
broken` does. `_collapse_staircases` already re-checked its L-bends this way.

**Why not just fix the geometry.** The smaller change was textbook
Douglas–Peucker — measure deviation against the *original* polyline instead of
the last kept point. It was measured, and on the crossing-wall fixture it does
come out clean. It is still not enough, because what it bounds is **deviation**
and what is needed is **clearance**, and here the two are the same number:
the tolerance is 0.1mm and `route_board`'s default `grid_resolution` is also
0.1mm, so a chord is licensed to wander a full cell off the path A* proved. The
counterexample is the commonest detour there is, a **one-cell jog** around a
single blocked cell: the jog point's deviation from the chord evaluates to
`0.09999999999999999`, *strictly less* than the 0.1 tolerance, so Douglas–Peucker
drops it and emits a chord through the blocked cell under either `>` or `>=`.
This is not a knife-edge comparison choice that could be tuned away — no
tolerance at or above one cell is safe, because the chord ends up a full cell off
the path A* proved.

**The trade, stated plainly.** Verifying incrementally means that when a chord is
blocked the simplifier anchors at the last *verified* point, even where some
longer chord past it would have been clear. So routes can carry more vertices
than before: the 3-pin net-classed fixture went from 4 segments to 6. (It later
moved again, to 5, once round C2d (`019f9d594f83`) stopped A* from offering
diagonal steps that cut a blocked cell's corner — fewer illegal-looking jogs
reach the simplifier in the first place, so it anchors less often. All three
counts are clean; only 6 and 5 are *proved* so end-to-end — and "proved" there
means proved at `_segment_clear`'s 0.1mm sampling, which is itself
corner-permissive, tracked as `019f9fb32de7`.) The pre-fix 4 was
probed and had zero blocked points, but it was not *proved* clean the way the
later counts are, and the failure direction here is extra vertices rather than
copper through a keepout. That is the same asymmetry the keepout margin is
built on: over-blocking is a cost, under-blocking is a defect.

The other half of the cost is time: simplification is **O(N²)** in the number of
A* points, because each drop re-probes the whole grown chord and the chord is a
different line every time, so nothing carries over. Measured on the worst case (a
straight run, every point droppable): N = 200 / 500 / 1000 / 2000 → 0.007 / 0.044
/ 0.182 / 0.737s — a clean 4× per doubling. It is a single forward pass with a
finite inner probe, so it cannot hang, but it is on the routing hot path and a
board producing tens of thousands of A* points would feel it. Left quadratic
deliberately: the incremental anchoring that costs the time is exactly what makes
each emitted segment individually verified.

Tested at the entry point, not on the helper:
`test_no_emitted_segment_crosses_a_cell_the_routing_grid_blocked` drives
`route()`, captures the grid the router actually built, and asserts no probe
point along any emitted segment is blocked;
`test_the_detour_that_exposed_the_bug_is_geometrically_clean` asserts the
independent geometric-DRC verdict on the same detour. The Douglas–Peucker
counterexample is regression-locked in
`tests/agent_router/test_pathfinder.py`, alongside a test that a genuinely
collinear run still collapses — so "stop simplifying" cannot pass as a fix.

## Layer-hop waypoints — one hint, one duck-under (work item `01a04106bd`)

A `pcb_route_hint`'s `kind_payload.waypoints` entry has two shapes:

| shape | meaning |
|---|---|
| `[x_mm, y_mm]` | a plain corner |
| `{"x": mm, "y": mm, "layer": "<copper>"}` | a corner **the run changes layer at** |

`layer` is a canonical copper id (`top` / `in1`..`in30` / `bottom`) or a KiCad
copper name; `PcbLayerStack` owns the translation and nothing here invents one.

**The rule.** Walking source pad → waypoints → destination pad,
`route_bridge._route_from_waypoint_stops` keeps the run on the hint's own
`kind_payload.layer` until a waypoint names a *different* copper layer. That
waypoint ends the current run, gets **one through via at exactly that point**,
and the run continues on the named layer. So one hint says "F.Cu, duck under
here, back up there, F.Cu", and the vias are a property of the corners rather
than four separate ghosts an agent has to match to segments by eye — the live
HITL that filed this.

**What is deliberately not a hop.** A waypoint with no `layer` key, or an empty
one, is an ordinary corner: absent means "stay on the layer you are on", never
"default to the top". A waypoint restating the layer the run is *already* on is
an ordinary corner too — punching a hole to change nothing would be a drill hit
nobody asked for.

**It takes the as-drawn path whatever `detail_level` says.** `detail_level` is
inferred from waypoint COUNT (`PcbAnnotationHost._derive_detail_level` calls 2-3
bends `guided`), and a two-hop duck-under is short. Naming where copper changes
side is by construction drawing your own path, so
`materialize_detailed_hints` accepts a layer-carrying hint regardless of the
inferred level.

**Fail-closed, same rule as authored segments.** A waypoint layer that is not
copper, or that the board does not declare, raises — the hint falls back to
engine-guided routing with a warning naming it. "in7" as a typo and "in7" as a
plane are indistinguishable, so an undeclared name is refused rather than
fabricated.

**Not honoured on the ENGINE path.** A hint steered by a task
`routing_constraint`, or one setting `allow_layer_change`, hands every layer
decision to the engine — the corridor there is a soft attraction field, not a
verbatim statement. `hints_to_router` therefore drops the hops and **says so**
in a warning naming the hint: a silent drop would look exactly like the via
evaporation this work exists to end.

**Via size comes from the board**, at proposal time — see "Where candidate
dimensions come from" below. The worker emits hop vias positionally (`[x, y]`),
the shape every consumer already speaks.

## Fail-closed reasons

| `error.kind` | Meaning |
|---|---|
| `parse` | the source will not load at all |
| `compile` | the board will not compile — carries the blocking `diagnostics` |
| `unsupported_geometry` | it compiles, but the routing grid cannot model it faithfully |
| `route` | the engine itself faulted |

`unsupported_geometry` covers: **inner copper layers** (the vendored engine is
2-layer F.Cu/B.Cu only), copper **zones**, copper **board/placed graphics**, a
non-rectangular **outline**, and accepted copper on a layer or **via span** the
2-layer grid does not carry.

That last one is what is LEFT of the old blanket "accepted traces/vias" entry,
which used to make a board unroutable the moment it carried any accepted copper
at all. See "Existing copper" below for what replaced it, and why the residue is
kept rather than deleted with the rest.

In every failing case **zero routes** are returned — no partial proposal, no
`routes: []` alongside a verdict a consumer could misread as "nothing needed".

### Per-pair refusal reasons on `unrouted` (docket `019f9d59a49b`)

Those `error.kind` values describe a call that failed as a whole. A call can
also SUCCEED while individual pad pairs refuse to route, and those land in
`unrouted: [{net, from, to, reason?}]`.

`reason` names why that specific pair refused — one of the five codes from
`agent_router.pathfinder.unroutable_reason`: `coincident_endpoints`,
`endpoint_out_of_bounds`, `start_blocked`, `end_blocked`, `no_path`. Without it,
a hard refusal and ordinary congestion were indistinguishable. That distinction
became more urgent, not less, when round C2b made A* refuse a blocked start: a
mounting hole placed over a pad is ORDINARY board data, and it now produces a
silent unroutable the user could fix in seconds if told.

`reason` follows the same **absent-key contract** as `hint_ids` and `drc`
elsewhere on this reply: a pair with no recorded reason **omits** the key
entirely. It is never `null` and never a placeholder — a null would claim "the
engine looked and found no reason", which is not what an unrecorded reason
means. Consumers must test key presence (`"reason" in entry`), not truthiness.

**Pairing is by INDEX, not by `(net, from, to)`.** The triple is not unique: a
user-authored `chain` pair is appended to a net's connections undeduplicated
against the automatic spanning tree (authored input is "admitted or rejected,
never reinterpreted"), so the same triple can appear twice in `unrouted` with
two independently-computed reasons. A join could not tell them apart.
`_serialize_routing_result` verifies the two engine lists are the same length
before trusting index *i*, and falls back to omitting `reason` on every entry
if they are not — a prefix of confidently-wrong reasons is worse than none.

## Not yet done (each has an owner; none of it is silent)

- ~~Effective width/clearance from the IR, and keepout inflation by clearance +
  half the trace width~~ — **done in E2**, both together, for **all three**
  markers (pads, holes, routed traces). They had to ship together: plumbing the
  real width alone would have the router path a 0.35mm trace against keepouts
  sized for 0.25mm, so the proposed copper would be wider than the clearance
  reserved for it — worse than either endpoint. See "Effective width and
  clearance" and "Inflation composes with that superset" above. The engine's own
  defaults (`trace_width=0.25`, `clearance=0.2`) are no longer what a board gets
  routed at.
- ~~Grid origin correctness~~ — **done in E2a**. `RoutingGrid` now carries the
  board `origin` and is the single owner of the world↔cell transform in both
  directions (`_pos_to_cell` / `_cell_to_pos` / `_cell_range`); callers still
  speak world coordinates at every boundary. It also floors rather than
  truncates, so a position just before the origin can no longer fold onto cell
  `-0` and read as in-bounds. The legal routing area is now the **outline**:
  `_effective_grid_size`, which grew the grid to cover any pad outside the board
  (+2mm), is gone — a pad outside the outline makes its net **unrouted** instead
  of routable off-board.
- ~~Per-net-class width/clearance minima~~ — **done**, on BOTH sides. Routing
  honours them (see "Per-net-class minima" above), and geometric DRC now enforces
  them too: `drc_geometric._net_class_minima` feeds GC1's
  `_effective_min_trace_width` and GC2's per-pair `_effective_min_clearance`, and
  the interim guard that made any net-classed board `indeterminate`
  (`019f958b45b9`) is deleted. Boards now AUTHOR their classes under
  `design_rules.net_classes` (`compile_board._build_net_classes` compiles them
  and inverts each class's `members` list; `compile_board._finalize_nets`
  assigns the resulting `ResolvedNet.net_class_id`), so
  both halves are reachable from a real board YAML — the hand-built and
  monkeypatched `ResolvedBoard`s remain only for class states the authoring layer
  refuses. Bus-hint
  routing (`route_bus`) honours net-class width too — see "Bus routing now
  honours net-class width too" above.
- ~~Existing accepted traces/vias in the grid~~ — **done, docket `019f70ebc9ed`**
  (see "Existing copper" above). Other-net copper is an obstacle through the one
  `keepout_margin`; same-net copper is already-connected, both as space the net
  may path through and as pads the spanning tree no longer has to join. A via's
  annulus is marked on every layer it spans. What remains refused is accepted
  copper on a layer or via span the 2-layer grid does not carry — narrowed, not
  deleted.
- ~~Whole-board re-routing on a scoped request~~ — **done, docket
  `019f80a80123`**, and its panel half is **done too, docket `019f9c3a136c`**
  (see "Run scope" above). `panel_tools` reads the worker's per-route
  `hint_ids` verbatim; `_source_hint_ids_for_net` and its blanket
  all-selected-hints fallback are deleted. **Both of the remainders it named
  are now done too**, in the routing batch: the workspace's independent
  net-names copy is off the production path (docket `019fa109766f`, Shape A —
  see "Still re-derived elsewhere" above), and the partial-failure bulk-apply
  path no longer consumes hints attributed to routes that FAILED to
  materialize (docket `019fa109b43c`).

  `_materialize_routes` now collects a route's hint ids *at the point of
  success*, inside the `made_any` branch, rather than re-deriving them
  afterwards by re-looping over `result.routes` — that re-loop could not tell a
  succeeded route from a failed one without redoing the `failed` computation,
  which was the bug. Hint deletion is how this surface says "answered", so
  consuming one for a route that laid no copper asserted an answer that did not
  exist.

  The same round closed an unfiled sibling in that function: the via-commit
  loop ran *outside* the `made_any` guard, so a failed route still landed its
  vias — and since the history snapshot is gated on `traces_added > 0`, when no
  route produced traces those vias landed with no checkpoint at all,
  unreachable by redo. A failed route now contributes no vias: no copper, no
  board mutation of any kind.
- ~~Native pad-list path~~ (`_board_from_native`) — **deleted, Round E3**. It
  still accepted a missing size as `0x0`, the same class of fictional copper
  E1 removed from the canonical path — but rather than fix it, the shape
  itself is gone: `route()` now accepts exactly one board census (canonical
  YAML/dict), and the retired shape returns a structured `parse` error naming
  the replacement. Zero in-repo callers ever constructed a pads list.

## One compile feeds both halves of the reply

`route()` compiles **once**. The router consumes the ResolvedBoard; DRC-at-propose
consumes `ir_connectivity.connectivity_board(rb)` — a normalized projection of the
*same* compiled board into the dict language the legacy connectivity kernel
already speaks (pad centres AND their lands, net ownership, existing
traces/vias — the lands because the kernel's pad-contact rule measures real
copper; see docs/drc.md). There is **no**
raw-dict and **no** best-effort-resolve fallback on the canonical path.

Since `019f70ebc9ed` the router's half is **two** projections, not one — the
`Board` (pads, nets, holes, outline) and the board's existing copper beside it —
because `agent_router.Board` has no slot for accepted copper. Both, plus the
connectivity projection, sit under **one** `UnsupportedGeometry` boundary, so
whichever meets geometry it cannot model produces the same structured
`unsupported_geometry` zero-route reply. (The connectivity projection briefly ran
ahead of that guard, where its failure would have escaped the route error
envelope — `019f97eb6adf`.)

This matters because E1's first cut moved only the routing half. Routes came from
IR pads while the attached DRC still read the raw dict's inline `pins`, so a
**footprint-only** board — components with a `footprint` and no inline pins, which
is both valid and what the panel produces — routed successfully *and* reported
every endpoint `dangling_endpoint`. Same board, same geometry, two pad censuses
(docket `019f97d021a8`).

The projection emits components at the origin with zero rotation and pins carrying
**absolute** positions, because the IR has already placed them; the kernel's own
`component position + rotate(pin offset)` composition is then the identity, so the
IR's placement (including bottom-side mirroring) reaches it unchanged instead of
having a rotation applied twice.

**It is still connectivity-only.** The projection deliberately carries no pad
extents — sharing a pad *census* is not sharing *geometry*. The attached result
stays `scope:"connectivity"` (see `docs/drc.md`) and is **not** a geometric gate.
The geometric gate is the candidate overlay below, attached beside it.

## Geometric DRC-at-propose (the candidate overlay)

Docket `019f952b99f2`, closing bug `019f80b5124d` — a proposal that ran through
the centre of a different-net pad and was reported **clean**, because the only
check attached to it was the centerline one.

The **same** compile feeds a third consumer: `ir_candidates.check_candidates`
layers each proposed route onto `compiled.board` as IR traces/vias and runs the
unchanged geometric kernel over base + candidates. `route()` therefore returns
**two** verdicts per proposal, answering two different questions:

| key | scope | shape |
|---|---|---|
| `routes[].drc` | `connectivity` | `{clean: bool\|null, violations}` (unchanged) |
| `routes[].drc_geometric` | `geometric_candidate` | `{verdict: "clean"\|"violations"\|"indeterminate", violations}` |
| `drc_geometric_summary` | `geometric_candidate` | the full candidate union (`docs/drc.md`) |

The geometric payload deliberately does **not** carry a `clean` field. The
connectivity one does, and a consumer must never be able to read "the geometric
check could not run" as "the geometric check passed". A geometric fault never
fails the route call — the proposal still returns, with an honest
`verdict:"indeterminate"`. The native pad-list path is retired (see "Not yet
done" above): `route()` no longer accepts it at all, so there is no longer a
routed shape that carries neither key.

### Where candidate dimensions come from — nothing is invented

A route reply carries geometry but not sizes, and the fail-closed ruling forbids
approximated copper, so both values are sourced explicitly:

- **Trace width** — the width the run *actually routed at*. **And when there is
  none, the copper-creating path REFUSES** (bug `01a02c480d50`): both
  `panel_tools._materialize_routes` (apply-and-commit) and
  `RoutingWorkspace._create_candidate_for_route` (propose → commit) used to fall
  back to a literal `0.25`. That fires only on a reply carrying no width stamp —
  an older worker, or a path that skipped the attach — but it is an invented
  number on the one path that ends in fabricated copper, and it is silent: the
  board would gain 0.25mm traces with nothing in any report saying so.

  Now the **copper-creating** paths refuse and name what they could not
  resolve: `_materialize_routes` skips the route into `failed[]` (no traces, no
  vias, the source hint not consumed), and `RoutingWorkspace.commit` refuses
  `unmodelable_segment` — "zero-width copper is not copper" — which it already
  did for a zero width; removing the invention is what lets a zero reach it.
  The **candidate** still lands: a ghost is a question, not a board edit. It
  carries width `0.0` and `width_source: "unresolved"`, and the propose replies
  name it in `unresolved_widths[]`. Since E2 that is
  literally the value `_effective_routing_rules` resolved and handed to the
  engine (`kw["trace_width"]`, precedence table above), passed on to the overlay:
  one variable, not two derivations that agree by coincidence. A proposal cleared
  at a width it was not routed at is a **false clean**, which is the failure this
  surface exists to remove. Per-net-class minima (this round) extend this rather
  than compete with it: `_attach_effective_routing_rules` stamps each segment's
  own `width_mm` with THAT net's actual width (its class override, or the run's
  baseline), so `build_overlay`'s existing per-segment `width_mm` precedence
  picks the right one automatically — see "Per-net-class minima" above.
- **Via diameter / drill** — the board's own authored routing defaults
  (`design_rules.via_diameter_mm` / `via_drill_mm`), which is what acceptance
  writes. The engine's vias are positional only.

  **Resolved at PROPOSAL time, through one rule** (bug `01a03b87473c`). The
  panel's `pcb/ui/model/pcb_via_dimensions.gd` is now the single place that
  answers "how big is this via": an explicit per-call size outranks
  `design_rules`, which outranks the 0.8/0.4 constants. Every via the plugin
  creates goes through it — router candidates, `minerva_pcb_propose_via`
  ghosts, candidate `add_via` inserts, and the copper `workspace_commit` writes.

  It used to be four rules, and one of them stamped a literal:
  `PcbRouteCandidate.make_via`'s `0.8`/`0.4` *parameter defaults* were what
  `_create_candidate_for_route` handed every ingested via, so a candidate via
  was BORN at 0.8/0.4. The rescue meant to catch that (`_via_dimensions`) only
  substitutes when the stamped value is **zero**, and 0.8 is never zero — so a
  ghost rendered and committed at 0.8 on a board whose rules said 0.6, while
  the direct-commit path honoured 0.6. Two paths, one hole, two answers.
  `0.0` is now the only value that means "nobody has said yet".

If a value cannot be sourced, the overlay fails closed (`unsupported_geometry`)
rather than guess one. Same `error.kind` vocabulary as the table above, plus
`unresolved_geometry` and `internal` from the geometric union.
