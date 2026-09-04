# Running the pcb GDScript test suite

Round A1a. `pcb/tests/gd/*.gd` covers the plugin's panel + UI models
(`PcbLayerStack`, `PCBData`, `PcbRoutingWorkspace`, `panel_tools.gd`, and
friends). Before this round, **nothing ran these tests** — there was no
runner script and no CI job invoking `godot` anywhere in this repo. This
document + `pcb/scripts/run-gd-tests.sh` + the `panel` job in
`.github/workflows/pcb.yml` fix that.

**The runner is shared.** `pcb/scripts/run-gd-tests.sh` is a one-line wrapper
over `scripts/run-gd-tests.sh` at the repo root, which cad (and any later
plugin with a `tests/gd/`) uses through its own wrapper. The whole pass/fail
contract described below therefore has exactly one implementation. Everything
plugin-specific is data beside the suites:

| file | role |
| --- | --- |
| `pcb/tests/gd/EXPECTED_SUITES` | the pinned suite manifest |
| `pcb/tests/gd/KNOWN_HARNESS_DIAGNOSTICS` | the fatal-diagnostic allowlist |
| `pcb/tests/gd/REQUIRED_HOST_FILES` | host paths beyond `src/project.godot` that the suites preload |
| `pcb/scripts/probe-worker-methods.py` | the stale-bundle probe, run only for `real-worker` suites |

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

The fix is a checked-in manifest, `pcb/tests/gd/EXPECTED_SUITES` —
`#`-comments and blank lines ignored, one suite per line in the v2 format

```
<filename> [assertions=N] [real-worker]
```

(the attributes are the enforcement layers described in the next section;
an unknown attribute is an `exit 2` hard error, so a typo cannot silently
un-enforce anything). As a **pre-flight step**, before `--import` and before
any suite runs, `run-gd-tests.sh`
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

## False-green hardening (bug 019ff2b1fccb)

Since CI went `--preflight-only`, this runner is the **only execution gate**
for the panel layer — and it was measured certifying runs it should have
refused: a "47/47 green" run whose log contained `SCRIPT ERROR` / `Compile
Error` diagnostics, and E2E suites reporting `real_worker_used=false`
because their worker seams had silently degraded to canned results after the
Round E IR cutover (`component 'U1' has no footprint ref` — nobody saw the
refusal because the fallback swallowed it). Three enforcement layers close
this, all fail-closed:

**1. Fatal diagnostics fail the suite that printed them.** Every
`SCRIPT ERROR:` and `ERROR: Failed to load script` line in a suite's
captured output — paired with its `at:` location into one record — must
match a pattern in the checked-in allowlist
`pcb/tests/gd/KNOWN_HARNESS_DIAGNOSTICS`, or the suite fails even with a
green Results line. The allowlist exists because `godot --script`
double-loads each suite: the first pass runs before autoloads register, so
any preload chain reaching `SingletonObject` prints a compile-noise cascade,
then the second pass runs the suite fine. That noise is the harness's; the
allowlist patterns pin it to exact messages and locations, with the proof
written next to each entry. Adding a pattern to silence a red run is the
same act as deleting the assertion that failed — every entry needs a dated
proof that the diagnostic is the harness's, not the suite's. Deliberately
NOT scanned: plain `ERROR:` engine lines (headless runs legitimately print
Node-not-found/socket noise that is not a script-layer verdict).

**2. Pinned assertion counts** (`assertions=N`, closing the remaining half
of `019fa83e8310`): the suite must report exactly N total (passed+failed).
The old per-suite floor was `n_pass > 0`, which `check(true); quit(0)`
planted above the real assertions satisfies while everything real silently
skips. When a suite legitimately grows or shrinks, re-pin in a deliberate,
reviewed own-commit.

**3. Real-worker proof** (`real-worker`): the suite's Results line must
carry `real_worker_used=true`. The E2E suites' seams still fall back to
canned subprocess-boundary fakes — quietly when the pcb-plugin binary
genuinely isn't built (the suite stays runnable anywhere), and LOUDLY via a
`REAL-WORKER INVOCATION FAILED` line carrying the worker's actual error
when the binary exists but the call failed. Either way the gate refuses the
run: a canned result can never satisfy an E2E acceptance. When the gate
fails a real-worker suite, the `REAL-WORKER INVOCATION FAILED` line above
it in the log is the diagnosis — not the green assertion count.

All three layers have negative self-tests: `pcb/scripts/test-gd-runner.sh
<minerva-checkout>` plants a compile error, a forced `real_worker_used=false`,
an assertion-count drift and a mid-suite `SCRIPT ERROR` into sandbox suite
dirs (via the runner's `RUN_GD_TESTS_SUITE_DIR` seam) and asserts the runner
exits nonzero on each — plus a healthy control proving it still exits zero
when everything is genuinely fine. The self-test executes godot against the
Minerva host, so it shares the real run's constraints (kills a running
Minerva; needs built GDExtensions) and runs at testex next to the real
suite run. A runner change is not done until it exits 0.

