# codetools — combined code-intelligence workflows

codetools is three subsystems behind one MCP surface. Each is useful alone, but
the payoff is the **loop** they form together:

```
        ┌─────────────────────────────────────────────────────────┐
        │                                                         │
   ┌────▼─────────┐      ┌──────────────────┐      ┌──────────────┴───┐
   │ UNDERSTAND   │ ───▶ │ NAVIGATE & EDIT  │ ───▶ │ INSPECT & VERIFY │
   │ (code-       │      │ (file primitives │      │ (code-probe:     │
   │  visualizer) │      │  + buffer docs)  │      │  explore/inspect/│
   │              │      │                  │      │  validate)       │
   └──────────────┘      └──────────────────┘      └──────────────────┘
   query / get_context     glob / grep / bash        explore (scored)
   get_diff / get_graph    cwd / doc_read            inspect (probe)
   analyze / stale_check    doc_edit / doc_save        validate (goal)
```

Each phase maps to one install-seeded skill:

| Phase | Skill | What it answers |
|-------|-------|-----------------|
| Understand | `minerva_codetools_understand_code` | "What is this code? Where is X? What does this change touch?" |
| Navigate & edit | `minerva_codetools_navigate_edit` | "Find the files, read them, make the change, save it." |
| Inspect & verify | `minerva_codetools_inspect_runtime` | "Did the change actually work at runtime? Prove it against a goal." |

Activate a skill with `minerva_activate_skill` to load its full step-by-step
system prompt; the table above is the index.

---

## The loop auto-chains itself (P4.3 follow_ups)

You do not have to remember the whole loop — the tools emit `follow_ups` (a
uniform `{tool, reason, params}` shape) that point you to the next call:

- A code-visualizer read (`query` / `get_context` / `get_graph`) run against a
  **stale index** appends a follow_up suggesting `minerva_codetools_stale_check`
  (precise) or `minerva_codetools_analyze` (reindex). You learn the index drifted
  *before* you trust a wrong answer.
- `minerva_codetools_inspect {op: "status"}` against a project with **no probe
  installed** appends a follow_up suggesting `inspect {op: "prepare"}`. You learn
  the runtime-verify dependency is missing *before* a capture fails.

Always read the `follow_ups` array of an envelope and act on it — it is the
connective tissue between the three phases.

---

## Recipe A — Godot warning → fix → verify (the canonical loop)

A Godot project emits a warning/error and you want it gone, with proof.

1. **Locate** the offending code.
   `minerva_codetools_explore {op: "search", query: "<warning text or symbol>", intent: "definition", root}`
   (or `op: "locate-edit"` for ranked edit targets). Falls back to
   `minerva_codetools_grep {pattern, type: "gdscript"}` for a raw sweep.
2. **Understand** the blast radius before touching it.
   `minerva_codetools_stale_check {root}` → if stale, `minerva_codetools_analyze {root}`.
   `minerva_codetools_get_context {symbol_id}` and, for a pending change,
   `minerva_codetools_get_diff {base_ref}` to see what else it touches.
3. **Edit** the file.
   `minerva_codetools_cwd {path}` → `minerva_doc_read {path, offset, limit}` →
   `minerva_doc_edit {path, old_string, new_string}` → `minerva_doc_save {path}`.
4. **Verify** at runtime via the Godot editor probe (HITL — see
   `docs/probe_capture_runbook.md`).
   `minerva_codetools_inspect {op: "prepare", project_path}` →
   `inspect {op: "status"}` until `installed=true` → ask the user to open the
   editor → `inspect {op: "status"}` until `loaded=true` →
   `inspect {op: "attach", artifacts: [["godot_probe_state", "<.../debugger_state.json>"]]}`.
5. **Prove it.**
   `minerva_codetools_validate {goal: "no GDScript warnings at editor load",
   artifact_ids: [...], require_no_runtime_issues: true}` → a pass/fail verdict
   with a confidence score and a recommended next step.

If validate fails, its `next_step` points you back to phase 1 or 2.

---

## Recipe B — Understand an unfamiliar codebase

1. `minerva_codetools_analyze {root}` — build the semantic index.
2. `minerva_plugin_open_panel {plugin_id: "codetools", panel: "code_graph",
   editor_item_id: "open_code_graph", filename: "code_visualizer.db"}` — the
   visual Code Graph (opens at a Level-0 splash; click in to explore).
3. `minerva_codetools_query {query}` + `get_context {symbol_id}` for targeted
   lookups (faster than the panel for "where is X").
4. Leave the index smarter than you found it: `minerva_codetools_undescribed`
   → `set_description` / `set_tags` so future semantic queries score better.

---

## Recipe C — Assess, change, and re-verify a refactor

1. **Assess**: `minerva_codetools_get_diff {base_ref}` for the changed-symbol
   blast radius; `where-tested` (explore) to find the covering tests.
2. **Change**: the `navigate_edit` phase (glob → grep → doc_edit → doc_save).
3. **Re-index**: `minerva_codetools_analyze {root}` — symbol ids may shift after
   a structural change; re-query for fresh ids.
4. **Verify**: `explore {op: "where-tested"}` to relocate tests, run them via
   `minerva_codetools_bash {command: "<test runner>"}`, then
   `minerva_codetools_validate {goal, code_result_ids: [...]}`.

---

## Notes

- **Buffer vs disk**: `doc_edit`/`doc_write` mutate an in-memory buffer; nothing
  reaches disk until `doc_save` / `doc_save_all`. The probe and any external
  build step see only saved files.
- **The probe is HITL**: the Godot `@tool` EditorPlugin activates only when the
  editor is open — it cannot be driven over MCP. `prepare`/`status` are the MCP
  touchpoints; opening the editor is the human step (`docs/probe_capture_runbook.md`).
- **Paths are absolute**: every `root` / `project_path` / `path` argument wants
  an absolute path. Relative paths resolve against the worker cwd, which does not
  persist across MCP reconnects — re-`cwd` at the start of each session.
