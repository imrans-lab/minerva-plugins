# Reusable validation and evidence

Save ordinary JSON beside the CAD source as `<source path>.checks.json`, or pass
an explicit path to `minerva_cad_validation`. The file is read from disk; its
SHA-256 identifies the exact requirements used. CAD source continues to come from
the shared completed document, including unsaved source.

```json
{
  "schema": "minerva.cad.validation/v1",
  "checks": [
    {
      "id": "bracket-fit",
      "kind": "design",
      "configuration": "assembled",
      "selection": "instance:bracket",
      "args": {"required_mm": 0.5}
    }
  ]
}
```

Kinds are `design`, `clearance`, `interference` and `fasteners`. Each entry names
one explicit selection and configuration; empty strings select the source's
default view. Use separate entries for different targets. `args` uses the existing
tool's shipped schema, including fastener and expected-contact declarations.
Unknown arguments, missing required fields and invalid types are refused before
measurement. Execution fields, temporary tickets and source overrides cannot be
stored as requirements. Up to 64 checks and 256 KiB of authored JSON are supported.

`action=inspect` validates and lists the file. `action=run` executes serially and
returns either a summary or `status=running` with a ticket. Collect that ticket
using `action=collect`; `cancel` stops before further checks. One job runs per
document, bounded to 15 minutes, and identical requests join the identified job.
Every check uses the normal selection, physical-configuration and freshness gates.
Edits during a run leave unmeasured or stale evidence, never an unconditional pass.

The summary shows failures and unknowns, counts passing checks, and links a full
content-addressed report. That file keeps the source snapshot, requirements,
provenance and each engine's response separately. `check_design` with `detail=full`
retains all three engine responses without the default clearance-row limit.
`action=report`, `report_path` and optional `sha256` retrieve saved evidence;
`detail=full` returns it explicitly. Saved reports describe historical evaluations.

Finding view hints use the existing posed-capture tool, named model scope, source
digest and reference digest. `include_context=true` includes the configuration's
reference geometry around the selected solid. Reproducing a view refuses changed
source or imported evidence rather than quietly depicting another revision.
Locations and framing boxes use world millimetres; local coordinates remain in
the underlying engine response when provided.

Evidence remains bounded by the engines' existing coverage and tolerance rules.
Absent targets, missing references, unbounded tolerance and uncertified intended
contacts remain visible. A requirement is not proof that its check passed.

`motion` checks use the same specification/report lifecycle; see [declared translation paths](motion.md).
