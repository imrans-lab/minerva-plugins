# Council

A council of grounded perspectives inside Minerva. You assemble a small group —
a chair plus a few advisors, some of them grounded in your own notes — ask it a
question from an ordinary Minerva chat, and read every member's argument, with
its sources, in the Council editor.

The chat answers with the chair's synthesis. The individually attributed
contributions live in the editor: Council is one chat provider, not native
multi-participant chat, and it invites nobody.

Once it is installed, the help you need day to day is in the panel itself —
**Help** in the footer. This file is the part you need before the panel opens.

---

## Requirements

| | |
|---|---|
| Host | Minerva with plugin support and a CEF-backed webview (the panel is an embedded HTML surface rendered by the host's CEF integration; Minerva must have started CEF successfully). |
| Platform | Linux x86_64. That is the only target this version has been verified on and the only one `release_targets` declares. Nothing here claims macOS or Windows support. |
| Models | At least one provider enabled in Minerva with at least one model. Council calls models only through the host — it opens no network connection of its own (`permissions.network.mode` is `none`). |
| Filesystem | None. Council declares `filesystem.mode: none`; documents reach it through Minerva's own save and load. |

## Install

**From the marketplace.** Install Council from Minerva's plugin marketplace and
start it. The archive carries a prebuilt `council-plugin` binary, the panel page
and the scene files; no source checkout, no Go and no Node are needed.

**From source (development lane).** Point Minerva's manifest-lane install at
this directory. The manifest's `setup` stanza runs `go build` for you and
produces `council-plugin` beside the manifest, so Go 1.22 or newer must be on
your PATH. To build it yourself:

```bash
cd council
go build -o council-plugin .
```

The panel page `ui/panel.html` is generated from `ui/src` and the shipped
councils in `presets/`. It is committed, so a user never builds it; when you
change a source, rebuild and verify:

```bash
node ui/build.mjs           # rewrite ui/panel.html and the replay harness
node ui/build.mjs --check   # fail if the committed page has drifted
```

The build is a concatenation — no dependencies, no network, no toolchain.

## Set up models

Council never falls back to Minerva's "default" model route. Every call names a
model explicitly, and a member with no `model_hint` is consulted with the FIRST
entry of the host's enabled catalogue — alphabetically first model of the
alphabetically first provider. That choice costs money and sets the answer's
quality, so:

1. Enable the providers and models you want in Minerva's settings.
2. Call `minerva_council_models` (or open a member in the panel) to see exactly
   what Council can offer. The list holds the providers Minerva manages
   dynamically and TurnRock/Core's live service actions; a built-in model that
   is callable elsewhere and absent here is one Council will refuse.
3. Give each member an explicit model, in the panel or as `model_hint`.

A hint the host does not have is refused **before** the round spends anything;
it is never silently substituted.

### Free local models

Models that Minerva runs through TurnRock/Core appear in the same list, under
the `turnrock` provider, as one entry per Core action — a `model-chat` action
running Qwen is listed and chosen exactly like a hosted model. They cost
nothing to ask, and Council calls them by the structured identifier the host
listed them with, so an action is reached even when two Core services offer one
of the same name.

They are slow to start. A local model that is not resident can spend **minutes**
loading before its first token, so a council of local models needs a longer
per-member time limit than a council of hosted ones. The limit is
`per_member_timeout_seconds` in the council's deliberation rules, editable on
the panel's Members pane; the shipped councils set it to 300 seconds, with a run
budget sized to leave one spare allowance so a slow round is stopped by the
member that ran out of time rather than by the round's own ceiling. A member
that runs out of time is recorded as timed out and the round is reported
partial — nothing retries on its own.

## Shipped councils

`presets/` holds three ordinary `council_definition` records:

| File | What it is |
|---|---|
| `decision_review.json` | **Decision Review** — a functional business council: unit economics, delivery risk, customer evidence, and a human seat for your own observed facts. |
| `second_opinion.json` | **Second Opinion** — general purpose: the case for, the case against, and what would have to be true. |
| `grounded_example.json` | **Source-Grounded Example** — one simulant grounded in a short essay written for this example, so the grounding and citation mechanism can be read before it is trusted. |

They are starting points, not advice, and nothing about them is special once
imported. None of them represents, quotes or implies the endorsement of any real
person; the example essay's "author" is unnamed and fictional, and the record
says so where a reader will see it.

Two ways to start one:

- **In the editor** — open a Council tab in an empty project; Members offers
  them.
- **Through MCP** — `minerva_council_presets` returns each record, and
  `minerva_council_command` with `definition.import` brings one in. Give the
  copy a fresh `definition_id` first: `definition.import` refuses an id the
  project already holds, which is what stops an import from quietly overwriting
  a council you have edited.

**Where a chat or MCP answer ends up:** the backend applies every mutation, and
it announces each one as `council.record_changed` with the document's
`project_id` and its new revision. The panel that holds that document reads the
snapshot back through its own exchange, marks the tab changed, and saves what the
engine holds — so a round driven entirely from chat is in the file the tab
writes. A panel showing a different council ignores the announcement. If the
backend cannot be reached when the panel goes to read it back, the panel says so
on screen and at save: what is written is the copy it holds, and the newest
results are still in the running backend rather than lost.

## Asking from chat

A consultation lives in a Minerva chat with Council chosen as its provider. Most
turns are ordinary questions; four lines are read as instructions to Council
itself.

| Line | What it does |
|---|---|
| `/council <definition_id>` | Picks which council takes the question, when the project holds more than one. Council offers this as a choice; clicking one sends the line. |
| `/council-session <session_id>` | Points this chat at a consultation that already exists. A chat has exactly one session, so this MOVES the binding. |
| `/ask <member> <question>` | Asks one member alone, by display name, seat id, or the id of a claim they made. The reply is the chair's revised synthesis, and it says who was consulted. Nobody else on the bench is re-asked. |
| `/bench` | Lists the latest round's members with their model, their claims labelled source / inference / unknown, and each one's status. It reads the record and consults nobody. |

A name that matches no member, or two, is refused with the list of seats —
Council does not guess which member you meant. A seat held by a human member is
the local user's own, and no round ever puts words in it.

## The tool surface

Nine tools. Five answer a caller; four belong to the host and the panel and are
listed so that calling one by mistake is a decision rather than an accident.

| Tool | |
|---|---|
| `minerva_council_command` | The one door to the protocol. Its arguments *are* the request envelope: `{request_id, command, base_revision, payload}`. Mutating commands carry `base_revision`; reads must not. |
| `minerva_council_presets` | The shipped councils, ready to hand to `definition.import`. |
| `minerva_council_models` | Minerva's enabled models, as Council sees them. |
| `minerva_council_status` | What the loaded document holds, without moving it. |
| `minerva_council_ping` | Liveness, version and the current `snapshot_revision`. |
| `minerva_council_chat_generate` | **The host calls this**, once per chat turn, when Council is the chat's provider. Not a tool to call by hand. |
| `minerva_council_chat_cancel` | **The host calls this** when a user stops a turn. |
| `minerva_council_load_snapshot` | **The panel's own seeding hook.** The Council tab owns the document and hands it to the backend with this. Calling it by hand replaces what the open panel is working on. |
| `minerva_council_export_snapshot` | **The panel's own persistence hook.** Returns the acknowledged snapshot for the host to write into the project or a `.mcouncil` file. |

The commands `minerva_council_command` carries are listed with their payloads in
`docs/architecture.md` §5; `minerva_council_command`'s own description is the
short version.

## Privacy: what leaves the project when you export a council

`definition.export` produces the portable half of a council and nothing else.

**It cannot carry** a question, a transcript, a contribution, an outcome, a note
id or a chat id — `council_definition.schema.json` is a closed object with
nowhere to put one, and every note, chat and file reference is stripped on the
way out.

**It always carries** the source *inventory*: each source's title, author,
locator, capture time, content hash and anchor quotes. That is deliberate — an
import that hid what it could not find would present an ungrounded member as
grounded — but it means the titles and quoted spans of your material travel even
when the material does not.

**It carries source material only where you say so.** `include_content` plus
`include_source_ids` chooses per source; omitting the list means every source,
an empty list means none. The reply names which sources travelled and which were
withheld, so what is leaving the project is reported rather than assumed.

An exported file is therefore as private as the sources you selected and the
titles and quotes of the ones you did not. Read the reply before you send one.

## Troubleshooting

**The plugin will not start.** Check `minerva_plugin_list` for its state. On the
manifest lane a missing Go toolchain leaves it in `BUILD_FAILED` or
`NEEDS_BINARY`; `minerva_plugin_build_status` carries the structured failure.
Probe a running backend with `minerva_council_ping`.

**Council is not offered as a chat provider.** The entry is registered after the
backend initialises, and re-registered when the plugin restarts. Restart the
plugin, then reopen the chat's provider list. Note that a plugin reload does not
refresh the host's MCP tool registry — reconnect MCP if the tools are missing
too.

**A member has no models to choose from.** Council offers Minerva's dynamically
managed enabled models and TurnRock/Core's service actions. A fresh Minerva
profile has every provider disabled; enable one, then call
`minerva_council_models` to re-read the catalogue. Core's actions appear only
once Core is connected and its services have been fetched.

**A local model times out every round.** It is loading, not stuck. Raise the
per-member time limit on the Members pane — and raise `run_budget_seconds` with
it, since that is the ceiling that stops the whole round. The pane STATES the
budget but does not edit it: change it with a `definition.upsert` carrying the
whole council, or by editing an exported council and importing it back. Or ask
the model once outside Council so it is resident before the round starts.

**A question in chat opened a new session instead of continuing.** A chat is
bound to a session in the document it was first asked in. If that document has
not been opened since the plugin started, Council has no record of the binding
and starts fresh in whatever document is loaded. Open the project the
consultation lives in before asking again; the original session is untouched.

**A round is stuck.** Nothing resumes or retries on its own. Cancel it, or read
it with `run.await`; a run reaches a resting state on its own budget regardless.
A run interrupted by a restart is demoted to a visible failed state with an
explicit retry.

**`/ask` says it cannot place a name.** Names are matched against each seat's
display name, its seat id and its member id — and against the id of any claim
made in the session. `/bench` prints the name and seat id of the seats that
answered the latest round; a name two members answer to has to be resolved by
seat id.

**Saving fails on a large project.** v0.1 moves the whole document across the
host's plugin IPC hop in one message, so every council, session, contribution
and embedded excerpt must fit in it together. The hop holds about 64 KiB as the
host counts it — the cap is 65536 UTF-16 code units of the serialised request,
so non-ASCII text costs more than its byte length, and Council budgets half of
it for any single field. It fails loudly rather than truncating. Trim embedded source material, or split the work across
projects.

**The panel shows "this document is not one Council can edit."** The file was
not a Council document. It is kept exactly as found and handed back unchanged on
save; nothing is overwritten.

## Licences

- **Code, schemas and documentation:** the repository `LICENSE.md`.
- **Presets and the example essay** (`presets/*.json`): written for Council and
  covered by the same licence. The essay is original text by no real author.
- **Fonts:** none are bundled. The page uses the reader's own system faces
  through CSS stacks (`ui/src/styles/reading-room.css`), so there is no font
  licence to carry.
- **Icons:** none are bundled. Every affordance in the panel is text.
- **Third-party code:** none. The backend has no dependency outside the Go
  standard library, and the page loads nothing at runtime — no CDN, no network,
  no font service.

## Where things are

| Path | What |
|---|---|
| `docs/architecture.md` | The contracts: records, ownership, state machines, the page↔wrapper protocol, limits. |
| `docs/t03-live-check.md` | The human checklist for verifying a live install. **Checkout only** — not in the installed plugin. |
| `docs/release-packaging.md` | What the marketplace archive holds, and the tag/release/registry order. **Checkout only** — not in the installed plugin. |
| `presets/` | The shipped councils. One source, used by both the backend and the page. |
| `schemas/` | The record schemas. The backend validates against these, embedded. |
| `ui/src/` | The panel's maintainable sources. `ui/panel.html` is generated from them. |
| `ui/tests/` | The recorded-envelope harness and the page self-test. |
