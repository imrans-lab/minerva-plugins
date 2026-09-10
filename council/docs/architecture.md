# Council v0.1 — records, authority, and the host integration contract

This document fixes three things for Council v0.1: what a Council record *is*,
who owns each piece of state, and how the plugin mounts inside Minerva. Every
claim about the host was read out of `/home/imran/github/Minerva` on branch
`development` and is cited as `file:line`. Where a claim in the parent DCR did
not survive contact with the source, it is corrected here and the correction is
marked.

The machine-readable half of this document is `council/schemas/*.json`. Those
schemas, not this prose, are the source of truth; the worked examples in
`council/fixtures/` are validated against them by
`council/internal/contract/contract_test.go`.

---

## 1. The question this task had to answer

> Is the existing Minerva CEF/webview bridge plus the scene-panel hooks enough
> for an HTML editor with native save/load, note creation and LLM context
> rendering — and if not, what is the smallest host addition?

**Answer: enough, with no host change, but not by the route the DCR assumed.**

An `html`-kind plugin panel is *not* sufficient and cannot be made sufficient
from the plugin side. A `godot_scene` panel that instantiates `CefTexture`
itself is sufficient, gets the full native lifecycle, and needs nothing new from
the host. The one genuine gap found — `_on_panel_render_for_llm` has no
production caller — does not block v0.1, because Council's context reaches a
chat through the note it creates.

### 1.1 Why an `html` panel cannot work

An HTML panel is opened as a plain `Editor.Type.WEBVIEW`:
`EditorPane.add_plugin_panel_editor(plugin_id, panel_name, panel_html, tab_title)`
(`src/Scripts/UI/Views/EditorPane.gd:337`) calls
`add(Editor.Type.WEBVIEW, ...)` and sets only `webview_editor.plugin_id`,
`.plugin_panel_name` and `.set_html(...)`. It never assigns
`editor.plugin_scene_root`.

Every panel lifecycle hook is gated on `Type.PLUGIN_SCENE` with a non-null
`plugin_scene_root`: dirty tracking (`Editor.gd:1539`), Ctrl+S
(`Editor.gd:1701-1712`), mark-saved (`Editor.gd:1710`), create-note
(`Editor.gd:2226`), note refresh (`Editor.gd:2435`), chat-inject toggle
(`Editor.gd:2494`), unload (`Editor.gd:748`), undo (`Editor.gd:2167`), project
serialize (`src/Scripts/UI/Controls/vboxEditor.gd:164`, `:494`) and project restore
(`vboxEditor.gd:757-784`).

What a WEBVIEW editor does instead is the damaging part:

- **Save writes the page, not the state.** `Editor.gd:1701-1709` opens the target
  file and stores `webview_editor.get_html()`. A user who presses Ctrl+S on a
  Council HTML panel would save the markup and lose the council.
- **A note captures the page, not the state.** `Editor.gd:2400-2406` builds
  `Note.create_html_note(tab_title, html)`; `Editor.gd:2427` refreshes it with
  `note.linked_html = html`.
- **Project serialize emits no panel state.** Only the `PLUGIN_SCENE` branch of
  `vboxEditor.serialize()` writes a `plugin_state` / `__panel_state` entry
  (`vboxEditor.gd:494-499`, `:518-527`).

An HTML panel's whole contract with the host is
`PluginWebviewBroker.handle_ipc_message(panel_name, message_type, payload)`
(`src/Scripts/Services/Plugins/PluginWebviewBroker.gd:150`) plus two one-way JS
pushes, `push_plugin_event` / `push_plugin_state`
(`src/Scripts/UI/Controls/WebViewEditor/CefWebViewEditor.gd:302`, `:312`).
That is a message pipe, not a document.

### 1.2 Why a scene panel that owns its own `CefTexture` does work

`CefTexture` is an ordinary GDExtension class in the project's `ClassDB`, not a
host-private type. The host itself reaches it that way:
`ClassDB.class_exists("CefTexture")` and `ClassDB.instantiate("CefTexture")` at
`CefWebViewEditor.gd:69`, `:88`, `:103`, and again at `Editor.gd:473`. Its
public surface is all a plugin needs:

| Member | Where it is defined |
|---|---|
| `eval(code: String)` | `vendor/godot_cef/crates/gdcef/src/cef_texture/mod.rs:371` |
| `signal ipc_message(message: String)` | `vendor/godot_cef/crates/gdcef/src/cef_texture/mod.rs:173` |
| `send_ipc_message(message: String)` | `vendor/godot_cef/crates/gdcef/src/cef_texture/mod.rs:507` |
| `url` property | set by the host at `CefWebViewEditor.gd:150` |

A plugin scene script may therefore mount the same browser view the host mounts,
inside a panel that receives the full hook set dispatched by
`PluginScenePanelHost` (`src/Scripts/Services/Plugins/PluginScenePanelHost.gd`:
`invoke_save:250`, `invoke_load:300`, `invoke_create_note:328`,
`invoke_restore_from_note:350`, `invoke_render_for_llm:380`,
`invoke_inject_toggle:404`, `invoke_unload:451`).

`council/ui/` is that panel, and it is the production one: `CouncilPanel.tscn`
(the surface, its SubViewport and the notice label as scene nodes rather than
generated UI), `council_panel.gd` (the hooks and the page protocol),
`council_record.gd` (what the held record is, and what happens to a document the
panel cannot read), `council_backend.gd` (the hop to the engine, the transport
budget, and the lease that keeps two panels apart — §5.4), and
`council_bridge.gd` (the JavaScript injected into the page). The wrapper applies
no command and edits no record; that is the engine's job (§3). The scripts pass
`godot --headless --check-only`; `council/tests/gd/test_council_panel.gd`
exercises the whole panel through the host's own mount path.

The exploratory `council/proof/` plugin that first established this shape has
been deleted: it existed to answer the question above, the production panel now
answers it, and a second installable Council plugin declaring a second panel is
a thing to install by mistake.

### 1.3 Three host behaviours the wrapper must copy, not discover

These are not optional style choices; each one is a defect if skipped.

1. **`CefTexture` must live in a `SubViewport`.** Its node-level `_input` hook
   otherwise consumes every event in the main viewport — tabs, menus and buttons
   across all of Minerva, not just the panel (`CefWebViewEditor.gd:114-141`).
2. **`eval()` must be deferred.** Evaluating JS synchronously from inside the
   browser's own IPC callback re-enters the view while it is still borrowed
   (`CefWebViewEditor.gd:291`, and the explicit warning at
   `WebViewEditor.gd:233-235`).
3. **The page must be materialised to a file.** `CefTexture` loads URLs, not
   inline HTML, so the bridge-injected page is written to `user://` and loaded
   as a `file://` URL (`CefWebViewEditor.gd:91-101`, `:150`).

Accelerated OSR is force-disabled by the host because the Vulkan DMA-BUF path
renders black on this stack (`CefWebViewEditor.gd:109-112`); the wrapper does the
same.

### 1.4 Compatibility detection

`godot-cef` may be absent from a build. The single check is
`ClassDB.class_exists("CefTexture")`, exactly as the host uses it
(`CefWebViewEditor.gd:69`). When it is false the wrapper renders a sentence that
tells the user what is missing and that their data is intact — it never renders
an empty rectangle. There is no WRY fallback for Council: `WebViewEditor` (WRY)
is a host *editor* scene, not a node a plugin can mount, and under WRY the
surface is an overlaid OS window rather than a texture
(`WebViewEditor.gd:49-58`).

Minerva keeps CEF alive process-wide by pinning a hidden `CefTexture`
(`src/Scripts/Models/singleton_object.gd:1296-1303`), so Council creating and
freeing its own texture cannot shut CEF down.

### 1.5 Corrections to the DCR and the discussion

- **"Native scene panel hooks support … rendering panel context for LLMs" is
  not true today.** `_on_panel_render_for_llm` is defined and documented
  (`PluginScenePanelHost.gd:368-380`) but has **no production caller**: the only
  references in the tree are the helper itself, two tests
  (`src/test/test_plugin_scene_panel_host_hooks.gd`,
  `src/test/test_presentation_panel_note_hooks.gd`) and documentation. The
  `MultimodalPayload` type it names does not exist in `src/Scripts/`. Council
  implements the hook anyway — it costs nothing and needs no change when a
  caller appears — but v0.1 must not depend on it. See §5.
