# Council v0.1 — release validation

Two different kinds of evidence live in this document, and they are kept apart
on purpose.

**Deterministic evidence** is what a suite decided: Go tests against the shipped
backend, the page's checks against recorded envelopes, the GDScript suite
against the real host mount. Every model in all of it is a double. A suite
passing says the code does what the code was written to do; it says nothing
about a real provider, a real CEF surface or a real person.

**Live evidence** is what happened when a real model was asked a real question
inside a running Minerva. It costs money, it is not repeatable, and it is the
only thing that can retire the phrase "not yet proven against a real model".

A live smoke is never reported as passing from a fake provider. Section 4 below
records that the live run **did not happen**, and why.

---

## C5 landing review addendum — 2026-09-10

The implementation evidence below is historical. Codex reviewed `332f0d2` in
`minerva-worktrees/council-c5-review` and added these corrections before landing:

- `01a08bb1acf7`: known directives now recognize missing arguments and Unicode
  whitespace through one reader. The regression test failed before the fix:
  tabs/newlines after `/ask` or `/bench`, and bare council-selection directives,
  opened consultations. It now verifies those inputs leave the record unchanged.
- `01a08bb1b2f6`: Help reflects C4's cancellation fix and distinguishes a panel
  closing from backend exit. The skill places `wait_seconds` at envelope level;
  the tool schema now exposes that existing field. Generated pages were rebuilt.
- `01a08bb2ec06` remains **open and blocks T12 and live acceptance**: chat/MCP
  changes advance the backend but do not automatically reach the panel's local
  record. Its Re-read is local, so saving it can omit recent results. This is a
  code-review finding requiring a real-host reproduction and an ownership-aware
  synchronization fix. README, Help and the skill no longer assume an open tab
  proves direct writes are persisted. Preserve backend exports until resolved.

Observed after the corrections: `go test -race -count=1 ./...` passed,
`go vet ./...` passed, built-binary stdio smoke passed (initialize, nine tools,
malformed-line recovery, shutdown, JSON-only stdout), page self-test **68/68**,
and `node council/ui/build.mjs --check` passed. Logs are
`/tmp/council-c5-go-final.log` and `/tmp/council-c5-page.html`.

No GDScript changed and its suite was not rerun in this review; **78/78 at C4**
remains its last observed result. No real provider was called. The real-model
scenario and the wrapper text-derivation test remain open. Local integration
landing does not satisfy these release gates.

---

## 1. What this build is

| | |
|---|---|
| Plugin | `council/v0.1` @ `b12fc60` (T10b), worktree `minerva-worktrees/council` |
| Plugin version | `manifest.json` `version`, asserted equal to `serverVersion` by the manifest test |
| Minerva checkout | `development` @ `c7ba56a9` |
| Godot | 4.6.2.stable.official.71f334935 |
| Go | go1.26.7 linux/amd64 |
| Node | v24.4.1 |
| Chrome (headless, page checks) | 136.0.7103.59 |
| Date | 2026-09-10 |

---

## 2. Deterministic coverage — commands and counts

Everything in this section was executed. Nothing here is a claim about a run
that was authored and not performed; those are named as such in section 3.

**Every command in this section runs from the plugin worktree root**
— `/home/imran/github/minerva-worktrees/council/`, the directory that holds
`council/`. `$PWD` below is that directory.

