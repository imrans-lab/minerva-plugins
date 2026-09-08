# CAD build policy

Compilation and document synchronization are independent. The shared text buffer
remains authoritative in both modes; Manual mode does not disconnect either editor.

- **Automatic builds** (default): source edits queue the existing debounce.
- **Manual builds**: edits synchronize immediately but do not queue compilation.
  Switching to Manual stops a queued debounce; already dispatched work can finish.
- **Build latest**: compile the current source snapshot. Repeated requests for the
  same in-flight source join it. A newer explicit build supersedes older work.

The controls appear in both responsive layouts. They show Current, Build required,
Building, or Build failed. Errors keep the last successful geometry visible.
An edit made during a build leaves the resulting geometry stale until rebuilt.

MCP uses `minerva_cad_build` with `action=status`, `action=set_mode` and
`mode=manual|automatic`, or `action=build_latest`. Build requests return immediately;
`minerva_cad_await_eval` waits for already queued/running work. Waiting and inspecting
never compile a Manual document. Source writes succeed independently of compilation
in Manual mode; `last_eval.build` reports whether a build is required.

Mode is persisted in panel state and CAD notes, not embedded in DSL syntax. A plain
DSL file opened without saved panel state starts in Automatic mode. Restoring a
Manual note mounts its references and requires an explicit build for source solids.
Geometry checks retain the freshness guard and identify the need to build first.
