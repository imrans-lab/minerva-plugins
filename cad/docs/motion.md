# Declared translation paths

`minerva_cad_check_motion` checks insertion, removal, or tool access by moving
one solid instance/group/binding against explicit solid obstacle selectors.
A tool envelope can be an ordinary authored solid. Nothing plans a path or
simulates mechanics; the caller declares the offsets from evaluated placement:

```json
{"editor_name":"fixture.mcad","selection":"instance:tool","configuration":"assembled",
 "against":["instance:case"],"path_mm":[[0,0,0],[0,20,0],[30,20,0]],
 "required_mm":0.5,"max_samples":64}
```

Offsets are world millimetres, joined by straight segments. No source is
rewritten and the visible configuration is unchanged. The same arguments can
be stored in a validation specification as `kind: "motion"`; selection and
configuration belong on the check entry, the remaining parameters in `args`.
The report retains the path, scope, numerical allowance, coverage and witness
points. An empty path or no movement is refused: static fit is another question.

Distances and overlap come from cached OCCT solid B-Reps, including containment.
Translation distance is 1-Lipschitz: each certified interval has a clearance
lower bound of its minimum endpoint distance minus half the interval's travel
minus `numeric_tolerance_mm` (default 0.000001 mm). Uncertified intervals are
subdivided. A pass requires all intervals to meet `required_mm`; a collision or
clearance violation fails. Exhausting the sample/body-pair budget leaves an
**unknown** verdict. A failure stops at its first witness and reports remaining
intervals. Results disclose sample count and distance-query count.

Only the declared configuration and obstacles are covered. Imported mesh
bodies, groups containing mesh bodies, and rotations are unsupported and
refused; presentation-only configurations cannot pass physical checks. Limits
are 64 path vertices, 64 obstacle selectors, 512 samples (default 64), 256
solid-body pairs, and 4096 distance queries. The numerical allowance describes
kernel calculations, not manufacturing tolerances or a certified machine model.