### 2.1 Static gates

    (cd council && gofmt -l .)                    # no output
    (cd council && go vet ./...)                  # clean
    (cd council && go build ./...)                # clean
    (cd council && node --check ui/build.mjs)     # clean
    (cd council && node ui/build.mjs --check)     # "ui/panel.html is up to date (12 sources, 146805 bytes)"
    (cd council && node --check <each ui/src/js/**/*.js and ui/tests/*.mjs>)   # clean

`godot --headless --check-only` was **not** run: the owner's Godot editor was
holding the Minerva project throughout, and a command-line launch against that
project kills it. No GDScript was changed in this task, so nothing new needs it.

### 2.2 Go suites — the backend, the engine and the host seam

    (cd council && go test -count=1 ./...)         # 3 packages ok
    (cd council && go test -count=1 -race ./...)   # 3 packages ok
    (cd council && go test -count=1 ./...)  x3     # green three consecutive times

    (cd council && go test -count=1 ./... \
       -coverpkg=./... -coverprofile=/tmp/council-t11.cov \
       && go tool cover -func=/tmp/council-t11.cov | tail -1)

**38 top-level tests; 74 tests and subtests in total.** Both are counted from
`go test -v`, because neither is visible in the ordinary output:

    (cd council && go test -count=1 ./... -v) | grep -cE '^--- PASS'        # 38
    (cd council && go test -count=1 ./... -v) | grep -cE '^[[:space:]]*--- PASS'   # 74

The first grep is anchored at column 0, which is where a top-level result is
printed; a subtest's result is indented, so only the second sees both.

Statement coverage, from the invocation above: **83.9 % before this task,
85.1 % after** (the profile total across all three packages). The per-package line `go test` prints for the
main package alone moved 81.2 % → 82.4 % over the same change; the two figures
count different denominators, so they are quoted together rather than mixed.

The profile total read 85.2 % at the end of T11's own work and 85.1 % here. The
difference is not a regression: the C5 batch folds for T10 and T10b added
production statements to `internal/session/chat.go` and `chat_directives.go`
after T11's tests were written, which moves the denominator. It is recorded
rather than smoothed over, because a coverage figure with no date and no tree
attached is not evidence of anything.

What decides each area, and where:

| Area | Where | The oracle |
|---|---|---|
| Record schema and invariants | `internal/contract/contract_test.go` | the shipped JSON schemas plus `invariants.go`, run over every fixture in `fixtures/` and every counter-example in `fixtures/invalid/` |
| Session identity | `internal/contract/identity_test.go` | duplicate ids across a snapshot |
| Protocol, end to end over stdio | `protocol_smoke_test.go` | a real pipe into the shipped `serve`; replay, stale revision, oversized and malformed lines, shutdown |
| Manifest ↔ backend ↔ install | `manifest_panel_test.go` | `manifest.json` against `newRegistry`, the panel entry against the scene, and the `go_build` output against the `backend.entrypoint` |
| Grounding, capture, export, import | `grounding_protocol_test.go` | sha256 computed in the test, anchor spans compared against the captured text, and a byte sweep of the export for project A's private material |
| A bounded round | `round_protocol_test.go` | the prompts each member was actually sent, the call count, the peak concurrency, and the engine's own labelling of a partial round |
| Council as a chat provider | `chat_provider_test.go` | the host behaviours it names by file and line — registration shape, catalogue shape, provider envelope kinds, and the model actually asked for |
| `/ask` and `/bench` | `chat_directives_test.go` | the system prompt on the wire, which is the only thing that names a member |
| Persistence, migration, recovery | `persistence_protocol_test.go` | a new store with a new loop; every claim made by loading a document and reading back what the engine holds |
| Snapshot budget | `internal/session/snapshot_budget_test.go` | `MaxEnvelopeBytes`, on both sides — a document already over it on arrival, and one that interruption expands over it |
| Chat scope races | `internal/session/chat_scope_test.go`, `review_regression_test.go` | `Export()` equality before and after, so a race that changed the record is visible as a changed document |
| Shipped help, skill and presets | `help_parity_test.go` | every tool, command and directive the help names, resolved against the manifest and the command table |

### 2.3 The page

    google-chrome --headless=new --allow-file-access-from-files \
      --virtual-time-budget=120000 --window-size=1400,900 --dump-dom \
      "file://$PWD/council/ui/tests/selftest.html" | grep -o '<title>[^<]*'

**68/68 checks passed.**

This number moves, so it is quoted with what moved it. T11 opened at **65/66**
— a red, defect D1 in section 5 — and closed at 66/66 once that check was given
an oracle. The C5 batch folds for T10 then added two named checks to the same
suite, and the count stands at **68/68** as measured here. The suite is not
pinned anywhere the way the GD suite is, so a changed total is only meaningful
against the change that caused it.

The page is driven against `ui/tests/recorded.js`, whose envelopes are what the
real backend returned after loading the shipped fixtures. Nothing in it is
hand-written.

`council/docs/t03-live-check.md` says this suite is "45 checks". It is 68. The
number in that document is stale (defect D4).

### 2.4 What was NOT run

- **`council/tests/gd/test_council_panel.gd`** (78 assertions, real host mount,
  real broker, real backend over stdio). The runner launches Godot against the
  Minerva project, which kills a running instance, and the owner's editor was up
  for the whole task. Nothing in this task touched GDScript, so the suite is
  expected to stand at 78/78 — but **expected is not observed**, and the
  orchestrator must run it when Minerva is down:

      council/scripts/run-gd-tests.sh <path-to-minerva-checkout>

  with `council-plugin` built first (`cd council && go build -o council-plugin ./`).

- **The full Minerva suites.** Still overdue, and outside this task.

---

## 3. Coverage changed in this task

### Added

| Test | Gap it closed | Falsified by |
|---|---|---|
| shutdown half of `TestCouncilRegistersBeforeReadingTheModelCatalogueAndWithdrawsOnShutdown` (`chat_provider_test.go`) | `chatProvider.withdraw` had no caller in any test: the orderly stop, which is the "stop the plugin and Council leaves the chooser" promise. What is actually at stake is ordering — a withdraw issued after `serve` returns reaches nobody | deleting the `provider.withdraw()` call from `main.go`'s shutdown arm → "the host saw 0 calls" |
| `source.upsert` section of `TestGroundedMemberLifecycleOverTheProtocol` | `cmdSourceUpsert` had zero coverage. It is the door that stores a caller-built record verbatim, and it is on the page's own command whitelist | the anchor assertion: a quote that appears twice, pinned to the first telling, which any re-derivation moves |
| the two `source.fetch` reads beside it | nothing asserted the documented difference between a fetch with a `source_revision` and one without | the revision-2 capture now sitting on the other occurrence of the same sentence |
| section 9 of `TestBoundedRoundDrivenByAFakeHost`, "a round that outruns its wait" | every other `run.start` in the suite finished inside its wait, so `run.start` could be read as blocking. It is not: it answers within `wait_seconds` and the round continues, which is the whole C3 transport ruling | the call count (3) across the section, which separates "answered early" from "started a second round" |
| `TestABrokerRefusalBecomesAVisibleMemberFailureThatCanBeRetried` (`chat_provider_test.go`) | `codeForBrokerError` had zero coverage. It is the failure a user meets first — no key, no budget, provider not configured — and it must arrive as a named member failure with the host's own words, not as a bad answer | forcing `codeForBrokerError` to return `model_error` → the assertion names `model_unavailable` |
| arrival-side half of `TestLoadReservesInterruptedSnapshotGrowth` | the `len(raw) > MaxEnvelopeBytes` branch of `Store.load`, and with it `countRecords`. The deliverable is the message: two byte counts and what the document holds | asserting on the message rather than on the fact of an error |

The harness gained one knob for this: `providerHost.refuseWith`, which makes
`host.providers.chat` answer with the broker's `{"success": false, error_code,
error_message}` envelope instead of a completion.

### Removed

- **`TestManifestMatchesTheToolRegistry`** (was `protocol_smoke_test.go`) —
  duplicate. It and `TestManifestAdvertisesExactlyTheToolsTheBackendAnswers`
  asserted the same three things (the name set, description parity,
  `input_schema` deep equality) over the same two inputs. Its unique
  assertions — manifest `version` against `serverVersion`, `id` against
  `serverName`, the single `go_build` step's output against
  `backend.entrypoint`, and `executor` — were folded into the surviving test,
  which reports every drift at once (`t.Errorf`) instead of stopping at the
  first (`t.Fatalf`).

### Rewritten

- **"v0.1 offers no invite control anywhere"** (`ui/tests/selftest.html`) had no
  oracle: it scanned `document.body.textContent` for the substring `invite`, and
  the page ships its JavaScript as inline `<script>` elements inside `<body>`,
  so the scan read the *source* and not the interface. It now walks the rendered
  controls under `#panel` and their accessible names. See defect D1.

### Considered and deliberately not added

The panel's **chat handoff** (`wrapper.chat_handoff` in `ui/council_panel.gd`
and `CouncilRecord.context_text`) has no automated coverage anywhere — not in
the GD suite, not in the page checks. It is the one derivation shared with
`_on_panel_render_for_llm`, so a change to either silently changes the other.

A GD section for it was **not** authored here. The suite's assertion count is
pinned in `tests/gd/EXPECTED_SUITES` and the runner fails loudly when the
reported total drifts from the pin, so a new section requires a number that can
only come from an observed run — and no Godot command could be run in this task.
Authoring assertions that have never been executed, and guessing the pin, would
put a red in front of the release gate rather than a test. Filed instead
(defect D5, work item `01a08a38b553`) for the orchestrator to add and run in the same
sitting.

---

## 4. The real-model desktop scenario — NOT PERFORMED

**The live run did not happen. No Council session has been consulted by a real
model. Nothing in this document should be read as evidence that it has.**

### Why

The scenario is driven through Minerva's MCP tools against the owner's running
instance. That instance was not running.

    $ pgrep -x godot
    2414468
    $ ps -p 2414468 -o cmd --no-headers
    /usr/local/bin/godot --path /home/imran/github/Minerva/src --editor

The only Godot process is the **editor** with the Minerva project open. Minerva
the application — the thing that starts plugins, owns chats and serves MCP — was
not launched from it.

    $ ss -ltn | grep 9315
    (no output)
    $ curl -s -m 5 http://localhost:9315/mcp
    (connection refused)

Minerva's MCP HTTP server is part of the running application
(`MinervaMCPHttpServer.gd`, `DEFAULT_PORT = 9315`; `singleton_object.gd:420`).
With no application there is no server, and every `mcp__minerva__*` call fails
with "Unable to connect". The read-only probes the brief asks for first —
`minerva_plugin_list`, `minerva_list_models`, `minerva_plugin_state`,
`minerva_list_chats` — could not be made either, so this task cannot even report
whether Council is installed, which providers are enabled, or which model would
have been used.

The two ways out were both closed by the brief and by the standing rule:
launching Minerva from the command line (`godot --path .../src`) kills the
owner's editor, and running a second Minerva was ruled out. So this thread stops
here and reports, rather than improvising.

### What is needed to perform it

1. The owner starts Minerva from the editor (or the orchestrator starts it once
   the editor is down), with **at least one provider enabled and one model in
   the catalogue**.
2. Council installed from this worktree and started, so the entry appears in the
   chat provider chooser.
3. Then the script below, driven through `mcp__minerva__*`, in scratch documents
   named with a `council-t11-` prefix, never in the owner's open work.

### The script, in order

Each line is a claim to confirm or refute. A refuted line is a finding to file.
Record, for every step: the exact tool call, the reply, and — where the step is
visual — a screenshot path. Record the **model identity as the record carries
it**: `contribution.model_id` in the session record, not the name in the
chooser, and not the name that was asked for.

**A. Two councils, two questions**

- [ ] Create project A (`council-t11-a`) and open a Council document in it.
- [ ] Import a shipped preset through `definition.import` with a fresh
      `definition_id`, and build a second council for a different question.
- [ ] Both councils are listed; each names its own purpose.

**B. A member grounded in a note**

- [ ] Create a Minerva note with material of your own.
- [ ] `source.capture` it into one council and give a simulant its grounding.
- [ ] The member pane shows what it represents and its limitations near its
      name, and the source pane shows the excerpt.

**C. Consultation with a real model**

- [ ] Open a chat, choose **Council**, and ask council A's question.
- [ ] The chair's synthesis arrives as the assistant message inside the entry's
      declared 120 s, or a reply that names the run and says it is still
      deliberating.
- [ ] **Record `model_id` and `usage` from each contribution in the record.**
      A contribution with no `model_id`, or usage of zero, means no real call
      was made and this whole section is void.
- [ ] The project holds one session, bound to that chat.

**D. Sources and disagreement**

- [ ] Open the session in the editor. Each member's argument is listed
      separately.
- [ ] A claim labelled `source` follows to the excerpt it cites; claims labelled
      `inference` and `unknown` offer no source link.
- [ ] At a pane wider than ~900 px, *Compare* two answers side by side.

**E. Follow-ups**

- [ ] From the editor, follow up on one claim. It reaches the member that made
      it and nobody else (check the run's contributions).
- [ ] In the chat, `/ask <member> <question>`. Same rule, from the other side.
- [ ] In the chat, `/bench`. The text equals what the record holds.

**F. An outcome retained**

- [ ] Retain a conclusion as a note. Reopen the session: the outcome is listed
      with its link back to the contribution.
- [ ] Delete the note, reopen: the outcome is still listed, marked as a note
      that cannot be resolved. Never silently dropped.

**G. Save, restart, reopen**

- [ ] Ctrl+S. `python3 -m json.tool` on the `.mcouncil` file: `record_kind` is
      `council_project_snapshot`.
- [ ] Save the project, quit Minerva, restart, reopen. The session, its runs and
      its synthesis come back, and nothing gained a "failed" or "interrupted"
      badge.

**H. The definition reused in project B**

- [ ] `definition.export` council A and import it into project B
      (`council-t11-b`).
- [ ] The export carries no session, no chat id and no question from A. Sweep
      the bytes.
- [ ] Ask a question in B. It runs on B's copy and A is untouched.

**I. The failure paths**

- [ ] **Missing model** — give a member a `model_hint` the host does not have.
      Refused before a round starts, naming the models that exist.
- [ ] **Missing source** — import a definition without content and consult a
      member grounded in it. The refusal names the source.
- [ ] **One failed member** — disable one provider mid-round, or use a member on
      a provider with no key. The round is partial, the failed seat is named and
      offers a retry, and the members that answered are still readable.
- [ ] **Plugin restart** — stop Council mid-round. The chat turn ends with a
      visible error rather than hanging. Start it, reopen: the interrupted run
      reads failed with an explicit retry and spent nothing.
- [ ] **Close and reopen** — close the Council tab mid-round and reopen from the
      same project. Contributions that landed after the tab closed are there.

**J. The panel itself**

- [ ] Narrow (~400 px): one column, opening a member covers the reading column
      and offers Back.
- [ ] Wide (>900 px): the detail column sits beside the reading column.
- [ ] Light and dark: the panel follows the host immediately, no reload, no
      flash of the wrong theme.
- [ ] Keyboard: Tab reaches every control with a visible ring; Enter on a
      citation opens the source; Escape returns to the same scroll position with
      the citation still focused.
- [ ] Ctrl `+` / `-` / `0` with the panel focused change Council's own text
      size, and the size survives a reopen.

**K. Ordinary chat is untouched**

- [ ] Switch the same chat back to a native provider: it answers normally.
- [ ] A chat that never had Council selected behaves exactly as before.

### Fake-provider coverage of the same ground — a separate thing

Everything in section A–I above has a deterministic counterpart. **Every one
that was executed in this task passed; the GD rows were last observed at the
78-assertion pin and were NOT re-run here** (§2.4), so they are marked as such
rather than counted as evidence from this task. They are listed so nobody has to
guess what is and is not already known:

| Scenario step | Deterministic counterpart |
|---|---|
| C, consultation | `TestCouncilAnswersAsAChatProvider`, `TestBoundedRoundDrivenByAFakeHost` |
| D, sources and disagreement | `TestGroundedMemberLifecycleOverTheProtocol`, page checks |
| E, follow-ups and `/ask` `/bench` | `TestCouncilChatAimsAtOneMemberAndReadsTheBench` |
| F, outcome retained then lost | `TestARetainedNoteThatCannotBeResolvedStaysLinked` |
| G, save / restart / reopen | `persistence_protocol_test.go` (run here); GD sections 2, 7–9 — **GD (not re-run)** |
| H, definition reused in project B | `TestDefinitionExportCarriesNoSessionData` and the export sweep |
| I, missing model | `TestCouncilAnswersAsAChatProvider` §3 |
| I, one failed member | `TestABrokerRefusalBecomesAVisibleMemberFailureThatCanBeRetried` |
| I, plugin restart mid-round | `TestInterruptedRunsAreNotResumed`, `TestSavedMidRunDocumentContinuesWithoutDuplicateCalls` |
| I, close and reopen mid-round | `TestAPanelClosedMidRunRecoversItsContributions` (run here); GD section 9 — **GD (not re-run)** |
| J, narrow / wide / dark / keyboard | `ui/tests/selftest.html` (68 checks) — synthetic events in a headless browser, **not** CefTexture's focus or native activation |

**Every model in that column is a double.** The column is why the code is
believed correct; it is not why it is believed to work.

---

## 5. Defects found in this task

| | What | Where | Filed |
|---|---|---|---|
| D1 | The page self-test's "no invite control" check had no oracle and went red on T10's help copy. It scanned `body.textContent`, which on this page includes every inline `<script>`, so it read the bundle rather than the interface. First run of this task: 65/66. Rewritten against the rendered controls, with a non-empty guard so an unmatched selector cannot pass vacuously; green ever since, and it falsifies on a real invite button (mutation-checked with both a `button` and a `select`) | `ui/tests/selftest.html` | bug `01a08a391d7a` |
| D2 | `schemas/envelope.schema.json` still describes `run.start` as returning "only once the run has reached a resting state", and `run.await` as being "for the second viewer of a run somebody else started". Both were true before the C3 transport ruling and are false now — `manifest.json` and `tools.go` describe the bounded wait correctly. The new section 9 of the round test falsifies the schema's prose directly | `schemas/envelope.schema.json:34` | bug `01a08a387422` |
| D3 | `Store.AwaitRun` has no caller anywhere. It is an exported wrapper on an `internal/` package, so no consumer outside the module can exist; the two live call sites both use the unexported `awaitRun` | `internal/session/round.go:520` | chore `01a08a38e08a` |
| D4 | `docs/t03-live-check.md` says the page self-test is "45 checks". It is 68 | `docs/t03-live-check.md:370` | chore `01a08a38e08a` |
| D5 | `wrapper.chat_handoff` and `CouncilRecord.context_text` have no automated coverage in any suite. `context_text` is the derivation shared with `_on_panel_render_for_llm`, so a change to one silently changes the other | `ui/council_panel.gd:551`, `ui/council_record.gd:266` | work item `01a08a38b553` |
| D6 | The live scenario could not be run at all: no Minerva application, so no MCP. Recorded in section 4 | — | work item `01a08a3957b6` |

None of D2–D5 was fixed here: they are out of T11's scope under file-don't-fix.
D1 was fixed because it is a test with no oracle, which is what this task is for,
and because it was red.

---

## 6. What this build is still not known to do

1. **Answer from a real model.** Section 4. Until it does, no claim about
   latency, cost, answer quality, provider compatibility or the chooser entry
   actually appearing has been tested.
2. **Render and behave in a real CEF surface driven by a person.** The GD suite
   proves the mount and the broker; `council/docs/t03-live-check.md` is the
   human half and is still open, including the populated-fixture persistence,
   note and restart checks (work item `01a083ddd85e`).
3. **Survive its own GD suite at this revision.** Authored, pinned at 78, not
   executed in this task.