- **The 64 KiB `pluginIPC` cap is real but is not measured in bytes.**
  `const MAX_PAYLOAD_BYTES := 65536` at `PluginWebviewBroker.gd:42`, enforced at
  `:200-208` using `JSON.stringify(payload).length()` — UTF-16 code units, not
  bytes — and applied only to the *inbound request*. Replies, events and state
  pushes are uncapped. `PluginScenePanelBroker.gd:160` carries the same
  constant. Council therefore budgets `InlineLimit = 32768`, half the cap, so a
  payload plus its envelope fits under either interpretation.
- **`window.minerva.call()` is not brokered.** It `fetch`es
  `http://localhost:9315` directly from the page
  (`src/Scripts/UI/Controls/WebViewEditor/minerva_bridge.gd:13-41`,
  `cef_bridge.gd:19-26`) into the unauthenticated MCP HTTP server
  (`src/Scripts/Services/MCP/MinervaMCPHttpServer.gd:12`), bypassing the
  manifest allowlist and the capability policy. Council's page must never use
  it; the wrapper injects its own bridge and the page reaches nothing else.
- **`plugin_owned` save is unimplemented** — `Editor.gd:1714-1721` warns and
  writes nothing. Council uses `host_owned`.
- **`invoke_restore_from_note` is not awaited** (`src/Scripts/UI/Controls/Note.gd:733`), unlike
  `invoke_create_note` (`Editor.gd:2263`). Council's restore hook must be a
  plain function; a coroutine there would return a truthy state object and look
  like success.

---

## 2. The records

Five schemas, one record family.

| Schema | Record | What it is |
|---|---|---|
| `common.schema.json` | — | Id, Revision, ContentHash, Timestamp, MemberKind, ClaimSupport, PayloadRef, ArtifactRef |
| `council_definition.schema.json` | `council_definition` | The **portable** half: members, seats, sources, deliberation rules |
| `session.schema.json` | `council_session` | One question in one project: bindings, runs, contributions, outcomes |
| `project_snapshot.schema.json` | `council_project_snapshot` | The **authoritative** record: definitions + sessions + view state |
| `envelope.schema.json` | request / reply / event | Wire traffic between page, wrapper and backend |

### 2.1 Identity and revision, in full

"Owner" in this table means the **durable** owner: who is answerable for the
value surviving a restart. It is not who executes the write. The backend applies
every mutation, advances `snapshot_revision` and returns it; the wrapper
persists the snapshot that comes back and is otherwise a view (see §3).

| Identity | Owner | Advances when | Read by |
|---|---|---|---|
| `project_id` | the wrapper, minted by the engine on the document's first load | **never** — it is the document's identity | the chat router, and the reload rule that tells a reopened document apart from a different one |
| `snapshot_revision` | the wrapper (native panel) | any accepted mutation | every request's `base_revision`, every reply |
| `definition_id` + `definition_revision` | the wrapper | a council's members, seats, sources or rules change | exports; a session's embedded snapshot |
| `member_id` + `member_revision` | the wrapper | kind, attribution, scope, limitations or grounding change — `member.upsert` and `member.adopt_source` mint it, so a cosmetic rename does not | every contribution, so an old answer is never re-attributed |
| `source_id` + `source_revision` | the wrapper | new material is captured — never an edit in place; `source.capture` mints the next revision number | grounding refs and citations |
| `anchor_id` | the wrapper, within a source revision | never; a new capture gets new anchors | citations |
| `session_id` + `session_revision` | the wrapper | any change to that session | the panel view |
| `run_id` | the backend, echoed into the snapshot | never | contributions, outcomes |
| `request_id` | the *caller* (page or chat provider) | never | idempotency: a repeat returns the stored reply |
| `contribution_id` | the backend | never | outcomes, citations, follow-ups |
| `chat_id` | Minerva | never | the session's `chat_binding` |

**Separation of member from seat is structural, not conventional.** `members[]`
holds identity (who this is, what they are grounded in, what they cannot speak
to); `seats[]` binds one member to one responsibility in *this* council. The
same member record can be seated differently elsewhere, and renaming a
responsibility cannot rename a person.

### 2.2 Invariants the schemas cannot state

Enforced in `internal/contract/invariants.go` and exercised by the records
indexed in `fixtures/invalid/cases.json`, each of which fails for the one reason
that index names:

- A council has **exactly one chair**.
- Every seat names a member that exists; every grounding ref names a
  `source_id` at a `source_revision` that exists.
- Ids are unique within their scope; anchors are unique within a source
  revision.
- A captured payload still hashes to its `content_hash` and matches its
  `byte_length`; an anchor's `[start, end)` really contains its quote; and the
  `content_hash` **on the source** describes the payload it holds. The source
  carries the hash as well as the payload so that an inventory entry whose
  content did not travel still says which bytes it stood for.
- **A simulant is grounded, a functional advisor is not obliged to be.** Only a
  simulant may carry `represents`, and a simulant must carry grounding, a scope
  and its known gaps: interpreting a named author with nothing behind it is the
  one thing this record must not be able to say. A `human` member — the local
  user — carries neither grounding nor a model hint.
- A payload carries **exactly one** of `inline` or `blob_handle`, and `inline`
  only under `InlineLimit`.
- A `source` claim cites at least one anchor; an `inference` or `unknown` claim
  cites none — an interpretation can never be rendered as something a source
  said.
- Every citation resolves to an anchor in the session's embedded definition.
- A contribution's `member_revision` equals the revision that was actually
  consulted.
- `request_id` is unique across a session's runs.
- A `complete` run carries a synthesis; a `failed`, `cancelled` or `partial` run
  carries a visible `failure`.
- Outcomes reference a run that exists and a contribution within it.
- A mutating command carries `base_revision`; a read command does not.
- A failed reply carries an error; a successful one does not.
- **A session's status equals `DeriveSessionStatus(session)`** (§4.1). This is the
  invariant that makes the rest of the model deterministic: status is computed,
  never chosen, so a valid record loads unchanged and at the same revision. Only
  a document the engine had to rewrite — an interrupted run demoted on load —
  comes back at a new `snapshot_revision`, because two different documents must
  never claim the same one.

### 2.3 Versioned migration, and the durable project identity

A stored document is durable state in a user's project, so a build either
understands its shape or refuses it. `schema_version` is the declaration of that
shape and `internal/contract/migrate.go` is the ladder that carries an older
document up to the shape this build speaks. It runs inside `Store.Load` **before
validation**, because an older document is not expected to satisfy today's
schema — that is what makes it older.

Two kinds of step, and the difference is worth keeping:

- A **ladder step** moves a document from one `schema_version` to the next and
  exists forever once written. `v0 → v1` stamps an explicit `schema_version` onto
  the snapshot and onto every record nested in it, which is the shape Council
  wrote before the version field was part of the contract
  (`fixtures/migrations/snapshot_v0_pre_project_identity.json`).
- A **fixup** runs at the current version and fills in a field introduced without
  a version bump, where absence is unambiguous. Every fixup is idempotent, so a
  document that already has the value is left exactly as it is.

A document from a **newer** version is refused, not guessed at, at both ends:
the engine refuses to load it and the wrapper preserves it byte-for-byte rather
than opening it (`council_record.gd`).

The one fixup today mints **`project_id`**: the durable identity of one Council
document, random rather than derived, minted once and never changed. It is what
makes two other things decidable that the record could not decide before —

- which project owns a chat, after a plugin restart (§5.3.2); and
- whether a document being handed to the engine is the same document it is
  already holding, which is the reload rule in §4.3.

**A migration costs a revision**, exactly as a demotion does: the document that
comes out is not the document that went in, two documents must never claim one
revision, and the wrapper has to persist the migrated form. A document already
current migrates nothing and loads at its own revision, so reopening it does not
dirty the project.

**A copied document keeps its identity**, because the identity is in the bytes.
Two projects holding a file copy of one council are, to the engine, one
document; while they are identical that is harmless, and the wrapper's lease
rule in §4.3 is what stops them from being merged once they diverge — the
engine's descendancy test alone cannot tell a lagging copy from a reopen.

