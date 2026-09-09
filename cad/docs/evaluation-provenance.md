# Evaluation provenance

The editable document and the completed model are separate records. Save and text
operations read current source; geometry consumers capture the completed source,
mesh, render target, and metadata at the start of their operation. Failed builds
leave that record intact. Measurements never silently substitute current edits for
the source that produced visible geometry.

Every panel-tool reply (except build control itself) carries available source and
buffer versions, evaluation time/status, stale state, and `provenance` containing
source SHA-256, document identity, tessellation settings, and a reference-set digest.
The reference digest covers loaded content stamps, units, axes and poses. Individual
content stamps are available through the reference inspection surface. A backend
without these fields is reported without invented settings or document identity.

- `require_source_version` requires a completed buffer revision.
- `require_source_digest` requires exact source bytes, including for unbacked notes.
- `accept_last_completed=true` permits measurement of an identified completed model
  while edits are pending. It does not override either requirement or clear stale.

Calls capture evaluated source once. If a model or reference pose changes while a
call is running, its result retains starting attribution, is stale, and carries
`result_valid=false`; any pass verdict becomes null. A caller must repeat it against
a settled model. Existing detached measurement tickets retain their starting stamp.

Legacy host inspection, snapshots, and exports forward the plugin's policy through
optional panel hooks. Old plugin builds remain usable without fabricated provenance;
explicit revision requirements need the new plugin. Job-only export collection needs
no live editor and keeps the worker's pinned attribution. Export replies distinguish
artifact `provenance` from `evaluation_provenance` of the input displayed model;
export tessellation is not claimed to be the viewport's tessellation.

Worker mesh caching uses source SHA-256 plus linear/angular tessellation settings.
B-Rep exports retain their existing source-keyed cache because tessellation settings
do not change the B-Rep. Dependency watching and cross-file invalidation extend the
existing reference content-stamp mechanism in the component-provenance roadmap item.
