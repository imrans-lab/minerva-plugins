# Assemblies and evaluated selection

Keep reusable geometry in existing bindings or modules. Use explicit instances
when identity and placement matter independently of Boolean operations:

```text
block = cube(2)
left = instance(block, id="left", accuracy="measured", source="Caliper measurement")
right = translate([2,0,0], instance(block, id="right"))
assembled = assembly([left, right])
exploded = configuration(assembled, [translate([10,0,0], right)], physical=false)
partial = configuration(assembled, [], include=["left"], physical=true)
assembled
```

Touching bodies remain separate; `assembly` never fuses them. Instances share a
bound definition. Optional `definition=` gives that definition an explicit ID;
using the same definition ID for different geometry is rejected. Nested assembly
instances flatten to hierarchical IDs such as `module/board`. Translate and rotate
compose placements in the same millimetre, Z-up frame used by mesh references.
Scale geometry before instancing it; instance placements support rigid transforms.

`accuracy` is a provenance declaration (`unspecified`, `supplier`, `measured`, or
`approximate`), not a numeric error bound or a certification. Source text, units
and reference paths travel with evaluated definitions. Imported geometry continues
to use `mesh(path, units=..., up=...)`.

Configurations replace existing instance placements and optionally select an
`include` subset. They retain the same definitions and IDs. They default to
`physical=false`; ordinary assemblies default to physical. The source's existing
last-binding/trailing-expression rule selects its default view.

The configuration menu and `minerva_cad_model` (`action=list|show`) share the same
completed model. Showing a view never rewrites the DSL. If edits need a build,
show records the choice and reports `build_required`; it does not override Manual
mode. The next explicit build uses that choice.

`cad.evaluate` and `cad.export` accept `selection` and `configuration`. A selector
is a binding, instance ID or reference name. Prefix it with `binding:`, `instance:`,
or `reference:` to resolve ambiguity. Missing or ambiguous names fail explicitly.
`part` remains an export alias. Named checks use the same resolver through `parts`.
Selection never appends an expression to the source, and all consumers reuse the
same compiled document and geometry. Export jobs pin selection and configuration.

Physical panel checks require the named configuration to be displayed, and refuse
presentation configurations. Select a physical view before checking it. Exports
can select any configuration without changing the viewport. Cross-configuration
checks against independently posed imported references are not yet implemented.

Imported files use the host file watcher, including opt-in removal events. Changes
mark the completed model stale independently of source revisions. Automatic mode
debounces a rebuild; Manual mode waits for Build latest. Measurement/export
boundaries verify content stamps (including glTF side files), catching replacements
between watcher ticks or with unchanged size/timestamp. Ordinary frame rendering
and evaluation polling do not repeatedly hash dependency files.
