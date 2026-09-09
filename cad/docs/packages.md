# Portable assemblies

`minerva_cad_package` freezes the completed DSL and its evaluated mesh
dependencies into a **new** destination directory, then generates `assembly.glb`.
It preserves unsaved source in the package without saving over the original tab.
Start requires current evaluated geometry; stale dependencies are refused.

```json
{"editor_name":"fixture.mcad","action":"start","path":"/absolute/new-package",
 "configuration":"assembled","wait_ms":0}
```

Collect the returned `ticket` with `action: "collect"`. Repeated collection
never rebuilds or rewrites a finished package. `cancel` stops publication after
the current export finishes. Failures return their private `staging_path` for
inspection; they never replace an existing directory.

The directory contains:

- `model.mcad`: byte-for-byte UTF-8 of the completed source.
- `model.mcad.package.json`: a document-scoped dependency map, configuration
  recipe, camera states, source annotations, instance/node identities, world
  transforms, units, file hashes and evaluation provenance.
- `model.mcad.checks.json`: the authored validation specification, if present.
- `dependencies/`: meshes plus glTF buffers and images. Relative URIs retain
  their directory relationships. Repackaging retains bounded relative paths.
- `definitions/`: one cached export per shared solid definition, produced by
  the existing `cad.export` job mechanism.
- `assembly.glb`: generated solids and imported components in glTF metres/Y-up.
  The companion manifest maps stable instance IDs to glTF node names; imported
  and generated meshes are converted through the ordinary reference reader.

Reopen **model.mcad with its sidecar beside it**. The CAD reference resolver
uses that document's path map, so even original absolute mesh paths resolve to
bundled data after relocation. Changing or deleting the sidecar invalidates
dependency freshness. Missing files are explicit failures. Run `start` again
with another new destination and the recipe's configuration to regenerate the
outputs; no placement script is needed. `action: "restore_view"` restores the
saved configuration and cameras through the existing model and note mechanisms;
Manual mode still requires an explicit Build latest when source is newer.

Reproducibility means retained source, input bytes, identities and world poses,
with the recorded 0.1 mm/0.1 angular solid tessellation settings and kernel
provenance. Third-party file bytes and output from different geometry-kernel
versions are not promised identical. The glTF is a visualization mesh, not
semantic manufacturing PMI. The source and validation specification retain
requirements separately from measured evidence.

Bounds: 512 MiB and 2048 dependency files, 128 definitions, 4 MiB metadata and
a 15-minute worker-export window. Dependency bytes are verified while freezing;
subsequent geometry export reads the staged copies. This prevents an input
changed during export from silently producing mixed provenance.

The end-to-end suite `tests/gd/test_package_export.gd` requires
`go build -o cad/cad-plugin ./cad` first. It uses the real host broker, Go
backend and Python worker, with no canned-result fallback. It deletes original
inputs, relocates and regenerates the package, and checks world bounds and
stable dependency paths.
