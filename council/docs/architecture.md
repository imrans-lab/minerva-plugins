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
(`Editor.gd:1711`), mark-saved (`Editor.gd:2072`), create-note
(`Editor.gd:2226`), note refresh (`Editor.gd:2434`), chat-inject toggle
(`Editor.gd:2493`), unload (`Editor.gd:748`), undo (`Editor.gd:2167`), project
serialize (`src/Scripts/UI/Controls/vboxEditor.gd:164`, `:494`) and project restore
(`vboxEditor.gd:769`).

What a WEBVIEW editor does instead is the damaging part:

- **Save writes the page, not the state.** `Editor.gd:1697` opens the target
  file and stores `webview_editor.get_html()`. A user who presses Ctrl+S on a
  Council HTML panel would save the markup and lose the council.
- **A note captures the page, not the state.** `Editor.gd:1807` builds
  `Note.create_html_note(tab_title, html)`; `Editor.gd:2427` refreshes it with
  `note.linked_html = html`.
- **Project serialize emits no panel state.** Only the `PLUGIN_SCENE` branch of
  `vboxEditor.serialize()` writes a `plugin_state` / `__panel_state` entry
  (`vboxEditor.gd:495-497`, `:521-527`).

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

`council/proof/` is that proof: manifest, scene, wrapper script, injected
bridge, a page that exercises the protocol, and a near-empty backend so the
plugin is installable. Both scripts pass `godot --headless --check-only`.

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
  `cef_bridge.gd:132-160`) into the unauthenticated MCP HTTP server
  (`src/Scripts/Services/MCP/MinervaMCPHttpServer.gd:12`), bypassing the
  manifest allowlist and the capability policy. Council's page must never use
  it; the wrapper injects its own bridge and the page reaches nothing else.
- **`plugin_owned` save is unimplemented** — `Editor.gd:1714-1721` warns and
  writes nothing. Council uses `host_owned`.
- **`invoke_restore_from_note` is not awaited** (`Note.gd:733`), unlike
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
| `snapshot_revision` | the wrapper (native panel) | any accepted mutation | every request's `base_revision`, every reply |
| `definition_id` + `definition_revision` | the wrapper | a council's members, seats, sources or rules change | exports; a session's embedded snapshot |
| `member_id` + `member_revision` | the wrapper | scope, limitations or grounding change | every contribution, so an old answer is never re-attributed |
| `source_id` + `source_revision` | the wrapper | new material is captured — never an edit in place | grounding refs and citations |
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

Enforced in `internal/contract/invariants.go` and exercised by the sixteen
records in `fixtures/invalid/`:

- A council has **exactly one chair**.
- Every seat names a member that exists; every grounding ref names a
  `source_id` at a `source_revision` that exists.
- Ids are unique within their scope; anchors are unique within a source
  revision.
- A captured payload still hashes to its `content_hash` and matches its
  `byte_length`; an anchor's `[start, end)` really contains its quote.
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

---

## 3. Who owns what

This is the table the acceptance criterion asks for. "Durable" means it
survives Minerva restarting.

| State | Owner | Where it lives | Durable | Rebuilt from |
|---|---|---|---|---|
| Council definitions, sessions, runs, contributions, outcomes, source captures | **native wrapper** | `_snapshot` in the panel; written into the project by `vboxEditor.gd:495-497` as `__panel_state`, and to a `.mcouncil` file by `Editor.gd:1711-1760` | yes | — it *is* the source |
| `snapshot_revision` | native wrapper | same | yes | — |
| In-flight model calls, per-member timers, cancellation tokens | **plugin backend** | backend process memory | **no** | not rebuilt: an interrupted run is demoted, never resumed (§4.3) |
| Rendered roster, open pane, scroll position, in-progress typing | **page (CEF)** | JS heap | no | re-read via `snapshot.get` |
| Last selected session / pane | native wrapper | `snapshot.view` | yes | defaults if absent |
| User/chair transcript | **Minerva chat** | the native chat history | yes | referenced by `chat_binding`, never copied |
| Retained conclusions | **Minerva notes** | native notes | yes | referenced by `outcome.note` |
| Panel reopen payload | Minerva notes | a `plugin_data` note's `linked_plugin_payload` (`Note.gd:363-369`) | yes | the snapshot it was made from |
| Source material larger than `InlineLimit` | host blob store | `(editor_name, "blob-N")`, referenced by `blob_handle` | yes, with the document | — |

Three rules follow, and they are the ones that keep the model honest:

1. **The page is a view.** It never holds state that is not in the snapshot or
   in flight. A page reload loses nothing.
2. **The backend is derived.** Anything it holds that must outlive the process
   has already been written into the snapshot.