---

## 3. Who owns what

This is the table the acceptance criterion asks for. "Durable" means it
survives Minerva restarting.

| State | Owner | Where it lives | Durable | Rebuilt from |
|---|---|---|---|---|
| Council definitions, sessions, runs, contributions, outcomes, source captures — the durable record | **native wrapper**, which persists it but never edits it | `_snapshot` in the panel; written into the project by `vboxEditor.gd:494-499` as `__panel_state`, and to a `.mcouncil` file by `Editor.gd:1727` → `PluginScenePanelHost.save_file` (`PluginScenePanelHost.gd:239-254`) | yes | — it *is* the source |
| `snapshot_revision` | **plugin backend** — minted on each accepted mutation, and on a load that had to rewrite the record | the record, persisted by the wrapper | yes | — |
| The record while a session is open (mutations, derivations, validation) | **plugin backend** — the one engine, `session.Store` | backend process memory | **no** | seeded by `minerva_council_load_snapshot` from the wrapper's persisted record; read back with `minerva_council_export_snapshot` |
| The idempotency ledger (`request_id` → the reply already produced) | **plugin backend** | backend process memory, cleared by every `Load` | **no** | not rebuilt — it is scoped to one loaded record, so a replay can never return a reply produced against a different snapshot |
| In-flight model calls, per-member timers, cancellation tokens | **plugin backend** | backend process memory | **no** | not rebuilt: an interrupted run is demoted, never resumed (§4.3) |
| Rendered roster, open pane, scroll position, in-progress typing | **page (CEF)** | JS heap | no | re-read via `snapshot.get` |
| Last selected session / pane | native wrapper | `snapshot.view` | yes | defaults if absent |
| User/chair transcript | **Minerva chat** | the native chat history | yes | referenced by `chat_binding`, never copied |
| Retained conclusions | **Minerva notes** | native notes | yes | referenced by `outcome.note` |
| Panel reopen payload | Minerva notes | a `plugin_data` note's `linked_plugin_payload` (`Note.gd:339-368`) | yes | the snapshot it was made from |
| Source material larger than `InlineLimit` | host blob store | `(editor_name, "blob-N")`, referenced by `blob_handle` | yes, with the document | — |

The seeding path is the seam between the two halves and is worth naming
explicitly: the wrapper holds the durable record, the backend holds the engine,
and `minerva_council_load_snapshot` / `minerva_council_export_snapshot` move the
record between them. A backend restart loses nothing durable, because everything
it held was either already in the record or was in-flight work that §4.3 refuses
to resume.

Four rules follow, and they are the ones that keep the model honest:

1. **The page is a view.** It never holds state that is not in the record or
   in flight. A page reload loses nothing.
2. **The wrapper is a store, not an engine.** It persists and re-serves the
   record; it does not edit one, derive a status, or mint a revision.
3. **The backend is the only engine, and it is not durable.** Anything it holds
   that must outlive the process has already gone back into the record.
4. **Nothing is shown as saved before it is in the record.** The backend
   applies a mutation, advances `snapshot_revision` and replies; the wrapper
   persists the snapshot it gets back and emits `content_changed` (which marks
   the tab dirty: `Editor.gd:323-324` connects it to `_on_editor_changed`, which sets `_plugin_scene_modified` at `Editor.gd:2068-2069`). The reply carries the new revision,
   which is what the page renders.

### 3.1 Why `__panel_state` and not `project_state`

Minerva has two project-persistence lanes. The `project_state` capability with
`project_file: {serialize_channel, deserialize_channel}` routes through the
backend over MCP. The other lane is unconditional: `vboxEditor.gd:494-499` calls
`panel_root._on_panel_save_request()` **directly** and stores the result under
`tab_state["__panel_state"]`, in all three of its paths — no MCP channel, plugin
dead, or MCP success. Restore mirrors it at `vboxEditor.gd:757-784`, calling
`_on_panel_load_request(panel_state)` **before** any MCP dispatch.

Council v0.1 uses the unconditional lane only. It works when the backend is
stopped or crashed, which is exactly when a user most needs their council to
still be there, and it removes a whole class of failure from the persistence
path. `project_state` remains available if a later version needs the backend to
participate in project save.

---

## 4. State machines

### 4.1 Session — derived, never set

A session's status is a **function of its run set and of nothing else**. No code
path assigns it; `contract.DeriveSessionStatus` computes it, and
`checkSession` asserts that a stored record agrees. That makes the derivation
the single oracle rather than a convention several writers each interpret.

| Run set | Status |
|---|---|
| no runs | `draft` |
| any run `pending` or `running` | `running` |
| otherwise the **last** run is `complete` | `complete` |
| otherwise the last run is `cancelled` | `cancelled` |
| otherwise the last run is `partial` | `partial` |
| otherwise the last run is `failed` **with contributions** | `partial` — members were dispatched, so some work exists |
| otherwise the last run is `failed` with none | `failed` — the round never started |

The last run decides because that is the state the user is looking at. An
earlier cancelled round does not keep a session cancelled once a later round has
answered.

`complete`, `partial`, `cancelled` and `failed` are all resting states from
which a new run moves the session back to `running` — again by derivation, not
by assignment. Reopening a session never changes its status by itself, with the
one exception in §4.3, and that exception works by changing *runs*.

### 4.2 Run and contribution

```
run:          pending ──► running ──► complete | partial | cancelled | failed
contribution: pending ──► running ──► complete | failed | cancelled | stale
```

`stale` is the state for a reply that arrives after its run has left `running`.
It is recorded with full attribution and **never applied**: it cannot change a
newer run, a newer revision, or another project.

### 4.3 The interruption rule

A run left in `pending` or `running` when the panel closed, the plugin stopped,
or Minerva exited is **not resumed**. The process that owned those model calls is
gone.

`contract.RehydrateOnLoad`, called by `session.Store.Load`, demotes the run and
its unfinished contributions to `failed` with `code: "interrupted"`,
`retryable: true`, and then re-derives the session status per §4.1. The user sees
a visible failure with an explicit retry; nothing spends tokens on its own.
Applying the rule twice changes nothing.

**There is one engine and it is the backend.** The wrapper does not demote, does
not re-derive, and does not mint revisions — a second implementation of this rule
in the panel would be a second engine free to disagree with the first. The
wrapper persists what `Load` returns.

**The panel closing is not the same as the process ending.** When the tab goes
away but the backend keeps running, the contributions that land afterwards are in
the engine and **nowhere else** — the wrapper was not there to persist them. On
reopen the panel hands back the record as it stood *before* the round, and taking
it would throw that work away.

This is the wrapper's **seeding** path and not loading in general, so it is a
mode on the tool rather than a change to what loading means:
`minerva_council_load_snapshot` takes `mode: "replace"` (the default — hold
exactly this document, stop whatever is running) and `mode: "reopen"`, which the
panel sends because a seed *is* a panel coming back to its own record. In reopen
mode the engine keeps what it is already holding when all of these are
true, and replaces it otherwise:

1. the resident document has the **same `project_id`** as the incoming one;
2. its `snapshot_revision` is **at least as high** — equal counts, because a
   panel can persist the revision `run.start` minted and close before the first
   contribution commits one of its own; and
3. every session and run the incoming record names is **still present** in it; and
4. at **equal revision**, the entire snapshot content is identical. Different
   content at the same revision is a replacement, even when all IDs match.

The third is a history compatibility check, not proof of ancestry. It detects
missing sessions or runs. The fourth prevents silently discarding edits to a
copy that retained its revision. Older copies remain subject to the policy below.

**The residual, stated honestly: a LAGGING file copy is indistinguishable from
the same document reopened.** Copy a `.mcouncil` into a second project, work in
the original until it is at revision 20 with sessions the copy never saw, then
open the copy in the same backend process: everything the copy names is still in
the original, so the descendancy test passes and the copy would be handed the
original's content. The identity is in the bytes and a copy carries it, so no
test on the documents alone can separate the two.

