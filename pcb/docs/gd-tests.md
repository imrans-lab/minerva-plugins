# Running the pcb GDScript test suite

Round A1a. `pcb/tests/gd/*.gd` covers the plugin's panel + UI models
(`PcbLayerStack`, `PCBData`, `PcbRoutingWorkspace`, `panel_tools.gd`, and
friends). Before this round, **nothing ran these tests** — there was no
runner script and no CI job invoking `godot` anywhere in this repo. This
document + `pcb/scripts/run-gd-tests.sh` + the `panel` job in
`.github/workflows/pcb.yml` fix that.

## Why a Minerva checkout is required

Every test is `extends SceneTree` and is invoked as `godot --headless
--script <path>`. Their `preload()` calls use `res://../../minerva-plugins/pcb/...`
— that only resolves if:

1. Godot is launched with `--path <minerva-checkout>/src` (so `res://`
   is Minerva's `src/` root), and
2. the minerva-plugins checkout sits **beside** the Minerva checkout on
   disk, named literally `minerva-plugins` (e.g.
   `<parent>/Minerva/src` + `<parent>/minerva-plugins`).

3 of the 7 tests (`test_workspace_persistence`, `test_workspace_ingest`,
`test_parity_bridge`) additionally preload
`res://test/helpers/plugin_panel_driver.gd` from Minerva core, to drive a
real `PCBPanel` instead of a stand-in. A stock Minerva checkout has this
file; it is not vendored here.

## Running locally

```bash
pcb/scripts/run-gd-tests.sh /path/to/Minerva
```

The Minerva checkout must:
- have a `src/` directory (it's a normal Minerva repo checkout — branch
  doesn't matter for local runs), and
- sit as a sibling directory of this `minerva-plugins` checkout on disk.

`godot` (4.6.2, tested against `4.6.2.stable.official`) must be on `PATH`.
The script discovers every `pcb/tests/gd/test_*.gd`, runs each one, and
prints a PASS/FAIL summary. **Exit code is non-zero if any test failed.**

## How pass/fail is signalled

Every test's `_init()` ends with:

```gdscript
quit(1 if _fail > 0 else 0)
```

So the Godot process's own exit code is a real, load-bearing pass/fail
signal — the runner checks `$?` after each invocation, it does not scrape
stdout for "FAIL" strings. This was verified by deliberately breaking one
assertion in `test_pad_synthesis.gd`, confirming `run-gd-tests.sh` exited
non-zero and reported the specific failing test, then restoring the file
(round A1a, 2026-07-25).

## CI

The `panel` job in `.github/workflows/pcb.yml` runs on every push and pull
request (same triggers as `test`): it checks out a **pinned** Minerva SHA
as a sibling directory, downloads/caches Godot 4.6.2 headless, and runs
`run-gd-tests.sh`. The Minerva SHA is pinned deliberately — see the
comment on `MINERVA_SHA` in the workflow — so a change to Minerva's
default branch can never turn pcb CI red without someone choosing to bump
the pin.
