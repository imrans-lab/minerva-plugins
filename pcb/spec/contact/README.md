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
  // The copper the run is measured AGAINST: exactly ONE of `pad` or `region`.
  "pad":   { "at": [x_mm, y_mm],          // land CENTRE, board frame
             "shape": "rect|roundrect|circle|oval",
             "size": [w_mm, h_mm],        // the land's full extent
             "rotation_deg": 0.0,         // land angle, KiCad clockwise
             "corner_rratio": 0.25,       // roundrect only; omit otherwise
             "drill_mm": 3.2,             // drilled types only
             "type": "smd|thru_hole|np_thru_hole",
             "layers": ["top"] },
  "region":{ "ring": [[x_mm, y_mm], ...], // ONE filled pour region
             "layer": "bottom" },
  "copper":{ "kind": "segment|endpoint",
             "a": [x_mm, y_mm],
             "b": [x_mm, y_mm],           // segment only
             "width_mm": 0.25,
             "layer": "top" },
  "touches": true
}
```

`region` is a pour's COMPILED FILL ring, never its authored outline, and it may
be concave or a self-touching keyhole — that is what a fill looks like once
clearance carving and voids are in it (see `140-endpoint-in-a-pour-void`).

`endpoint` is the round cap at ONE end of a run — what "is this end landed?"
asks. `segment` is the whole swept stadium — what "does this run reach the pad?"
asks. They are separate kinds because an end must not be credited by copper at
the other end of its own segment.

Every `why` is derived by hand from the geometry and states its numbers. A case
whose expectation cannot be arrived at with a ruler does not belong here.

## Deliberately out of scope

* **The pin centre.** A single-land pad node on the panel side also carries the
  pin's own centre point (zero swell), for the case where a footprint's
  `pins[]` and `pads[].position` disagree. The worker has one position per pad
  and no second field to disagree with. These vectors compare LAND geometry, so
  they set the land centre and the pin centre to the same point.
* **Vias and trace-to-trace.** The predicate takes them as node kinds, but
  nothing has drifted there yet. Extend the schema with a new `copper.kind`
  when one of them starts mattering.
* **THE NET.** The predicate is net-BLIND: two pieces of copper either meet or
  they do not, and which potentials may be joined is the CALLER's rule. So
  "a run must not end in a foreign-net pour" cannot be pinned here — it is
  pinned where the net is decided, on each side separately: the worker's
  same-net pour credit in `worker/tests/test_zone_copper_drc.py`, and the Trace
  tool's terminator in `tests/gd/test_trace_pour_terminator.gd`.
