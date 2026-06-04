# Probe Capture Runbook (Option C — HITL)

This runbook describes how to refresh the committed probe-state fixture with
real data captured from a live Godot editor. Run this whenever:

- The schema-version guard test (`test_sightline_probe_schema_guard.py`) fails
  because `codetools_probe.gd` was updated and bumped its schema version.
- You want to update the fixture with richer representative data.

> **Option A** (headless Godot in CI) is deferred. **Option B** (replay from
> this fixture) is the automated path. This runbook is the **Option C** human
> gate for refreshing the fixture that Option B replays.

---

## Steps

### 1. Install the probe into a Godot project

Pick any Godot 4.x project you have locally (or use the one in
`codetools/worker/tests/fixtures/godot_project/`).

```
minerva_codetools_inspect {"op": "prepare", "project_path": "<absolute-path-to-project>"}
```

Verify the addon landed:

```
minerva_codetools_inspect {"op": "status", "project_path": "<absolute-path-to-project>"}
# Expected: installed=True, enabled=False (until editor restart), loaded=False
```

### 2. Open the project in the Godot Editor

The probe is an `@tool` EditorPlugin. It does **not** hot-load into a running
editor — you must open (or re-open) the project:

```bash
godot --editor --path <absolute-path-to-project>
```

Or open it from the Godot project manager GUI.

### 3. Wait for the probe to write its JSON (~0.5 s cadence)

The probe writes `res://.codetools/godot_probe/debugger_state.json` every
0.5 seconds from `_process()`. After the editor finishes loading (a few
seconds), the file will exist.

Confirm it is being written:

```
minerva_codetools_inspect {"op": "status", "project_path": "<absolute-path-to-project>"}
# Expected: installed=True, enabled=True, loaded=True
```

The file lives at:

```
<project-path>/.codetools/godot_probe/debugger_state.json
```

### 4. Copy and normalize the captured JSON

Copy the captured JSON over the committed fixture, replacing any absolute
paths with the placeholder `/project`:

```bash
# From the repo root:
cp "<project-path>/.codetools/godot_probe/debugger_state.json" \
   codetools/worker/tests/fixtures/probe/debugger_state.v3.json

# Normalize absolute project paths (sed or your editor):
# Replace every occurrence of "<project-path>" with "/project"
sed -i 's|<project-path>|/project|g' \
    codetools/worker/tests/fixtures/probe/debugger_state.v3.json
```

Make sure the fixture still contains a recognizable marker line. The
Option B replay test (`test_sightline_p36_replay.py`) searches for
`probe_fixture_marker` in the artifact text. If the live capture does not
naturally include that string, add a sentinel GDScript file to the project
that triggers it (e.g., a `.gd` file with `SCRIPT ERROR: probe_fixture_marker`
in a comment that the probe picks up via the output console).

Alternatively, hand-patch one row in `debugger.rows[*].text` to include
`probe_fixture_marker` — the key invariant is that the marker exists
somewhere in the serialized JSON that `validate` will read back.

### 5. Re-run the worker tests

```bash
cd codetools/worker
python3 -m unittest discover -t . -s tests -p 'test_*.py'
```

The schema-version guard (`test_schema_versions_match`) confirms the fixture
schema now matches the probe, and the replay tests confirm the attach→validate
round-trip works with the fresh data.

### 6. Uninstall the probe (optional but recommended)

```
minerva_codetools_inspect {"op": "remove-probe", "project_path": "<absolute-path-to-project>"}
```

Verify:

```
minerva_codetools_inspect {"op": "status", "project_path": "<absolute-path-to-project>"}
# Expected: installed=False, enabled=False, loaded=False
```

---

## Schema version drift

If `codetools_probe.gd` bumps the top-level schema (e.g.,
`editor_probe_state.v3` → `editor_probe_state.v4`):

1. The guard test `test_schema_versions_match` will fail immediately.
2. Follow this runbook to capture a new fixture with the updated schema.
3. If the sub-schemas (`debugger_rows.vN` or `output_console.vN`) also change,
   update the guard tests `test_fixture_debugger_schema` and
   `test_fixture_output_console_schema` accordingly.

---

## Notes

- The probe file is written atomically (truncate + store_string in GDScript).
  Reading it while the editor is running is safe.
- Large projects may produce a large `diagnostics` block. Trim it to keep the
  fixture under ~50 KB — only the `rows` and `output_console.text` fields are
  load-bearing for the replay tests.
- The fixture `project_path` field should be `/project` (the normalized
  placeholder). The `provenance.output_path` should match:
  `/project/.codetools/godot_probe/debugger_state.json`.
