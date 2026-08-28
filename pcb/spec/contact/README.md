# Pad-contact vectors

One question — **does this copper join that pad?** — answered by two
implementations, on two sides of the panel/worker boundary:

* `pcb/worker/pcb_worker/copper_contact.py` (connectivity DRC, the census)
* `pcb/ui/model/pcb_copper_contact.gd` (the trace verbs, the pin inspector,
  the ratsnest)

Neither side can call the other while the answer is needed — the panel answers
during a drag with no backend round trip, and the worker answers inside an
O(pads x segments) sweep. So the algorithm exists twice and **these vectors are
what stop the two copies from drifting**. Every case here is run by both:

* `pcb/worker/tests/test_copper_contact_vectors.py` (pytest)
* `pcb/tests/gd/test_copper_contact_vectors.gd` (GD suite)

Both runners **enumerate this directory**. Adding a case directory therefore
adds it to both suites at once, and a case the two sides answer differently
cannot be added without one of them going red.

## One case

`<NNN>-<slug>/case.json`:

```jsonc
{
  "name":  "...",
  "why":   "the hand derivation — the numbers, not the intent",
  // The copper the probe is measured AGAINST: exactly ONE of `pad`, `region`
  // or `trace`.
  "pad":   { "component":                 // OPTIONAL placement; see below
               { "at": [x_mm, y_mm],      // component anchor, board frame
                 "rotation_deg": 90.0,
                 "layer": "top|bottom" },
             "at": [x_mm, y_mm],          // land CENTRE, board frame
             "shape": "rect|roundrect|circle|oval|<unmodelled>",
             "size": [w_mm, h_mm],        // the land's full extent
             "rotation_deg": 0.0,         // land angle, KiCad clockwise
             "corner_rratio": 0.25,       // roundrect only; omit otherwise
             "drill_mm": 3.2,             // drilled types only
             "type": "smd|thru_hole|np_thru_hole",
             "layers": ["top"] },
  "region":{ "ring": [[x_mm, y_mm], ...], // ONE filled pour region
             "layer": "bottom" },
  "trace": { "a": [x_mm, y_mm],           // ONE run, as its swept width
             "b": [x_mm, y_mm],
             "width_mm": 0.5,
             "layer": "top" },
  "copper":{ "kind": "segment|endpoint|via",
             "a": [x_mm, y_mm],           // via: the barrel centre
             "b": [x_mm, y_mm],           // segment only
             "width_mm": 0.25,            // segment / endpoint only
             "diameter_mm": 0.8,          // via only: OUTER copper diameter
             "layers": ["top", "bottom"], // via only: the barrel's span
             "layer": "top" },
  "touches": true
}
```

A land both sides model exactly (`rect`, `circle`, `oval`, a `roundrect`
carrying `corner_rratio`) is compared as that exact copper. Anything else — a
ratio-less `roundrect`, or a token neither side knows — is compared as the
STADIUM inscribed in the stated size, which every land of that size contains,
so an unmodelled shape can never manufacture copper. Cases 160-180 pin that,
and a token like `trapezoid` is admitted here on purpose to state it.

## A PLACED land

Without `pad.component` a land states its own board-frame centre, angle and
layers, and both runners hand them to the predicate untouched. That cannot ask
the one question a back-mounted part raises, because **no footprint authors the
side it will end up on**: a package states `F.Cu` and the PLACEMENT decides
whether that copper is front or back.

So `pad.component` gives the land a component to be placed by. When it is
present, `at`, `rotation_deg` and `layers` are **footprint-local** and each side
puts them on the board with its own production rule — the worker through
`geometry.component_transform` + `drc.placed_pad_layers`, the panel through
`pcb_component.get_transform` + `pcb_component.placed_pad_layers`. A back-side
placement does three things, and cases 220/230/240 take one each:

* negates local Y **before** the rotation (the pcbnew footprint flip),
* swaps every explicit front/back layer token,
* reverses the sense of the land's own `rotation_deg`.

`region` is a pour's COMPILED FILL ring, never its authored outline, and it may
be concave or a self-touching keyhole — that is what a fill looks like once
clearance carving and voids are in it (see `140-endpoint-in-a-pour-void`).

`endpoint` is the round cap at ONE end of a run — what "is this end landed?"
asks. `segment` is the whole swept stadium — what "does this run reach the pad?"
asks. They are separate kinds because an end must not be credited by copper at
the other end of its own segment.

`via` is a barrel: a disc of the stated OUTER diameter, on the layers the span
names. Pair it with a `trace` target for the question cases 200/210 ask — *does
a via sitting under a run join that run?* — which has one answer wherever along
the run it sits, endpoint or interior. Note the two builders take different
units: `copper_contact.via_node` is handed a DIAMETER and
`PcbCopperContact.via_node` a RADIUS, so each runner converts and the vector
states the diameter.

Every `why` is derived by hand from the geometry and states its numbers. A case
whose expectation cannot be arrived at with a ruler does not belong here.

## The unknown-land disc

A pin whose footprint never resolved states no land at all, so neither side has
geometry to be exact about. Both give it a **disc of the board's own
`design_rules.clearance_mm`**, falling back to **0.2 mm** when the board
declares none:

* worker — `drc._board_clearance` feeds `copper_contact.pad_node`'s
  `unknown_land_radius_mm` (`drc.DEFAULT_COINCIDENT_MM`)
* panel — `pcb_copper_contact.unknown_land_radius`
  (`DEFAULT_UNKNOWN_LAND_RADIUS_MM`)

A via that declares no diameter gets the SAME disc, from the same two places:

* worker — `drc._via_radius`, fed by `drc._board_clearance`
* panel — `pcb_data.via_radius`, delegating to
  `pcb_copper_contact.unknown_land_radius`

**No vector can pin either**, because every vector states a size and the
fallback is therefore never the answer inside one — both runners hand
`copper.diameter_mm` straight to `via_node`, so an unsized via inside a case is
a zero-radius disc on both sides. They are pinned instead by the fallback tests
each runner carries beside the vector walk
(`test_a_pad_with_no_stated_size_falls_back_to_the_coincidence_disc` /
`_run_unknown_land`, and `test_an_unsized_via_falls_back_to_the_coincidence_disc`
/ `_run_unknown_via`). The land pair probes 0.15 mm off centre (landed) and
0.25 mm (clear by 0.05 mm); the via pair probes 0.15 mm (landed) and 0.30 mm
(clear by 0.10 mm) — 0.30 mm being the distance a fixed 0.8 mm via assumption on
the panel called landed while the worker called it dangling.

## Deliberately out of scope

* **The pin centre.** A single-land pad node on the panel side also carries the
  pin's own centre point (zero swell), for the case where a footprint's
  `pins[]` and `pads[].position` disagree. The worker has one position per pad
  and no second field to disagree with. These vectors compare LAND geometry, so
  they set the land centre and the pin centre to the same point.
* **Trace-to-trace.** The predicate takes it as a node kind, but nothing has
  drifted there yet. Extend the schema with a new `copper.kind` when it starts
  mattering. (Vias were on this list until a via under a run's interior turned
  out to be credited on one side and not the other — cases 200/210.)
* **THE NET.** The predicate is net-BLIND: two pieces of copper either meet or
  they do not, and which potentials may be joined is the CALLER's rule. So
  "a run must not end in a foreign-net pour" cannot be pinned here — it is
  pinned where the net is decided, on each side separately: the worker's
  same-net pour credit in `worker/tests/test_zone_copper_drc.py`, and the Trace
  tool's terminator in `tests/gd/test_trace_pour_terminator.gd`.