## Real plugin-subprocess suites need a BUILT Minerva checkout

`test_pcb_backend_lifecycle.gd` and `test_pcb_plugin_smoke.gd` (and any other
suite that calls `PluginManager.start_plugin` for a real, un-mocked
subprocess) additionally require the Minerva checkout's `terminal`
GDExtension to be **built**, not just checked out: `<minerva>/src/bin/`
must contain `libterminal.<platform>.*.so` (or `.dylib`/`.dll`), produced by
`scripts/build-extensions.sh` in the Minerva repo (see that repo's
`CLAUDE.md`, "Building C++ Extensions"). A checkout with no `src/bin/`
directory at all has never run that build.

That extension registers the native `SubProcess` class that
`MCPServerConnection.gd`'s STDIO transport instantiates
(`ClassDB.class_exists("SubProcess")`). Without it, `start_plugin` fails for
**every** plugin — not a pcb-specific problem — with:

```
ERROR: SubProcess GDExtension not available - STDIO transport not supported
ERROR: [PluginManager] Failed to start plugin '<name>': Unavailable
FAIL: start_plugin returns ok — got: { "error": "Subprocess failed to start: Unavailable" }
```

Diagnosed (round B5u1, chore 019fb6632a4e) by first suspecting the
**pcb-plugin** binary itself, then ruling that out: running
`pcb/pcb-plugin --help` directly on the host starts the process cleanly
(prints its startup banner, finds `worker/`, exits 0 on stdin close) — the
binary and its worker venv are fine. The failure is entirely on the
Godot-host side of the STDIO pipe, before the pcb-plugin binary is even
reached. A scaffold used only for the bare-script suites above (mode
resolvers, model logic, panel construction) has no reason to have run
`build-extensions.sh`, so this is an expected gap on such a host, not a
regression — attribute FAILs from these two suites to it (`start_plugin
returns ok`, `plugin state == RUNNING`/`connection exists post-start`)
rather than re-investigating the pcb plugin.

## CI does NOT run these suites — execution is a local gate

**Running the suites is your job, not CI's.** Run `run-gd-tests.sh` locally
before you push panel work; nothing downstream will catch a regression for
you.

The `panel` job in `.github/workflows/pcb.yml` checks out the **pinned**
Minerva SHA as a sibling directory and then runs
`run-gd-tests.sh --preflight-only`. It downloads no Godot and executes no
suite. It certifies exactly one thing: **suite-registry and host-contract
compatibility** — host present, driver helpers present at the pinned SHA,
sibling layout correct, and the suite set on disk matching `EXPECTED_SUITES`
in both directions.

> **It is not a build check and not a test.** An earlier version of this
> section called it evidence that the GD layer is "in a testable state"; cold
> review (`019ff34dd1cf`, blocking finding 1) rejected that wording, and it
> was right to. A `.gd` file can be syntactically invalid, fail to preload, or
> regress outright while its filename sits in `EXPECTED_SUITES` and this job
> stays green.
>
> **There is currently no automated execution check for this layer at all.**
> The old CI run was removed as unhostable; the local runner it defers to is
> itself known to false-green on `SCRIPT ERROR` / `Compile Error` output and
> canned-worker fallback (`019ff2b1fccb`). Treat local green as "the runner
> exited 0", not as "the layer is verified".
>
> The agreed path back: fix `019ff2b1fccb` so the runner fails closed,
> classify suites into stock-host-safe vs native-extension/real-worker
> required, and run the stock-safe subset in CI under the fixed runner. Do
> **not** restore the old full run unchanged.

Two reasons, and the scoping one comes first:

1. **CI is not a test runner.** Its purpose is to certify that the plugin
   built and is testable, not that it has been tested. Running 5000
   assertions on every push was never in that remit.

2. **It could not do it correctly anyway.** Per the section above, any suite
   that starts a real plugin subprocess needs the host checkout's native
   GDExtensions *built*, and a plain `actions/checkout` has no `src/bin/`.
   Scripts that reach the FFmpeg-backed VideoRecorder fail to **compile**
   without it, and `Failed to compile depended scripts` cascades into
   `SingletonObject`, taking down suites unrelated to either extension.

   Measured at commit `014b6d7`: CI reported **27/47** suites with real
   assertions and 2233 assertions; the identical commit on a developer
   machine with `build-extensions.sh` already run reported **47/47** and
   5093. Every failure was host scaffolding; none was pcb code. The job had
   been red for five consecutive commits while telling nobody anything.

   Building three native toolchains (Zig, SCons/C++, FFmpeg) for *another
   repo* on every push — to run a suite CI should not be running — is the
   wrong trade twice over.

The Minerva SHA is still pinned deliberately — see the comment on
`MINERVA_SHA` in the workflow — so a change to Minerva's default branch can
never turn pcb CI red without someone choosing to bump the pin. Bumping it
now fails loudly and immediately if the pinned tree drops a driver helper,
which is precisely what the pre-flight is for.
