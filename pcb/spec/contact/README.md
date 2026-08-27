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
  "pad":   { "at": [x_mm, y_mm],          // land CENTRE, board frame
             "shape": "rect|roundrect|circle|oval",
             "size": [w_mm, h_mm],        // the land's full extent
             "rotation_deg": 0.0,         // land angle, KiCad clockwise
             "corner_rratio": 0.25,       // roundrect only; omit otherwise
             "type": "smd|thru_hole",
             "layers": ["top"] },
  "copper":{ "kind": "segment|endpoint",
             "a": [x_mm, y_mm],
             "b": [x_mm, y_mm],           // segment only
             "width_mm": 0.25,
             "layer": "top" },
  "touches": true
}
```

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
* **Vias, zone fill regions, trace-to-trace.** The predicate takes them as node
  kinds, but a pad is where the two sides had drifted, so a pad is what is
  pinned here. Extend the schema with a new `copper.kind` when a second kind
  starts mattering.