What separates them is the WRAPPER, which knows something the engine does not:
whether this panel is coming back to a document nobody else has, or joining one
another panel is already working in. `_ensure_seeded` therefore sends
`mode: "reopen"` **only when the lease holder is empty** — nobody's record is in
the engine, which is what an unmount, a tab close or a backend restart leaves —
and `mode: "replace"` whenever another panel is the holder. Recovery is then
scoped to exactly the case it exists for, and two panels open at once can never
merge, whatever their documents' identities say.

Two panels showing two projects are unaffected for the same reason twice over:
their identities differ, and the second panel's seed is a `replace`.

**A rewrite costs a revision.** Demotion produces a document that is not the one
handed in, so `Load` increments `snapshot_revision` when it demoted anything, and
likewise when a migration rewrote it (§2.3).
Two different documents must never claim the same revision, and the wrapper has
to persist the demoted form rather than the one it sent. The corollary is the
useful half: a valid record loads **unchanged and at the same revision**, because
with the derivation invariant in force there is nothing left to fix.

---

## 5. Concrete APIs

### 5.1 Panel lifecycle — the hooks Council implements

All are duck-typed with `has_method` by `PluginScenePanelHost`; the signatures
are exact.

| Hook | Council's contract | Error case |
|---|---|---|
| `_on_panel_loaded(ctx: Dictionary) -> void` | mounts the CEF surface from `ctx.data_directory`; `ctx` shape at `PluginScenePanelHost._build_ctx`, `PluginScenePanelHost.gd:677-715` | `CefTexture` missing, page file missing, `user://` unwritable → an explanatory label, never a blank panel |
| `_on_panel_save_request() -> Dictionary` | returns the held record verbatim, or `{"_bytes": …}` for a document Council could not read | none: it cannot fail. A non-Dictionary return is refused by the host at `PluginScenePanelHost.gd:244-245`, which is also where `_bytes` is written verbatim (`:246-250`) rather than re-serialised (`:254`). The same dictionary feeds two writes — the tab's file and the project's `__panel_state` — so it has to be right for both |
| `_on_panel_load_request(document) -> void` | strips the host's `file_path` / `raw_text` keys, checks `record_kind` + `schema_version`, replaces the record, tells the page to re-read. Does **not** demote or re-derive — the engine does that on `Load` (§4.3) | the file-open path passes `{"file_path": path}` merged with the parsed JSON, or `raw_text` for a non-JSON file (`Editor.gd:1291-1299`). An empty document opens an empty council. An unrecognised one — not JSON, not a council, or a newer schema — is **kept byte-for-byte** and handed back on save, with the panel saying why it will not edit it; it is never replaced by an empty council and never half-recognised |
| `_on_panel_create_note_request(ctx) -> Dictionary` | `{kind: "plugin_data", plugin_id, panel_name, payload: <snapshot>, preview_alt_text: <one line>}`; accepted shapes at `Editor.gd:2278-2323` (`_build_note_from_plugin_payload`), the `plugin_data` branch at `:2298-2311` | omitting the hook degrades to a screenshot note (`Editor.gd:2262`). The host backfills a missing preview image (`Editor.gd:2239-2251`) |
| `_on_panel_restore_from_note(payload: Dictionary) -> bool` | `false` unless `record_kind == "council_project_snapshot"` and `schema_version == 1` | `false` → the host toasts and leaves the panel blank (`src/Scripts/UI/Controls/Note.gd:733`). Must not be a coroutine |
| `_on_panel_render_for_llm(ctx) -> Array` | one `{"type":"text","text":…}` part | **no production caller today** — implemented for the day there is one |
| `receive(channel: String, payload: Dictionary) -> void` | raw event name, or the literal `"state"` | unknown channel → forwarded to the page as an event; the page re-reads |
| `_on_panel_unload() -> void` | disconnects `ipc_message`, removes the staged page file, gives up the backend lease (§5.5) | none |
| `signal request(channel, payload, reply_id)` | the backend hop, via `PluginScenePanelBroker.handle_scene_request` (`PluginScenePanelBroker.gd:740`) | channel not in `ui.ipc_messages` → refused by the broker |

### 5.2 Page ↔ wrapper protocol

Council injects **its own** bridge, not `window.minerva`. The host bridge exists
to serve the webview broker, which a scene panel does not use; owning the bridge
is also what lets the envelope carry `base_revision` and `request_id`, which the
host bridge has no notion of.

```js
council.call(command, payload, baseRevision) -> Promise<Reply>
council.onEvent(cb)
```

Envelope shapes are in `envelope.schema.json`. Rules:

- Mutating commands (`definition.upsert`, `definition.import`, `source.upsert`,
  `source.capture`, `member.upsert`, `member.adopt_source`, `session.create`,
  `session.bind_chat`, `run.start`, `run.cancel`, `run.retry`,
  `outcome.retain`) **must** carry `base_revision`; read commands
  (`snapshot.get`, `source.fetch`, `definition.export`) must not.
- `base_revision != snapshot_revision` → `ok: false`, error `stale_revision`,
  `retryable: true`, and the reply carries the current revision so the page can
  re-read.
- A repeated `request_id` returns the stored reply with `replayed: true`. The
  command is applied once. The ledger holding those replies lives in the backend
  and is cleared by every `Load`, so a replay can never return a reply produced
  against a different record.
- Every reply carries the `snapshot_revision` it was produced against.
- An event never carries authority. It says the record moved; the page re-reads
  what it needs.
- A message over `InlineLimit` (32768 UTF-16 code units) is **refused with a
  `payload_too_large` reply**, not dropped. A dropped message leaves the page's
  Promise pending forever, which is indistinguishable from a hung panel.
- The wrapper answers `snapshot.get` from the record it holds — that record is
  the durable one, and a council must still be readable when the backend is
  stopped — and relays every other schema command. It applies none of them:
  `base_revision` checking, mutation, derivation and revision minting all belong
  to the one engine in the backend (§3). After an accepted mutation the wrapper
  reads the acknowledged snapshot back with `minerva_council_export_snapshot`
  and persists that, because a command reply carries its own payload and not the
  record.
- Commands named `wrapper.*` are the wrapper's own and never reach the engine.
  They touch the host rather than the record: `wrapper.describe` (panel identity,
  theme, and whether the open document is one Council can edit),
  `wrapper.set_view` (the user's selected session and pane — the one field the
  wrapper writes, which advances no revision because no engine derives anything
  from it), `wrapper.chat_handoff` (§5.3), `wrapper.models` (Minerva's enabled
  providers and models, relayed to the backend's `minerva_council_models` tool
  without taking the store lease, because the catalogue is the host's state and
  no snapshot is touched), and `wrapper.get_preferences` /
  `wrapper.set_preference` (Council's own view preferences — today the reader's
  text size; `wrapper.describe` also carries the list of sizes the wrapper will
  store, so the page offers only sizes both sides know rather than keeping a
  second list that can drift). The preferences are stored beside the panel in
  `user://council_ui_preferences.json` and deliberately NOT in the record: a
  reader's chosen text size is not project data, must not advance a revision or
  travel in an exported council, and `ViewState` is closed to
  `selected_session_id`, `selected_definition_id` and `pane` in any case.
- A document the wrapper does not recognise is **kept, not replaced**. Its bytes
  are handed straight back on save — under the host's `_bytes` raw-write key for
  the file, and as a base64 sibling for the project, because `__panel_state`
  goes through `JSON.stringify`, which turns a `PackedByteArray` into a quoted
  string of its `str()` form and not into bytes. The panel says in words why it
  will not edit the document, and every command that would change a council is
  refused while it is open. The alternative — opening an
  empty council over an unrecognised file — destroys that file on the next
  Ctrl+S, because the same hook feeds the file write and the project's
  `__panel_state`.
- The page announces itself with an `envelope: "ready"` message as soon as its
  bridge exists (the `Ready` variant in `envelope.schema.json`); anything the
  wrapper would push before that is queued. An
  `eval` into a document that has no `window.council` yet is simply lost, and a
  lost event looks exactly like a panel that never updates.

Error codes are the `Failure.code` enum in `session.schema.json`:
`model_unavailable`, `model_error`, `timeout`, `cancelled`, `interrupted`,
`missing_source`, `missing_chat`, `stale_revision`, `payload_too_large`,
`internal`.