3. **Nothing is shown as saved before it is in the snapshot.** The backend
   applies a mutation, advances `snapshot_revision` and replies; the wrapper
   persists the snapshot it gets back and emits `content_changed` (which marks
   the tab dirty at `Editor.gd:2095-2096`). The reply carries the new revision,
   which is what the page renders.

### 3.1 Why `__panel_state` and not `project_state`

Minerva has two project-persistence lanes. The `project_state` capability with
`project_file: {serialize_channel, deserialize_channel}` routes through the
backend over MCP. The other lane is unconditional: `vboxEditor.gd:495-497` calls
`panel_root._on_panel_save_request()` **directly** and stores the result under
`tab_state["__panel_state"]`, in all three of its paths — no MCP channel, plugin
dead, or MCP success. Restore mirrors it at `vboxEditor.gd:769-784`, calling
`_on_panel_load_request(panel_state)` **before** any MCP dispatch.

Council v0.1 uses the unconditional lane only. It works when the backend is
stopped or crashed, which is exactly when a user most needs their council to
still be there, and it removes a whole class of failure from the persistence
path. `project_state` remains available if a later version needs the backend to
participate in project save.

---

## 4. State machines

### 4.1 Session

```
        create                    run.start
draft ─────────────► draft ─────────────────► running
                                                 │
              all members answered + synthesised │──► complete
              some member failed / cancelled     │──► partial
              user cancelled                     │──► cancelled
              round could not start              │──► failed
```

`complete`, `partial`, `cancelled` and `failed` are all resting states from
which `run.start` (a follow-up or a retry) moves back to `running`. Reopening a
session never changes its status by itself — except for the interruption rule
below.

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
or Minerva exited is **not resumed**. The process that owned those model calls
is gone. On load, `contract.RehydrateOnLoad` (and its mirror in the wrapper)
demotes the run and its unfinished contributions to `failed` with
`code: "interrupted"`, `retryable: true`, and moves a `running` session to
`partial`. The user sees a visible failure with an explicit retry; nothing
spends tokens on its own. Applying the rule twice changes nothing.

---

## 5. Concrete APIs

### 5.1 Panel lifecycle — the hooks Council implements

All are duck-typed with `has_method` by `PluginScenePanelHost`; the signatures
are exact.

| Hook | Council's contract | Error case |
|---|---|---|
| `_on_panel_loaded(ctx: Dictionary) -> void` | mounts the CEF surface from `ctx.data_directory`; `ctx` shape at `PluginScenePanelHost.gd:657-685` | `CefTexture` missing, page file missing, `user://` unwritable → an explanatory label, never a blank panel |
| `_on_panel_save_request() -> Dictionary` | returns the snapshot verbatim | none: it cannot fail. A non-Dictionary return is refused by the host at `Editor.gd:1730` |
| `_on_panel_load_request(document) -> void` | replaces the snapshot, applies the interruption rule, tells the page | non-Dictionary → ignored, panel keeps its current state |
| `_on_panel_create_note_request(ctx) -> Dictionary` | `{kind: "plugin_data", plugin_id, panel_name, payload: <snapshot>, preview_alt_text: <one line>}`; accepted shapes at `Editor.gd:2298-2334` | omitting the hook degrades to a screenshot note (`Editor.gd:2286`). The host backfills a missing preview image (`Editor.gd:2270-2275`) |
| `_on_panel_restore_from_note(payload: Dictionary) -> bool` | `false` unless `record_kind == "council_project_snapshot"` and `schema_version == 1` | `false` → the host toasts and leaves the panel blank (`Note.gd:733`). Must not be a coroutine |
| `_on_panel_render_for_llm(ctx) -> Array` | one `{"type":"text","text":…}` part | **no production caller today** — implemented for the day there is one |
| `receive(channel: String, payload: Dictionary) -> void` | raw event name, or the literal `"state"` | unknown channel → forwarded to the page as an event; the page re-reads |
| `_on_panel_unload() -> void` | disconnects `ipc_message`, removes the staged page file | none |
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
  `session.create`, `session.bind_chat`, `run.start`, `run.cancel`, `run.retry`,
  `outcome.retain`) **must** carry `base_revision`; read commands
  (`snapshot.get`, `source.fetch`, `definition.export`) must not.
- `base_revision != snapshot_revision` → `ok: false`, error `stale_revision`,
  `retryable: true`, and the reply carries the current revision so the page can
  re-read.
- A repeated `request_id` returns the stored reply with `replayed: true`. The
  command is applied once.
- Every reply carries the `snapshot_revision` it was produced against.
- An event never carries authority. It says the snapshot moved; the page
  re-reads what it needs.
