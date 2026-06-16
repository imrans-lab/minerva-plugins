# Media Plugins Build Protocol (3d-gen + movie-gen)

Operating agreement for building the **3d-gen** and **movie-gen** Minerva plugins in
**Claude Code** (not Minerva's agent fabric — a docket `policy` item would not bind
Claude Code, so the gates live here). Plan tree: `plugins.dct`, components `3d-gen` /
`movie-gen` (parents `019ed133683b` / `019ed13386af`) + the cross-repo H.264 quality
knob `minerva-services:019ed138265f`.

## Base contracts (assert at the top of every session)

Work is **direct on mainline, no branches, no worktrees.** Before any edit:
`git -C <repo> rev-parse --abbrev-ref HEAD && git rev-parse --short HEAD` and confirm:

| Repo | Branch | Known-good base | Notes |
|---|---|---|---|
| `~/github/Minerva` | `development` | `22b87346` | **Standing dirty set is NOT ours** — `src/gdextension/terminal/unix/subprocess.cpp`, `unix/terminal.cpp`, `windows/terminal.cpp`, `vendor/godot_cef`. Keep dirty; **never stage**. |
| `~/gitlab/minervaservices` | `development` | `267b4dc` | media-gen lives here (H.264 quality knob). |
| `~/github/minerva-plugins` | `main` | `fcc1d58` | Both plugins + shared client. Remote `imrans-lab/minerva-plugins` (NOT deprecated `~/github/plugins`). |

## Commit discipline

- **Frequent WIP commits, per-grandchild** (smallest reversible unit on mainline).
- **Explicit paths only** — never `git add -A` / `git commit -a` (would sweep the
  standing Minerva dirty set). Stage the exact files the item touched.
- Commit message trailer ends with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- Push/merge only when the owner authorizes.

## Model assignment (Claude Code pool: Opus 4.8 + Sonnet 4.6 + Haiku 4.5; Fable disabled)

| Model | How | Work |
|---|---|---|
| **Opus 4.8** (me, main loop, direct) | inline | Orchestration; **all Minerva host changes** (A1a credential seam, A4c install enablement); panels (A3*/B3*); GHA authoring; API-freeze + DRY review gates; HITL + live-stack validation; **every commit**. |
| **Sonnet 4.6** | delegated subagent | A1b Rust client; A2*/B2* MCP tools; B1* backend wiring; MIN quality knob. |
| **Haiku 4.5** | delegated subagent | manifest/registry scaffolds, PLUGIN_DIRS edits, schema/boilerplate stubs, fixtures. |

**Subagents propose; Opus disposes.** A subagent returns edits; I run the tests,
review the diff, and make the scoped commit. No branch quarantine + no Minerva
auto-gate ⇒ **I am the gate.**

## Gates

- **Pre-flight:** assert base contract (above) · enumerate the files the item may
  touch · confirm the item's acceptance criteria.
- **Concurrency:** no two subagents in the **same repo** at once (shared working
  tree, no worktree). Parallel only **across** repos.
- **Green-tests-before-commit:** a delegated batch is committed only with its tests
  green in-hand. Exception: live-stack-dependent items (need the GPU node) — I
  validate those manually before committing.
- **Post-flight:** `git diff --stat` within the enumerated set; out-of-scope hunks
  are reverted or re-filed, never committed as "while I was here."

## Scope & DRY

- The **docket item is the scope contract.** "Do the rest" is never a follow-up —
  under-scoped items get re-filed, not silently expanded.
- **A1 lands first and is the only path to Core.** B1 is `blocked-by` A1; movie-gen
  consumes the shared client, never forks it. Client lives in `shared/` beside the
  existing DRY follow-ups (shared MCP router loop, codetools→shared bridge).
- **Freeze-the-interface gate:** the A1 client API is frozen (Opus, direct) before
  A2/A3/B1 fan out, so consumers code against a stable surface.
- A4/B4 release acceptance includes a **"no duplicated relay/auth/credential logic"**
  review.

## Decisions use the 7-axis rubric

reliability / durability / performance / debuggability / cost / discoverable /
user-visible — applied to any judgment call.

## Sequence (critical path A1 → (A2/A3 ∥ B1) → A4/B4)

1. **A1** hybrid — freeze API (Opus) → Rust client (Sonnet, test-gated) → A1a
   credential seam (Opus, Minerva) → A1c bind + live-stack validate (Opus).
2. **A2/A3 ∥ B1** — tools/backend (Sonnet), panels (Opus). Serial within
   minerva-plugins; Minerva edits (A1a/A4c) may run parallel (different repo).
3. **A4/B4** hybrid — manifest/registry (Haiku) direct, GHA authored (Opus) + proven
   on real CI, marketplace-install HITL (the large end HITL).