### 5.3 Chat handoff — and why no routing by active tab

Council registers a chat provider through the capability
`host.chat_providers.register`
(`src/Scripts/Services/Plugins/CapabilityBroker.gd:3544`). The registration is
validated at `:3549-3578`: `entry_id`, `display_name` and `generate_tool` are
required, `history_mode ∈ {newest_only, full}`, and `generate_tool` /
`cancel_tool` must start with `minerva_council_`. The entry is keyed
`plugin:council:<entry_id>`
(`src/Scripts/Services/Plugins/PluginChatProviderRegistry.gd:39`) with a default
timeout of 600 s (`:32`).

The host then calls Council's `generate_tool` with, from
`src/Scripts/Services/Providers/PluginProvider.gd:106-113`:

```
{ "chat_id": <owning history id>, "text": <newest user text>, "entry_id": <entry> }
+ "messages": <full prompt array>   // only when history_mode == "full"
```

**`chat_id` is the binding.** It arrives in the call, it is written into
`session.chat_binding.chat_id`, and every later reply for that session goes
there. Council never asks which tab is focused, and there is no code path in
which it could: the identity is a parameter, not an ambient.

The reply Council returns is mapped at `PluginProvider.gd:194-238`:

| Council returns | Effect |
|---|---|
| `{kind:"answer", text}` | the chair's synthesis becomes the assistant message |
| `{kind:"question", text, options:[{label, keystroke}]}` | a choice is offered in chat |
| `{kind:"error", text}` | `bot.error`, shown as a failure |
| any other `kind` | the host reports an unrecognised reply kind |

`prompt_tokens` / `completion_tokens` are copied through if present.

