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

Several suites additionally preload `res://test/helpers/plugin_panel_driver.gd`
and/or `res://test/helpers/panel_tool_registry_driver.gd` from Minerva core, to
drive a real `PCBPanel` instead of a stand-in. A stock Minerva checkout has
both files; they are not vendored here.

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
prints a PASS/FAIL summary with a per-suite assertion count and a campaign
total. **Exit code is non-zero if any suite failed.**

## How pass/fail is signalled

Every test's `_init()` ends with:

```gdscript
quit(1 if _fail > 0 else 0)
```

and, just before that, prints a uniform `=== Results: N passed, M failed ===`
line. Historically the runner trusted the process exit code alone (`$?`) as
the pass/fail signal. **That was a real defect (round 019fa603827b):** a
suite that returns or `quit(0)`s before running any `check()` call — an
accidental early `return`, an aborted fixture, a mid-refactor slip —
exits 0 without asserting anything, and exit-code-only checking reported
it PASS. Measured directly: planting `quit(0); return` at the top of
`test_pcb_panel_ui.gd::_init()` made `run-gd-tests.sh` report
`PASS test_pcb_panel_ui.gd` and `gd test suite passed (30/30)` while none
of that suite's 22 assertions ran.

The runner now captures each suite's combined stdout+stderr (still
streamed live via `tee`, so a human watching the run sees the same output
as before) and parses the Results line in addition to checking `$?`. A
suite FAILS if the process exited non-zero, OR the Results line is absent
(suite quit/crashed before reporting), OR the line reports zero total
assertions, OR it reports zero passed — fail closed in every case where the
signal can't be trusted. This was verified two ways: (1) planting
`quit(0); return` at the top of `test_pcb_panel_ui.gd::_init()` and
confirming the runner goes red and names that suite specifically, then
restoring the file; and (2) deliberately weakening the runner's own guard
to check only that the Results line *exists* (dropping the N > 0
enforcement) and confirming that a suite which legitimately completes and
prints `=== Results: 0 passed, 0 failed ===` then slips through as a false
PASS — proving the N > 0 check is load-bearing, not decorative — before
restoring the full guard (round 019fa603827b, 2026-07-27).

It was also verified, prior to this defect fix, by deliberately breaking one
assertion in `test_pad_synthesis.gd`, confirming `run-gd-tests.sh` exited
non-zero and reported the specific failing test, then restoring the file
(round A1a, 2026-07-25) — that case (a suite that runs assertions and one
of them fails) was always caught correctly; it's the zero-assertion case
above that exit-code-only checking missed.

## CI

The `panel` job in `.github/workflows/pcb.yml` runs on every push and pull
request (same triggers as `test`): it checks out a **pinned** Minerva SHA
as a sibling directory, downloads/caches Godot 4.6.2 headless, and runs
`run-gd-tests.sh`. The Minerva SHA is pinned deliberately — see the
comment on `MINERVA_SHA` in the workflow — so a change to Minerva's
default branch can never turn pcb CI red without someone choosing to bump
the pin.