- A message over `InlineLimit` (32768) is refused rather than truncated.

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

The other direction — bringing a question and selected context *to* Council from
elsewhere — is an MCP tool on Council's backend taking an explicit `session_id`
(or creating one and returning it). Never an implicit destination.

### 5.4 Retaining an outcome as a note

Two notes, two jobs, and the distinction matters:

- **The outcome note** is a normal text note holding the conclusion and its
  provenance. It is what the user keeps and what reaches a later chat turn as
  text. `outcome.note` points at it.
- **The reopen note** is the `plugin_data` note produced by
  `_on_panel_create_note_request`. Its purpose is to reopen the panel
  (`Note.gd:684-733`).

The split exists because of a measured limitation: a `plugin_data` note is built
with `NoteImageControls` (`Note.gd:349`, `:357`), so what a provider sees is the
preview image plus a **single-line caption** (`image_controls.gd:64`; the
caption reaches a prompt via the image-caption path, e.g.
`GoogleProvider.gd:305-312`). That is enough to say *which* council session this
is, and nowhere near enough for a deliberation. Council therefore puts the
substance in a text note and uses the caption to identify the session.

If Minerva later wires `invoke_render_for_llm` into the chat-injection path,
Council's existing hook supplies the full text with no plugin change.

---

## 6. Sources, payload size, and missing references

- A source revision is a **capture**, never an edit. Changing the material
  creates a new `source_revision`; the old one stays so a past contribution can
  still be inspected against what it actually read. Re-grounding a member is an
  explicit act that selects new revisions and advances `member_revision`.
- **Under `InlineLimit` (32768):** the content travels inline, and its
  `byte_length` and `content_hash` are checked on every validation.
- **Over it:** the content goes to the host blob store and the record carries a
  `blob_handle` with the same hash and length. Per `host.documents.put_blob`, a
  blob is unreferenced until a `patch_state` embeds its
  `{"__blob_handle__", "content_type"}` placeholder, so a `put_blob` is always
  followed by the write that references it, or the blob lingers until the editor
  closes.
- A source with an inventory entry but no payload is legitimate — that is what
  an import without embedded content looks like. Its citations resolve to
  "material not available", which is a state the UI shows, not an error.
- `ArtifactRef.missing` records that a note, chat or file could not be resolved
  on the last attempt. The reference is **kept**, never dropped; a missing chat
  holds replies rather than posting them somewhere else.

---

## 7. Export, import, and project switch

`contract.ExportDefinition(definition, includeContent)` produces the portable
form. It:

- takes the definition only — a session has no way to be included, because
  `council_definition.schema.json` is a closed object with nowhere to put a
  question, transcript, outcome or chat id;
- **strips every `artifact` reference**, because a note id from project A is
  meaningless and leaky in project B;
- keeps the full source **inventory** — title, author, locator, capture time,
  hash, anchors — whether or not the content travels, so an import can name
  exactly what it could not find instead of presenting an ungrounded member as
  grounded;
- does not mutate the in-project definition, which keeps its note links.

`TestDefinitionExportCarriesNoSessionData` asserts all of this, including a
field-name sweep for every session-side key.

**Project switch.** The wrapper's snapshot belongs to the project that loaded
it. On `_on_panel_load_request` the whole snapshot is replaced and the
interruption rule runs; there is no cross-project cache to leak. A reply for a
run from the previous snapshot cannot apply: the run id is not present, and
`base_revision` will not match.

---

## 8. What is deliberately not decided here

- The command set is the minimum the state model requires. The engine (T06) may
  add commands; it may not add a second place where state lives.
- The presets and the production visual design are T02 / T08 / T10.
- `project_state` / `project_export` capabilities are available and unused; if a
  later version wants the backend in the project round-trip, the channels are
  declared then, not now.

---

## 9. Verification

| Gate | Command | Result |
|---|---|---|
| formatting | `gofmt -l .` (in `council/`) | clean |
| static analysis | `GOWORK=off go vet ./...` | clean |
| build | `GOWORK=off go build ./...` (in `council/` and `council/proof/`) | clean |
| contract tests | `GOWORK=off go test ./internal/contract/` | 5 tests, over 6 valid and 16 invalid fixtures |
| GDScript syntax | `godot --headless --check-only -s <file>` on both wrapper scripts | clean |

`council/` is outside the repo's `go.work`, so Go commands there need
`GOWORK=off` (or a `use ./council` entry once the plugin is added to the
workspace).

Not verified here, and honestly out of reach for a task that may not launch
Minerva: that the wrapper actually renders in a live CEF panel. That is T03's
first job, and `council/proof/` exists so it can be done by installing one
directory.
