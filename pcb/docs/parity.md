# Cross-surface geometry parity (standing gate 3)

Stage-4 acceptance is: *for the smart-remote fixture, each surface reports/uses
identical pad centres/shapes, trace/via/hole geometry, outline, layer identity,
and net ownership.* `pcb_worker/ir_parity.py` is that check, and
`tests/test_ir_parity.py` is the gate that runs it on every push and PR.

It exists **now**, mid-migration, rather than at the end, because a check that
only runs at the end discovers drift many rounds after the round that caused it.
This one fails inside the round that breaks it.

## The four surfaces and their seams

Each surface is read at the seam closest to what it **actually emits or uses**.
Reading all four through one shared helper would make them agree by construction.

| Surface | Seam | Why this seam |
|---|---|---|
| `ir` (reference) | `compile_board()` → `ResolvedBoard`, read field-by-field | The only seam that does **not** go through `pad_source`, so a change of mind in the shared land owner is visible |
| `drc` | `drc_geometric.project_board()` → `Projection` | The copper the geometric DRC literally collision-checks |
| `kicad` | the emitted **`.kicad_pcb` text**, parsed back | The hazard is `_to_footprint_local` + KiCad's load transform; a dict-level seam sits upstream of both |
| `gerber` | the emitted **Gerber + Excellon bytes**, parsed with gerbonara | The flash/aperture/coordinate-format pipeline is where a fab file loses a rotation |

### What this gate cannot catch

`drc`, `kicad` and `gerber` all resolve a through-hole pad's copper **land**
through the same neutral owner, `pad_source.th_land` + `placed_pad_to_geom`.
Those three therefore agree by construction on whether a land is a round annulus
or a shaped rectangle, and no parity run can report a disagreement about that
decision. What the gate does prove is everything around it: coordinate
transforms, per-pad rotation survival, copper-layer assignment, net ownership,
PTH/NPTH drill routing, outline framing, and whether any of it reaches the
emitted bytes. The `ir` reference is the independent seam; a change inside the
shared owner shows up as `ir`-vs-everyone.

## The row format

Every surface produces a `SurfaceTable` of `ParityRow` = `(family, key, fields)`.

- **`family`** — the comparison bucket: `copper_flash`, `copper_trace`, `drill`,
  `outline`, `cutout`, `mask_opening`, `copper_layer`, `net_ownership`.
- **`key`** — identity within the family. **Geometric** (quantized position +
  canonical layer token), never an IR id: a parsed Gerber flash is anonymous, so
  an id-based key would be unproducible by one of the four surfaces.
- **`fields`** — named values, compared pairwise against the reference.

Two distinct "cannot say" mechanisms, and the difference matters:

- **`NA`** for a *field* a surface cannot express (a Gerber flash has no net).
  `NA` on either side is never a disagreement. It is **not** `None` — `None` is a
  real value meaning "this pad has no net", and conflating them would let a
  genuinely dropped net hide.
- **non-participation** for a whole *family* (`SurfaceTable.families`). Gerber
  carries no nets at all, so it opts out of `net_ownership` rather than emitting
  zero rows — otherwise "Gerber carries no nets" reads as "Gerber lost 76 nets".

Copper rows are **per layer**: a through-hole pad or a via emits one row per
copper layer it occupies, because that is what the fab file physically contains
and it makes "the land vanished from B.Cu" a nameable failure.

### `mask_opening` — the family that had to be argued for twice

Solder-mask apertures are compared by **`ir`, `drc` and `gerber`**; `kicad` opts
out, because it writes a per-pad `solder_mask_margin` and never an aperture, so
there is nothing to read back.

Stations S4/S5 declined this family as a tautology — `Projection.mask` and the
Gerber emitter's buckets both come from `mask_source`, so tabulating those two
asserts one function call agrees with itself. Two independent cold reviews
overturned it (epoch CP2 S11), and the reason generalizes:

- `gerber` is independent because that surface is defined as the **emitted
  bytes**. Between `mask_source`'s answer and the `F_Mask`/`B_Mask` bytes sit
  side-to-bucket routing, the Y-frame negation, aperture construction and
  serialization — none of it reachable by comparing two in-memory harvests.
- `ir` is independent because this module **forbids** the reference from
  borrowing the shared owner. `_ir_mask_openings` re-derives the enumeration
  *and* the enlargement rule from `ResolvedBoard` fields, the same discipline
  `_ir_pad_land` already follows for copper.

So the family is two independent derivations against one shared owner, not three
readings of one call. Three things it carries that copper rows do not:

| Field | Why |
|---|---|
| `corner_radius_mm` | **absolute mm**, never a ratio — Gerber has no concept of one. Same extents with different rounding is a real fabrication difference that `w_mm`/`h_mm` cannot express. |
| `polarity` | a clear flash has identical extents and the opposite meaning. Geometry alone cannot catch an inverted one. |
| occurrence ordinal *(in the key)* | `by_family` is a `{key: row}` dict, so without it two coincident identical apertures collapse to one row and **losing one is a clean diff**. |