**Cancellation.** `PluginProvider.cancel_active_resquests()` (`:270` — the
misspelling is the host's, and overriding it requires matching it) resolves the
awaiting `generate_content` immediately with `"Request cancelled."` and *then*
fire-and-forgets `cancel_tool` with `{"chat_id": …}` (`:286`) without awaiting
the acknowledgement. Consequences Council must design for, and does:

- The chat gives up before Council knows. Council's own run is only cancelled
  when `cancel_tool` arrives, so the run must be cancellable by `run_id` and
  must reach a resting state on its own timeout regardless.
- A member reply landing after cancellation is recorded `stale` and never
  applied.
- A stale generation is already neutralised host-side by the `_call_generation`
  token (`PluginProvider.gd:81-83`, `:177-186`), so a late Council reply cannot
  overwrite a newer chat turn.

**Sending a selection from the panel to that chat** is the `wrapper.chat_handoff`
operation (§5.2). It reads `chat_id` from the session's own `chat_binding` in the
record, refuses with `missing_chat` when there is none, and delivers the text
through `capability:mcp.proxy:minerva_send_message`, whose `chat_id` is a
parameter — there is no host call in this path that could learn which tab is
focused, and no fallback that would guess. Sending starts a turn in that chat, so
it is always a user action. The text is built by the same derivation
`_on_panel_render_for_llm` uses, so what the user sends and what a provider reads
can never be two different summaries.

The other direction — bringing a question and selected context *to* Council from
elsewhere — is an MCP tool on Council's backend taking an explicit `session_id`
(or creating one and returning it). Never an implicit destination.

#### 5.3.1 What the registration actually is (implemented)

One entry, registered at every process start:

| field | value | why |
|---|---|---|
| `entry_id` | `council` | the key `plugin:council:council` is what a chat remembers across a restart (`ServiceHistory.gd:361-371`) |
| `display_name` | `Council` | what the chooser shows (`ProviderOptionButton.gd:366-381`) |
| `generate_tool` | `minerva_council_chat_generate` | must carry the plugin's own prefix |
| `cancel_tool` | `minerva_council_chat_cancel` | same rule |
| `history_mode` | `newest_only` | Council's own record is the transcript; a second unversioned copy of the chat is not something a citation could point at |
| `timeout_sec` | `120` | the registry default is 600 (`PluginChatProviderRegistry.gd:32`); 120 keeps a Council turn on the same budget as every other tool call |

Registration happens after the host's `initialize`, on its own goroutine, so the
handshake reply is not held behind two host round trips. It is idempotent on
`(plugin_id, entry_id)` and replaces the prior entry in place
(`PluginChatProviderRegistry.gd:58-59`), which is the whole of "re-registers on
restart" — there is no second mechanism.

**Registration goes first, and the catalogue read never shares its deadline.**
The catalogue is 1 + N host round trips (§5.3.3); registration is one. On a
single budget a host slow to enumerate models would spend it before
registration was attempted, and the failure would be Council never appearing in
the chooser — invisible, because there is nothing to select and no error to
read. Reading the catalogue second costs something much smaller and it says so
out loud: a turn taken in the window before it lands has no list to check a
hint against, so the hint travels unchecked and an absent one falls back to the
host's default route. Neither call's failure stops the other. Cleanup on stop is already the host's:
`plugin_stopped` and `plugin_crashed` are connected to `drop_plugin`
(`src/Scripts/Services/Plugins/PluginManager.gd:220-221`). Council additionally
withdraws on an orderly `shutdown`, bounded to two seconds so a host that has
stopped listening costs the exit a moment and no more.

A turn holds its reply for at most **90 s**, comfortably under the declared
120. A round that outruns it keeps going and the chat gets an `answer` saying
so and naming where to watch it — never a silent timeout, and never an `error`
for work that has not failed.

#### 5.3.2 chat_id → session, and the cross-project refusal

The durable binding is the session's own `chat_binding.chat_id`, in the project
snapshot. Resolution is: scan the loaded document's sessions for that chat.

- **Found** → this turn is a `follow_up` run on that session.
- **Not found, and Council has never routed this chat** → it is new; a session
  is opened here, `question` = the user's text, `chat_id` = the binding.
- **Not found, but Council has routed this chat into another project** →
  *refused*. That chat belongs to a session in a document that is not the one
  open, and opening a fresh one here would write project A's consultation into
  project B's record.

The third case cannot be decided from the loaded document alone — the snapshot
in front of the engine cannot distinguish "a chat from another project" from "a
chat nobody has used yet" — so it is decided from **project identity**.

`project_snapshot.project_id` is minted once, when a document is first loaded by
a build that has the field, and never changes (§2.3). Every `chat_binding`
stamps the project it was made in. Two things follow:

- `Store.adoptChatRoutes` rebuilds `Store.chatProject` — chat → owning project —
  from the bindings of **every document the process loads**. The guard is
  therefore *recovered from the record* rather than remembered across a restart:
  as soon as project A's document has been opened once, a chat bound in it is
  refused everywhere else, in that process or any later one.
- A binding whose `project_id` is not the loaded document's belongs to a session
  that was imported or copied in from elsewhere. Its chat is that project's, and
  `sessionForChat` refuses it here rather than continuing somebody else's
  consultation into this record.

The refusal names the owning project, because "this chat belongs somewhere else"
without saying where is not something a user can act on.

**The residual limit, stated plainly.** The evidence is durable but it still has
to be *read*: a chat whose owning document has not been opened at all since the
plugin started is a chat this process has never seen any binding for, and the
first turn on it opens a fresh session in whatever document is loaded. Nothing
is corrupted — project A's session is untouched and keeps its own binding — but
the chat has moved projects. Closing that last gap needs Council to ask the host
which project a chat belongs to, which is a host capability that does not exist;
it is tracked rather than guessed at. The bound on the table
(`pruneChatRoutes`, 4096 chats, other projects evicted first) degrades one chat
to exactly this same state, and the next load of the owning document puts it
back.

**One chat, one session.** The provider routes by `chat_id` alone, so a chat_id
appearing on two sessions has no correct resolution — whichever the resolver
reached would be array order deciding where a user's follow-up lands.
`session.bind_chat` therefore *moves* the binding: it removes `chat_binding`
from any other session carrying that id (naming them in
`released_session_ids`), and `checkSnapshot` refuses a document where two
sessions share one. `chat_binding` is consequently **optional** in
`session.schema.json`: a session a chat was moved away from keeps its question,
its runs and its outcomes and simply has no chat until somebody gives it one.
Relaxing the requirement is backward compatible — every session written before
this still validates — and it replaced the invalid fixture
`session_without_chat_binding.json` with `snapshot_two_sessions_one_chat.json`,
which is the rule that actually matters, and with
`session_malformed_chat_binding.json`, which holds the *shape* of a binding to
the contract now that its presence is optional: a binding that is there at all
carries a `chat_id` and a `bound_at` and nothing else.

Which council a new session runs is the user's choice, made explicitly: the one
council the project holds, otherwise a `question` envelope offering each by
name. The host does not report which label was clicked — it sends the option's
**keystroke** as an ordinary user turn on that chat
(`ChatPane.gd:2380-2391`, `:2399-2406`) — so each option's keystroke carries the
whole choice as `/council <definition_id>`, and the question the user already
typed is remembered against the chat so they never type it twice.
`/council-session <session_id>` is the same mechanism for binding a chat to a
consultation that already exists.

Cancellation arrives carrying only `chat_id`, so the backend keeps the run each
chat last started and cancels that. A cancel for a chat with nothing running,
or for a round that already stopped, is a success that moves nothing.

**One round at a time per chat.** A round can outlive the 90 s reply, and the
host then hands the user their prompt back with no idea anything is still in
flight — so a user who asks again would otherwise buy a second full bench over
the same question and get two syntheses of it. While the chat's session holds a
run that is `pending` or `running`, a turn dispatches `run.await`, not
`run.start`: it reports the running round and says plainly that the new question
was **not** asked and should be asked again once this one lands.

**Both of those read the RECORD, not a remembered handle**, and that is load
bearing rather than tidy. An earlier draft kept the run id in process memory,
written by the turn that started the round — which meant it was written when
`run.start` *returned*, after its bounded wait of up to 90 s. For the whole
duration of the round there was nothing recorded to find, and that window is
exactly when the host's `cancel_tool` arrives and exactly when an impatient user
types again: cancel found nothing and did nothing, and a second turn started a
second round. The snapshot holds the run from the instant `run.start`'s mutation
commits, under the same lock every other reader takes, so there is no window
once the run exists. Two protocol tests hold a round open on a gated model call
and assert both behaviours against it.

One residual, and it is narrow: `session.create` and `run.start` are two
commits, so a cancel landing between them finds no run and truthfully answers
"nothing was running" while the round then starts uncancelled. The user's next
turn hits the await path and reports it rather than spending again, and stopping
that turn cancels it — so the cost is one round the user asked to stop and got
anyway, not a runaway. Closing it properly means creating the session and its
first run in one mutation.

Ownership, session and live round are resolved together in `routeChat`, under
one lock and in that order, because the order is the correctness property: a
foreign chat must be refused before anything asks whether its session has a
round going. `ChatTurnFor` and `ChatCancelFor` share the one rule, and a cancel
for another project's chat is answered as "nothing was running" — another
project's round is emphatically not ours to end.

A run that has reached any resting state is not live, so the next question
starts a round of its own and a late cancel truthfully answers "nothing was
running". A document replaced by `Load` takes its runs with it, and
`RehydrateOnLoad` demotes anything left in flight, so neither a project switch
nor a crashed process can wedge a chat behind a round that will never finish.

**Choosing a council is refused rather than guessed.** `/council <id>` naming a
council the open document does not hold is an error: falling through to "the
only council there is" would consult a different bench and present its answer as
the one the user chose. A council *remembered* from an earlier turn that has
since gone is not an error — the user did not name it this turn — and falls
through to the ordinary choice. Option labels are made distinct, because
ChatPane keys its buttons by label and keeps only the first of a repeated one
(`ChatPane.gd:2322-2324`): two councils sharing a name would render as one
button with the other unreachable, so a repeated name carries its
`definition_id` and an unnamed council is shown by id.

Every chat-driven step is an ordinary protocol command run through `Dispatch` —
`session.create`, `run.start`, `run.cancel`, `session.bind_chat`. A chat turn
therefore gets the same schema validation, idempotency ledger, revision check
and bounded waiting as a turn driven from the panel, and there is one engine
rather than two. A chat turn pins its commands to the document load generation;
revision retries cannot cross a document replacement. Cancellation marks active
turn scopes as well as cancelling committed runs, so it also stops setup before
`run.start`. The dispatcher checks for an already-live round under its mutation
lock to prevent overlapping turns from starting duplicate consultations.

### 5.3.3 Model choice is explicit, never the host's default route

`member.model_hint` and `run.start`'s `model_overrides` used to be free strings
resolved at call time, with an empty one becoming the literal `"default"`. That
is not safe: the broker resolves `"default"` to the TurnRock/Core provider
(`CapabilityBroker.gd:2354-2361`), which is constructible with no service and no
action — a degraded instance the chat picker itself refuses
(`ChatPane.gd:5244-5253`).

So the backend reads the host's own catalogue at startup, on every
`minerva_council_load_snapshot`, and on demand through
`minerva_council_models`: `host.models.list_providers` answers
`{providers:[{key, display}]}` and `host.models.list_models` answers
`{provider, models:[{model_name, display}]}`
(`CapabilityBroker.gd:565-576`, `singleton_object.gd:2058-2091`). Each grant is
declared separately in `permissions.host_capabilities`; the policy gate refuses
an undeclared capability before dispatch (`CapabilityBroker.gd:271-285`, with
`:286-293` refusing everything when there is no policy engine at all), and
`host.chat_providers.unregister` is gated on the **register** grant rather than
one of its own (`CapabilityBroker.gd:261-267`).

Two strings come out of that and they are not interchangeable.
`host.providers.chat` matches its `model` argument against each enabled model's
`model_name` (`CapabilityBroker.gd:2402-2416`); when two providers offer the
same name it disambiguates with `provider`, compared against the provider's
**display** name lowercased (`:2427-2432`) — *not* the `key` that
`list_providers` returns beside it. Council carries both, so a call can be aimed
unambiguously.

One gap in the catalogue is worth knowing about, and it is the host's:
`host.models.list_models` enumerates the **dynamic** provider map alone
(`singleton_object.gd:2079-2091`), while `host.providers.chat` also matches the
**static built-in** models (`CapabilityBroker.gd:2374-2392`). A built-in the
user has enabled is therefore callable but absent from the list, and Council's
check refuses a hint naming it. The refusal names the models Council *can* see,
so the user is told what to pick rather than left guessing — but it is a
refusal of something that would have worked.

With a catalogue in hand: `member.upsert` refuses a hint the host does not have,
`run.start` and `run.retry` refuse an override or a seat hint before the run
record exists, and a call with no hint at all asks for the catalogue's first
model — deterministic, because the catalogue is sorted, and visible, because
`contribution.model_id` records what actually answered. With **no** catalogue —
an older host, a missing grant, a call that failed — a hint travels unchecked
and an empty one still becomes `"default"`: absence of the list is not evidence
that a model is missing, and refusing every council because Council could not
ask would be worse than the risk it avoids.

### 5.4 Retaining an outcome as a note

Two notes, two jobs, and the distinction matters:

- **The outcome note** is a normal text note holding the conclusion and its
  provenance. It is what the user keeps and what reaches a later chat turn as
  text. `outcome.note` points at it. When that note cannot be resolved — moved,
  deleted, or in a project that is not open — `outcome.mark_missing` sets
  `note.missing` and the reference is **kept**: dropping it would lose the only
  link between a conclusion the user kept and the contribution it came from, and
  the note coming back clears the flag. Resolving the note is the wrapper's job,
  because it is the only side that can ask the host; the command carries the
  answer rather than deriving it.
- **The reopen note** is the `plugin_data` note produced by
  `_on_panel_create_note_request`. Its purpose is to reopen the panel
  (`Note.gd:684-733`).

The split exists because of a measured limitation: a `plugin_data` note is built
with `NoteImageControls` (`Note.gd:349`, `:358`), so what a provider sees is the
preview image plus a **single-line caption** (`image_controls.gd:64`; the
caption reaches a prompt via the image-caption path, e.g.
`GoogleProvider.gd:305-312`). That is enough to say *which* council session this
is, and nowhere near enough for a deliberation. Council therefore puts the
substance in a text note and uses the caption to identify the session.

If Minerva later wires `invoke_render_for_llm` into the chat-injection path,
Council's existing hook supplies the full text with no plugin change.

### 5.5 Two panels, one backend store

One plugin process serves every open Council tab, and its engine holds exactly
one working snapshot (`Store.snapshot`, replaced wholesale by `Load`). Two
panels showing two projects therefore share it, and nothing in the backend can
tell them apart — the durable record lives in the panel, not in the backend.

So a panel may only speak to the engine while the engine is loaded with *that*
panel's record. One exchange is: take the process-wide lease, seed the engine
with this panel's record if it is not already the holder, send the command, read
the acknowledged snapshot back, release. The lease makes an exchange atomic
against every other panel; the seed makes "the engine holds my record" a fact
rather than a hope.

Four things give the claim up, and each of them is a way it could otherwise
become a fiction:

- **A failed exchange** clears the holder, so the next one re-seeds instead of
  trusting a working copy nobody can name.
- **A refusal produced against a revision that is not the one we seeded** does
  too. The backend can restart underneath a mounted panel — `auto_reload`
  rebuilds the binary and the host restarts the process while every tab stays
  open — leaving the engine with an empty store and the panel still named as its
  holder. Without this the seed is skipped forever, mutations loop on
  `stale_revision`, and relayed reads answer from an empty council.
- **Adopting a different document** — a file opened, a project restored, a note
  reopened — because the engine is still holding the one this panel had a moment
  ago, and the holder still names this panel. This forgets the *seed* only and
  leaves the lease alone: the host's own restore order runs the file load and its
  rehydrate first and the project restore a frame later, so this fires while the
  panel's own exchange is very often still in flight, and releasing there would
  hand a running exchange's lease to somebody else. The exchange in flight is
  handled instead by a **document epoch**: it captures the epoch before its await
  and, if a load moved it, reports `stale_revision` rather than adopting a
  snapshot of the document that has just been replaced.
- **Unloading**, which also *releases*, because a queued exchange must not wait
  on a tab that no longer exists.

Only the holder may release: an exchange that resumes after its claim was taken
over must not clear or hand off somebody else's lease. And a lease whose taker is
a panel the host no longer has registered — a tab closed mid-exchange abandons
that coroutine, so its release never runs — is reclaimed by the next exchange
rather than waited behind forever.

The lease is one object per process, held in engine-level metadata rather than a
`static var`: a static lives on the script resource, and a plugin hot reload
replaces that resource while panels mounted before it keep the old one — two
scripts, two sets of statics, two panels each certain the engine is theirs.

**Size is measured where it is enforced.** The host caps a scene request at
`JSON.stringify(payload).length()` of the whole argument dictionary
(`PluginScenePanelBroker.gd:883`), which includes the keys the wrapper wraps a
snapshot or an envelope in. A record that fits 65536 on its own can fail once it
is inside `{"snapshot": …}`, so the wrapper measures the message that will
actually travel and refuses it with `payload_too_large` — a refusal the page can
render, rather than a message the broker drops.

### 5.6 The round engine, and the one call it makes

**How Council reaches a model.** The backend writes a JSON-RPC *request* to its
own stdout — `{"method": "minerva/capability", "id": …, "params": {"capability":
"host.providers.chat", "args": {…}}}` — and the host answers on its stdin,
correlated by `id`. The JSON-RPC `result` holds a second envelope,
`{"success": true, "result": {…}}` on success and a flat
`{"success": false, "error_code", "error_message"}` on refusal. The grant is
`permissions.host_capabilities: ["host.providers.chat"]` in the manifest.
`hostchat.go` is the whole of that transport, and `session.ChatHost` is the one
method the engine sees through it, which is what lets a deterministic fake stand
in for a live model in tests without standing in for anything else.

**One reader, routing by shape.** `serve` starts the single goroutine that reads
stdin for the life of the process and classifies each line the only way JSON-RPC
allows: a message carrying a `method` is a request and goes to the protocol
loop; one carrying an `id` and no method is a response and goes to whichever
capability exchange is waiting on that id. Two readers on one `bufio.Reader`
would each swallow bytes the other was waiting for, and a handler that read
stdin directly would swallow the very requests it is meant to leave room for.
All writing goes through one `stdoutWriter` with one lock, because several
replies are now in flight and two encoders interleaving would emit lines that
are not messages.

An exchange registers a channel under its id before it writes, so it can be
**abandoned**: waiting on a channel can be given up when a member's context
expires, and waiting on a `Read` cannot. Giving up costs nothing — the entry is
removed, and a reply that arrives afterwards finds nothing waiting and is
dropped by the reader. There is no desynced state to recover from, because
nothing was ever swallowed.

**Several requests at once, deliberately.** The host runs any number of requests
in flight; panel IPC, MCP tool dispatch and a provider's cancel are independent
coroutines, and the host's own stdout drain already routes capability replies by
id. Council matches that on both sides. Each `tools/call` handler runs on its own
goroutine, so a read, a `run.await` or a `run.cancel` is answered while a round
is running — answering them in order would mean answering none of them until the
round finished. And exchanges do not serialise, so a round may run as many
concurrent calls as `max_concurrent_members` allows.

An adapter that can carry fewer is expected to say so through
`session.ConcurrencyLimiter`, and the engine clamps its own semaphore to it.
That is not a nicety: a member's timeout is armed when it takes a semaphore
slot, so one left queueing inside an adapter would spend its whole allowance
waiting and expire without ever having been asked.

**Bounded replies.** The host gives a tool call 120 seconds by default, so a
reply held past that is a reply nobody receives. `run.start` and `run.retry`
therefore set the round going and answer within the envelope's `wait_seconds`
(1–90, default 20, schema-validated) with the run's id and its status so far; a
round that outruns the wait keeps going on its own goroutine and the caller
reads it with `run.await` — bounded by the same field, so there is one answer to
"how long may the backend hold a reply" rather than two that can drift.

**Where a round runs.** `run.start` and `run.retry` create the pending run under
the engine lock, hand it to a background goroutine, and wait for it with the
lock **released**. Nothing else would work: a round that held the lock would
make every read and every cancel wait on a model, however concurrent the
protocol loop was. The mechanism is one field on the command table, `after`, and
it is the only place in the engine where a command has a second stage.

**What a member is sent.** `prompt.go` is the only builder, and it is never
handed another member's answer on an initial call — that is how
`independent_initial_round` is enforced rather than promised. A member gets the
question, the session's context snapshot, and the source revisions **its own**
`grounding` pins, with the anchor ids it may cite. A follow-up adds the focused
prompt and, when it names a claim, that claim — which is always this member's
own, because a follow-up about an argument is routed to whoever made it. Only
the chair sees the bench.

A seat held by a `human` member is never consulted: nothing prompts the local
user, and their view reaches a council as context or as a captured source.

**What comes back.** Members answer in a small JSON shape; a reply that is not
in it is still kept as the answer with no claims. A `source` claim keeps only
the citations that resolve inside the grounding sections actually sent to that member, and a claim left
with none becomes `unknown` — an interpretation is never displayed as something
a source said, and dropping the label is the only way to keep that true without
dropping the assertion. `model_id` and `usage` are recorded from the reply, so
an answer is never attributed to a model that did not produce it and a cost is
never estimated.

**What the chair is told, and what it cannot leave out.** Synthesis runs over
the results that exist. When a member is missing, the engine appends its own
`unknown` claim to the synthesis naming the seats that did not answer — written
after the model's reply is read, so a chair that wrote around the gap still
produces a labelled partial. A round with no answers at all is `failed` and
carries no synthesis. The chair may cite only the citations present in completed
member contributions retained in its prompt; unrelated or omitted source anchors
are not eligible.

**Limits are data.** `max_members_per_round`, `max_concurrent_members`,
`max_prompt_bytes`, `run_budget_seconds`, `max_rounds_per_session` and
`per_member_timeout_seconds` live on `deliberation` in the council definition,
where the schema validates them and an export carries them. A run may **narrow**
any of the four per-call limits through `run.start`'s `limits`, and never widen
one; the narrowing is stored on the run, because a round is planned from the
record and a limit that lived only in the request would be gone by the time it
mattered. `max_rounds_per_session` is the ceiling that makes "nothing loops"
more than a claim about control flow: the engine starts nothing on its own, and
a client that did could still only reach that many runs. The prompt byte limit
counts system and user text together. Optional sections and their citation
eligibility are removed together; if required sections cannot fit, the call
fails visibly before contacting the model.

Asynchronous result writes use the same schema and snapshot budget checks as
commands. A rejected result terminates the run with a visible, retryable failure,
retaining already accepted contributions. The budget check reserves the exact
failure-state representation so a full document can still record that failure.

**Superseding.** Each executing run holds a `runControl`, and its *pointer* is
the identity a landing result is checked against. A cancelled run, a document
replaced by `Load`, or a second attempt at the same seat all leave a reply with
nowhere to land. A reply that arrives after its own run left `running` is
recorded `stale` with full attribution and changes nothing else (§4.2), keeping
any failure already recorded against that seat; a reply whose control is gone is
dropped without touching the snapshot at all. Deferred commands also carry the
store's load generation: replacing a document invalidates old planning, awaits,
and outcome replies even when record IDs match. Reading an outcome and updating
its idempotency entry happen under the same lock.

---

## 6. Sources, payload size, and missing references

- A source revision is a **capture**, never an edit. Changing the material
  creates a new `source_revision`; the old one stays so a past contribution can
  still be inspected against what it actually read. Re-grounding a member is an
  explicit act — the `member.adopt_source` command — that selects a revision and
  advances `member_revision`. Nothing adopts on a member's behalf: a new capture
  appears beside the old one and every member keeps reading what it was grounded
  in until somebody says otherwise.
- **Capturing is `source.capture`, and it derives.** The caller supplies the
  text and the quotes it wants anchored; the engine computes `content_hash` and
  `byte_length` and locates each quote, refusing one that appears nowhere or
  twice. The page never computes a hash or an offset, because two implementations
  of the same derivation eventually disagree and the disagreement shows up as a
  citation pointing at the wrong sentence. `source.upsert` remains for a caller
  that has already built the record — a blob-carried payload, for instance.
- **A missing reference is repaired, not re-created.** An inventory entry
  carries the `content_hash` of the material that did not travel, so
  `source.capture` naming that revision accepts text that hashes to it, fills in
  the payload and recovers the anchor spans, and refuses anything else as
  different material that has to be captured as its own revision. That is why
  the hash lives on the source and not only inside the payload.
- **The v0.1 ceiling is the whole record.** v0.1 moves an entire snapshot across
  the host's pluginIPC hop in one message, and that hop is capped at 65536
  (`PluginWebviewBroker.gd:42`; see §1.5 for how it is measured). So the ceiling
  is not per field — it is that **every council, every session, every
  contribution and every embedded excerpt in one project must together fit in
  65536**. `InlineLimit` is 32768, half of it, and is the maximum for any single
  free-text field: contribution text, the chair's synthesis, and a captured
  source excerpt all carry that same `maxLength` in the schemas, derived from
  the one constant and asserted against it by
  `TestInlineLimitIsDerivedFromTheHostIPCCap`. No single field may fill the hop
  on its own.
- **This is a real limit, not a safety margin.** A project with a few long
  councils will reach it, and when it does the transport fails loudly rather
  than truncating. Lifting it — chunked snapshot transport, and moving source
  payloads to the host blob store so they never cross the hop — is tracked as
  work item `01a08311401f` and is the follow-up this section exists to point at.
- **Over `InlineLimit`, the intended path** is the host blob store: the record
  carries a `blob_handle` with the same hash and length. Per
  `host.documents.put_blob`, a blob is unreferenced until a `patch_state` embeds
  its `{"__blob_handle__", "content_type"}` placeholder, so a `put_blob` is
  always followed by the write that references it, or the blob lingers until the
  editor closes. v0.1 defines the shape; the follow-up above wires it.
- A source with an inventory entry but no payload is legitimate — that is what
  an import without embedded content looks like. Its citations resolve to
  "material not available", which is a state the UI shows, not an error.
- `ArtifactRef.missing` records that a note, chat or file could not be resolved
  on the last attempt. The reference is **kept**, never dropped; a missing chat
  holds replies rather than posting them somewhere else.

---

## 7. Export, import, and project switch

`contract.ExportDefinition(definition, includeContent, selected)` produces the
portable form. It:

- takes the definition only — a session has no way to be included, because
  `council_definition.schema.json` is a closed object with nowhere to put a
  question, transcript, outcome or chat id;
- **strips every `artifact` reference**, because a note id from project A is
  meaningless and leaky in project B;
- keeps the full source **inventory** — title, author, locator, capture time,
  hash, anchors — whether or not the content travels, so an import can name
  exactly what it could not find instead of presenting an ungrounded member as
  grounded;
- **includes content per source, not all-or-nothing.** `include_source_ids`
  names the sources whose captured bytes travel; absent means every source,
  present-and-empty means none. A council usually mixes material the user is
  happy to share with notes they are not, and a single switch would make the
  cautious choice cost the whole grounding. The reply reports which sources
  travelled and which were withheld, so the panel can show what is leaving the
  project rather than assert it;
- does not mutate the in-project definition, which keeps its note links.

`definition.import` names every source that arrived without content, and
`source.capture` against that revision is how the receiving project repairs one
(§6).

`TestDefinitionExportCarriesNoSessionData` asserts all of this. Its sweep is
derived from the schemas rather than from a list: every property name declared
by `session.schema.json` or `project_snapshot.schema.json` and not by
`council_definition.schema.json` or `common.schema.json` is a key an export may
not contain, so a field added to a session extends the test on its own.
`TestGroundedMemberLifecycleOverTheProtocol` runs the same claim end to end over
the live protocol, sweeping the exported bytes for project A's question, session
id, chat id, note ids and unselected material.

**Project switch.** The wrapper's snapshot belongs to the project that loaded
it. On `_on_panel_load_request` the whole snapshot is replaced and the
interruption rule runs; there is no cross-project cache to leak. A reply for a
run from the previous snapshot cannot apply: the run id is not present, and
`base_revision` will not match.

---

## 8. What is deliberately not decided here

- The command set is the minimum the state model requires. The engine (T06) may
  add commands; it may not add a second place where state lives.
- The shipped councils now live in `presets/` as ordinary `council_definition`
  records with no preset-only field and no preset loader. One directory is the
  single source: the backend embeds it for `minerva_council_presets`, and
  `ui/build.mjs` inlines the same bytes into the page so the editor can offer
  them with no round trip. Starting one is `definition.import` under a freshly
  minted `definition_id`, because the shipped id names the preset and import
  refuses an id the project already holds.
- `project_state` / `project_export` capabilities are available and unused; if a
  later version wants the backend in the project round-trip, the channels are
  declared then, not now.

---

## 9. Verification

| Gate | Command | Result |
|---|---|---|
| formatting | `gofmt -l .` (in `council/`) | clean |
| static analysis | `GOWORK=off go vet ./...` | clean |
| build | `go build ./...` (in `council/`) | clean |
| contract tests | `GOWORK=off go test ./internal/contract/` | over 10 valid and 20 invalid fixtures (the populated `.mcouncil` is one of them) |
| GDScript syntax | `godot --headless --check-only -s <file>` on every `ui/*.gd` | clean |
| panel suite | `council/scripts/run-gd-tests.sh <minerva>` | authored, never executed — see `tests/gd/EXPECTED_SUITES` |
| chat provider | `GOWORK=off go test -run TestCouncilAnswersAsAChatProvider ./` | authored, not executed in the task that wrote it |
| persistence, migration, recovery | `go test -run 'Migrated\|MidRun\|ClosedMidRun\|AnotherProjectAfterARestart\|CannotBeResolved' ./` | authored, not executed in the task that wrote it |

`council` is a `use` entry in the repo's `go.work`, so Go commands there need
no `GOWORK=off`.

Still not verified by any of the above: that the panel actually renders in a
live CEF surface, that a real Minerva install mounts it, and that the tabs,
menus and keyboard around it keep working. None of that is reachable from a
task that must not launch Minerva. `docs/t03-live-check.md` is the checklist for
doing it on the owner's machine, and it is the gate this document's §1 answer
finally rests on.
