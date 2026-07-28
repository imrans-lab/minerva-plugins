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

## Suite-count floor (the manifest)

Everything above catches a suite that runs but reports nothing. It does
**not** catch a suite that never runs at all: the test list is
`${GD_TEST_DIR}/test_*.gd`, a bare glob, and a deleted or renamed suite file
simply disappears from it with nothing left to report a failure. Before this
was fixed (docket `019fa83e8310`), deleting 29 of the 30 suites made the
runner print `gd test suite passed (1/1, ...)` and exit 0 — only the
all-suites-gone case (`${#tests[@]} -eq 0`) was caught.

The fix is a checked-in manifest, `pcb/tests/gd/EXPECTED_SUITES` — one
filename per line, `#`-comments and blank lines ignored. As a **pre-flight
step**, before `--import` and before any suite runs, `run-gd-tests.sh`
cross-checks the glob's discovered file list against the manifest and fails
(`exit 2`, the same "harness/environment problem" convention as the other
pre-flight guards — not `1`, which means "a suite failed") in either
direction:

- a manifest entry with no corresponding file on disk (deletion or rename —
  the defect above), naming the missing suite(s); or
- a `test_*.gd` file on disk with no manifest entry (an added suite that
  wasn't registered), naming the unregistered suite(s).

The suite count is never hardcoded as an integer in the script — a literal
`30` goes stale the first time a suite is legitimately added, and the fix
someone reaches for is bumping the number rather than investigating, which
is the same act as deleting a suite performed by a different hand. Adding a
suite is meant to be a one-line, reviewed edit to the manifest file instead.

The final summary line also reports real, independent counts —
`gd test suite passed (${total_suites_ok}/${EXPECTED_SUITE_COUNT} suites, N
assertions)` — rather than the pre-fix `${#tests[@]}/${#tests[@]}`, a ratio
that is 100% by construction regardless of how many suites the glob actually
found.

## CI

The `panel` job in `.github/workflows/pcb.yml` runs on every push and pull
request (same triggers as `test`): it checks out a **pinned** Minerva SHA
as a sibling directory, downloads/caches Godot 4.6.2 headless, and runs
`run-gd-tests.sh`. The Minerva SHA is pinned deliberately — see the
comment on `MINERVA_SHA` in the workflow — so a change to Minerva's
default branch can never turn pcb CI red without someone choosing to bump
the pin.