Two shape folds keep representation differences from reading as defects, and
both are narrow enough that a wrong value still fails: a quarter-turned land
folds to its axis-aligned representative (shared with copper), and a roundrect
folds to `rect` at radius 0 or to `oval` at fully-rounded — the two radii where
the emitter itself changes aperture family.

### Two tolerances, because there are two questions

| Constant | Question it answers | Value |
|---|---|---|
| `PARITY_KEY_QUANTUM_MM` | *are these two rows the same entity?* | `1e-2` (10 µm) |
| `PARITY_TOLERANCE_MM` | *do these two values agree?* | `1e-4` (0.1 µm) |

The key quantum wants to be as **coarse** as it can be without merging two
genuinely distinct features, so rows correlate and a disagreement is reportable
as a legible field diff. The comparison epsilon wants to be as **tight** as fab
relevance allows. Making them one number was a design error: any disagreement
larger than the epsilon also broke the join, so rows never correlated and every
real difference was reported in the least legible form available — a missing row
plus an unrelated extra row. 10 µm is safe as an identity bucket; the tightest
feature spacing in these fixtures is a 0.4 mm via drill.

Each row therefore carries its centre **twice**: bucketed in the key (identity)
and raw in `x_mm`/`y_mm` (a compared value). Without the raw copy, position is
never actually checked as a value anywhere. Angles use their own `1e-3` degree
threshold, since 0.1 µm means nothing for a rotation. Field values are stored
raw — no scattered `round()` calls; only keys are quantized.

Rotation is folded by the land's own **symmetry** before comparison: a 2×2 square
at 180° is the same copper as at 0°, and the emitters legitimately disagree about
which number to carry. An oblong land's 90° error still survives the fold, which
is the case that actually changes copper.

## The known-delta baseline

Where a surface is not yet migrated — or is knowingly conservative — the delta is
**enumerated**, not deleted. Each `KnownDelta` carries a reason, a docket id (or
the literal `"unattributed"`; ids are never invented), and **the exact row keys
it explains**.

Matching on identity rather than arity is what stops the baseline being a
suppression list:

- a **new** delta of a listed class carries an **unlisted key** → unexplained →
  **fail**;
- a **fixed** delta leaves a listed key unmatched → the entry is stale →
  **fail**, forcing the list to shrink with the code instead of rotting into a
  record of things that used to be true.

An earlier revision matched on the signature plus a **count**, and that silently
swallowed regressions: displacing one baselined drill hit by 80 mm kept the count
at 3, so the gate passed clean. A baseline that suppresses more than it names is
worse than no baseline. `test_a_displaced_baselined_row_is_not_swallowed` pins
this.

**The exit condition for the migration is both baselines reaching length 0.**

Current entries: **1**, for `parity_corners` — DRC's oval→bounding-rect fail-safe
superset, accepted, and the one entry that should *not* go to zero by "fixing
DRC" (only by DRC gaining a true obround primitive). The Gerber rotated-oval
defect this fixture found on its first run is **fixed**, and its entry was
deleted rather than relaxed; the baseline shrinking is the proof. `smart_remote`
was withdrawn from the corpus (docket `019fbe68c5f8`, see `testdata/POLICY.md`)
and `parity_corners` is now the primary case.

## Fixtures

- `tests/testdata/smart_remote.yaml` — the Stage-4 acceptance fixture.
- `tests/testdata/parity_corners.yaml` — geometry smart-remote does not reach:
  bottom-side components, **oblong** (non-square) through-hole lands at a
  rotation, and a plated board hole. Every shaped land in smart-remote is a
  square, whose rotation folds away under its own symmetry — so smart-remote
  alone cannot tell a correct rotation from a dropped one. The Gerber rotation
  defect above was found by this fixture on its first run.

  Extended for the mask family (epoch CP2 S11) with a **bottom-side SMD land**
  (the only entity whose mask opening is single-sided, so the only one that can
  catch a side-routing error), an **untented via** beside the tented one (the
  only entity where "has copper here" and "opens mask here" differ), and an
  **unplated through-hole pad** (drill-sized opening, no margin). Each was added
  because its absence was *measured* to leave a real mask defect undetected —
  the corresponding mutation left the whole suite green. `GEOMETRY_CLASS_FLOOR`
  in `test_ir_parity.py` pins all three so they cannot quietly disappear again.

  A **half-tented** via is not authorable from board YAML (a single symmetric
  `tented` boolean), so the per-side rule is exercised by constructing one on the
  compiled IR in `test_a_HALF_tented_via_opens_mask_on_exactly_one_side`.

Still uncovered: non-rect **SMD** shapes (circle/oval/roundrect). A pad shape is
owned by the locked footprint and is not authorable from board YAML
(`compile_board._INLINE_FAB_KEYS` carries sizes, drills, annuli and plating but
no shape token), so closing that gap needs a purpose-built test footprint.

## Porting this to another language

The GDScript panel is a fifth surface and a separate follow-up. To add it, mirror
in order: the family list, the key construction (`_q` quantization + canonical
layer token), the `NA` sentinel as a value distinct from null, the
family-participation set, and the symmetry-folded rotation. Then add
`tabulate_panel` and diff it against `ir` like the rest — nothing else changes.
