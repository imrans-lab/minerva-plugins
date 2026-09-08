# Source annotations

`annotate` adds a read-only callout to the completed model. It does not change
geometry or manufacture a compensating offset.

```text
part = cube(20, 20, 5)
annotate [10,10,5], text="Check this face", id="top"
annotate [5,5,0], dimension="diameter", nominal=4, tolerance=[0,0.2], id="bore"
```

Points are **final model coordinates in millimetres**. They are not attached to
faces, propagated through Booleans, or transformed with a module's returned
shape. Calculate the final point explicitly when using placement parameters.
The same syntax works with reference-only models.

Dimensions are `diameter`, `radius`, or `length`. `nominal` is positive and in
millimetres. Optional `tolerance=[lower,upper]` specifies signed deviations from
that nominal, not a printer error or clearance allowance. Omitted tolerance is
unspecified. An annotation can instead contain only `text`.

Use an explicit `id` for stable identity across edits. Otherwise identity follows
evaluation order (`annotation-1`, etc.). IDs must be unique per evaluation.
At most 200 annotations are accepted; each text is limited to 2,000 characters.
Invalid declarations fail the build and retain the previous model and callouts.

The panel projects callouts into each visible CAD pane using Minerva's shared
annotation renderer. Rebuilding replaces derived records; independently authored
annotations remain separate. Source callouts must be edited in the DSL.

Worker evaluation replies include `annotations`. Export replies include
`annotations.records` and `annotations.included_in_geometry=false`: ordinary
STL, 3MF, STEP and GLB solid exports do not embed these records as manufacturing
PMI. The record retains nominal values, deviations, source line and the explicit
coordinate-only association; the viewport envelope also identifies its completed
evaluation. Neither the callout nor an export certifies a manufacturing process.
